# 移除 todo_tasks.end_date（结束日期）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 全栈移除 `todo_tasks.end_date` 列——DB（0004 迁移）、Rust 核心、orbit-flutter DTO/FRB 生成物、桌面端 TS/React、移动端 Dart，同步文档。

**Architecture:** 走新增 `0004_remove_end_date.sql` 增量迁移删列（不能改 0001：v0.1.1 已发布，改 checksum 会让存量库打不开），从内到外逐层拔字段，每层测试门禁通过后再动下一层。`StatsHeatmap.end_date`（热力图区间端点，字符串日期）与任务 end_date 无关，**不动**。

**Tech Stack:** Rust/sqlx/SQLCipher（sqlx::migrate! 宏）、flutter_rust_bridge 2.12 codegen、React/Tauri+vitest、Flutter/Dart。

## Global Constraints

- 迁移执行机制：`sqlx::migrate!("./src/db/migrations")`（`crates/orbit-core/src/db/pool.rs:55`），按文件名序号排序应用。
- **禁止修改 0001_init.sql**（已发布版本的库 checksum 不可变）。
- FRB 生成物（`crates/orbit-flutter/src/frb_generated.rs`、`apps/mobile/lib/src/rust/**`）只能由 `flutter_rust_bridge_codegen generate --config-file crates/orbit-flutter/flutter_rust_bridge.yaml`（仓库根目录执行）重新生成，禁止手改；移动端桥接产物一致性由 CI 门禁校验。
- 测试命令：Rust `cargo test --workspace`（仓库根）；桌面 `pnpm --filter orbit test`（或仓库根 `pnpm test`）；移动 `cd apps/mobile && flutter test`。
- 文档惯例（用户记忆 docs-sync-convention）：CHANGELOG Unreleased 追加条目 + docs 04/05 划线✅；单功能单 commit。

---

### Task 1: Rust 核心 —— 0004 迁移 + 模型/仓储/CSV + 测试

**Files:**
- Create: `crates/orbit-core/src/db/migrations/0004_remove_end_date.sql`
- Modify: `crates/orbit-core/src/models/business.rs:129,157,226`
- Modify: `crates/orbit-core/src/db/repository/generic_repo.rs:504,520,570-571,624-625`
- Modify: `crates/orbit-core/src/api/plaintext_export_api.rs:111,181,207,346`
- Modify: `crates/orbit-core/src/api/trash_api.rs:452`、`stats_api.rs:393`（测试构造删行）
- Modify: `crates/orbit-core/src/db/mod.rs:7-8`（迁移注释更新）

**Interfaces:**
- Produces: `TodoTask`/`TodoTaskCreateInput`/`TodoTaskUpdateInput` 均不再有 `end_date` 字段（下游 FRB/双端依赖此签名）。

- [ ] **Step 1: 写 0004 迁移**（内容如下，全文件）

```sql
-- 移除 todo_tasks.end_date（结束日期）。
--
-- 背景：end_date 与 start_date 成对，是 0001 建库时从 Vikunja API 模型平移的
-- 「任务执行区间终点」，但在排序/筛选/逾期/日历/提醒/统计中零消费，
-- 且与用户实际理解的「截止日期」（due_date，唯一日期主轴）语义混淆。
-- 产品决策（2026-09-07）：移除该字段，任务只保留 截止/开始 两个日期。
-- 已设值用户的 end_date 数据随本迁移丢弃；导入导出全链路同步收窄。
-- schema 前向兼容：列随行同步（LWW，行级 _table 路由），旧版本客户端
-- 的 update 语句若含 end_date 列将失败——本仓库同版本发布双端，无混跑场景。
ALTER TABLE todo_tasks DROP COLUMN end_date;
```

- [ ] **Step 2: 0001 顶部注释勘误 + db/mod.rs 迁移说明更新**

`0001_init.sql` 只改文件头注释中「结构变更直接改 0001」表述为「结构变更走增量迁移文件」（grep 到原文再改，不改 DDL 本体）。`db/mod.rs:7-8` 注释同步：「仅 0001 一个文件」→「0001–0004 增量迁移」。

- [ ] **Step 3: 逐文件删 end_date**

