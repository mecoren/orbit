# 10 TickTick 对标差距分析 —— 移动端

> 基准版本：v0.1.0（`main` 分支，2026-09-23 静态盘点）。
> 方法：`apps/mobile/lib` + `crates/orbit-flutter/src/api` + `crates/orbit-core` 源码静态盘点，
> 复用 `docs/05` §八~§十一（移动端口径基线）与 `docs/07`（竞品矩阵与 backlog）既有结论。
> **本环境无法安装运行 TickTick**：凡 TickTick 侧描述均来自公开能力认知，一律标注「须真机验证」，
> 不写成实测结论；文档内不出现无出处的量化数字。
>
> **本文档是只读分析产物**：不含代码改动、不改 DDL、不动同步白名单。文内条目标注为
> 「候选（待圈选）」，圈定后由 `docs/07 §五` 作为 backlog 唯一状态源承接（见 §九）。

对标对象：**TickTick（滴答清单）**——移动端形态的功能最全竞品，中文市场主要对手（`docs/07 §一`）。

---

## 一、对标范围与判定口径

| 项 | 约定 |
|---|---|
| 范围 | **仅移动端 Flutter（`apps/mobile`）**；桌面端只作「双端不对称」参照列 |
| 排除项（2026-09-23 拍板，维持 `docs/07 §五`） | 番茄钟/专注计时、习惯追踪、协作共享、i18n/Web 版 —— 不列为建议项 |
| 判定口径 | 只认「用户可感知的能力差」；「桌面命令平价遗留」「基础设施诊断口」不计为差距 |
| 改造面标注 | DDL 迁移 / `sync_registry.rs` 白名单 / FRB codegen / 是否双端不对称 |
| TickTick 侧证据强度 | 公开认知，标「须真机验证」；Orbit 侧一律给文件:行号 |

**三类差距定义**（后文按此分章）：

- **A 类**：能力**已在 orbit-core 或 FRB/Dart 桥存在**，移动端 UI 未接线或未启用 —— 性价比最高（多数零 Rust 改动）。
- **B 类**：**结构性缺失**，需追加 DDL 迁移（新列/新表）才能表达。
- **C 类**：能力**完全缺失**，且落地需新机制（网络轮询 / 新表 / 平台权限），成本与定位须权衡。

---

## 二、移动端能力现状（已落地，**不列为差距**）

先固化去重名单，避免同一项被反复提出。以下均已核实接线到 UI：

