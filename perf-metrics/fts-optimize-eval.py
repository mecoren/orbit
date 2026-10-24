#!/usr/bin/env python3
"""FTS5 `optimize` / `merge` 时机评估（docs/13 §七 P3 第二项）。

背景：`orbit-core` 的 `fts_todo` 是 external-content 的 trigram 索引，写路径经
触发器同步。批量写入（CSV 导入）与高频更新（同步合并）都会在索引里留下大量
小段，旧段只标记删除、空间由 `optimize` 才真正回收。P3 要求评估「大数据导入
后执行 optimize/merge 的时机」，本脚本给出实测依据。

复刻口径与迁移 0001 一致（6 列 + `tokenize='trigram'`），四组状态：

  A insert-only   模拟导入：每 200 行一个事务写入 N 行
  B A + optimize
  C B + 30% 行 UPDATE（FTS5 的 UPDATE = 删旧段 + 插新段，旧段只标记）
  D C + optimize

每组测唯一短语 / 宽词两口径的 p50/p95、库体积、段行数（`fts_todo_data` 行数）。
只测 FTS 通道：拼音走派生的 `search_pinyin` 表、<3 字短词走 LIKE 兜底，均不经过
`fts_todo`，不在本评估范围内。

用法：
  python perf-metrics/fts-optimize-eval.py                       # 10k + 50k，30 次采样
  python perf-metrics/fts-optimize-eval.py --rows 10000 --samples 10
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import statistics
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNS = ROOT / "perf-metrics" / ".runs"

SCHEMA = """
CREATE VIRTUAL TABLE fts_todo USING fts5(
  kind,
  ref_id UNINDEXED,
  ref_uuid UNINDEXED,
  task_id UNINDEXED,
  title,
  body,
  tokenize='trigram'
)
"""

# 与 operation_probe 的 seed_tasks 同构：标题带 6 位序号（唯一短语命中 1 行），
# 「操作探针」是宽词（命中全表后由 limit 截断）
TITLE = "操作探针任务 {i:06d}"
BROAD = "操作探针"
BODY = "这是一段用于评估全文索引体积与查询延迟的中文描述文本"


def make_db(path: Path) -> sqlite3.Connection:
    if path.exists():
        path.unlink()
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(SCHEMA)
    return conn


def insert_rows(conn: sqlite3.Connection, start: int, count: int, body_repeat: int) -> None:
    """按导入节奏分批提交（每 200 行一个事务，模拟 CSV 导入的批量写）。"""
    body = BODY * max(1, body_repeat)
    batch = 200
    for offset in range(0, count, batch):
        rows = [
            ("task", i, f"uuid-{i:06d}", i, TITLE.format(i=i), body)
            for i in range(start + offset, min(start + offset + batch, start + count))
        ]
        conn.executemany(
            "INSERT INTO fts_todo(kind, ref_id, ref_uuid, task_id, title, body) "
            "VALUES (?,?,?,?,?,?)",
            rows,
        )
        conn.commit()


def update_rows(conn: sqlite3.Connection, count: int, ratio: float) -> int:
    """模拟同步合并/编辑：UPDATE 在 FTS5 内部是删旧段 + 插新段。"""
    step = max(1, int(1 / ratio))
    touched = 0
    batch = 200
    pending: list[tuple[str, int]] = []
    for i in range(0, count, step):
        pending.append((f"操作探针任务 {i:06d}（已编辑）", i))
        touched += 1
        if len(pending) >= batch:
            _apply_updates(conn, pending)
            pending.clear()
    if pending:
        _apply_updates(conn, pending)
    conn.commit()
    return touched


def _apply_updates(conn: sqlite3.Connection, pending: list[tuple[str, int]]) -> None:
    for title, i in pending:
        conn.execute("DELETE FROM fts_todo WHERE ref_uuid = ?", (f"uuid-{i:06d}",))
        conn.execute(
            "INSERT INTO fts_todo(kind, ref_id, ref_uuid, task_id, title, body) "
            "VALUES ('task', ?, ?, ?, ?, ?)",
            (i, f"uuid-{i:06d}", i, title, BODY),
        )
    conn.commit()


def optimize(conn: sqlite3.Connection) -> float:
    started = time.perf_counter()
    conn.execute("INSERT INTO fts_todo(fts_todo) VALUES('optimize')")
    conn.commit()
    return (time.perf_counter() - started) * 1000


def seg_rows(conn: sqlite3.Connection) -> dict:
    """段结构：data 表每个 B-tree 页一行，idx 表是段索引；两者数量随段数增长。"""
    out = {}
    for table in ("fts_todo_data", "fts_todo_idx"):
        try:
            out[table] = conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
        except sqlite3.OperationalError:
            out[table] = -1
    return out


def measure(conn: sqlite3.Connection, sql: str, params: tuple, samples: int) -> dict:
    lat: list[float] = []
    for _ in range(samples):
        started = time.perf_counter()
        conn.execute(sql, params).fetchall()
        lat.append((time.perf_counter() - started) * 1000)
    lat.sort()
    return {
        "p50Ms": round(statistics.median(lat), 2),
        "p95Ms": round(lat[min(len(lat) - 1, int(round(0.95 * (len(lat) - 1))))], 2),
    }


def snapshot(conn: sqlite3.Connection, path: Path, rows: int, samples: int) -> dict:
    # 先把 WAL 落回主库再量体积，否则 optimize 产生的 WAL 会被算成「体积增长」
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    unique = measure(
        conn,
        "SELECT ref_uuid FROM fts_todo WHERE fts_todo MATCH ? LIMIT 20",
        (f'"{TITLE.format(i=rows // 2)}"',),
        samples,
    )
    broad = measure(
        conn,
        "SELECT ref_uuid FROM fts_todo WHERE fts_todo MATCH ? LIMIT 20",
        (f'"{BROAD}"',),
        samples,
    )
    return {
        "uniqueP50Ms": unique["p50Ms"],
        "uniqueP95Ms": unique["p95Ms"],
        "broadP50Ms": broad["p50Ms"],
        "broadP95Ms": broad["p95Ms"],
        "dbMB": round(sum(p.stat().st_size for p in path.parent.glob(path.name + "*")) / 1048576, 2),
        "segRows": seg_rows(conn),
    }


def run_case(rows: int, samples: int, body_repeat: int) -> dict:
    path = RUNS / f"fts-eval-{rows}.db"
    conn = make_db(path)
    insert_rows(conn, 0, rows, body_repeat)
    after_insert = snapshot(conn, path, rows, samples)

    optimize_ms = optimize(conn)
    after_opt = snapshot(conn, path, rows, samples)

    touched = update_rows(conn, rows, 0.3)
    after_update = snapshot(conn, path, rows, samples)

    optimize_ms_2 = optimize(conn)
    after_opt_2 = snapshot(conn, path, rows, samples)

    conn.close()
    for suffix in ("", "-wal", "-shm"):
        stale = Path(str(path) + suffix)
        if stale.exists():
            stale.unlink()

    return {
        "rows": rows,
        "updatedRows": touched,
        "samples": samples,
        "bodyRepeat": body_repeat,
        "optimizeMs": round(optimize_ms, 2),
        "optimizeAfterUpdateMs": round(optimize_ms_2, 2),
        "stages": {
            "insertOnly": after_insert,
            "insertOptimized": after_opt,
            "afterUpdates": after_update,
            "afterUpdatesOptimized": after_opt_2,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", default="10000,50000", help="逗号分隔的规模档")
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--body-repeat", type=int, default=3, help="描述长度倍数（3 ≈ 90 汉字）")
    args = parser.parse_args()

    RUNS.mkdir(parents=True, exist_ok=True)
    results = [
        run_case(int(r), args.samples, args.body_repeat) for r in args.rows.split(",") if r
    ]
    print(json.dumps({"platform": "python-sqlite3", "cases": results}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
