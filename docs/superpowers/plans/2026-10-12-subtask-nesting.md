# 子任务多层嵌套（docs/10 §七 M10 / B-4）实施计划

> 立项：2026-10-12 ｜ 对标：TickTick / Todoist 子任务层级
> 先例：`0003_project_parent.sql`（项目文件夹树）——树形父引用一律用
> `parent_uuid`（同步键）而非 `parent_id`（自引用整数外键会死锁同步引擎）。

## 设计口径（已定）

1. **Schema**：`0007_subtask_parent.sql` 追加 `parent_uuid TEXT DEFAULT NULL`
   （NULL = 顶层；存量行语义零变化）。**不声明外键、不动 `sync_registry`**——
   `load_table_items` 走 `SELECT *`，新列自动随载荷同步（与 parent_uuid 项目同路径）；
   `fk_map_matches_ddl` 对账保持绿（无新整数外键）。
2. **限定同任务内嵌套**：父须与子同 `task_id`。跨任务移动会牵动整棵子树的
   task_id 与同步 `_fk` 重解析，v1 不做（报错明确拒绝）。
3. **percent_done 不变**：所有子孙行同带 task_id，现有 COUNT 即全树聚合，
   「多级回算」天然成立，无 SQL 改动。
4. **顺序**：后端仍平铺返回，新增纯函数 `order_subtasks_for_tree`（DFS 按
   (position, id) 展开；悬空父/脏环回落顶层，visited 防环）。详情与列表同口径。
5. **promote（转独立任务）**：子孙随迁——先把子孙 `task_id` 改新任务 id、
   `parent_uuid` 置 NULL，再软删源行（先迁后删防悬空）。
6. **删除**：软删整棵子树（BFS 收集 + 逐行软删 + 逐行 emit 事件 + 逐行历史）。
7. **重复克隆**：`subtasks_to_clone` 带 parent_uuid，按拓扑序插入并重映射
   到新 uuid（树形随实例延续）。
8. **更新三态**：`parent_uuid: Option<Option<String>>`——None 不动 /
   Some(None) 提顶层 / Some(Some(uuid)) 挂父（环防护：父不能是自身后代）。

## 切片（每片独立可编译、独立提交）

| # | 切片 | 落点 | 验证 |
|---|---|---|---|
| 1 | core：迁移+模型+校验+树序+delete 子树+promote 随迁+克隆保树 | `db/migrations/0007`、`models/business.rs`、`api/{business,todo}_api.rs`、`db/repository/generic_repo.rs` | `cargo test -p orbit-core --lib` |
| 2 | 桥：FRB DTO + codegen + 桌面 tauri.ts + 双 mock | `crates/orbit-flutter`、`apps/desktop/src/lib/tauri.ts`、`src/test/ipc-mock.ts` | codegen diff 空 + `pnpm typecheck` + vitest |
| 3 | 桌面 UI：递归缩进 + 行内「+子任务」+ 「提到顶层」 | `task-detail-drawer.tsx` SubtasksSection | vitest + 浏览器目检 |
| 4 | 移动 UI：同款 + mock 桥 + test | `detail_screen.dart` `_SubtasksSection`、`mock_orbit_bridge.dart` | `flutter analyze` + `flutter test` |
| 5 | 文档：docs/10 M10 ✅、CHANGELOG Unreleased | docs | — |

## 交互取舍（v1 明确不做）

- 无拖拽排序（双端现状即无；position 仍按创建序）。
- 无行内改名入口（现状即无；UpdateInput 保留 title 能力）。
- 无跨任务移动、无层级深度上限（数据层不限深，UI 缩进不限）。