| 能力 | 证据 |
|---|---|
| 列表 / 看板 / 表格三视图切换 | `sub_list_screen.dart:45`、`kanban_view.dart:28`、`table_view.dart:21`、`logic/view_mode.dart:12` |
| 月历 + 年视图 + 农历/节气/休班徽标 | `calendar_screen.dart:39`、`year_overview_page.dart:31`、`shared/widgets/shadcn/orbit_month_calendar.dart` |
| 统计仪表盘（热力图 / streak / 分布） | `stats_screen.dart`、`shared/widgets/shadcn/orbit_heatmap.dart` |
| 全局搜索（任务/项目/评论三路） | `search_screen.dart:24` |
| 保存的筛选器（Smart List） | `saved_filters_screen.dart:28` |
| 回收站（TTL / 恢复 / purge） | `trash_screen.dart` |
| 任务模板 | `modules/settings/template_manager_page.dart`、`todo/logic/template_apply.dart` |
| NLP 快速输入（中文日期/优先级/项目/标签） | `todo/logic/parse_quick_input.dart:93`、`form_bottom_sheet.dart:171` |
| 侧滑完成/删除（TickTick 式动作面板） | `sub_list_screen.dart:1737-1775`（`flutter_slidable`） |
| 长按操作菜单 / 长按整行拖拽重排 | `sub_list_screen.dart:1119` / `:1182` |
| 多选批量（完成/优先级/改期/移动项目/加标签/删除） | `sub_list_screen.dart:597-964`、`logic/batch_actions.dart` |
| 撤销栈（Ctrl+Z 等价物） | `todo/logic/undo_stack.dart`、`todo/providers/undo_provider.dart` |
| 下拉刷新（侧栏/主列表/统计/回收站） | `sidebar_screen.dart:335`、`sub_list_screen.dart:1323`、`stats_screen.dart:76`、`trash_screen.dart:251` |
| 骨架屏 / 行入场 / 行退场 / 视图切换过渡 | `shared/widgets/shadcn/orbit_skeleton.dart`、`docs/05 §九` |
| 详情十区块（信息/描述/子任务/标签/提醒/关联/评论/附件/历史） | `detail_screen.dart:386/566/764/881/1292/1557/1679/1935/2068` |
| 附件（内容寻址 + E2E 同步） | `detail_screen.dart:1935`、桥 `taskAttachment*` |
| 模板 / 活动历史 | `detail_screen.dart:2068` |
| CSV 导入三档预设（Orbit / Todoist / TickTick） | `settings_screen.dart:209-213` |
| 明文导出 JSON / CSV / ICS(VTODO) | `settings_screen.dart:129-131`、`:184-188` |
| 云同步（WebDAV/S3）+ 冲突副本 + 全量备份 | `sync_settings_page.dart`、`sync_conflicts_page.dart`、`backup_page.dart` |
| 节假日联网更新 + 农历 | 桥 `holiday*`（`crates/orbit-flutter/src/api/holiday.rs`） |
| Android 桌面小组件 / 快捷设置磁贴 / 系统分享接收 | `apps/mobile/android/app/src/main/AndroidManifest.xml:78` / `:96` / `:53-58` |
| 通知「完成 / 推迟三档」action | `services/notification_service.dart:70`、`:555-557` |
| 图标角标（未完成数） | `todo/logic/badge_count.dart` |
| a11y：操作按钮读屏标签 + 色点热区 48 | `test/a11y_test.dart`（6 例）、`core/theme/app_dimens.dart:63` |
| 设计系统 v3 + 自绘原语层 | `core/theme/*.dart`（11 文件）、`shared/widgets/shadcn/orbit_*.dart`（15 个原语） |

> 结论：**TickTick 待办主线的高频能力，移动端基本齐备**。差距集中在「核心已有但移动端未接线」与少量结构性空白。

---

## 三、A 类差距：能力已在 core/桥，移动端未接线或未启用

> 反向盘点（「Rust 有 / Dart 桥有」×「移动端 UI 调用点」交叉比对）的结果。
> 判定依据：全仓检索该符号命中范围仅 `apps/mobile/lib/data/api/*`（接口 + 两实现）与 `lib/src/rust/*`（生成物），
> 即 `modules/`、`services/`、`shared/`、`core/` 下零调用。
> 说明：LSP `findReferences` 对 Dart 抽象成员未解析 override（仅回声明本身），故本节证据以全仓文本检索为准。

### A-1 ICS 日历导入（VTODO）—— 能力全链已就绪，移动端入口被文件过滤器挡住 ⭐

| 层 | 状态 | 证据 |
|---|---|---|
| orbit-core | ✅ 已实现 | `crates/orbit-core/src/api/ics_import_api.rs`；`csv_import_api.rs:93-98` 枚举含 `Ics`，`:200-204` `Ics` 预设分流至 `map_ics_rows` |
| 桌面壳 | ✅ 已接线 | `components/settings/sync-section.tsx:1952`（文案）、`:1970`（预设项「ICS 日历（VTODO）」）、`:1884-1889`（文件过滤器 `.ics`） |
| 移动端 | ❌ 未接线 | `settings_screen.dart:209-213` 预设仅 `orbit/todoist/ticktick`；`:219-220` `allowedExtensions: ['csv','txt']` |

- **用户价值**：从 Google Calendar / Outlook / Apple 日历 / TickTick（导出 ICS）一次性迁入任务（VTODO）。
- **改造面**：**纯 Dart**（补 1 个预设 chip + 扩展名放行 + 卡片文案）；零 Rust、零 DDL、零同步面。
- 与 TickTick 的关系：TickTick 支持 ICS 导入/订阅（**须真机验证**）；一次性导入属其导入能力子集。

