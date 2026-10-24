"""50k 拼音通道 reconcile 逐语句耗时拆解（docs/13 §七 P3 收尾）。

对着 operation_probe 真实产出的 50k 库（未加密 SQLite），逐条测量
`search_pinyin::reconcile` 的 6 条语句，并验证 `NOT IN` → `NOT EXISTS` 改写收益。

注意：只在探针产出的一次性库上运行——为测真实写路径成本会实际执行 DELETE
（正常库上无幽灵行可删，故幂等，但绝不要指向用户数据库）。

用法：
  python perf-metrics/pinyin-reconcile-cost.py <probe.db> [samples]
"""

import sqlite3
import statistics
import sys
import time

DB = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\wait\AppData\Local\Temp\orbit-probe-50k\global-search.db"
SAMPLES = int(sys.argv[2]) if len(sys.argv) > 2 else 15

KINDS = [
    ("task", "todo_tasks", "title"),
    ("project", "todo_projects", "title"),
    ("comment", "todo_comments", "content"),
]


def timeit(conn, sql, params=(), samples=SAMPLES, label=""):
    lat = []
    rows = 0
    for _ in range(samples):
        t = time.perf_counter()
        cur = conn.execute(sql, params)
        rows = len(cur.fetchall()) if cur.description else cur.rowcount
        lat.append((time.perf_counter() - t) * 1000)
    lat.sort()
    p50 = round(statistics.median(lat), 2)
    p95 = round(lat[min(len(lat) - 1, int(round(0.95 * (len(lat) - 1))))], 2)
    print(f"  {label:<46} p50={p50:8.2f}ms p95={p95:8.2f}ms")
    return p50


def main():
    conn = sqlite3.connect(DB, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")

    n_py = conn.execute("SELECT count(*) FROM search_pinyin").fetchone()[0]
    n_tasks = conn.execute("SELECT count(*) FROM todo_tasks").fetchone()[0]
    print(f"search_pinyin={n_py}  todo_tasks={n_tasks}")

    print("\n[1] 步骤①：清幽灵（NOT IN 全扫）")
    total_ghost = 0.0
    for kind, table, _ in KINDS:
        sql = (
            f"DELETE FROM search_pinyin WHERE kind = '{kind}' AND uuid NOT IN "
            f"(SELECT uuid FROM {table} WHERE is_deleted = 0)"
        )
        total_ghost += timeit(conn, sql, label=f"DELETE NOT IN  {kind}")

    print("\n[1b] 同上改写为 NOT EXISTS")
    total_exists = 0.0
    for kind, table, _ in KINDS:
        sql = (
            f"DELETE FROM search_pinyin WHERE kind = '{kind}' AND NOT EXISTS "
            f"(SELECT 1 FROM {table} t WHERE t.uuid = search_pinyin.uuid AND t.is_deleted = 0)"
        )
        total_exists += timeit(conn, sql, label=f"DELETE NOT EXISTS {kind}")
    print(f"  --> 步骤① 合计：NOT IN {total_ghost:.1f}ms  vs  NOT EXISTS {total_exists:.1f}ms")

    print("\n[2] 步骤②：补缺失/更新不一致（LEFT JOIN + title 比对）")
    total_join = 0.0
    for kind, table, column in KINDS:
        sql = (
            f"SELECT t.uuid, t.{column} FROM {table} t "
            f"LEFT JOIN search_pinyin s ON s.kind = '{kind}' AND s.uuid = t.uuid "
            f"WHERE t.is_deleted = 0 AND (s.uuid IS NULL OR s.title != t.{column})"
        )
        total_join += timeit(conn, sql, label=f"LEFT JOIN {kind}")

    print("\n[3] 参考：拼音命中查询本身")
    for label, sql, params in [
        ("search_hits initials 前缀", "SELECT uuid FROM search_pinyin WHERE kind=? AND (initials LIKE ? OR pinyin_full LIKE ?) LIMIT ?", ("task", "cztc%", "%cztc%", 40)),
        ("FTS 唯一短语", "SELECT ref_uuid FROM fts_todo WHERE fts_todo MATCH ? LIMIT 20", ('"操作探针任务 025000"',)),
        ("FTS 宽词", "SELECT ref_uuid FROM fts_todo WHERE fts_todo MATCH ? LIMIT 20", ('"操作探针"',)),
    ]:
        timeit(conn, sql, params, label=label)

    print("\n[4] 计划：NOT IN 的查询计划")
    for row in conn.execute(
        "EXPLAIN QUERY PLAN DELETE FROM search_pinyin WHERE kind = 'task' AND uuid NOT IN "
        "(SELECT uuid FROM todo_tasks WHERE is_deleted = 0)"
    ):
        print("   ", row)

    print("\n[5] 计划：search_hits LIKE 的查询计划")
    for row in conn.execute(
        "EXPLAIN QUERY PLAN SELECT uuid FROM search_pinyin WHERE kind=? AND (initials LIKE ? OR pinyin_full LIKE ?) LIMIT ?",
        ("task", "cztc%", "%cztc%", 40),
    ):
        print("   ", row)

    conn.close()


if __name__ == "__main__":
    main()