| 文件 | 动作 |
|---|---|
| `models/business.rs` | 删 :129（TodoTask）、:157（CreateInput）、:226（UpdateInput）三行字段 |
| `generic_repo.rs` | INSERT 列清单 :504 删 `end_date,`；占位符 `?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?` 减一个 `?`（13→12）；删 :520 bind；UPDATE 删 :570-571 sets 分支 + :624-625 bind 分支 |
| `plaintext_export_api.rs` | CSV_COLUMNS 删 :111；行构造删 :181 读取 + :207 写出；测试断言 :346 改为 `"due_date,start_date"` |
| `trash_api.rs:452` / `stats_api.rs:393` | 测试 UpdateInput 构造删 `end_date: None,` 行 |

- [ ] **Step 4: cargo test --workspace 全绿**

Run: `cargo test --workspace`
Expected: 编译通过（frb_generated.rs 此时会红——Task 2 修），若 orbit-flutter 编译报 end_date 缺失属预期，此时可先 `cargo test -p orbit-core` 验证核心层，全 workspace 留到 Task 2 后。

- [ ] **Step 5: Commit（可与 Task 2 合为一个 commit）**

按用户惯例单功能单 commit：Task 1+2 合一提交（同一变更的 Rust 两侧不可拆分构建）。

---

### Task 2: orbit-flutter DTO 镜像 + FRB 重新生成

**Files:**
- Modify: `crates/orbit-flutter/src/api/dto.rs:134,162,194,214,598,632`（删 TodoTask/CreateInput/Detail 的 end_date 字段与映射；:181 注释行去掉 end_date 字样）
- Regenerate: `crates/orbit-flutter/src/frb_generated.rs`、`apps/mobile/lib/src/rust/**`（codegen 产物）

**Interfaces:**
- Consumes: Task 1 的 Rust 模型签名（无 end_date）。
- Produces: `apps/mobile/lib/src/rust/api/dto.dart` 中 TodoTask/CreateInput/UpdateInput/Detail 不再含 `endDate`（供 Task 4 的桥接层编译）。

- [ ] **Step 1: 删 dto.rs 六处字段/映射 + 注释**

- [ ] **Step 2: 跑 codegen**（仓库根目录）