### A-2 「修改后立即同步」移动端已生效（2026-09-23 收口，见 `docs/07 #58`）

| 项 | 状态 | 证据 |
|---|---|---|
| 桥能力 | ✅ 存在 | `orbit_bridge.dart:338-339` `cloudSyncPushOnly` |
| 移动端 | ✅ 已生效 | 设置页开关（`sync_settings_page.dart`）+ `services/sync_on_change_scheduler.dart`：写路径 db-change → 5s 滑动防抖 → `cloudSyncPushOnly(origin: background)`，五道门控与桌面 `sync_scheduler.rs` 同口径 |
| 桌面 | ✅ 已生效 | `docs/07 §五 P1#13`（`sync_scheduler.rs` 5s 防抖订阅 EVENT_BUS） |

- **用户价值**：TickTick 为秒级同步（**须真机验证**）；Orbit 双端现状为「编辑后约 5 秒推送」，此前移动端「手动触发为准」的对称性缺失已收口。
- **耗电/流量权衡结论**（原延后理由）：只在用户真实编辑后触发 + 5s 滑动防抖合并 + 引擎忙让位 + 增量指纹未变秒级跳过，**不做后台轮询**；进入/退出前台仍由 `cloudSyncForce` 必同步兜底。移动端两处有意差异：①无桌面 60s tick 兜底 → 推送进行中收到的写入出窗后补排一轮；②无 sync-progress 事件流 → 后台推送不占标题栏「同步中」指示，仅成功后刷新「上次同步」。

### A-3 同步密钥治理三入口在移动端不可达

| 桥方法 | 语义 | 移动端调用点 | 桌面调用点 |
|---|---|---|---|
| `syncCryptoMetaVersion`（`orbit_bridge.dart:492`） | 本机密钥方案版本 v1/v2 | **无** | `pages/sync-recovery-page.tsx` |
| `syncCryptoUpgradeV2`（`:495`） | v1→v2 迁移（同密码确定性派生 + 云端全量重传） | **无** | 同上 |
| `cloudSyncRekey`（`:498`） | 以本机为准重置云端（当前 Data Key 全量重加密覆盖） | **无** | 同上 |

- **用户价值**：属**数据自愈路径**——v1 老用户无法在移动端完成密钥方案升级；「以本机为准重置云端」这一恢复动作移动端不可达；也看不到自己处于 v1 还是 v2。
- **改造面**：纯 Dart UI（复用既有桥，含二次确认弹层口径 `docs/05 §十一`）。

### A-4 移动端列表/看板/表格行不显示提醒徽标，信息密度低于桌面与 TickTick

| 项 | 状态 | 证据 |
|---|---|---|
| 桥投影 | ✅ 存在但**未被任何 UI 调用** | `orbit_bridge.dart:323-324` `taskRemindersProjection` |
| 桌面 | ✅ 四个视图都消费 | `task-list-view.tsx` / `kanban-view.tsx` / `calendar-view.tsx` / `task-table-view.tsx` + `features/todo/shared/reminder-chip.tsx` |
| 移动端任务行 | ❌ 副标题仅「优先级色点 + 项目名 + 截止日期」+ 星标 | `sub_list_screen.dart:1815-1854`、`:1859-1866` |

- 同族事实：标签投影 `taskLabelsProjection` **已接线**（`sub_list_screen.dart:1039-1044`），但仅用于**列表标签筛选与看板/表格标签色点**，行内不渲染标签 chip。
- **用户价值**：TickTick 移动端行内可见标签/子任务进度/附件/提醒标记（**须真机验证**）；Orbit 需进入详情才能确认这些状态。
- **改造面**：纯 Dart（Tile 副标题扩列）；提醒徽标需接 `taskRemindersProjection`。

