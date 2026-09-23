/**
 * mock IPC 与真桥的分页/排序/覆盖面契约（D10）。
 *
 * 三处漂移的守门犬（本轮核验）：
 * 1. mock 曾无视 page/page_size（恒返全量）——第五轮 A5/A6 真分页后，
 *    growth-curve 与 e2e 会在测一个不存在的行为，门禁被静默架空；
 * 2. mock 曾返回插入序，真桥返回 ORDER BY updated_at DESC
 *   （generic_repo.rs）——贴近上限截断时哪些行可见完全不可复现；
 * 3. 列裁剪保真：空 keyword 时行 description 为 null（D0 的守门犬，防复发）。
 *
 * 纪律：契约测试必须先写红（旧 mock 下跑红），观测失败再修 mock，
 * 否则不知道该信哪一处。本文件落盘时三条在 HEAD mock 下已验红，
 * 随 mock 修复同批转绿（见 commit 信息）。
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

import { mockCommands, paginateRows } from "./ipc-mock";

const TEST_DIR = import.meta.dirname;

/** tauri.ts 侧 invoke("cmd") 全集（静态提取：前端 IPC 契约真值） */
function tauriCommands(): string[] {
  const src = readFileSync(path.join(TEST_DIR, "../lib/tauri.ts"), "utf8");
  const set = new Set<string>();
  for (const m of src.matchAll(/invoke<[^>]*>\("([^"]+)"\)/g)) set.add(m[1]);
  return [...set].sort();
}

/**
 * 有意不进 mock 的命令（冒烟主链路不走，mock 顶层注释同口径：
 * “内存库只覆盖主链路用到的命令，未覆盖统一 reject 防静默假绿”）。
 * 新命令忘分类会在用例 ① 当场红：补 mock 实现或入此表并注明原因。
 */
// bounded-by-data: 手写固定 allowlist（字面量枚举，只随新命令分类变更）
const MOCK_ALLOWLIST = new Set<string>([
  // —— 启动/鉴权（浏览器冒烟恒走明文免密分支）——
  "db_init_encrypted",
  "db_is_ready",
  "db_migrate_to_encrypted",
  "db_migrate_to_plaintext",
  "master_auth_change_password",
  "master_auth_clear",
  "master_auth_init",
  "master_auth_unlock",
  "master_auth_verify",
  // —— 同步/加密（需云端凭据与网络，冒烟不走）——
  "cloud_sync_rekey",
  "sync_config_save",
  "sync_crypto_change_password",
  "sync_crypto_export_bundle",
  "sync_crypto_forget_session",
  "sync_crypto_import_bundle",
  "sync_crypto_init",
  "sync_crypto_lock",
  "sync_crypto_restore_session",
  "sync_crypto_unlock",
  "sync_crypto_upgrade_v2",
  "sync_disconnect",
  "sync_test_connection",
  // —— 备份/导出（文件落盘链路，冒烟不走）——
  "backup_prefs_save",
  "full_backup_export",
  "full_backup_import",
  "full_backup_list_cloud",
  "full_backup_restore_cloud",
  "plaintext_export_csv",
  "plaintext_export_json",
  // —— 单条 get/杂项（冒烟主链路未调用，调用即 reject 会立刻暴露）——
  "todo_comments_get",
  "todo_projects_get_by_uuid",
  "todo_projects_update_sort_order",
  "todo_subtasks_get",
  "todo_task_labels_get",
  "todo_task_relations_get",
  "todo_tasks_duplicate",
  "todo_tasks_recalc_percent",
]);

/** 45 行任务库：updated_at 严格递增，插入序 = 更新序的逆序可区分 */
function seedTasks(n: number) {
  const tasks = Array.from({ length: n }, (_, i) => ({
    id: i + 1,
    uuid: `contract-u${i}`,
    title: `契约任务 ${String(i).padStart(3, "0")}`,
    description: `描述 ${i}`,
    project_id: null,
    priority: 0,
    status: "pending",
    done: 0,
    done_at: null,
    due_date: null,
    start_date: null,
    repeat_after: 0,
    repeat_mode: 0,
    percent_done: 0,
    position: i,
    is_favorite: 0,
    my_day_date: null,
    is_deleted: 0,
    created_at: 1000 + i,
    updated_at: 1000 + i,
    deleted_at: null,
    version: 1,
  }));
  // 故意打乱插入序：偶数在前、奇数在后，插入序≠更新序才能验出排序漂移
  const shuffled = [...tasks.filter((_, i) => i % 2 === 0), ...tasks.filter((_, i) => i % 2 === 1)];
  return { tasks: shuffled, projects: [] as never[] };
}

function list(filter: Record<string, unknown>) {
  const db = seedTasks(45);
  const impl = mockCommands.todo_tasks_list as (
    args: unknown,
    ctx: unknown,
  ) => Array<{
    id: number;
    updated_at: number;
    description: string | null;
    uuid: string;
    title: string;
  }>;
  return impl({ filter }, { db });
}

describe("mock IPC 契约", () => {
  it("① 前端 invoke 命令 ⊆ mock 注册键 ∪ 有意 allowlist（新命令忘分类当场红）", () => {
    const mockKeys = new Set(Object.keys(mockCommands));
    const missing = tauriCommands().filter((c) => !mockKeys.has(c) && !MOCK_ALLOWLIST.has(c));
    expect(missing, `未分类新命令：${missing.join(", ")}（补 mock 实现或入 MOCK_ALLOWLIST）`).toEqual([]);
  });

  it("② 分页保真：page1 ∩ page2 = ∅ 且 page1.length === pageSize", () => {
    const p1 = list({ page: 1, page_size: 20 });
    const p2 = list({ page: 2, page_size: 20 });
    expect(p1).toHaveLength(20);
    expect(p2).toHaveLength(20);
    const ids1 = new Set(p1.map((t) => t.id));
    for (const t of p2) expect(ids1.has(t.id)).toBe(false);
    // 尾页不足一页：45 行第 3 页剩 5 行
    expect(list({ page: 3, page_size: 20 })).toHaveLength(5);
    expect(list({ page: 4, page_size: 20 })).toEqual([]);
  });

  it("②-2 排序保真：mock 返回 updated_at DESC（与真桥 ORDER BY 同口径）", () => {
    const p1 = list({ page: 1, page_size: 45 });
    const ats = p1.map((t) => t.updated_at);
    expect([...ats].sort((a, b) => b - a)).toEqual(ats);
  });

  it("②-3 paginateRows 默认口径：page_size 缺省/0 → 20，page 越界 → 空", () => {
    const rows = Array.from({ length: 45 }, (_, i) => i);
    expect(paginateRows(rows)).toHaveLength(20);
    expect(paginateRows(rows, 1, 0)).toHaveLength(20);
    expect(paginateRows(rows, 0, 10)).toHaveLength(10);
    expect(paginateRows(rows, 99, 10)).toEqual([]);
  });

  it("③ 列裁剪保真：空 keyword 时 description 为 null（D0 守门犬）", () => {
    const pruned = list({ keyword: "", page: 1, page_size: 45 });
    expect(pruned).toHaveLength(45);
    for (const t of pruned) {
      expect(t.description).toBeNull();
      // A2：uuid 同为列表通道零消费列，以空串占位（Rust 侧 '' AS uuid）
      expect(t.uuid).toBe("");
    }
    // 非空 keyword 走全列：描述保留且按 title+description 过滤
    const full = list({ keyword: "描述 1", page: 1, page_size: 45 });
    expect(full.length).toBeGreaterThan(0);
    for (const t of full) {
      expect(t.description).not.toBeNull();
      expect(t.uuid).not.toBe("");
    }
  });
});