Run: `flutter_rust_bridge_codegen generate --config-file crates/orbit-flutter/flutter_rust_bridge.yaml`
Expected: 成功；`git diff` 确认 frb_generated.rs 与 lib/src/rust/** 变更均为删 end_date 相关。

- [ ] **Step 3: cargo test --workspace 全绿**（core+flutter 均无 end_date）

- [ ] **Step 4: Commit Task 1+2**

```bash
git add crates/ apps/mobile/lib/src/rust/
git commit -m "refactor(core): 移除 todo_tasks.end_date——0004 增量迁移删列 + 模型/仓储/CSV/FRB 全链路收窄"
```

---

### Task 3: 桌面端（TS/React）

**Files:**
- Modify: `apps/desktop/src/lib/tauri.ts:191,215,232`（三接口删 end_date；:745 StatsHeatmap 不动）
- Modify: `apps/desktop/src/features/todo/desktop/task-form-sheet.tsx:94,562`（字段清单删行 + 提交映射删行）
- Modify: `apps/desktop/src/features/todo/shared/repeat-task.ts:39`（删 end_date 平移）
- Modify: `apps/desktop/src/test/ipc-mock.ts:49,176,294`（mock 类型/种子/落库删 end_date；:671 heatmap 不动）
- Modify: 测试 `repeat-task.test.ts:16`、`task-filters.test.ts:20`、`batch-actions.test.ts:36`（fixture 删 `end_date: null,`）

**Interfaces:**
- Consumes: Task 1 后端不再接受 end_date。
- Produces: 无下游依赖。

- [ ] **Step 1: 全部文件删 end_date 相关行**（heatmap 的 `end_date: string` 保留）
- [ ] **Step 2: 全库 grep 复核** `grep -rn "end_date" apps/desktop/src --include="*.ts*"` 仅剩 tauri.ts:745 附近 StatsHeatmap 一处
- [ ] **Step 3: pnpm --filter orbit test 全绿**（repeat-task.test 有断言 next 输入的用例需同步删字段）
- [ ] **Step 4: Commit**

```bash
git add apps/desktop/src
git commit -m "refactor(desktop): 移除结束日期——类型/表单/重复平移/mock 收窄 end_date"
```

---

### Task 4: 移动端（Dart）

**Files:**
- Modify: `apps/mobile/lib/data/api/dto.dart:109,135,161,201,218,560,591`（TodoTask/CreateInput/Detail 删 endDate；:834 StatsHeatmap 不动）
- Modify: `apps/mobile/lib/data/api/rust_orbit_bridge.dart:133,168,672`（桥接映射删行）
- Modify: `apps/mobile/lib/data/api/mock_orbit_bridge.dart:155,219`（mock 映射删行；:857 heatmap 不动）、`mock_store.dart:122`（种子删 `'end_date': null,`）
- Modify: `apps/mobile/lib/modules/todo/form_bottom_sheet.dart`（`_endDate` state :117、编辑回填 :178、新建提交 :226、patch :245、UI tile :592-607 及其前 _tileDivider :590）
- Modify: `apps/mobile/lib/modules/todo/detail_screen.dart:483-491`（结束日期 InfoTile + `end_date` patch）、:514 注释改「开始日期行点击」
- Modify: `apps/mobile/test/slidable_test.dart:38`、`task_logic_test.dart:37`（fixture 删 `endDate: null,`）
- Regenerate: FRB 产物已在 Task 2 覆盖。

**Interfaces:**
- Consumes: Task 2 的无 endDate 生成物。
- Produces: 无。

- [ ] **Step 1: 逐文件删**（表单里结束日期 tile 删除后注意 `_tileDivider` 数量配平——删 tile 必删其前面的分隔线）
- [ ] **Step 2: 全库 grep 复核** `grep -rn "endDate\|end_date" apps/mobile/lib apps/mobile/test` 仅剩 StatsHeatmap/stats 桥接的区间语义
- [ ] **Step 3: flutter test 全绿**（form_bottom_sheet_test/detail_screen_edit_test 若有日期字段断言需同步）
- [ ] **Step 4: Commit**

```bash
git add apps/mobile
git commit -m "refactor(mobile): 移除结束日期——DTO/桥接/mock/表单/详情页收窄 endDate"
```

---

### Task 5: 文档同步 + 全库验收 + 最终 commit

**Files:**
- Modify: `docs/04_UI复刻规格-桌面端.md:119-121`（删 end_date 行）
- Modify: `docs/05_UI复刻规格-移动端.md:110-113`（字段表删「结束日期」行）
- Modify: `CHANGELOG.md` Unreleased 追加条目
- Modify: `docs/03_数据模型与同步.md`（若提及 end_date；已核实正文「关键列」未提及，仅需检查）

- [ ] **Step 1: 三处文档更新**（04/05 划线或删行按现有格式惯例；CHANGELOG 写「移除 todo 任务的『结束日期』字段（end_date），日期口径统一为 截止/开始 两个」）
- [ ] **Step 2: 全库最终验收 grep**（仓库根，排除 node_modules/.dart_tool/target/frb_generated 等）

```bash
grep -rn "end_date" --include="*.rs" --include="*.ts" --include="*.tsx" --include="*.dart" --include="*.sql" --include="*.md" . | grep -v node_modules | grep -v frb_generated | grep -v "\.dart_tool"
```
Expected: 仅 StatsHeatmap 区间语义（stats_api.rs / stats.dart / tauri.ts / dto.dart:834 / 桥接 heatmap 映射）+ docs 历史记录（CHANGELOG/07 对比文档如提及属历史记录可保留）。

- [ ] **Step 3: 三套件终验** `cargo test --workspace` + `pnpm --filter orbit test` + `cd apps/mobile && flutter test` 全绿
- [ ] **Step 4: Commit**

```bash
git add docs/ CHANGELOG.md
git commit -m "docs: 移除结束日期字段——04/05 规格与 CHANGELOG 同步收窄"
```

---

## Self-Review 结论

- 覆盖面：探查报告列出的全部 end_date 触点（DB/Rust/FRB/桌面/移动/文档）均有对应任务；StatsHeatmap 同名异物已在全局约束与各任务明确豁免。
- 类型一致性：三态 `Option<Option<i64>>` 清空语义随字段整体删除，无需替代实现（Rust UPDATE 侧/移动端 patch 侧同步删分支）。
- 迁移风险：sqlx migrate 无 down 迁移，删列不可逆——v0.2.0 未发布，可接受；已设值用户的 end_date 数据丢弃已在迁移注释中声明。