### A-5 桥已暴露但全仓零调用 —— 完整清单与逐条判定（22 条）

| # | 桥方法 | 判定 |
|---|---|---|
| 1 | `cloudSyncPushOnly` | **真实缺口** → 见 A-2 |
| 2 | `syncCryptoMetaVersion` | **真实缺口** → 见 A-3 |
| 3 | `syncCryptoUpgradeV2` | **真实缺口** → 见 A-3 |
| 4 | `cloudSyncRekey` | **真实缺口** → 见 A-3 |
| 5 | `taskRemindersProjection` | **真实缺口** → 见 A-4 |
| 6 | `taskDependencyFlags`（`orbit_bridge.dart:327`） | **已双端消费**（2026-09-23）：两端列表行渲染「关联」徽标（桌面 `use-task-dependencies` + `task-list-view` 元信息行、移动 `taskDependencyFlagsProvider` + `TodoTaskTile`），关联行写事件经 db-invalidation 精确失效该投影。「被阻塞」档**不做**——双端详情抽屉的「添加关联」固定写 `relates_to`，无任何入口写 `blocks` / `blocked_by`，分档字段会是恒 0 的死数据（core 侧注释记此口径） |
| 7 | `fullBackupDeviceInfo`（`:555`） | **已接线**：移动端 2026-09-23（`docs/07 #57`）；桌面同步接线同批完成（`docs/07 #60`，`tauri.ts` 包装 + 备份卡导出区展示） |
| 8 | `cloudSyncIsRunning`（`:344`） | **已消费**（2026-09-23，M6）：`services/sync_on_change_scheduler.dart` 以「引擎忙让位」纳入推送门控（`docs/07 #58`）；UI 仍以本地 busy 态替代（非 UI 缺口） |
| 9 | `todoProjectGetByUuid`（`:266`） | 桌面同步引擎定位远端记录用；移动端同步由 core 内部完成 —— 平价遗留 |
| 10 | `todoTaskGetByUuid`（`:269`） | 同上 |
| 11 | `businessCount`（`:272`） | 侧栏计数走 `todoTasksProvider` 派生 —— 平价遗留 |
| 12 | `todoProjectGet`（`:237`） | 详情页从列表已加载数据取值 —— 冗余 getter |
| 13 | `todoLabelGet`（`:288`） | 同上 |
| 14 | `todoTaskLabelGet`（`:296`） | 同上 |
| 15 | `todoCommentList`（`:301`） | 详情聚合已含评论 —— 冗余 getter |
| 16 | `todoTaskRecalcPercent`（`:263`） | 子任务变更后 core 自动回算 —— 冗余 |
| 17 | `masterAuthVerify` | 待核实（疑为导出/改密前置校验的桌面路径） |
| 18 | `dbIsReady` | 基础设施探针（BootGate 走自身编排） |
| 19 | `ping` | 诊断口 |
| 20 | `cryptoSha256` | 工具口 |
| 21 | `cryptoRandomHex` | 工具口 |
| 22 | `cloudSyncPullThenPush`（`:342`） | 由 `cloudSyncNow`（`:336`）覆盖 —— 冗余别名 |

> 第 8–22 条**不计为功能差距**：属「桌面命令平价遗留 / 基础设施诊断口 / 冗余 getter」。
> 记录在此仅为了让下批盘点可直接复用作去重依据，避免重复判定。

### A-6 Rust 桥已有、Dart 桥接口未暴露（11 个，二级缺口）

| Rust 函数 | 文件:行 | 影响 |
|---|---|---|
| `db_get_device_id` | `crates/orbit-flutter/src/api/auth.rs:89` | 无（`dbSetDeviceId` 已在用） |
| `db_reset_state` | `api/auth.rs:96` | 待核实（重置本地状态入口） |
| `todo_subtasks_get` | `api/todo.rs:264` | 冗余（子任务列表已含全部字段） |
| `todo_comments_get` | `api/todo.rs:424` | 冗余（Dart 有 `todoCommentList`） |
| `todo_task_relations_get` | `api/todo.rs:463` | 冗余 |
| `todo_reminders_get` | `api/todo.rs:504` | 冗余 |
| `cloud_sync_get_state` | `api/sync.rs:558` | **已双端消费**（2026-09-23）：移动抽象桥补 `cloudSyncGetState`（Rust/Mock 两实现 + `SyncStateView` 镜像 DTO），两端设置页新增「同步账本」卡（桶指纹 + 水位线 + 设备 / epoch，只读诊断）。语义是同步**状态账本**（`sync_state.json`），**非**「是否正在同步」（后者用 `cloudSyncIsRunning`）——M6 忙门控只用后者，与本项无依赖关系 |
| `holiday_set_fixed_hour` | `api/holiday.rs:100` | **双端均已接线**：移动端 2026-09-23（`docs/07 #59`，设置页「日历与节假日」卡）；桌面同批（`docs/07 #60`，设置页新增「日历」分类 + 日历页 tooltip 带时刻） |
| `trash_purge_expired` | `api/trash.rs:143` | 无（`startTrashScheduler` 守护覆盖） |
| `attachments_gc` | `api/asset.rs:57` | 无（`dbMaintenance` 内含 GC） |
| `orbit_state_initialized` | `api/state.rs:72` | 无（BootGate 走自身编排） |

**A 类净结论**：真实缺口 5 项（A-1 ~ A-4 + `fullBackupDeviceInfo`），其中 **A-1 是零 Rust 改动的单点缺口**。

---

## 四、B 类差距：结构性缺失（需追加 DDL 迁移）

> 仓库只有 `crates/orbit-core/src/db/migrations/0001_init.sql` 一个文件（已合并基线，**冻结永不改**）；
> 以下各项落地都需追加 `NNNN_xxx.sql`，加列必须带 `DEFAULT`，新字段补行尾中文注释。

| # | 缺失 | 现状证据 | TickTick 侧（须真机验证） | 改造面 |
|---|---|---|---|---|
| B-1 | **清单文件夹分组**（项目层级） | `todo_projects` 列仅 `title/description/hex_color/sort_order/is_archived`…**无 `parent_id`**（`0001_init.sql:119-132`）；侧栏为一维 `ReorderableListView`（`sidebar_screen.dart:369-403`） | 有「清单文件夹」，可折叠分组 | DDL 新增列 + `sync_registry.rs` 白名单列 + 侧栏层级 UI + 拖拽层级语义（跨层级 drop 判定） |
| B-2 | **任务预计时长 / 时间块** | `todo_tasks` 有 `due_date/start_date/my_day_date`，**无 duration 类列**（`0001_init.sql:138-177`） | 有「预计时长」并可拖入日历时间段 | DDL + 日历周/日档 + 时间块拖拽（移动端手势与滚动冲突风险高） |
| B-3 | **日历缺议程档**（双端不对称） | 移动端仅**月 + 年**（`calendar_screen.dart`、`year_overview_page.dart`）；桌面为**三档 `month \| year \| agenda`**（`apps/desktop/src/features/todo/desktop/calendar-view.tsx:77`、`:409-416`） | 有日/周视图 | **纯 Dart**（补齐桌面已有第三档，享 `VirtualGroupedList` 同口径分栏/自动滚到今天语义） |
| B-4 | **子任务仅一层** | `todo_subtasks` 仅 `task_id`（FK→`todo_tasks`），**无 `parent_id`**（`0001_init.sql:196-209`）；UI 单层（`detail_screen.dart:764`） | 支持多层子任务 | DDL + 详情递归渲染 + 进度回算链改造（`percent_done` 多级聚合） |
| B-5 | **提醒无「相对档」快捷** | 移动端表单提醒=绝对日期+时刻单面板（`form_bottom_sheet.dart:391-404`），无「提前 15/30/60 分钟」预设；桌面 `components/business/quick-date-options.tsx` 亦无 | 提供「当天 9:00 / 提前 N 分钟」等快捷档 | **纯 Dart**（输入便利层；`remind_at` 仍是绝对时刻，**零 DDL**） |

> B-1/B-2/B-4 属「动 DDL + 动同步面」的重投入项；**B-3/B-5 是纯 Dart 的对称性/便利性补齐**。

---

## 五、C 类差距：能力完全缺失，须评估（含与定位的冲突）

| # | 能力 | TickTick 侧（须真机验证） | 与本项目定位的关系 | 建议 |
|---|---|---|---|---|
| C-1 | **日历订阅（URL 订阅外部 ICS）** | 支持订阅外部日历只读展示 | 需周期性网络轮询 + 外源只读层；与「本地优先/零遥测」需权衡（轮询目标 URL 会外泄存在性） | 待评估，**不建议在 v1.x 内启动** |
| C-2 | **倒数日 / 纪念日** | 独立「纪念日」模块（天数倒数） | 与待办主线弱相关，但不属四大排除项 | 待评估（低优先） |
| C-3 | **位置提醒**（地理围栏） | 支持到达/离开某地提醒 | 需持续定位权限，与「免注册、零遥测、本地加密」叙事直接冲突 | **有意不跟进**（见 §八） |
| C-4 | **语音输入** | 支持语音转任务 | 平台 STT 可能联网，隐私面不可控 | **有意不跟进**（见 §八） |

---

## 六、UI/UX 差距

> 判定原则：移动端视觉蓝本是 wait-home（`docs/04`/`docs/05`），**不是 TickTick**。
> 因此「设计语言不同」不自动等于差距；只有「结构缺失 / 信息不全 / 触达不便」才计入。

| 维度 | Orbit 现状 | TickTick 侧（须真机验证） | 结论 |
|---|---|---|---|
| 视觉语言 | shadcn New York 语言：1px 描边 + 表面分层，阴影只留给浮层（`docs/05 §二`、设计系统 v3） | Material 风、高信息密度、顶部大标题 | **不跟进**——属设计体系选择，改写即与复刻蓝本冲突 |
| 导航结构 | 栈式导航，无底部 Tab（全仓 `bottomNavigationBar\|NavigationBar\|TabBar\|BottomAppBar` 零命中）；侧栏首屏 `sidebar_screen.dart:344-485` | 底部 Tab（任务/日历/…） | **不跟进**——`docs/07 §2.3` 已判「符合复刻规格，不算差距」，本轮维持 |
| 侧栏信息架构 | 7 快捷视图 + 日历/统计/搜索/筛选器/回收站 + 项目（可拖拽排序）+ 已归档 + 未分组 | 清单抽屉 + 文件夹分组 | 侧栏结构**已达标**；唯一缺口是 B-1 层级分组 |
| 列表行信息密度 | 优先级色点 + 项目名 + 截止 + 星标（`sub_list_screen.dart:1815-1866`） | 行内可见标签/子任务进度/提醒标记 | **差距** → A-4 |
| 任务详情 | 十区块全屏页（`detail_screen.dart`） | 同类区块（Tab 化） | Orbit 区块数**不落下风**（`docs/07 §六`已判信息密度超多数竞品） |
| 新建/编辑入口 | 底部抽屉 + NLP + 「字段行→选择抽屉」二段式（`form_bottom_sheet.dart:406-440`） | 底部输入 + 展开面板 | **已对齐**（同构交互） |
| 日历入口 | 侧栏行 + 月/年两档 | 一级 Tab + 日/周/月 | 入口层级属导航决策（不跟进）；**视图档位差距**见 B-3 |
| 手势 | 侧滑完成/删除、长按菜单、长按拖拽重排、横滑翻月/切年 | 滑到底完成、长按多选 | `docs/05 §9.2` 已明确「不做滑到底直接完成」（手势语义变更），**维持**；多选已具备（`sub_list_screen.dart:597`） |
| 动效 | 已按微软 To-Do 口径收口（`docs/05 §九`：勾选/划线/行入场/行退场/拖拽抬起/抽屉/骨架呼吸/页面转场） | 同类微交互 | **已对齐**，无新增项 |
| 无障碍与热区 | 操作按钮全带读屏标签、色点热区统一 48 且视觉直径不变（`docs/05 §十`、`test/a11y_test.dart` 6 例） | 无公开 a11y 基线可比 | **达标**，无需对标 |
| 设置页完备度 | 同步/回收站/安全/组织/数据安全/明文导出/数据库维护/CSV 导入/关于/小组件（`settings_screen.dart:757-1364`） | 同类 + 专注/习惯设置 | Orbit **去掉排除项后覆盖完整**；缺 A-3 的密钥治理三入口 |

---

## 七、优先级建议（候选清单，**待圈选**）

评分口径沿用 `docs/07 §五`：影响 H/M/L；难度为人日量级；一致性 = 与「单人 / 本地优先 / E2E / 移动端复刻蓝本」的契合度。

### P0 —— 立即做（零 Rust 改动、零 DDL、高一致）

| # | 候选 | 影响 | 难度 | 一致性 | 改造面 |
|---|---|---|---|---|---|
| M1 | **ICS 日历导入（VTODO）打通移动端**（A-1） | H | S（0.5d） | H | 纯 Dart：+1 预设 chip + `allowedExtensions` 放行 + 文案 |
| M2 | **提醒相对档快捷**（B-5：提前 15/30/60 分钟 / 当天 9:00） | M | S（0.5d） | H | 纯 Dart（表单预设行），零 DDL |
| M3 | **列表行信息补齐**（A-4：提醒徽标 + 标签 chip + 子任务进度） | M | S–M（1d） | H | 纯 Dart（Tile 副标题扩列 + 接 `taskRemindersProjection`） |

> **2026-09-23 落地进度**：P0（M1–M3）、P1（M4–M7）与 P2 中成本最低的 M11 **均已完成**，
> 逐项要点与状态见 `docs/07 §五 #52–#59`（backlog 唯一状态源）；本文档保持盘点快照，不回写状态列。
> P1 末项 M6「修改后立即同步生效」按既定路径**单独立项评估后完成**——5s 滑动防抖 + 五道
> 门控 + 引擎增量指纹跳过，不做后台轮询（`docs/07 #58`）；M11 节假日更新时刻可配同步落地
> （`docs/07 #59`，**纯 Dart——FRB 生成物早已就绪，零 codegen**，下表原「FRB codegen」为盘点期误判）。
> P2 余项（M8 / M9 / M10 / M12 / M13）**尚未启动**，全部要动 DDL、新表或新机制。
>
> **双端不对称已全部收口（2026-09-23 桌面补齐批次，`docs/07 #60–#63`）**：①M2 提醒相对档的桌面侧
> （`buildReminderDueOptions` + `QuickDateMenu.dueDateMs`，三处提醒入口全覆盖）；②M7 的
> `full_backup_device_info` 桌面侧包装 + 备份卡展示；③`holiday_set_fixed_hour` 桌面侧设置项。
> 另：`taskDependencyFlags`（A-5#6）与 `cloud_sync_get_state` 均已于 2026-09-23 **双端消费**
> （列表行「关联」徽标 / 设置页「同步账本」卡，见上表）。

### P1 —— 近期做（中难度、修正双端不对称）

| # | 候选 | 影响 | 难度 | 一致性 | 改造面 |
|---|---|---|---|---|---|
| M4 | **同步密钥治理三入口**（A-3：版本显示 / v1→v2 迁移 / rekey 重置云端） | M–H | S–M（1d） | H | 纯 Dart（复用既有桥 + 二次确认） |
| M5 | **日历议程档补齐**（B-3，对齐桌面第三档） | M | S–M（1d） | M | 纯 Dart（复用桌面 `VirtualGroupedList` 分组/滚到今天语义） |
| M6 | **「修改后立即同步」生效**（A-2） | M–H | M（1–2d） | M | Dart 写路径触发 `cloudSyncPushOnly`；须评估耗电/流量，建议独立批次 |
| M7 | 备份导出预览补设备信息（`fullBackupDeviceInfo`，A-5#7） | L | S（0.2d） | M | 纯 Dart |

### P2 —— 规划做（动 DDL / 动同步面 / 成本高）

| # | 候选 | 影响 | 难度 | 一致性 | 改造面 |
|---|---|---|---|---|---|
| M8 | **清单文件夹分组**（B-1） | M–H | M–H（3–5d） | M | DDL 加列 + `SYNCABLE_TABLES` + 侧栏层级 UI + 拖拽层级语义 |
| M9 | **任务预计时长 + 时间块**（B-2） | M | H（5–8d） | L–M | DDL + 周/日档 + 拖拽时段（手势冲突面大） |
| M10 | **子任务多层嵌套**（B-4） | L–M | H（3–5d） | L–M | DDL + 递归 UI + `percent_done` 多级回算 |
| M11 | 节假日更新时刻可配（`holiday_set_fixed_hour`，A-6）——**已完成** `docs/07 #59` | L | S | L–M | 纯 Dart（FRB 生成物已就绪，零 codegen）+ 设置项 |
| M12 | 日历订阅 URL（C-1） | M | H | L | 网络轮询 + 外源只读层 + 隐私权衡 |
| M13 | 倒数日 / 纪念日（C-2） | L–M | M | L–M | 新表 + 独立视图 |

### 一页结论

- **最值当的三项（P0，合计约 2 人日）**：M1 ICS 导入（core + 桌面早已就绪，移动端只差一个文件过滤器与预设 chip）、M2 提醒相对档、M3 列表行信息补齐 —— 全部零 Rust、零 DDL。
- **结构性空白只有四类**：清单文件夹分组、任务时长与时间块、子任务多层、日历订阅 —— 前三类是 TickTick 的「厚度」，但都动 DDL 与同步面；建议按需而非按对标清单推进。
- **移动端相对桌面的不对称已收口**（2026-09-23：议程档 / 行内提醒徽标 / 密钥治理入口 /「修改后立即同步」四项全部落地，见 `docs/07 §五 #54–#58`）——这类改动零协议风险、可直接复用桌面既有实现，比相对 TickTick 的差距更值得优先处理。

---

## 八、有意不跟进（保定位）

| 项 | 理由 |
|---|---|
| 番茄钟 / 专注计时、习惯追踪 | `docs/07 §五`「不建议跟进」+ 2026-09-23 维持：偏离待办单一职责 |
| 协作 / 指派 / 共享 | 与「单人 / 免注册 / E2E」定位冲突 |
| i18n / Web 版 | `docs/02` 已定非目标 |
| 位置提醒（C-3） | 需持续定位权限，与零遥测/本地加密叙事直接冲突 |
| 语音输入（C-4） | 平台 STT 可能联网，隐私面不可控 |
| 底部 Tab 导航改版 | 与 `docs/04`/`docs/05` 复刻蓝本冲突；`docs/07 §2.3` 已判非差距 |
| 「滑到底直接完成」/ 星标弹跳 | `docs/05 §9.2` 已明确的有意边界 |

---

## 九、圈选与文档流转

1. **本文档不另立 backlog**：`AGENTS.md` 明确 `docs/07 §五` 是 backlog 唯一状态源，本文所有条目均为「候选（待圈选）」。
2. 用户圈定后：把选中项按 `docs/07 §五` 的表格式（影响/难度/一致性/依据）**新增行**并入，编号顺延；同时在 `CHANGELOG.md` `[Unreleased]` 补条目。
3. 完成后按 `docs/07 §五` 惯例回写「✅ 已完成（日期 + 要点）」；本文档保持为**盘点快照**，不承担状态跟踪。
4. 下批盘点直接复用 §二「不列为差距」名单与 §三 A-5/A-6 判定表，避免重复评估已完成项与平价遗留项。
