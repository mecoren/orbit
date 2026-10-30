# Changelog

本文件记录 Orbit 的所有显著变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> **0.1.0 条目口径**：0.1.0 是项目整体首个版本，本条目由 2026-08-23 初始提交至
> 2026-09-26 的**全部工作**归并总结——首批至 2026-09-24 的 git 记录（543 次提交：
> 222 feat / 130 fix / 32 perf / 84 docs，余为 chore / refactor / style / test 及其他；
> 计数口径为提交主题前缀，`git rev-list --count` 与 `findstr` 实测，PowerShell 原生
> 管道会吞掉含中文主题的行故不用它计数）加上 2026-09-25/26 的移动端对标优化批次；
> 按模块归并——合并同源提交、剔除过程性改动，不逐条罗列中间过程；逐条明细以
> git 历史与 `docs/07` backlog 为准。历史 `v0.1.0`（2026-09-15）tag 及其后的全部
> 未发布工作（云同步存储结构重构、第五轮探查收口、内存门禁入库、移动端快速添加
> 面板与抽屉口径收口等）已一并并入本条目。

## [Unreleased]

### 优化：看板截止条目对齐日历——逾期红胶囊 + 悬浮完整时刻（2026-10-30）

看板卡片的截止一直只有「日历图标 + 灰色 MM-dd」：逾期只靠整段染红、看不出具体时刻（卡片宽度也放不下），与日历视图行尾的截止处理不一致。现对齐日历口径：①逾期未完成渲染红色胶囊（`bg-destructive/10` 底 + 11px font-medium，与日历同款）；②截止条目挂 Tooltip——逾期「已逾期 · 截止 M月d日 HH:mm」，未逾期「截止 M月d日 HH:mm」（`zhCN` locale，随主题色底白字）。docs/04 §3.3 同步。

### 优化：看板拖拽卡顿——dnd 订阅拆薄壳，帧间隔 83ms→16.7ms（2026-10-30）

dnd-kit 的 internal context 在指针跨卡时更新，`useDraggable/useDroppable` 的每个消费者都会重渲染。此前 hook 直接挂在卡片与列本体上：卡片一体订阅 → 每次跨卡把整张卡的子树重建；列一体订阅 → 整列连带 `getVirtualItems()` 的 15 行树重建（实测一次拖拽整列重渲染 86 次），dev 下 60 张卡的看板单次拖拽生成上万 React 元素、p95 帧间隔 83ms、最长一次掉帧 483ms。现改为：①`SortableKanbanCard` 薄壳承载 dnd 两 hook 与 listeners，`KanbanCard` 本体只吃 `dragging/isOver/dragAttributes`；②`DroppableKanbanColumn`（isOver 边框 + droppable 注册）包 `KanbanColumnBody`（虚拟行树），列本体不再订阅拖拽上下文；③`dragging` 改由 `useDraggable().isDragging` 内聚，不再把 `draggingId` 提到列 props（一起手就击穿整板 memo）；④`onClearSelection` 改 `useCallback` 恒定引用、`displayReminder` 产物按任务 `useMemo` 缓存。实测同一场景（240 任务 / 4 列 × 60）：p95 83ms → 16.7ms、掉帧（>32ms）28 → 1、最长帧 483ms → 50ms、长任务 24 段 → 1 段。docs/04 §3.3 补「拖拽性能口径」防回退。

### 修复：看板列滚动条越拖越短——虚拟高度容器被 flex 压缩（2026-10-30）

卡片区是 `flex flex-col` 的滚动容器，虚拟化高度容器（`height: getTotalSize()`）作为 flex 子项默认 `flex-shrink: 1`，被压回视口高度（533px）；绝对定位卡片溢出该容器，滚动高度退化为「已渲染行下缘」——每往下滚一屏 `scrollHeight` 就长一屏（60 条列实测 1016 → 3392px），滚动条滑块随之越拖越短。给高度容器补 `shrink-0` 后 `height` 与 `scrollHeight` 一致（4440px 恒定），滑块稳定在 ~12%。顺带把看板拖拽源改为**任何排序档都挂**：此前用 `!sortable` 一并禁用，非「拖拽顺序」档整块拖不动，与「跨列改归属任何档位都可用」的既定口径矛盾；列内落位仍只在 manual 档生效，其他档位落位时提示「列内顺序由当前排序档决定」。docs/04 §3.3 同步（含 flex 陷阱）。回归锚点：`tsc` 零错误、同列/跨列/滚动后拖拽与 due 档提示实测、看板多选批量 e2e 绿、`vitest` 769 绿。

### 优化：看板卡片版式收敛——去顶部优先级孤线 + 元信息单行对齐（2026-10-30）

卡片原来自上而下是「顶部 2px 通栏优先级色条 → 勾选 + 标题 → 标签行 → 日期行」：色条悬在标题上方只剩一道孤线（P0 浅灰尤其像误画的分隔线），标签行与日期行又挂在卡片左内边距上、比标题少缩进 26px，整卡看着是歪的；多选态还常驻一个 `opacity-0` 的隐形勾选圈，把勾选框与标题整体右推。现改为：①**撤掉顶部色条**，优先级统一由勾选框描边承载（与列表行 2026-10-29 口径一致），多选态勾选框让位给多选框时改由左缘竖条续上，同时删掉隐形勾选圈、卡片左侧不再留空槽；②标签/截止/提醒/进度**合并为元信息单行并对齐标题左缘**（逾期未完成染 `text-destructive`——旧版只有灰色 MM-dd，逾期在看板上没有任何信号）；③单卡高度约 98→68px，同屏能多看约三成卡片。回归锚点：`tsc` 零错误、看板多选批量 e2e 绿、亮/暗两套截图目检。

### 优化：加载动画双端统一「环 + 绕行点」（2026-10-29）

移动端 45 处裸 `CircularProgressIndicator`（外加节假日补写弹层里 1 处不定态 `LinearProgressIndicator`——拿不到总数时走转圈，有确切比例才画进度条）与桌面端 26 处 `Loader2 + animate-spin`、3 处「让图标自己转」（同步状态云图标 / 诊断刷新 / 同步卡状态刷新）、7 处三块弹跳 `EqualizerLoader`（启动等待、退出同步遮罩、懒加载兜底、统计、回顾中心、规划今天、创建按钮），全部收敛到一个原语：静止细环 + 环内一个匀速绕行的实心点（几何按边长比例推导——描边 8%、点心轨道 42%、点半径 34%、轨道透明度 0.28，一圈 1200ms 线性；只表达「在动」，不画进度弧）。移动端新建 `shared/widgets/shadcn/orbit_spinner.dart`（`OrbitSpinner`，默认色取 `themeAccent`，深底显式传色，周期走 `AppMotion.spinnerOrbit`；自带方形占位，调用方不再套 `SizedBox`）；桌面新建 `components/ui/spinner.tsx`（`Spinner`，`currentColor` 继承按钮文字色，尺寸沿用原 `size-*` 类，动画走新增的 `--animate-orbit-spin` token），`components/EqualizerLoader.tsx` 无引用后删除。语义进度（带 `value` 的进度条 / 同步 checked-total）与骨架屏、下拉刷新（平台 `RefreshIndicator`，与蓝本同口径）保留不动。回归锚点：移动 `flutter analyze` 干净 + 新增 `orbit_spinner_test` 10 绿 + 节假日页 18 绿；桌面 `tsc --noEmit` 零错误 + `vitest` 769 绿（含新增 `spinner.test.ts` 5 例）+ `pnpm build` 产物确认生成 `.animate-orbit-spin` 与 `@keyframes orbit-spin`。

### 优化：保存筛选器弹层重排 + 入口更名「保存为筛选器」（2026-10-29）

弹层从 448px 窄栏单列改为 672px 分组构建器：名称即标题（无边框大标题输入，与任务创建抽屉同款，不随条件区滚走），条件按「状态 / 截止时间 / 范围 / 时间范围 / 属性」分区，项目/标签胶囊与日期控件不再挤成多行；头部与底部动作条常驻、仅中段滚动（`max-h-[88vh]` + `flex-1 overflow-y-auto`），条件再多也不会把「保存」按钮顶出视口——与项目编辑弹窗同为底部固定动作条口径（此前 14 键长表单整窗滚动，「保存」落在视口外）。语义统一：桌面「···」菜单与移动端列表 ⋮ 面板的「存为视图」一并更名「保存为筛选器」，与弹窗标题「保存筛选器 / 编辑筛选器」、侧栏分组「筛选器」同一口径（e2e 选择器与移动端 `save_as_view_test` 同步）。回归锚点：`tsc` 零错误、桌面 `vitest` 764 绿、e2e 筛选器构建器与更多菜单用例绿、移动 `save_as_view_test` 4 绿。

### 新增：列表排序档「开始时间」（2026-10-29）

「↑↓ → 排序」菜单在「截止时间」与「优先级」之间补「开始时间」档，口径与截止时间同构：无 `start_date` 的行恒沉底、默认升序、方向档只翻主键；同值回落创建时间降序。全链路同步：桌面 `TaskSortKey`/`BASE_SORT_DIR`/`sortTasks`/`loadSortKey`、移动 `TaskSortKey`/`baseSortDir`/`sortTasks`/⋮ 排序面板/`buildPagedQuery`；键集分页 core 侧新增 `TaskSortKey::Start`（parse/order_by/游标，NULL 沉底谓词抽成 `null_last_cursor` 与 due/done_at 共用），增量迁移 `0002_task_start_sort_index.sql` 建 `idx_todo_tasks_keyset_start`（表达式索引承载 NULL 尾段）；桌面 `ipc-mock` 与移动 mock 桥同语义复刻（排序、游标、换档作废）。回归锚点：core 分页档位矩阵含 start 升/降序逐页遍历 38 绿、桌面 `vitest` 91 绿（新增 start 升降序用例）、移动定向 147 绿、e2e 排序菜单用例绿、`tsc` 零错误、`pnpm frb` 生成物仅注释同步。

### 变更：撤回主列表日期分节，改回平铺（2026-10-29）

主列表的「今天 / 以后 / 无日期 / 已完成」四档分类头与左侧快捷视图完全重复，撤掉；列表回到「逾期处置条 + 平铺任务」两段——逾期集仍置顶（33px 处置条：折叠箭头 + 计数 + 「顺延」下拉，折叠态仍存 `todo_section_collapsed`），其余任务按当前排序档平铺，已完成整段沉尾（不夹在待办中间）。逾期行在元信息首位补一枚 `已逾期` 红色胶囊徽标——分节撤掉后长列表里只剩「标题/元信息染红 + 相对时间」两处弱信号，行级需要自报身份；**拖拽顺序档（manual）不再抽段**：逾期置顶会让整段行不给拖拽把手，251 条逾期时首屏无一行可拖——该档改为完全不抽段、不沉尾（顺序即 position 序），逾期行同样可拖，处置条降级为只读总览 + 顺延（计数取壳层全局逾期集，不随滚动漂移）；`groupByDueSection` / `DUE_SECTION_META` / `DUE_SECTION_ORDER` 与对应单测、e2e「节头计数 + 折叠/展开」用例一并移除；`docs/04` 骨架与 `docs/07 #118` 已标注撤回。回归锚点：`tsc` 零错误、桌面 `vitest` 762 绿、Playwright 77 绿。

### 优化：列表分页页长 500 + 进度收进标题行（2026-10-29）

839 条的视图按 200 条/页要翻 5 次，滚动中反复出现整行「向下滚动加载更多 · 已加载 X 条 / 共 Y 条」的提示。三处一起改：①**单页 200→500**（回到 docs/13 §七 P1 方案给的 500–1000 首屏档；core `limit` 钳制上限 1000，桌面 `TASK_PAGE_WINDOW` 与移动 `kTaskPageWindow` 同值同改），翻页次数压到 1/2.5；②**触底预取余量 5 行→20 行**（`TASK_PREFETCH_ROWS`，列表与表格同口径），500 条页长下触底前约两屏就开始拉下一页，滚到底不再停在转圈；③**原独立条幅收进标题行**——未加载完时标题旁显示「已加载 X / Y」，加载中转「正在加载更多…」，滚动口径进 Tooltip，末页到账回落为纯计数（列表/表格/Logbook 同口径）。e2e 用例改 1200 条逾期数据锚定 500 → 1000 → 消失。回归锚点：`tsc` 零错误、桌面 `vitest` 全绿、Playwright **78 绿**、移动 `flutter analyze` 干净 + 分页定向用例 35 绿。

### 修复：列表触底「加载更多」只推进一页就卡死（2026-10-29）

分节化后主列表滚到已加载窗口末尾不再继续翻页，增量条幅长期停在「已加载 200 条 / 共 1177 条」。根因在面板层预取锁：`useRef` 锁的释放依赖 `useEffect` 观察到 `isFetchingNextPage` 由 true 回 false，而本地 SQLite 查询快到该中间态被 React 批处理合并、从不提交渲染，effect 再也不重跑——锁置 true 后永久不再放行，之后的每次触底都被静默吞掉（首屏那一页是唯一能通过的，因为锁的初值就是 false）。改为直接用 React Query 的 `hasNextPage` / `isFetchingNextPage` 实时快照做守卫（同一次触底的重复调用仍由视图层的行数水位挡住），并补 e2e 用例「1200 条逾期任务 → 滚到底 500 → 1000 → 末页进度消失」锚定连续翻页。回归锚点：`tsc --noEmit` 零错误、`vitest` 766 绿、新增用例与既有「节头计数 + 点击折叠/展开」用例双绿。

### 优化：行勾选框二合一 + 多选态优先级竖条（2026-10-29）

多选态不再多出一个勾选框：列表视图与表格视图的行首**原完成框就地变多选框**（选中蓝底白勾、未选中空心灰描边），退出多选（清空选中）即恢复完成语义；shift 点击仍做区间选择。**默认态视觉不变**——列表行优先级仍在完成框描边上（同一信息不上两处颜色）；只有进入多选、完成框变多选框后，优先级才移到行最左缘竖条（`absolute inset-y-1.5 left-0 w-1 rounded-full`，六档全显含 P0 浅灰）承接，表格视图竖条本就常显。表格视图的 hover 多选框随之移除（不再额外占位），多选入口改为右键菜单「多选」+ x 键（与列表/看板一致），多选态下点击行 = 切换勾选而非打开详情。

### 功能：同步取消（N33，协作式分片取消）——双端（2026-10-28）

大附件分片上传可持续数十秒，此前双端都只有「转环」没有「停下」的出口。本批按 ADR 0010 的建议做**协作式取消**（边界检查，不做在途请求强杀）：最坏再等一片（~5MiB）。

- **core**：新增 `sync::cancel::SyncCancelToken`（`AtomicBool`）；`CloudSyncError::Cancelled` + `category_tag()` 新增 `cancelled`（主动取消不是故障，不并入网络错误）；`SyncAdapter` 增加 `attach_cancel`/`is_cancelled` 两个默认方法，`BasePathAdapter` 在**每次**远端调用前检查，S3/WebDAV 的分片循环**逐片**检查——S3 命中即 `AbortMultipartUpload` 清理会话，WebDAV 不写 `head.json`（完成信号缺席 → 下轮 prepare 判定不可续传并整体清理），下载半截的目标文件删除。
- **引擎**：`SyncEngine::request_cancel()` 只在运行中置位（空闲返回 false 且**不置位**，否则下一轮一开跑就自杀），取消标记只在 `acquire_lock` **成功之后**复位；`sync_now`/`push_only`/`pull_then_push` 在阶段边界（备份后 / pull 后 / push 后 / 附件拉取后）各查一次；退避等待改为 200ms 分段探测（限流档最长 120s，睡满再查等于让用户干等）；**取消不落 Error 进度帧**（否则双端指示器被染成红色故障态）；历史记 `cancelled`（不算失败率），`last_synced_at` **不推进**（回收站守卫线只认完整轮次）。
- **双端**：Tauri `cloud_sync_cancel` 与 FRB `cloud_sync_cancel` 同名同参（桥门禁自动配对）；桌面设置页同步卡运行中把「同步」换成「取消」，取消中保持「取消中」直到命令 reject 回到 finally；移动端设置页「立即同步」与同步面板主按钮同样在运行中换「取消同步」。取消回包按 `[cancelled]` tag 特判为中性提示（「已取消同步」），历史行用灰点 / 「已取消」，不再显示错误文本。
- **回归锚点**：core `sync_cancel` 集成 **3 绿**（已取消入口零请求；S3 中段取消发起 Abort 且不 Complete 不落对象；WebDAV 中段取消不传后续分片不写 head.json——用假服务 `slow_first_put_ms` 把「首片在途」做成确定窗口，不靠睡眠竞速）、引擎取消语义 **6 绿**、`cargo test -p orbit-core --lib` **930 绿**、`sync_fault_matrix` **14 绿**；桌面 `tsc` 零错误、`vitest` **766 绿**；`flutter analyze` 零问题、`flutter test` **1100 绿**；桥门禁 `bridge-parity`（桌面 184 / 移动 198）与无界审计双绿。
- **已知非本批问题**：`calendar_screen_test`「长按日格」一例在 HEAD 上即红（与本批无关）。

### 功能：桌面列表多状态筛选 + 日期状态分节折叠（2026-10-28，docs/07 #118）

对齐 TickTick 主列表的「多状态筛选 + 分节收起」心智，截图口径的五档状态按本仓模型落成。

- **状态筛选改多选**：工具栏「状态」从单选 radio 换成 checkbox 多选（待办 / 进行中 / 已完成任意并集，空集 = 全部状态，「未完成」= 待办 + 进行中两选）。谓词全链下推：壳层 `statusFilters` 集合 → `ListFilter.status_in`（单档且非 done 仍走原 `status` 等值，其余交集合；派生状态口径与看板 status 列同源，`done` 档兼容 `done=1` 老数据）。「存为视图」仅在恰好单档且非「未完成」时固化 status 等值键，多档丢弃（对话框提示）。
- **列表分节 + 点击收起**：任务按「已逾期 / 今天 / 以后 / 无日期 / 已完成」五节分组，节头 33px（箭头 + 语义色 + 计数），**整行点击折叠/展开**，折叠态持久化 `todo_section_collapsed`；空节不渲染，逾期节不给拖拽把手；节头与任务行合成同一条虚拟流（节头也过虚拟窗），j-k 键盘导航只走可见任务序列。逾期判定 = 截止早于 now（与行内红字同源），完成态优先入「已完成」不进逾期节。（2026-10-29 撤回日期分节，仅保留逾期处置条，见本文件顶部变更条目）
- **回归锚点**：`tsc --noEmit` 零错误、桌面 `vitest` **764 绿**（`task-filters` / `saved-filter-builder` 新增多选与分节用例）、Playwright **77 绿**（新增「节头计数 + 点击折叠/展开」用例，状态子菜单断言同步改多选）、core `cargo test -p orbit-core task_predicate` **14 绿**（`status_in` 派生状态 + done 兼容）。

### 功能：移动端同步进度流接通 + 桌面同步历史类型筛选（2026-10-28，docs/07 #117）

两处都是「桌面已有、移动端或反向缺失」的双端不对称，且都在同步域——最需要可观测性的地方。

- **移动 · 同步进度流**：移动端引擎此前用 `NoopProgressSender`（模块注释自陈「sync-progress 尚无 StreamSink 消费方」），同步期间只有一个不动的转环。大附件同步（分片上传可跑数十秒）时用户无法判断是在推进还是卡住。落地：FRB 新增 `FrboProgressSender`（`SyncProgress` → 有界 broadcast 通道，容量 64）+ `subscribe_sync_progress(sink)`；`SyncStatusButton` 信息面板在「立即同步」期间显示进度条 + 阶段文案。**core 侧零改动**——`ProgressSender` trait 本就是为「Tauri Event / FRB StreamSink」两种壳抽象的，桌面 `TauriProgressSender` 已实现前半。**按 origin 过滤只认 manual**：后台自动同步的进度不该在用户点开的面板里闪。
- **桌面 · 同步历史类型筛选**：`SyncHistoryCard` 此前固定 `cloudSyncHistory("all", 50)`，排障时想「只看失败的那几次即时推送」只能自己在上百行里翻；移动端早有四档筛选。补齐 all / 完整同步 / 即时推送 / 启动同步四档，切档先置空列表再拉取（否则切档瞬间仍显示上一个 scope 的行，像「筛选没生效」），副标题随档改口、空态点名当前档位。零协议改动——`scope` 入参与 `ipc-mock` 的过滤本就支持四档。
- **设计要点（同步进度）**：①**有界是硬约束**——进度按模块/附件条数产生，一次大附件同步可达数百条，无界通道在 UI 来不及消费时会累积；超出容量丢最旧事件（订阅方收 `Lagged`），正是「最新值有意义」该有的语义。②通道独立于 `SyncRuntime` 槽位：`send` 在同步主流程中同步调用，sender 反向去锁 `SYNC_RUNTIME` 会在持锁同步期间自锁。③DTO 压平成 `SyncProgressDto`（phase 判别 + 其余字段可空）而非 enum 家族——core 是内部标签 enum，FRB 不能镜像变体；压平后与桌面 `SyncProgressEvent` 逐字段同形。④**不引入 `serde_json::Value`**：进度是高频流，动态 JSON 只会让 UI 线程多做一次解析。⑤文案直接用 core `display_text` 单点产出，Dart 侧不另拼一套（双端各拼一份必然漂移）。
- **回归锚点**：`flutter analyze` 零问题、`flutter test` **1100 绿**（新增 2 例：推 manual 进度 → 进度条 value=0.3 且文案为 core 产出的「正在上传任务...」；推 background 进度 → 面板不显示）；桌面 `tsc --noEmit` 零错误、`vitest` **764 绿**、`e2e` **74 绿**（新增 `sync-history-scope.spec.ts` 3 例）；桥门禁与无界审计双绿（有界通道标记被正确识别）。
- **已知非本批问题**：`calendar_screen_test`「长按日格」一例、smoke 两例（读屏 j 键播报 / 更多菜单视图切换）在 HEAD 上即红——已分别 stash 掉本批改动复跑确认。

### 功能：「桥已就绪但 UI 零入口」收口三件——移动云端存储补孤儿数据桶、移动同步排障、桌面日志入口（2026-10-28，docs/07 #114）

全仓普查后确认「账面功能缺口已清空」，剩余真实缺口集中在「core/命令就绪、壳层零入口」。本批按三处补齐，另清两处已被替代的前端包装。

- **移动 · 孤儿数据桶回收**（#96 尾款）：`cloud_sync_api::cloud_orphan_chunks_gc` 与 Tauri 命令早已就绪，但 `crates/orbit-flutter` 零 `orphan` 命中，移动端完全不可达。新增 FRB `cloud_orphan_chunks_gc` + DTO 镜像 `OrphanChunkGcResult` + Rust/Mock 两实现（mock 恒 0，与桌面 `ipc-mock` 同口径）；设置页「云端清理」卡改名「云端存储」，两行并列——附件清 `assets/`、数据桶清 `tables/`，判据分别是云端引用集与清单索引，卡片说明写清两者目录互不相交。**不做二次确认**：删的桶按定义不可达，core 侧另有 24h 窗口 + 服务端不回 mtime 一律跳过两道兜底，桌面入口同样一键执行。
- **移动 · 单向同步排障**：桌面 #107 已有「仅推送 / 先拉后推」两钮，移动端只有同步历史里的类型文案而无触发入口。新增「同步排障」卡，两钮走既有 `cloudSyncPushOnly` / `cloudSyncPullThenPush`（零新协议）；文案写明只用于判断卡在哪一侧、连续点会让对端改动晚一轮可见——与桌面把它放在诊断分区而非同步主路径同口径。
- **桌面 · 日志文件入口**（`docs/02 §九` 的 M6+ 项）：插件自 2026-09-13 就把日志落到 `{app_log_dir}/app_log.log`，但用户侧无任何入口。新增只读命令 `log_overview`（目录绝对路径 + 文件清单名字/大小/mtime，按修改时间倒序上限 20 条，**不读日志内容**——日志可达数十 MB，整份读进前端只会让设置页变卡）+ 诊断页「日志文件」卡（打开目录 / 打开最新日志 / 逐文件可点），打开走既有 `plugin-shell` open 通道，零新插件零新权限。路径口径与 `lib.rs::log_dir_writable` 逐字一致（含用发布标识、不跟随 `data_dir_override.json`）——两处一旦分叉就会出现「显示 A、写 B」；目录不可读时如实回报 `readable:false` + 原因，不用空清单冒充「没有日志」。
- **清理**：删除 `tauri.ts` 两处已被替代的前端包装——`csvImportExecute`（旧阻塞入口，保留等于留一条回退到「大文件静默卡住」的路）与 `attachmentsGc`（附件回收现由 `db_maintenance` 三件套统一承载，单独调用会让账本/关联/缓存上限三步错拍）。其余 16 个零引用包装**有意保留**（`docs/10 §A-5` 已登记的桌面命令平价遗留，且部分被 `ipc-contract` 的 `MOCK_ALLOWLIST` 按命令名分类）。
- **回归锚点**：`flutter analyze` 零问题、`flutter test` 1098 绿（新增 4 例：仅推送/先拉后推的成功 toast 各报对应模块数、孤儿附件扫描空态、孤儿数据桶回收空态）；桌面 `tsc --noEmit` 零错误、`vitest` 753 绿（`ipc-contract` 新增 ⑤ 锁 `LogOverview` 字段与「按 mtime 倒序」这条 UI 契约）、`e2e` 73 绿；壳 `cargo check` 通过，新增文件 clippy 零告警。
- **已知非本批问题**：`calendar_screen_test`「长按日格」一例在 HEAD 上即红（已 stash 复跑确认）；壳 clippy 仍有 21 处 `doc_lazy_continuation`（`db_cmd` / `notification_scheduler` / `saved_filter_cmd` / `template_cmd` / `sync_scheduler` / `aumid_registry`），同样在 HEAD 上即存在。

### 文档：勘误四处——修 #90 重复行、重写一页结论、撤回倒数日待评估、更新强调色口径（2026-10-28，docs/07 #115）

- **`docs/07` #90 行尾粘连了一整段 #89 正文**（2072 字符），表格结构损坏、按行检索会重复命中；截断回状态列为止。
- **`docs/07 §六「一页结论」重写**：原文「最大的三个洞 = 捕捉效率 / 规模化渲染 / 工程护栏」是 2026-08-25 v0.1.0 快照，三项均已收口（#7/#32 NLP、#5/#105 虚拟化与键集分页、#6 CI + #19 e2e），「P0 六项一个迭代做完」的判断前提不复存在。新结论：账面已无功能缺口，剩余为同步域两个产品概念（N33 同步取消 / N15 设备注销）、桥已就绪但 UI 零入口的三处、以及真机/规模化验收欠账；性价比判断从「补功能」反转为「接线 + 补验收线」。
- **`docs/10` C-2 倒数日**仍写「待评估（低优先）」，与 `docs/07 #76` 的 ⛔ 撤回冲突（生活记录域；蓝本 wait-home 本就有更完整的 `important_events`）。改为已撤回并给出判据与出处。
- **`docs/05 §2.1` 强调色**仍写「自定义入口记 M6+」，实际 #112（2026-10-27）已落地外观页 10 色 + 自定义 HEX。更新为现状。
- **`docs/07 #81` 表述修正**：原记「移动端对称项待补」，核实 `sub_list_screen.dart` 早有完整实现（`_postponeOverdue` 18:00 归一、已过则越到明天、区块头入口、manual 档横幅卡、多选态不挂、反向补丁入撤销栈），改为已闭环并新增 #116 记录该核实结论。

### 构建：Android 发布签名固定化——禁止 debug 兜底，支持跨版本覆盖安装（2026-10-28）

- **Gradle 硬失败**：`apps/mobile/android/app/build.gradle.kts` 在 release 任务缺 `key.properties` 时抛 `GradleException`，不再回落 debug keystore。随机 debug 签名会让不同机器/不同 CI 运行产出不同签名的 APK，覆盖安装报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`；debug 构建不受影响。
- **CI 注入**：`release.yml` 的 audit job 校验 `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` 四项 Secrets；android job 构建前还原 `android/app/ci-release.keystore` 并写 `key.properties`（`storeFile=app/ci-release.keystore`）。
- **生成工具**：新增 `pnpm keystore:android`（`scripts/generate-android-keystore.mjs`）与 `apps/mobile/android/key.properties.sample`；脚本在 `~/.orbit/orbit-release.keystore` 生成 RSA-2048 keystore、写 `key.properties`，并打印四个 Secrets 与 base64 命令。keystore 与密码必须离线备份——丢失后存量用户只能卸载重装。
- **文档**：ADR 0004 证书 TODO、`docs/08 §3.6/§6`、README 安装与更新口径同步。

### 功能：双端未完成缺口收口——筛选器下推 / 桌面零入口 / 移动存储与平板适配 / 检查更新（2026-10-27，docs/07 #107–#113）

审查口径：`docs/07` 的 #1–#106 与 `docs/12` 的 G1–G16 已全部收口，真实缺口集中在「桥已就绪但 UI 零入口」「双端不对称」「注释明写留后续」「分页条件未下推」四处；本批按三类逐项补齐。

- **共用 · 保存筛选器条件下推（#107，P0）**：桌面 `buildPagedFilter` 新增 `savedConditions`，选中保存筛选器不再回退万行全量；`mergeSavedFilterConditions` 纯函数按 14 键 AND 合并（区间取交、`done_from` 与未完成冲突→恒假集合、损坏 JSON 忽略），主列表与逾期段同口径（逾期段 `due_to` 取 min 防条件上界被放宽）。移动端补齐 `priority_min` 合并与「标签空交集→恒假」两处谓词丢失。
- **桌面 · 零入口接线（#108）**：保存筛选器可编辑（`saved_filter_update`）；同步恢复页「导入密钥包」（结构校验 + 已有本机密钥时二次确认 force）；设置页冲突数量角标；回收站「清理过期」；诊断页运行环境卡（云母 build/透明效果/DWM before→after/设备 ID）与「仅推送 / 先拉后推」排障入口。
- **桌面 · 零入口接线（#109）**：详情单字段编辑进 Ctrl+Z（8 字段白名单，文本类仅在 blur/Ctrl+Enter 入栈）；表格表头按标题/截止/优先级排序；看板列满「在列表中查看」出口；未缓存附件「立即同步」；桌面「有描述」投影（命令 + hook + 日历行图标）。
- **桌面 · 窄窗（#110）**：900–1023px 下表格 `min-w-[860px]` + 横向滚动（表头与数据行同容器），设置页导航/内边距收窄；日历窄窗本就上下堆叠、回顾中心本就单列，未改动。
- **移动 · 存储工具（#111）**：设置 → 存储清理（未使用附件清单 + 多选删除，确认抽屉列数量与体积）；详情附件「另存到指定目录」（core `export_task_attachment` 新增 FRB 包装，按块流式复制）；设置页回收站「立即清理过期」（如实提示因未同步被保留的条数）。
- **移动 · 强调色（#112）**：`OrbitAccents.themeAccent` 改为可配置静态（默认仍 `#4E8CFF`），外观页新增「强调色」行（10 色预设与桌面同源 + 自定义 `#RRGGBB`），启动首帧前恢复偏好；`todoAccent` 与优先级/状态色不跟随。
- **移动 · 平板/横屏与检查更新（#113）**：解除竖屏锁定，新增 `OrbitBreakpoints`（compact<600 / medium / expanded≥840）；expanded 下非清单页常驻 320dp 侧栏、详情限宽 760、子列表 720、抽屉 640、月历日格封顶 520（360dp 竖屏零变化）；补充无障碍字号锚点（360dp + `textScale` 2.0）后暴露并修复月历日格溢出：月历子树字号封顶 1.3（定宽定高网格，页面其余文本仍按系统档）、日号恒单行；宽屏**不做日历双栏**（整页单滚动 + 点圆点改期定位共用同一 Scrollable，拆栏会切断手势与定位）；关于页「检查更新」走 core `update_api`（仅点击时请求一次 GitHub Releases 清单，不轮询/不下载/不安装，失败降级发布页），版本比较纯函数 `isNewerVersion`；删除关于页过时的「Unreleased」日志条目。
- **评审修复（同批）**：①**宽屏重复侧栏**——壳层改为按「非清单模块」嵌常驻侧栏（清单页根页本身就是侧栏整页），常驻形态不再注册全局快捷方式处理器（`ShortcutReceiver` 单槽，双实例会在 dispose 时清空导致快捷方式静默失效）；②**保存筛选器语义同源**——本地回退通道（标题排序档）也把条件与当前项目/未分组/工具栏状态/优先级/hideDone 取交集，与分页通道一致，切排序不再改变列表内容；③**空 `project_ids`** 两端统一为恒空结果（与本地 `includes` 同口径，脏数据不再出现「列表空、表格全」）；④月历字号封顶只作用于网格（自绘页头仍按系统档），日号恒单行。
- **回归锚点**：core `cargo check --workspace --all-targets` 通过、`cargo clippy --workspace --all-targets -D warnings` 零告警、lib **914 绿**；桌面 `tsc --noEmit` 零错误、vitest **753 绿**、e2e **73 绿**；移动 `flutter analyze` 零问题、`flutter test` **1095 绿**（新增分页下推 9 + 6 例、断点 3 例、版本比较 3 例、大字号码点 1 例、宽屏侧栏 1 例）。
- **SKIP（本机无设备/环境，未实测，不伪造数值）**：50k 真机 UI 验收线（首屏/滚动 p95/heap/DOM）、移动端真机内存基线（`perf-metrics/mobile-baselines.json` 仍为空）、Linux runner RSS 阈值。

### 维护：代码收尾四件套——桌面启动轻维护 / 附件事务化 / 移动端附件路径入参 / 审计翻正（2026-10-27，docs/07 #106）

- **桌面启动轻维护**：新增 `spawn_idle_maintenance`（`db_maintenance_cmd`），启动 15s 后跑 core 的 `db_maintenance_routine`——WAL checkpoint → 附件 GC → 附件缓存上限 → 日志 TTL → 统计仅在缺失时。与移动端 `boot_gate` 同一函数、同一顺序；`VACUUM` 仍只走手动「立即维护」。补掉此前如实记账的「桌面不点维护就只涨不清」缺口（`CHANGELOG` 2026-10-25 条目）。
- **附件写入收进单事务**：`attachment_repo::upsert_in_tx` + `finish_add_attachment` 把账本 upsert 与任务关联 INSERT 放进同一事务，提交后才 emit / 清缓存 / 记历史。启动期附件 GC 判「无引用」只看 `todo_task_attachments`，原两个独立写事务之间窗口会把刚上传的文件当孤儿删掉。新增 `add_attachment_rolls_back_ledger_when_link_rejected`（上限拒绝 → 账本行随事务回滚、既有挂载不受影响）。
- **移动端附件改路径入参**（docs/07 #94 遗留）：FRB 新增 `task_attachment_add_path`、`OrbitBridge.taskAttachmentAddPath` 与 Rust/Mock 两实现；详情页文件来源传 file_picker 路径（core 按 256KiB 块流式读盘），不再 `readAsBytes` 整份过桥；拍照等内存内字节来源仍走字节版。契约用例补两条断言（磁盘字节数 = 挂载大小、源文件缺失抛错）。
- **`sql-fetch-all` 审计复核收口**：19 个文件 / 58 处逐个人工判定（按 task_id 等键查询、结果集 = 桶数/项目数/列数等天然小集、导出·GC·同步索引这类函数内临时集合），结论随源码 `bounded-by-data` / `bounded-by-lifecycle` 标记落地；提示级清零后规则由 `blocking:false` 翻正为拦停，`audit-unbounded --gate` 0 处 0 组。
- **a11y 地标层**：侧栏两态改 `<nav aria-label="侧栏导航">`，任务面板 / 回顾中心 / 回收站 / Logbook 补 `role="region"` + 区域标签；全量 `role` 语义化（`list`/`grid` 等）仍属持续项。
- **回归锚点**：core lib 914 绿、桌面 vitest 743 绿、flutter 1081 绿、`flutter analyze` 零问题。

### 修复：统计热力图年份切换时尺寸跳动 + 年份栏被裁（2026-10-27）

- **现象**：切到 2023 年时格阵整体缩小一点（格宽少 1px、格阵矮一截），下方分布卡跟着上下跳；年份按钮到第 4 个「2023」时被卡片下沿裁掉一半（滚动条按既定口径隐藏，看不出可滚）；窄窗口下格阵横滚还会把整列年份推出可视区。
- **根因**：① `layoutHeatmap` 的总列数用循环游标回报，末日恰为周日时会先 `++col` 再退出，多算一列——2023 全年报 54 列、2024 报 53 列，`floor` 后格宽差 1px、格阵高度差 7px；② 年份列原先 `maxHeight` = 月份标签 + 格阵高度，4 个按钮即溢出；③ 年份列与格阵同处一个横向滚动容器。
- **修法**：① 总列数改取末日实际所在列（回归用例锁定 2023=53、2012=54）；② 排版统一按 54 槽（闰年且 1/1 为周日的最坏情况）计算格宽与格阵宽高，所有年份几何完全一致，切年份不再引起页面回流；③ 年份列移出横向滚动容器并去掉限高，按钮压到 24px，4–5 个年份完整显示；④ 动态格宽改按滚动容器宽度计算。

### 功能：开发环境一键生成测试数据（2026-10-27）

- **入口**：设置 → 测试数据（仅 `pnpm tauri dev` 的 DEV 构建列出；分区内再自检一次，release 构建下不渲染）。三档规模（300 / 1,200 / 5,000 条任务）一键写入项目树、标签、任务、子任务、提醒、评论、标签关联与任务关联，并可一键清除。
- **两步确认**：生成与清除都走「说明范围 → 再次确认」两屏，每屏 3 秒冷静期（第二屏 `key` 强制重挂，冷静期从满格重计而不是继承已走完的倒计时）；第二屏标题固定「再次确认…」并复述后果，两屏都标明当前规模与「仅操作 `dev-seed-` 前缀行、手工数据不在范围内」。
- **core**：新增 `api/dev_seed_api.rs` —— 单事务批量 INSERT（不逐行走 `create_todo_*`，几千行一次提交后按表补发一条 db-change），重复生成先按 uuid 前缀 `dev-seed-` 物理清除上一批，标题统一 `【示例】` 前缀，手工数据不受影响。日期按本地时区日界铺开，覆盖已完成 / 逾期 / 今天到期 / 未来 30 天 / 无日期 / 回收站六档；**完成时间按「近密远疏」铺满近 3 年**（前 10 天每天一条保证连续天数与近 7 天卡片有数，其后 18% 落两周内、14% 落 30 天内、23% 落半年内，其余铺到 3 年前），热力图可切年份看往年，且 `created ≤ done ≤ updated` 保持自洽；约八成任务带开始日期（有截止的提前 1–4 天开工，每 13 条留一条「只有截止」；无截止的半数只有开始、半数完全未排期），完成行的截止日期跟随完成时间，不再出现「两年前完成、截止在下个月」；软删行先按活行插入再 UPDATE 成墓碑，避免混进 FTS 搜索结果；提交后置脏拼音索引，首查自动对账。
- **桌面壳**：新增 `commands/dev_cmd.rs` 薄转发，命令在 release 构建里直接返回不可用（`cfg!(debug_assertions)` 常量折叠）；前端 `lib/tauri.ts` 补 `devSeedDemoData` / `devSeedClear` 与 DTO 镜像，`ipc-contract` allowlist 登记「开发专用、冒烟不走」。
- **移动端**：FRB 桥新增 `api/dev_seed.rs`（`dev_seed_demo_data` / `dev_seed_clear`，release 下返回「不可用」），设置 → 测试数据入口按 `kDebugMode` 隐藏、页面内再自检一次；mock 桥按 core 的比例与 uuid 前缀在内存库铺样本；生成/清除与桌面同文案的两步确认（第 1 步说明范围 → 第 2 步「再次确认」，第二步取消不落库），每步确认钮带 3 秒冷静期（`showConfirmBottomSheet` 新增 `holdSeconds`，倒计时期间禁用并显示「请阅读后果（Ns）」，与桌面 `DangerousConfirmDialog` 同口径），写后由 db-change 失效链自动刷新列表与统计。
- **回归锚点**：`cargo test -p orbit-core --lib dev_seed_api` 5 例（各实体齐全 + 重复生成不叠数据、前缀齐全、读通道分布覆盖 + 软删行不进 FTS + 完成时间跨年与时间线自洽、完成时间分布的段内占比、清理只删示例行）；`test-data-confirm.test.ts` 2 例锁定「两个动作都是两步、第二步标题带『再次确认』且确认钮文案不同」；移动端 `test/test_data_page_test.dart` 2 例（mock 生成/清除按 uuid 前缀收敛且不动手工数据、页面确认后结果卡回显）。

### 功能：日历视图支持按开始/截止日期排布（2026-10-26）

- **日期口径切换**：日历工具栏新增「开始 / 截止」分段（与月/周/时间/年/议程同款分段，补 `aria-pressed` 选中态），格子圆点、右栏按日分组、议程列表统一按当前口径分桶并持久化到 `todo_calendar_date_field`（缺省 = 截止，存量行为不变）。口径缺失的任务不回落另一字段——两种日期语义混排会让用户判断不出拖拽改的是哪个字段。
- **范围取数**：按开始日期时改用 `start_from`/`start_to` 圈定可见窗口（并清掉快捷视图注入的 `due_to`），避免「今天开始、明天截止」的排期任务被截止区间挡掉；mock 桥补同名谓词。
- **拖拽与新增**：按开始日期看时拖拽改写 `start_date`（保留原时刻，零点不升级 18:00），右键日格新增预填开始日期；行尾时刻跟随口径，逾期红保持截止语义（按开始日期时不染红）。
- **空态文案**随口径切换（「没有带开始日期的任务」等），e2e 新增 `calendar-date-field.spec.ts` 覆盖默认口径、切换、补数据回流与切回截止。

### 性能：50k 规模档键集分页与列表窗口化（docs/07 #105，2026-10-26）

- **core 读通道**：新增 `list_todo_tasks_page`（键集游标 `ListCursor` = 排序键值 + 主键，`has_more` 靠多取一条判定，不逐页 `COUNT`）与 `todo_task_overview`（总数 + 按项目未完成计数，替代壳层万行数组内存分组）。`ListFilter` 新增 `sort_key`/`sort_dir`（manual/due/priority/created 四档下推）、`ungrouped`/`priority_eq`/`exclude_due_before` 三个谓词。
- **`title` 档显式拒绝分页**：前端按 `localeCompare("zh-Hans-CN")` 排中文拼音序，SQLite 的 BINARY collation 复刻不了（多音字/声调都会分叉）；强行下推会让翻页边界与视觉顺序不一致——该档继续走全量单页通道，core 侧返回可读错误而不是静默乱序。
- **索引**：新增 `0011_task_keyset_indexes.sql` —— priority/created/due 三档的 `(is_deleted, 排序键, id)` 索引（due 档用表达式索引把「无截止沉底」纳入排序），manual 档复用既有 `idx_todo_tasks_position`。
- **桥接双端同签名**：Tauri `todo_tasks_page`/`todo_task_overview`、FRB 同名函数与镜像 DTO、桌面 `ipc-mock` 同语义实现（含游标谓词与四档排序）。
- **桌面窗口化**：列表与表格改 `useInfiniteQuery`，200 条/页，虚拟列表在末尾 5 行内预取；逾期置顶段独立查询后按 id 去重（时间戳不进 queryKey——否则每分钟重拉首屏、滚动位置回跳）；条幅从「任务数超过单次加载上限」改为「已加载 X / 共 Y」；壳层全量通道按视图启停（列表视图不再拉 10k），周回顾/分诊打开时各自取全集；分页窗口下禁用容器尾部拖拽落位（跨窗口落点不可知）。
- **修复**：`query-patch`/`hideFromQueries` 原假设缓存是行数组——分页缓存是 `{pages:[{items,next_cursor}]}`，原实现会在 `old.some` 抛 `page.map is not a function`，且异常发生在 `todoTaskComplete` 之前，表现为「点勾选没反应、删除不提交」。现同时支持「页 = 行数组」与「页 = `{items}`」两种形态。
- **回归锚点**：`keyset_paging_tests`（四档 × 多页长逐页遍历必须等于单页全量、换档作废、总览口径）、`buildPagedFilter` 单测、`ipc-contract` 分页保真用例、`query-patch` 分页形态用例；桌面 vitest **730 绿**、e2e **73 绿**。
- **看板/四象限/日历/Logbook 接入窗口通道**：新增 `list_todo_tasks_board`（先 `GROUP BY` 拿每组总数，再逐组 `LIMIT 60` 取前 N 条；组键与前端 `kanbanColumnKey` 逐字一致）；看板列头报真实总数、列内注明「还有 N 条」；四象限的「已完成」筛选与 `groupEisenhower` 同口径（追加 `done = 0`，显式筛已完成时为空）；日历按月窗口 `due_from`/`due_to` 取数（月/周/议程/时间轴取前后各一月，年视图整年），范围查询首屏计入加载态；Logbook 新增 `done_at` 排序档 + `0012_task_done_at_index.sql` 表达式索引（`done_at` 为空的历史行沉底），滚到底部续拉。标签看板保留全量——列定义随任务标签动态变化，窗口内的标签会让空列消失。
- **移动端窗口化（同日补做）**：Dart `ListFilter` 补全 core 全量谓词，并新增 `start_from`/`start_to`（日历时间轴按块起点取数，NULL 不命中；桌面「按开始日期」日历复用同一谓词）。`buildPagedQuery` 纯函数承载「视图态 → ListFilter」下推矩阵（标签筛选与保存筛选器条件同样下推 `label_ids`/`has_reminder`/`has_attachment`/`has_open_subtask`/`created_from`/`done_from` 六谓词，与当前列表范围取交集；唯一回退项只剩标题排序的拼音序与标签看板列定义）；`TaskWindowNotifier`（family + autoDispose）持键集游标与续拉守卫，滚动距底 400px 预取；逾期置顶段独立查询后按 id 去重；列表完成行改独立 `done_at` 通道（前 20 条 + SQL 总数），主窗口只装未完成行；看板/矩阵走 `todo_tasks_board`，日历按可见范围（due ∪ start 两路并集）取数，Logbook 按 `done_at` 续拉。
- **移动端全量通道收敛**：侧栏/底栏角标、角标刷新与提醒快照改读 `todo_task_overview` 聚合或按需全量；移除 `listenManual(todoTasksProvider)`（它会让万行全量常驻）；周回顾打开时按需取全集；多选改选中即记对象快照（滚出窗口仍可批量撤销）、拖拽限定已加载窗口且 `has_more` 时禁止落位尾部、入场动画已知集只增、今日条改有界两路查询；看板/矩阵首帧渲染常显面板，不再闪整屏骨架。
- **回归锚点**：mock 桥分页/看板契约 8 例（done/项目集合/start 区间/`exclude_due_before`/游标续拉/看板组键与每列限额）+ 下推矩阵 22 例；flutter 全量 **1075 绿**、analyze 零问题。
- **修复**：移动端多选「已选 N 项」与批量动作实际落地数不一致——`_toggleSelect` 在拿不到行快照（窗口重建后 `_visibleById` 无该 id）时仍把 id 塞进选中集合，而 `_runBatch` 只处理有快照的行，导致选 3 条只写 2 条（2026-10-27 真机 3000 行库实测复现，批量设优先级 3 选 2 落地 + Toast「已调整 2 个任务」）；改为拿不到快照即不入集合，保证两个集合恒等；重装后同场景复验「已选 3 项 → 3 条 UPDATE」，Toast 文案同步为「已调整 3 个任务」。
- **新增**：`crates/orbit-core/examples/seed_demo_db.rs` 种子库生成器（明文、全类型关联、分布可调），配 `--rows` 一条命令产出真机/性能验收库；替换流程写在文件头（含原库备份回滚），本批真机验收用的 3000 行库即由此生成。
- **修复**：桌面 mock 的 `todo_tasks_page`/`todo_tasks_board` 漏了 keyword 谓词（core `build_task_where` 一直有），全量 e2e 表现为「搜索后不匹配的行仍在列表里」（单跑该用例因前序状态不同会假绿）；补 `filterByKeyword` 叠加并加契约用例 ④-4（标题命中/描述命中/看板组总数三断言）；e2e 复跑 **73 绿**。
- **未做（如实记账）**：50k 真机验收线（首屏 <1.5s、滚动 p95 <20ms、heap ≤120MB、DOM ≤1200、筛选 <300ms）未实测——目前只有搜索 p95 与单测/冒烟证据，按本仓口径「未实测不下结论」。

### 性能：维护改全量 ANALYZE，`PRAGMA optimize` 退场（docs/13 §七 P5，2026-10-25）

- **评估**（新增探针 `crates/orbit-core/examples/pragma_eval.rs`，50k 行、每口径 30 采样；同库同池，逐连接抓 `EXPLAIN QUERY PLAN` + `sqlite_stat1` 摘要 + `INDEXED BY` 强制计划比价）：
  - **统计有明确收益**：首屏列表 10～12ms → **0ms**（计划从 `idx_todo_tasks_trash` + 临时 B 树排序，变为 `idx_todo_tasks_updated_at` 有序扫 + `LIMIT 50` 提前终止）；按项目 9→0ms、未完成 10→0ms。
  - **不是缓存的功劳**：先把表与两个候选索引整扫一遍（15ms）再量，无统计仍是 10～11ms——排除了「ANALYZE 顺带预热页缓存」这一误判（首版探针差点据此得出反向结论）。
  - **必须全量，不能采样**：`analysis_limit=400` 把等值前缀的平均行数夹在采样规模上（`is_deleted=0` 写成 `50000 401`，真值 `50000 25000`，低估 60 倍），重开池后仍是排序计划 9/15ms——**等于没建**。全量 ANALYZE 50k 行 47～88ms，`stat1` 只多 25 行，VACUUM 后库反而更小。
  - **`PRAGMA optimize` 恒为空转**：从未分析过的库 0ms 且 `stat1` 0→0（默认掩码 `0xfffe` 不含 `0x1`）；10 倍膨胀导入（5k→50k、同一连接）后 3ms、`stat1` 摘要一字未变；新鲜态 0～1ms 幂等。
  - **导入后不需要 ANALYZE**：10 倍膨胀的陈旧统计下计划与时延都不变（0/0ms）——缩放的是绝对行数，选择率比例没变。
  - **生效范围是连接**：`ANALYZE` 后不重开池时 3 条连接只有 1 条换新计划，再 `VACUUM` 也只到 2 条（`VACUUM` 不刷新语句缓存）；要全量生效需重建连接池。
- **改动**：`db_maintenance_api` 的 `PRAGMA optimize` 换成全量 `ANALYZE`（新 `analyze_plan_stats`，注释带上述口径与「为什么不采样」），顺序仍在 `VACUUM` 之前（`VACUUM` 原样保留 `sqlite_stat1`，已单独实测）。
- **回归锚点**：`maintenance_builds_plan_stats` —— 维护跑完 `sqlite_stat1` 必须真实存在且覆盖 `idx_todo_tasks_updated_at`；旧实现（`PRAGMA optimize`）在从未分析过的库上跑完是**空的**，这条用例会翻红。lib **893 绿**（892 + 1）。
- **空闲引导（桌面已接线）**：`setup` 期 `db_maintenance_cmd::spawn_idle_plan_stats` —— 启动后 15s 在后台运行时调 core 的 `maybe_analyze_plan_stats`，只在「从未建过统计 + `todo_tasks` ≥ 5k 行」时真跑一次，跑过之后每次启动零成本空转；不压启动预算（全量 ANALYZE 50k 47～88ms、1M 行外推 1～2s，与 P1「首屏可交互 < 1.5s」互斥），失败只记日志。
- **启动路径不再 VACUUM（移动端已改）**：新增 `db_maintenance_routine`（WAL checkpoint → 附件 GC → 缓存上限 → 日志 TTL → 统计仅在缺失时），移动端 `boot_gate` 改调它。实测（`scenarioD_maintenanceCost`，50k / 21MB，两跑）：稳态整套维护 **435～499ms，其中 VACUUM 332～429ms 占 76%～86%，而空闲页为 0**——重写 20MB 换回 0 字节；只有「当次 TTL 删掉 2 万行日志」那一次才有 416 页 / 1.7MB 可收。改后这条路稳态 **5ms**，首次多一次 62～79ms 的 ANALYZE。手动「立即维护」保持无条件 VACUUM（`freelist_count` 看不见「页内半空」的内部碎片，只有整库重写能收）。
- **顺带否证一个想当然的理由**（`scenarioE_bootContention`）：维护与首屏列表并发跑，列表 p50 **0ms** / p95 0～1ms / max 1～2ms，与无维护基线一致（WAL 读者不被写者挡）。故这条改动的收益是**省 IO 与电量**（移动端每次冷启动一次整库重写 + flash 磨损），不是「VACUUM 卡首屏」。
- 桌面仍只做统计引导、不顺手加 GC/TTL：`gc_local_attachments` 判「无引用」= 无存活 `todo_task_attachments` 行，若账本行与关联行不同事务写入，空闲 GC 会撞进窗口误删；移动端该风险是既有的，桌面不新引入。桌面「不点维护就只涨不清」的日志缺口留待确认写入事务性后单独接。
- 连接池 3 与 `cache_size` 8MB 口径未动（实测差异全部来自计划选择与连接级语句缓存，与池大小无关）。

### 修复：拼音对账移出查询路径（docs/07 #104，2026-10-25）

- **问题**：`search_all` 在纯字母查询时每次调用都先跑 `search_pinyin::reconcile`——3 条 `DELETE ... NOT IN` + 3 条 `LEFT JOIN title 比对`，合计 6 次全表扫描，等于**在只读查询路径上挂写事务**。50k 行下单次对账 ≈316ms，把拼音通道 p95 拖到 374ms、四口径合计 p95 337ms，**未达 P1 的「50k 搜索 p95 < 150ms」验收线**；而检索本身只要 11ms。
- **修法（脏标记 / 事件驱动对账）**：新增 `0010_search_pinyin_state` 单行哨兵表（`dirty`/`gen`/`reconciled_at`，不同步不进备份，缺行等价「需对账」）。`search_all` 拼音分支改为 `ensure_fresh`——只读哨兵行 O(1) 判定，脏了才对账一次；对账结束按 `gen` 乐观锁清零，对账期间并发的置脏不会被误清。
- **置脏点（直写路径穷举，5 处）**：云同步 `pull_all`（`changed_tables` 命中三表）、全量备份恢复 v1/v2（无条件——DELETE + 裸 INSERT 后索引必失配）、批量导入 `bulk_import_records_from_values`、冲突副本 `restore_conflict`。
- **顺带补齐三处裸 INSERT 的索引缺口**（原先靠「每查必对账」掩盖，只置脏会变成长期漏命中）：子任务转出 `promote_todo_subtask`、重复任务下次实例、复制任务 `duplicate_todo_task` 提交后精确 `sync_row`。
- **复测（同口径 50k，每口径 30 采样，两跑）**：拼音首字母 316/374ms → **15/22ms 与 13/23ms（降 17 倍）**，四口径合计 p95 337ms → **77ms 与 72ms（达标）**；10k 档 p50 2 / p95 8ms（修前 6/14）、拼音首查 129ms，门禁三阈值 8/16/500ms 全绿。宽词/短词的小幅波动属跑间抖动（该路径未改）。
- 契约用例 3 例：直写未置脏→查不到、置脏→下一查补齐且清零；`gen` 单调 + 清零乐观锁 + 干净态幂等；两条裸 INSERT 路径提交即入索引。
- **新增直写路径的硬约定**：凡直接写 `todo_tasks`/`todo_projects`/`todo_comments` 的 `title`/`content` 且不经 generic_repo 钩子，提交后必须 `mark_dirty`（或 `sync_row` 补那一行）。
- **纪律的强制层**：新增集成测试 `tests/search_index_guard.rs` 扫描 `src/**/*.rs` 生产代码（剔除 `#[cfg(test)]`、注释不参与，字符串照常扫），把三表裸写按「文件 × 动词 × 表」计数，与人工审过的台账（13 组 / 21 处，逐组写明「已补索引」或「不碰检索列」）比对；新增一处裸写即失败并打印实际语句。已实测会翻红（临时塞一条 `UPDATE todo_tasks SET title = ?` 报「台账 1 处，实际 2 处」）。顺带把 `generic_repo` 软删里内联的三表 `matches!` 收敛为 `search_pinyin::is_indexed_table`，索引面向表清单只剩一处定义。

### 性能：搜索延迟基线 + 拼音对账批量化（docs/13 §七 P3，2026-10-24）

- 操作级探针新增 `global-search` 场景（10k 任务库）：中文 FTS 唯一 / 宽词、两字短词 LIKE 兜底、拼音首字母四口径各 30 次采样，报 p50/p95 与拼音首查耗时；`operation-baselines.json` 增 `overallP50Ms=8` / `overallP95Ms=16` / `pinyinFirstMs=500` 三项阈值（含 15% 缓冲，防对账路径被改回逐行）。
- 10k 实测：四口径合计 p50 6ms / p95 14ms（FTS 唯一 2/2、宽词 7/8、LIKE 短词 2/3、拼音 11/15），内存四指标照常登记（堆 +0MB）。
- 修复存量库首次拼音检索卡顿：`search_pinyin::reconcile` 逐行走 `sync_row` 的自动事务，per-row fsync 让 10k 行首次回填耗时 7.8s；改单事务批量写（WAL 一次提交）后 **133ms**。
- FTS `optimize`/`merge` 时机评估（`perf-metrics/fts-optimize-eval.py`，10k/50k 四状态各 30 采样）：导入后 optimize 只省 0.12ms 却要 0.5s，日常 10k 库零收益；仅「更新量 ≥30% 且库 ≥50k」时有效（p50 1.01→0.22ms），且 optimize **不缩体积**（需 VACUUM）。结论：不挂导入/启动路径，按段行数阈值在空闲窗口触发。
- 50k 全链路补测（探针三档同口径，每口径 30 采样）：FTS 唯一 1/1ms、宽词 46/65ms、短词 LIKE 16/19ms、拼音首字母 **316/374ms**，四口径合计 p50 36ms / **p95 337ms**——**未达 P1 的「50k 搜索 p95 < 150ms」，超 2.25 倍**。唯一超标且唯一超线性的是拼音通道（10k→50k 数据涨 5 倍、延迟涨 24 倍），FTS 主路径不受影响。
- 根因定位：`search_all` 在拼音查询时每次调用都先跑 `search_pinyin::reconcile`，3 条 `DELETE ... NOT IN` 加 3 条 `LEFT JOIN` 共 6 次全表扫描——只读查询路径上挂写事务（`perf-metrics/pinyin-reconcile-cost.py` 逐语句拆解：DELETE 34ms + LEFT JOIN 42ms + 命中 10ms）。已立项 `docs/07 #104`（脏标记 / 降频两方案），本轮只测量未改产品代码。
- 环境结论修正：探针 exe 并非「完全无写盘权限」——`target/` 与工作区其他目录内被拒（`OS Error 5`），复制到用户 `%TEMP%` 后写盘正常，Python 3.13.14 / Node 22.22.2 则不受限。此前记为「环境阻塞」的 50k 遗留由此解除。
- 详见 docs/13 §七 P3 记录。

### 新增：排程作息偏好编辑（docs/13 §五 F3 阶段三，2026-10-24）

- 「规划今天」的作息可编辑：工作开始/结束、午休两端（半小时档）、排程粒度（5–60 分钟）、无时长兜底（15–120 分钟）、逾期是否纳入——落 cfg_kv 单键 JSON（本机偏好不同步，与「每台设备可有自己的作息」口径一致）；core `set_day_plan_prefs` 逐字段校验钳制（工作窗倒挂整体回落默认、午休按回落后的工作窗校验无效清 0），损坏偏好读取回落默认不阻断。
- 双端编辑面：桌面弹窗头部「作息」钮展开内联编辑区；移动端排程抽屉头部「作息」入口逐项底部抽屉选档（选择类交互统一口径）。保存即按新作息重拉预览（queryKey 变化 / `_load` 重载）。
- 测试：core 偏好 3 例（roundtrip/非法回落钳制/损坏 JSON），day_planner 21 例全绿；桌面 e2e「改工作开始 → 预览随之变化 + 重开回显」（plan-day 5 例）；移动 widget 同款（全量 1045 绿）。

### 新增：排程应用——勾选写入开始时间与我的一天（docs/13 §五 F3 阶段二，2026-10-24）

- 「规划今天」从只读预览升级为一键落地：预览槽位逐条勾选（默认全选）→ 应用写入 `my_day_date`（今天零点）+ `start_date`（槽起点），**不修改截止日期**；core `apply_day_plan` 单事务批量写入，任一行失败整批回滚。
- 撤销闭环：core 返回每行的 prev 快照，双端经既有撤销通道写回——桌面 Ctrl+Z（通用撤销栈）、移动端 WaitToast 撤销钮（5 秒窗）。
- 应用语义自然闭环：候选谓词补「今日已有开始时间的任务不再入候选」，应用过的任务不重复建议；应用后预览即时重拉。
- 测试：core 应用 4 例（写值+截止不动/prev 写回/缺行整批回滚/空 noop）；桌面 e2e「勾选应用 + Ctrl+Z 撤销」（fake clock 固定 10:00 逐值断言，plan-day 4 例）；移动 widget 同款（全量 1044 绿）。

### 新增：拼音/首字母搜索（docs/13 §五 F5，2026-10-24）

- 「gzs → 工作总结」「gz → 工作」「gongzuo → 工作…」级别的中文检索：新增 `search_pinyin` 派生索引表（0009 迁移；任务/项目/评论三类的检索文本转无声调小写全拼 + 首字母，非汉字原样保留可直命中；多音字取首选音）。**不同步、不进备份白名单**——可随时整表重建的派生索引，白名单/模块计数零变更。
- 写路径双通道维护：任务/项目/评论的创建与更新在 generic_repo 实时重建单行索引（微秒级），软删即移除（无幽灵命中）、回收站恢复即重建；同步合并/CSV 导入等直写路径由搜索入口的幂等对账兜底（补缺失 / 清幽灵 / 按 title 不一致重建，通常 0 行改动，1 万行 < 5ms）。
- 搜索合并：纯字母查询在既有 FTS/LIKE 主路径之外额外命中拼音通道，结果按分类回源活跃行**追加在主路径之后去重**（中文精确命中优先于拼音猜测，排序不劣于现状）；双端搜索 UI 零改动自动受益。
- 依赖：`pinyin` 0.11（MIT、零依赖，spike 实测 10k 回填 2.7ms / 索引 165KB / 查询 p95 279μs，见 docs/07 #101）。
- 测试：core 纯函数 5 例 + 集成 8 例（含 migrate 种子行首次对账补索引、直写兜底、幂等零改动、幽灵清除、恢复重建、泛型软删覆盖），lib 882 绿；双端全量回归（vitest 716 / e2e 70 / flutter 1043）。

### 新增：规划今天——本地启发式日排程只读预览（docs/13 §五 F3 阶段一，2026-10-24）

- core 新增 `day_planner_api`（ADR 0013）：纯函数 `plan_day_slots` 完全在「相对今天零点的分钟」整数域运算（DST 安全、确定性输出）——排序五桶（逾期 → 今日带时刻截止 EDF → 纯日期截止 → 我的一天 → 未排期带时长，桶内短任务优先），放置硬约束（不排到过去、工作窗 09:00–18:00 挖午休、今日带时刻截止不越线），无时长任务兜底 30 分钟；每条建议带可解释理由（已逾期 N 天 / 截止 HH:mm / 紧急·高优先级 / 我的一天 / 填充空档 / 顺序安排），放不下的进未排入清单带原因，总量超容量只提示不阻断。候选四类谓词单条 SQL 收敛；零 DDL、不 emit、不进同步白名单。
- 桌面：「···」菜单新增「规划今天」——弹窗含容量头（剩余可排 / 候选分钟）、时间轴建议列表（HH:mm–HH:mm + 理由徽标分色：逾期红 / 截止琥珀 / 优先级主题色）、未排入区、超载警示条；显式标注只读预览，不写库。
- 移动端对称：子列表 ⋮ 面板「规划今天」底部抽屉（FRB 新域 planner.rs + mock 桥镜像 core 口径），同款容量头 / 时间轴 / 未排入 / 超载琥珀条。
- 阶段二（应用写入：写我的开始时间与我的一天、不改截止、快照撤销）与阶段三（作息偏好 cfg_kv 可编辑）另行立项。
- 测试：core 纯函数 11 例 + API 3 例（lib 869 绿）；桌面 e2e `plan-day.spec` 3 例（vitest 716 / e2e 全量 70 绿）；移动 widget 3 例（analyze 无问题 + 全量 1043 绿）。

### 新增：收件箱分诊——未分组任务逐条定归属（docs/13 §五 F2，2026-10-24）

- 对标 Things/OmniFocus Inbox 的「捕获→澄清」环节：未分组任务一次一张卡逐条决定归属，零 DDL、零协议（全部复用既有更新/删除/项目列表与撤销通道）。队列=未分组未完成任务（打开即快照，写库后的缓存失效不重算队列）；**归属动作**（归入项目 / 排今天 / 排明天 / 删除 / 跳过）完成即出队，**字段修正**（清日期 / 改优先级）不出队；排期落当日 18:00（与视图创建默认同口径）。
- 桌面：全屏分诊弹窗 + 键盘流——`1-9` 归入项目（色点快捷位 + 超出项目数走下拉）、`T/M` 今天明天、`N` 清日期、`P` 优先级循环（无→高→紧急）、`D` 软删（5 秒延迟提交撤销窗）、`Enter/S` 跳过、`Backspace` 撤销上一条字段动作并把卡片拉回队首；进度条与结束「收件箱已清空」正反馈 + 「已分诊 X · 跳过 Y · 删除 Z」汇总。入口三处：「···」菜单「分诊未分组」、侧栏未分组行 hover 分诊钮、以及经新增 `triageIntent` 意图计数器的跨层触发。
- 移动端对称：`/todo/triage` 全屏流程页（动作全落拇指区——归入项目底部抽屉色点选、今天/明天/清日期/优先级六档抽屉、删除确认抽屉 + WaitToast 撤销走回收站恢复、页头「撤销」回滚字段动作）；入口在子列表页头 ⋮ 面板「分诊未分组」；`TodoTask` 补 `copyWith`（可空字段配 clear 旗标）。
- 测试：桌面 shared 纯函数 7 例 + e2e `triage.spec` 5 例（vitest 716 / e2e 全量 67 绿）；移动纯逻辑 5 例 + widget 5 例（flutter analyze 无问题 + 全量 1040 绿）。

### 新增：项目回顾节奏与回顾中心（docs/13 §五 F1，2026-10-24）

- 每个项目可自带回顾周期（对标 OmniFocus Review，GTD 维护闭环的「按项目检查目标是否仍有效」）：`0008` 迁移给 todo_projects 加 `review_interval_days` / `review_last_at` / `review_snooze_until` 三列（NULL=未设置，不新增同步表，列随整行同步，白名单零变更）。
- core 新增 `project_review_api`：到期判定纯函数 `review_due_day_index`（本地日序号整数域——从未回顾立即到期、到期=上次回顾日+周期、暂缓只推迟不重置周期）+ 待回顾清单（逾期天数降序、未完成任务单遍聚合计数）+ 标记已回顾/设置周期/暂缓三个语义化写路径（开启时从未回顾过则从设定日起算，防刚开开关即被到期徽标轰炸；关闭清残留暂缓、保留历史）。
- 桌面：侧栏新增「回顾」入口（到期计数徽标，折叠窄条圆点变体）与项目行「待回顾」琥珀点徽标；回顾中心面板 `/todo/review` 列出到期项目（周期/上次回顾/未完成数/逾期徽标），「开始回顾」复用周回顾三步向导（任务集按项目过滤，走完自动标记已回顾），另给「稍后一周」暂缓与「已回顾」快捷收口；编辑项目弹窗新增「回顾周期」下拉（关闭/每天/每周/每两周/每月）。
- 移动端对称：`/todo/review-center` 回顾中心整页（同款三动作，复用周回顾底部弹层，中途退出不推进周期）、侧栏功能入口卡「回顾」行与项目行琥珀点、编辑项目页「回顾周期」段（底部抽屉挑档）；FRB 桥四命令 + codegen 产物入库，Mock 桥含 core 到期判定镜像。
- 缓存失效链：桌面 `["todo-project","review-due"]` 挂 todo_projects/todo_tasks 双表映射，移动 `db_invalidation` 补 reviewDue 目标（回顾行的未完成计数聚合自任务表）。
- 测试：Rust 纯函数 4 例（DST 安全的 noon 基点日算术）+ 内存库 API 5 例，lib 855 绿；桌面 shared 纯函数 13 例 + e2e `project-review.spec` 4 例，vitest 709 绿；移动纯函数 11 例 + mock 桥口径 7 例 + widget 5 例，flutter 1030 绿。

### 新增：NLP 快速输入补时刻/时长/重复（docs/13 §五 F4，2026-10-23）

- 双端快速输入解析器升级 v2（`parse-quick-input.ts` / `parse_quick_input.dart` 同口径）：新增**时刻**（`HH:mm` 含全角冒号、时段词+X点(半)——凌晨/清晨/早上/上午/中午/下午/傍晚/晚上，中午仅认 11/12/1/2 点口语窗口、裸 `X点半`/`X点钟`、组合词 `今晚/明晚X点`）、**时长**（`N小时`/`N分钟`/`Nh`/`N小时M分钟` 组合/`半小时` → `duration_minutes`）、**重复**（`每天`/`每周X`/`每周`/`每月X号`/`每月` → `repeat_mode/after/weekdays` 三列并给出锚点日）。歧义防护：裸 `X点`（「三点原因」枚举）、「一个半小时」「30分钟后」相对语、数字粘连（`比分2:10`）一律不识别保原文。
- 组合规则：显式日期 token 与时刻组合；无日期取重复锚点（每天=今天、每周X=未来最近该日、每月X号=顺延下一有该日号的月）；纯时刻已过顺延明天——重复为按天档同样顺延，周/月锚点保序列对齐不顺延；显式日期优先于重复锚点。NLP 显式时刻不再参与今日/本周视图的 18 点归一。
- 双端一致性验收：新增共享测试向量 `parse-quick-input-vectors.json`（54 组，期望值写本地时区日期串防 CI 时区漂移），TS vitest 与 Dart test 跑同一组输入/期望（双端各 71 例全绿，含既有 17 例零回归）。
- 接线四处置为同一优先级口径（NLP 显式值 > 手动选择 > 视图默认）：桌面 QuickAddBar 预览 chips 扩展时长/重复并支持**全维度逐项取消**（点 × 按解析值键控，token 改动自动复活）；移动快加面板与分享接收随任务一次落库；移动完整表单 chips 同步扩展并可在保存时逐项取消应用。
- e2e 新增「NLP 快速输入：时长/重复/显式时刻随快加一次落库」用例；既有「重复任务完成推进」用例标题避开新 token。附带修复：`ipc-mock` 补 `plugin:window|` 系 no-op（main.tsx 启动链 `window.show()` 未 mock 的报错此前污染 7 个 e2e 用例的 console errors 断言）。

### 新增：云端孤儿附件清理（T1.4，2026-10-23）

- 设置 → 诊断新增「云端存储」卡片（仅已配置云同步时显示）：「清理云端孤儿附件」扫描 `assets/` 与 `assets_parts/` 中无任何设备引用、且写入超过 30 天的对象，列明整包/分片形态、密文体积与最后写入时间，支持多选/全选/全部删除，破坏性操作走 `DangerousConfirmDialog` 五秒冷静期。移动端 UI 入口留第二批（FRB 桥接已就位）。
- core 新增 `cloud_sync::asset_gc`：判据为「云端对象集 − 云端引用集」，引用集取 `tables/todo_task_attachments` 云端分桶中 `is_deleted = 0` 行的 hash 并集——以云端表（跨设备并集）为权威，不看本机账本；服务端不提供 mtime 的对象一律跳过。删除前重读清单比对 `epoch`，扫描后他端 push 过即拒绝执行并要求重扫；分片形态先删 `head.json` 再逐 `.bin`，单对象失败只记 errors 不中断。
- 适配器新增 `list_assets_with_meta`（裸 hash + 密文体积 + mtime + 整包/分片形态）：WebDAV 用两次 Depth:1 PROPFIND 归并（递归列举等于每附件一次请求，不可用），S3 用前缀分页列举聚合；`BasePathAdapter` 显式转发，避免退化为全零元数据。
- 配套自愈（必做，非可选）：附件 pull 侧新增「活跃引用 + 云端无对象」对账——本地仍有明文的置 `is_uploaded = 0`，下一轮 push 以同一 hash 自动重传（封住清理竞态与用户手工误删网盘对象的历史静默缺附件）；本地也无副本的汇总一条错误让 UI 可见。
- 桥接四处同口径：Tauri `cloud_unused_attachments_scan` / `cloud_unused_attachments_delete`、`tauri.ts`、`ipc-mock`（账本模型模拟云端对象集）、FRB 镜像 + codegen 产物。
- 移动端：设置 → 云同步配置新增「云端清理」卡（清单底部抽屉、全选/多选、epoch 过期自动重扫），`OrbitBridge` / Rust / Mock 三实现同口径；mock 无云端后端，清单恒为空。
- 同卡新增「回收孤儿数据桶」（docs/07 #96 尾款）：`cloud_orphan_chunks_gc` 把手动入口接到 `collect_and_delete_orphan_chunks`，清的是同步清单已不再引用、且写入超过 24h 的 `tables/` 分桶，与附件对象无关。
- 测试补强：pull 置待传 → 下一轮 push 真重传的闭环用例；epoch 竞态改为真实改写云端清单后验证拒绝；删除零调用方的 `attachment_repo::delete_orphans`（第二套孤儿判定口径）。

### 新增：诊断页「清除未使用附件」（2026-10-23）

- 设置 → 诊断 → 本地存储卡片新增「清除未使用附件」入口：弹窗列出 `sys_attachments` 中无任何存活任务引用的账本行（文件名 / 大小 / 缓存状态，按体积降序），支持多选批量删除与一键全部删除，破坏性操作走 `DangerousConfirmDialog` 五秒冷静期。
- core 新增 `asset_api::list_unused_attachments` / `delete_unused_attachments`，口径与 `gc_local_attachments` 同源（存活引用集 = `todo_task_attachments.is_deleted = 0`）；删除执行时重查引用集复核，弹窗打开期间被重新挂载的 hash 跳过不删。只删本地文件与账本行，云端 `assets/` 对象保留（多设备安全）。
- 新增 shadcn 风格 `Checkbox` 原语（Radix 底座 + 语义 token）；桥接三处同口径：Tauri 命令 `attachments_unused_list` / `attachments_unused_delete`、`tauri.ts` 绑定、`ipc-mock` 内存实现（含复核语义）、FRB 镜像。

### 修复：回收站彻底删除补齐附件链行清理（2026-10-23）

- `trash_api` 三处物理删除路径（单任务彻底删除 / 清空回收站 / TTL 过期清理）此前漏清 `todo_task_attachments`，残留的 `is_deleted = 0` 链行会让已彻底删除任务的附件被永久判为「使用中」，本地文件与账本行无法回收（诊断页清理入口也列不出来）。现按 task_id 一并物理清除，并补 `purge_paths_clear_attachment_links` 用例锁定三条路径。

### 性能：冷启动脚本补 10 轮 p50/p95（T4.1 口径，2026-10-23）

- `cold-start.mjs` 改为 10 轮采样 + 最近秩 p50/p95，marker 落 `perf-metrics/.runs/`（工作区可写，避开 Low 完整性进程无法写用户 TEMP）；本机数值仍需在桌面会话人工跑。

### 同步：孤儿分桶物理回收（T1.3，2026-10-23）

- 新增 `cloud_sync::gc::scan_orphan_chunks` / `collect_and_delete_orphan_chunks`：遍历每张可同步表的 `tables/{table}/` 目录，回收「清单无引用 + mtime 早于 24h 保留窗口」的孤儿桶对象；`last_modified <= 0`（服务端不回时间）一律跳过，刚写入的桶留给下一轮，防删其他设备上传中的对象。
- 删除复用既有的 `delete_orphan_chunks`，单个失败只记 `errors` 不中断；顺序约束同墓碑回收（清单落定后执行）。
- 修正测试夹具 `FakeCloud` 的 S3 列表口径：此前 `prefix` 未 percent-decode、对象键未剥前导斜杠，导致 S3 列表恒空（假绿）；修正后 `sync_fault_matrix` 14 例仍全绿。
- 新增 `tests/orphan_chunk_gc.rs`（WebDAV / S3 各一）：孤儿（旧）被删、清单引用保留、孤儿（新）保留，断言 `deleted_buckets` 与云端对象数下降。
- 文档：`docs/07 #96`、`docs/03` 同步模型。

### 性能：50k 首同步与 200MB 级备份峰值实测（T0.2 + T1.2，2026-10-23）

- 操作探针新增两个验收场景：`backup-export-large`（50k 行 × 4KiB 描述，产物 222.9MB）与 `initial-sync`（50k 行、云端为空、丢弃型适配器只统计上传字节，真实走 `push_all` 的分桶扫描 → 逐桶装载 → 加密 → 上传）。
- 探针支持 `--description-kb` 放大字段体积、`--only` 定向调试；`--record` 改为**合并写回**，单场景调试不会清掉其他基线；`initial-sync.uploadedMB` 作为上下文指标单独记录。
- 实测（3 次中位）：大库备份导出堆 +7.8MB / RSS +14MB / 6.6s；50k 首同步堆 +9.1MB / RSS +31.5MB / 22.1s，65 桶、上传 2.3MB。两条 128MB 验收线（`docs/13 T1.2`、`docs/07 #91`）全部达标。
- `perf-metrics/operation-baselines.json` 新增 4 项阈值（大备份 20/30MB、首同步 24/60MB）与 2 条 targets（128MB）。
- 文档：`docs/07 #95`、`docs/09 §8.5`、`docs/14 §三`、`docs/13` M4/6.3 表格回写实测值。

### 性能：附件流式化与分块加密（M3/T1.1，2026-10-23）

- **本地写入改路径入参**：新增 `asset_api::add_task_attachment_from_path`——按 256KiB 块边读边算 SHA-256、写同目录临时文件、完成后原子 rename，峰值与文件大小解耦；`add_task_attachment(&[u8])` 保留给剪贴板/拖放。桌面文件选择器改调 `task_attachment_add_from_path`，不再把整份文件读成 JS 数组经 IPC 搬运。
- **预览/另存走流式导出**：新增 `export_task_attachment`（256KiB 块 copy → tmp+rename）与 Tauri 命令 `task_attachment_export`；非图片附件与大于 12MB 的图片改「导出缓存 + 系统默认程序打开」，不再把整份内容读进渲染进程。
- **云端附件换 `OSAC` 分块容器**（ADR 0012）：magic + version + 4MiB 定长帧 + 确定性 nonce（Data Key 与附件 hash 派生）+ 帧序号/总长进 AAD；逐帧加解密，峰值 ≈ 一帧明文 + 一帧密文。**存量 `OSZS` 对象读兼容**，内容寻址 hash 与对象键（`assets/{hash}.orsync`）不变。
- **适配器流式通道**：trait 新增 `upload_asset_file` / `download_asset_to_file` / `download_to_file`；WebDAV 分片协议改为从文件按块读 5MiB、下载支持流式 GET 与「分片拼装到文件」（逐片 append + 失败截回重试）；S3 新增 `multipart_upload_file`（逐片 5MiB 读盘）与流式 GET；`BasePathAdapter` 显式转发，避免默认实现把容器整包读回。
- **并发与背压**：附件推拉并发 4 → 2，叠加默认 64MiB 在途字节预算（`AttachmentTransferLimits`，push 按明文大小加权、单件超预算按上限放行）。
- **实测**（50MB 附件，`perf-metrics/operation-baselines.json`）：写入 +0.3MB 堆 / +0.4MB RSS、导出 +0.3MB / +0.3MB、推送 +12MB / 8–10MB、拉回 +8MB / +8.3MB——四条 32MB targets 全达；写入前值 +50.2MB / +50.1MB。thresholds 同步收紧（写入/导出 8MB、推送 24MB、拉回 20MB）。
- **桌面壳**：`asset_cmd` 增 `task_attachment_add_from_path` / `task_attachment_export` 并在 `invoke_handler` 注册；`tauri.ts` 与浏览器 mock 同步（mock 对路径导入/导出显式报「不支持」而非伪造成功）。
- **验证**：`cargo test -p orbit-core --lib` 837 绿、`sync_fault_matrix` 14 绿、新增 `asset_stream_transfer` 4 例（WebDAV 小/大附件分片拼装、S3 小/大附件 multipart，含对象键与请求链路断言）、`pnpm typecheck` / `pnpm test` 627 绿、`operation-probe --gate` 7 场景 14 项全过。
- **发布注意**：旧版本客户端读到 `OSAC` 对象会报「payload 格式不匹配」，需升级后再同步；旧客户端已上传的 `OSZS` 对象不受影响。

### 性能：操作级内存探针与桌面基线刷新（T0.1，2026-10-23）

- **新增操作级探针**（`perf-metrics/operation-probe.mjs` + `crates/orbit-core/examples/operation_probe.rs`）：备份导出/导入、CSV 导入、附件写入四场景各跑独立进程，自定义 `GlobalAlloc` 采净分配峰值 + 10ms 采样 RSS，三跑取中位写入 `perf-metrics/operation-baselines.json`；thresholds 拦回归、targets（docs/13 M1/M2/M3 验收线）只报不拦。
- **首轮数字**（10k 任务 / 20k CSV 行 / 50MB 附件）：备份导出 +5.8MB 堆 / +3.8MB RSS、备份导入 +0.1MB / +5.7MB、CSV 导入 +1.9MB / +4.6MB 均在本规模验收线内；**附件写入 +50.2MB / +50.1MB，未达 32MB 目标**——`add_task_attachment` 仍是整文件读入 + AES-GCM 整包加密，即 M3（T1.1）要消掉的 before 列。
- **修好真机口径 `memory3.mjs`**：B 段从已不存在的 `perf-snapshots/post/dist` 改到当前 `apps/desktop/dist`，路径改仓库相对，补 `--gate`/`--record` 与 `baselines.json#desktopExe`；缺 exe/dist 时 exit 2 而非假绿。首轮 Tauri release 稳态 385MB、Chromium 10k 空闲 335MB。
- **三门禁复跑全绿**：`audit-unbounded --gate`（拦停 0）、`growth-curve --gate`（11 项阈值全过，`--record` 刷新 measured 至 36.3MB used / 797 DOM / 351MB RSS）、`memory3 --gate`、`operation-probe --gate`（8 项阈值全过）。口径与缺口见 `docs/09 §八`。
- **验证**：`pnpm typecheck` 通过、vitest 627 绿、`cargo check --example operation_probe` 通过。

### 变更：桌面新增任务改详情形态（TaskCreateDrawer，2026-10-22）

- **新增与详情同一套字段语言**：新增抽屉宽度由 `max-w-md` 提到与详情一致的 `max-w-xl`，结构改为「固定标题行 + 属性网格 + 描述/子任务/标签区块」；`InfoRow` / `SectionBlock` / 开始日期 / 截止日期 / 重复五个部件从详情模块直接复用（它们只吃 `value + onChange`），两处不再各写一套控件。
- **空值可辨识**（本次核心诉求）：未填的开始/截止日期用虚线胶囊「+ 设置」替代与真值同权重的「设置」；标题改为常驻输入框（placeholder「准备做什么？」+ 打开自动聚焦），空标题点创建会聚焦并给出 `role=alert` 提示；描述/子任务/标签沿用详情既有「+ 添加描述」「添加标签」等空态。
- **提醒与持续提醒保留在新增态**：`+ 添加提醒` 展开日期时间选择器 + 「持续提醒（响到完成为止）」开关，确定后成行（`Bell + yyyy-MM-dd HH:mm`，持续态带「持续」chip 可点关闭），创建时随任务落库；关联/评论/附件/历史仍在创建后进详情补充。
- **语义仍是草稿 + 一次性创建**：全部字段只写本地 state，点「创建」才落库（`todoTaskCreate` → 标签/子任务/提醒挂载 → `status=done` 走完成引擎）；取消不产生任何行、不写活动历史。默认值链路保真：模板 > 日历右键 > 视图默认（#39）、开始日期默认今天、提交瞬间重算视图标记。预计时长在详情是只读，新增态补为可填（否则创建后无录入入口）。
- **旧表单链路下线**：删除 `task-form-sheet.tsx`、`entity-form-sheet.tsx`、`lib/form-types.ts`——编辑模式全仓无入口，通用表单组件的唯一消费方就是被删的任务表单（合计约 -1.6k 行）。
- **验证**：`tsc --noEmit` 通过、vitest 627 绿、Playwright 冒烟 50 绿（新建 / 视图标记 / 日历右键路径全绿；另有 7 条既有失败为 mock 缺 `plugin:window|show` 导致的 console-error 断言，与本批无关）。

### 修复：桌面端启动「窗口不显示 / 进程直接死」三层收口（2026-10-22）

> 两个独立故障叠加出「啥都没有：托盘没、页面也没弹出来」：
>
> 1. **进程级死亡**：`tauri-plugin-log` 的 LogDir 目标在 `Builder::build()` 阶段
>    打开日志文件，撞上瞬时「拒绝访问 (os error 5)」（本机复现一次：预探通过
>    后插件仍被拒——预探与初始化之间存在毫秒级窗口，杀软/扫描类瞬时锁挡不住），
>    壳入口 `.expect()` panic，窗口/托盘/守护全部不出现。
> 2. **窗口级隐藏**：`capabilities/default.json` 缺 `core:window:allow-show`
>    （`core:default` 内含的 `core:window:default` 只有只读查询权限），前端
>    `main.tsx` 的 `getCurrentWindow().show()` 一直被权限拒绝，又被
>    `.catch(() => {})` 吞掉——此前窗口能出来全靠 window-state 插件 Rust 侧的
>    `show()`；剔除 VISIBLE 标志后前端这条唯一路径的缺口暴露。
> 3. **闪现根因（前一轮已改）**：window-state 默认 `StateFlags::all()` 含
>    `VISIBLE`，在 `on_window_ready`（webview 无首帧）就 `show()+set_focus()`，
>    首启状态文件缺失走默认 `visible:true` 必闪空壳窗，也破坏 `--hidden` 静默驻留。

- **日志插件挪 setup 期运行时注册**（`AppHandle::plugin`）：从 Builder 主链摘下，初始化失败只丢日志、不再否决启动（stderr 打一行 `[log]` 提示）；`log_dir_writable` 预探保留为优雅降级（不可写 → 仅 stdout，不打错误）。
- **capability 补 `core:window:allow-show`**：前端 `show()` 是冷启动显隐的唯一正路；`main.tsx` 的 `.catch` 改为 `console.error` 留痕（吞错让本次排查多绕两圈），注释同步修正「core:default 含 show」的错误断言。
- **window-state 剔除 VISIBLE**（前一轮）：注册与窗口重建路径 `restore_state` 统一走 `window_state_flags()`（`all() & !VISIBLE`），只恢复几何状态，显隐一律归前端。
- **壳层 8s 兜底 show**：setup 起线程，8 秒后主窗仍不可见且非 `--hidden` 拉起时由壳层 `show()`——前端链路任何一环坏（权限/JS 异常/devUrl 不可达）窗口也能出来，「不出现」比「迟出现」严重得多。
- **验证**：`cargo build` + 实跑 debug exe（vite dev server 在线）：进程存活、窗口 6 秒内由前端 show 显示（早于 8s 兜底，stderr 无兜底行）、无 panic、托盘无报错；dev server 离线直跑 exe 时 8s 兜底接住（页面加载失败场景）。`pnpm typecheck` 通过。
- **托盘补充排查（同日）**：托盘「消失」的根因 = **本机对项目工作区目录的隔离策略**——`C:\Develop\project\...` 下的可执行文件被强制降为 Low 完整性级别，Windows 拒绝 Low IL 进程调 `Shell_NotifyIcon`（os error 5），托盘注册失败（tray-icon 库又把该失败**静默吞掉**，只等 explorer 重启重注册，故此前零报错）。三组对照实测定性：工作区内 `target\debug\orbit.exe` → IL=4096(Low)；同一 shell 起的 `notepad.exe` → 8192(Medium)；**同一 exe 复制到 `%TEMP%` 运行 → 8192(Medium) 且托盘正常**。结论：与 IDE/终端无关，**安装版与工作区外运行完全正常**；dev 需要托盘时可把 `CARGO_TARGET_DIR` 指向工作区外（如 `%USERPROFILE%\orbit-target`）再跑 `pnpm tauri dev`。setup 后延迟 2s 读回 rect 复核，未注册成功时打一行明确告警（`[tray] 托盘图标未注册成功…`），不再无声悬案。
- **无托盘环境的驻留降级（同日）**：托盘不可用时按「关窗驻留」处理会留下**没有唤起入口的幽灵进程**（只剩热键/任务管理器）。现在按托盘实际可用性分流：托盘可用 → 关窗隐藏驻留；托盘不可用 → 关窗直接退出（`mark_quitting` 放行 ExitRequested 拦截）；`--hidden` 自启 + 托盘不可用 → 复核后直接 `exit(0)`，不留不可见守护。实测（降权环境）：关窗 2s 内进程退出，不再残留。
- **遗留说明**：`.window-state.json`（LocalAppData 落点）仅在 `RunEvent::Exit` 保存——需托盘「退出」一次干净退出才会建立；`%APPDATA%\cn.wait.orbit\.window-state.json` 为 9-19 旧相对名时期的遗迹，不影响现行为。

### 修复：定时备份在同步密码未解锁时静默延后（2026-10-22）

> 全量备份的加密复用「已解锁态缓存的同步密码」，未解锁时 core 返回
> `InvalidState("执行全量备份前请先解锁同步密码")`。桌面守护把它当失败处理：
> 每个周期 `eprintln` + `emit auto-backup-finished{ok:false}`，设置页据此弹
> 「自动备份失败」。而未配置云同步时，启动根本不会恢复会话
> （`use-startup-sync` 仅在存在 `sync_config` 时调 `restore_session`）——
> 只开「本地定时备份」的用户会周期性收到一条永远无法自愈的失败提示。

- **未锁即延后**：tick 里先判 `svc.is_unlocked()`，未解锁就静默跳过且**不推进 `next_backup_at`**，不 emit、不弹提示；解锁后下一个 tick 立即补跑。
- **语义分层**：未解锁属「未就绪」，真正的失败（磁盘满 / 云端错误）仍走原失败路径（`last_backup_at` 保留「最近一次成功」语义）。
- **双端同口径**：`crates/orbit-flutter` 的 `tick_once` 同步改为「未解锁跳过且不推进 next」（原实现只推进 next，等于把本轮备份永久丢掉，解锁后还得再等一个完整周期）；`start_backup_scheduler` 文档随改，FRB 产物同步重生成。
- **设置页提示**：自动备份卡在「已到点但未执行」时显示一行警示，说明定时备份用同步密码加密、未解锁时静默延后、解锁后 1 分钟内自动补跑——替代被移除的失败 toast。
- **验证**：`pnpm typecheck` / `pnpm test`（621 绿）/ `cargo check -p orbit-flutter` 通过；本机（未配置云同步、会话未解锁）启动后 stderr 不再出现 `[backup-scheduler] 定时备份失败` 行。

### 修复：通知身份注册改为只读比对，消除受限环境假告警（2026-10-22）

> AUMID 身份（`HKCU\Software\Classes\AppUserModelId\cn.wait.orbit` 的
> DisplayName / IconUri）此前每次启动都无条件覆盖写。当进程被降为 Low
> 完整性（受限沙箱 / 工作区内核）而注册表仍是 Medium 时，写入必被拒，
> 于是每次启动都打一行 `[aumid] AUMID 身份注册失败…拒绝访问`——即便注册表
> 里的值本来就完全正确。

- **先读后写**：先以只读方式打开比对两个值，都已对齐则直接返回（读权限不受完整性上限限制）；不一致才申请写权限并覆盖写。
- **效果**：值正确时零写入、零告警；真实需要更新时行为与原来一致。
- **验证**：注册表值已正确的前提下启动，stderr 不再出现 `[aumid]` 告警行。

### 修复：日志目录不可写不再阻断启动（2026-10-22）

> `tauri-plugin-log` 的 `LogDir` 目标打不开日志文件时会让 `Builder::build()`
> 返回 `PluginInitialization("log", "拒绝访问。(os error 5)")`，壳入口的
> `.expect()` 随即 panic——日志这种旁路观测能力握有否决启动的权力。

- **可写性预探**：启动时按 Tauri 口径（`data_local_dir()/<bundle identifier>/logs`）先建目录并追加打开 `app_log.log`，成功才挂 `LogDir` 目标。
- **退化行为**：不可写（只读 AppData / 企业策略 / 受限沙箱 / 磁盘满）时仅保留 stdout 目标，stderr 打一行提示，应用照常启动。
- **验证**：受限沙箱下 `orbit.exe` 由「必崩」变为正常驻留，stderr 输出 `[log] 日志目录不可写，本次仅输出到 stdout: …`。

### 性能：同步装载逐桶流式化（M4，2026-10-21）

> `load_table_items` 此前把整表行物化成 `Vec<Value>` 常驻，直到全部桶上传完毕才
> 释放——峰值与表大小线性相关，10 万行表首同步可吃掉数百 MB。这正是
> docs/13 §6.2 M4 要解的「整表驻留」。

- **逐桶装载**：先建 uuid→桶索引（只读 `uuid` 一列，几百 KB 级），再逐桶取行 → 建块 → 上传 → 释放。任一时刻内存只有一个桶的行（10k 行 / 64 桶 ≈ 160 行/桶），与表大小解耦。
- **`FkResolver`**：缓存父表 `id→uuid` 映射并跨桶复用——否则 64 个桶会各扫一次父表。
- **自检语义保留**：N52 的「逐桶行数必须与扫描值相符」改为装载一桶判一桶（不符立刻退回全量），不再先攒齐全部 chunk 再比对——那样等于把整表重新物化回来。
- **审计分类**：新增 `docs/14_大表读路径清单.md`，把 18 组 `sql-fetch-all` 归入「合法全表 / 可加 LIMIT / 天然有界 / 只读聚合」四档，并规定新增 `fetch_all` 必须登记数据上界。
- **未做**：审计提示数量未下降（`sql-fetch-all` 是静态规则，看不见逐桶调用的运行时语义）；50k 首同步的实测峰值未验证（需大数据集）。
- **测试**：Rust +5（uuid 索引分桶正确 / 逐桶装载与整表装载**逐行等价**（含 `_fk`）/ 索引规模与行数成正比 / 空清单不查库 / 非白名单表拒绝），`cargo test --lib` 823 绿。

### 性能：移动端内存门禁与代码侧护栏（M5，2026-10-21）

> 移动端内存长期是盲区：只有一个 RSS 读数，无基线、无门禁、无回归可见性。
> 同时 M1/M2 刚把备份与导入改成流式，但新代码随时可能再把整份文件读成
> `List<int>` 过桥——这类回归不会让任何测试变红，只会让内存悄悄翻倍。

- **门禁脚本** `perf-metrics/mobile-mem.mjs` + `mobile-baselines.json`：六场景（冷启动 / 1 万行列表 / 月历 / 时间轴 / 备份往返 / 搜索）阈值与目标，与桌面 `baselines.json` 同构；三次采样取中位。
- **SKIP 语义是关键**：无设备时以 **exit 2** 退出并打印原因，绝不被读成「通过」——若「没设备」算绿灯，盲区会永远不被看见。
- **诊断页增强**：补「本页峰值 RSS」+ 六场景标注下拉 + 手动「采样」钮；**不做后台常驻采样器**（避免诊断本身成为负担），采样不上报、不持久化。
- **代码侧门禁入 CI** `perf-metrics/mobile-bridge-audit.mjs`：静态断言桥接口不得新增「整文件 `List<int>` 跨桥」API，白名单每条必须写明「为什么整块合理」（附件上传/读取因 50MB 上限与内容寻址是协议决定的；备份字节版入口因 v1 是整包 ZIP）。已做正向控制验证（注入违规方法 → exit 1 并点名；移除 → 通过）。
- **未做**：真机实测数值（本机 `adb devices` 为空，`measured` 保持空对象，阈值是估算初值）、六场景自动化驱动（除冷启动外需点击/滚动，硬编码坐标在分辨率与语言变化下失效，故未自动准备的场景计入 SKIP 而非伪造数值）。

### 性能：移动端备份按路径过桥（M1 移动端层，2026-10-21）

> 移动端恢复此前把整份备份读成 `List<int>` 再过桥：Dart 侧一份、FRB 序列化一份、
> Rust 侧一份，三份同时驻留——v2 降低的是 Rust 侧峰值，跨桥字节数一份没少。

- **core 按路径入口**：`import_full_sync_backup_from_path` / `peek_backup_preview_from_path` / `peek_full_sync_manifest_from_path`。v2 全程 `BufReader` 逐帧读（峰值 = 一帧明文 + 一帧密文，与体积无关）；v1 因格式所限仍整份读入，但**在 core 内部完成、不过桥**。
- **v2 按路径 API**：`import_v2_from_path` / `peek_v2_meta_from_path` / `peek_v2_tables_from_path` / `is_v2_backup_path`（只读前 4 字节判 magic）。
- **单一写库口径**：bytes 与 path 两条导入入口共用同一 `import_frames_into_pool`，避免两套逻辑漂移。
- **双端桥**：FRB `full_backup_import_path` / `full_backup_peek_path`，Dart 桥与 mock 同口径镜像；移动端恢复页改 `withData:false` + 传路径。
- **字节版入口保留**（小文件或已持有字节的场景）。
- **测试**：Rust +3（按路径与按字节导入结果一致 / 按路径 peek / `is_v2_backup_path` 只读 magic），`backup_v2_streaming` 14 绿；移动端桥契约 +5。

### 性能：云端备份上传流式化（M1 云端层，2026-10-21）

> 接续 v2 流式化。本地路径已解耦，但云端上传仍要 `std::fs::read` 整包再交给适配器
> （接口是 `&[u8]`）——等于把流式化的成果又打回整包驻留。

- **`SyncAdapter::upload_file`**：适配器按块从文件读（64KiB），内存峰值与文件大小无关。默认实现退回「整包读 + `upload_owned`」，未覆盖的适配器与测试桩行为不变。
- **`HttpClient::put_file_with_retry`**：`Body::wrap_stream(ReaderStream)` 按块送；每次重试重新 `open` 文件（流不可重放）；**必须显式 `Content-Length`**——`wrap_stream` 无长度时走 chunked，而不少 WebDAV/S3 兼容实现不接受 chunked PUT（实测会被直接断开）。
- **WebDAV**：目录预建与 409 AncestorNotFound 重建重试语义与 `put_object_bytes` 完全一致。
- **S3**：SigV4 要求载荷哈希，故**先流式算 SHA-256 再流式上传**——两遍顺序读换取完整性背书，不选 `UNSIGNED-PAYLOAD`（备份是丢了就恢复不了的数据）；≥ multipart 阈值仍走分片。
- **依赖**：reqwest 加 `stream` feature、tokio-util 加 `io` feature。
- **测试**：5 例独立 target（零依赖假服务）——WebDAV 1 MiB 逐字节一致 / S3 带载荷哈希 / 空文件 / 缺失文件不发 PUT / 默认实现回退仍传完整内容。

### 性能：全量备份 v2 帧式流式化（M1，本地路径，2026-10-21）

> docs/13 §6.2 M1（`docs/07 #89`，格式见 `docs/adr/0011-backup-streaming-format.md`）。
> v1 把每张表全量序列化成 String 汇总后整包 ZIP + AES-GCM 加密，峰值 ≈ 库 JSON +
> ZIP + 密文三份叠加，与数据总量线性相关——而备份正是最不能失败的路径。

- **新容器 v2**（magic `OFS2`）：magic + 36B header（salt / nonce_base / iterations / frame_max）+ 重复帧（seq 8B + ct_len 4B + 密文）。帧 nonce 由基础 nonce 与帧序号异或派生（序号唯一即 nonce 唯一），**帧序号进 AAD** 防重排/截断/拼接，读侧另强制序号严格递增。
- **帧上限 4 MiB**：读侧先按 header 声明校验密文长度上限再分配缓冲，防伪造超大长度打爆内存。
- **导出**：逐表 COUNT → 按 rowid 分页（每页 500 行）读 → 逐条写帧 → 落 `.staged` → 原子 rename。本地备份峰值由「一页 + 一帧」决定，与库大小无关；失败路径删临时文件。
- **导入**：逐帧解密 → 逐条写库，同一事务先 DELETE 再 INSERT；单条失败记账不中断；缺结束标记（截断）直接拒绝且事务不提交。
- **peek 分层**：`peek_v2_meta` 只读 header + 首帧；`peek_v2_tables` 只解预览需要的两张表。
- **v1 读兼容完整保留**：生产入口按 magic 分流（`is_v2_backup`），不看扩展名；v1 备份照常恢复，有独立回归用例。
- **口径修正**：导出只取 `is_deleted = 0` 的存活行，与 v1 一致——这条是与 v1 对拍时发现的真实偏差（墓碑进备份会让恢复把已删行带回来）。
- **未做**：云端三协议流式上传（适配器接口是 `&[u8]`，仍需读回整包）、移动端按路径过桥（仍搬运整份字节）。格式升级不可逆，发布说明需标注「旧版无法恢复新备份」。
- **测试**：容器层 9 例 + 集成 target 11 例（往返 / 截断 / 错密码 / v1 兼容 / 超大记录跨帧 / 空库 / 导出失败不留 tmp），`cargo test -p orbit-core --lib` 818 绿。

### 性能：导入进度与取消（M2 后半，2026-10-21）

> 接续同日的导入限额与流式解析（`docs/07 #88`），补齐 docs/13 §6.2 M2 的第 3、5 点。
> 此前大批量导入是一个不可观测的黑盒：没有进度、不能中止，用户只能等或强杀。

- **core 新增可取消任务三件套**：`start_csv_import_job` 返回 `job_id`，`csv_import_job_status` 轮询进度，`csv_import_job_cancel` 请求取消（另有 `drop` 释放条目，避免任务表滞留）。
- **启动前同步预检**：行数与字节限额在 start 阶段就数清并校验——超限立即同步拒绝，不会「跑了一会儿才失败」；副作用是 `total` 一开始就精确，UI 能显示真实百分比。
- **取消在行边界生效**：已写入的行保留（增量导入不做整批回滚），因此不会留下半行；`processed` 恒等于实际写入行数。
- **双端 UI**：桌面与移动端都改为轮询 200ms 显示「已处理 / 总数 + 进度条」，并带「取消导入」钮；终态区分「完成 / 已取消 / 失败」三档文案。
- **任务表有界**：已结束任务最多保留 8 条，超出按结束时间淘汰；运行中的不淘汰。
- **测试**：Rust +4 例（跑完带统计 / 取消停在中途且无半行 / 超限启动前拒绝 / 未知 id），`cargo test -p orbit-core --lib` 807 绿；移动端桥契约 +3 例；`flutter analyze` 零告警、桌面 `tsc` 通过、`cargo clippy -D warnings` 零错误。

### 性能：导入硬上限 + 流式解析（M2，2026-10-21）

> docs/13 §6.2 M2 落地（`docs/07 #88`）。CSV/ICS 导入此前把整份文本读进 core、
> 物化成行列矩阵、再物化成全部映射行——三份常驻叠加，文件多大内存就多大，且没有
> 任何大小/行数上限，误选一个几百 MB 的数据库 dump 就能把应用打爆。

- **硬上限单一口径在 core**：20 MB / 20 万行 / 预览 200 行；超限整体拒绝并给可读文案（报实际值与上限、建议拆分），不做截断——截断会让用户以为导入完整却丢数据。
- **解析改迭代器**：`CsvRows` 逐行产出，内存只与单行宽度相关；`parse_csv` 退化为其便利入口，解析口径逐字不变（引号转义 / 逗号内换行 / CRLF / 孤立 CR / 无换行尾行 / 空行跳过，5 组样本对拍）。
- **预览只留前 N 行**：统计仍全量流式扫描，载荷按 200 行封顶（传 `usize::MAX` 也不会无界）。
- **执行改交错流式**：逐行产出即写库，不再先物化全量映射行；ICS 与 CSV 两条具体迭代器分别驱动（不装箱，避免破坏 FRB 的 Send 约束）。
- **双端读前预检**：桌面选文件后先 `stat` 比对大小再读（超限不读，补 `fs:allow-stat`），移动改 `withData:false` + `File.length()`（不再整份 `List<int>` 过桥）；限额经 `csv_import_limits` 命令 / FRB 桥下发，mock 同口径镜像。
- **测试**：Rust +7 例（字节边界 / 行数超限报实际值 / 预览截断但统计全量 / limit 封顶 / 迭代器与物化对拍 / 空文件 / 行号 1 基），`cargo test -p orbit-core --lib` 803 绿。

### 功能：双端功能对齐（第三批六项 G11–G16，2026-10-18）

> 双端功能对齐专项第三批（清单、逐项比对与完成报告见 `docs/12`）：再次全量核对桌面
> 模块/交互/流程后，锁定 6 处残余差距；移动端为纯 Dart，桌面仅补表单完成态编排
> （零 Rust / 零 DDL / 零协议）。

- **状态切「已完成」接回完成引擎（G11，P0）**：详情信息区、编辑表单与新建表单此前把 `status=done` 走普通 `todoTaskUpdate`/`todoTaskCreate`，绕过重复规则——重复任务完成后不生成下一期，新建即完成还会留下 `status=done / done=0` 的不一致行。移动端三入口改调 `todoTaskComplete`（编辑表单先写普通字段、跨完成边界再走完成入口；新建先落非完成态、挂载子任务/标签/提醒后再完成），桌面编辑/新建表单同步收口；撤销完成沿用 `buildDoneTogglePatch`。完成失败时明确提示「字段已保存，完成未生效」，不再误报整单失败；重复任务完成后 toast 提示下一期日期。
- **保存筛选器对齐桌面构建器（G12）**：状态档补「进行中」；项目/标签条件从裸 ID 文本框改为名称+色点多选抽屉，条件 JSON 仍落 `project_ids`/`label_ids` 白名单。
- **预计时长支持自定义分钟（G13）**：常用档位之外新增「自定义分钟数…」（1–10080 校验），对齐桌面数字输入；输入 controller 由表单态持有，修子抽屉关闭动画期间的 dispose 崩溃。
- **明文导出加「排除已删除条目」开关（G14）**：导出确认抽屉默认勾选（不导出墓碑），透传 `excludeDeleted` 到 JSON/CSV 导出桥，对齐桌面导出弹窗。
- **持续提醒恒显可点 + 月重复文案（G15）**：详情提醒区「持续」chip 不再只在已开启时出现（未激活弱化灰、可点开关；桌面为编辑面板内 Switch，移动端为行内 chip 的等价形态）；补 48dp 热区与 tooltip；重复徽标透传月模式/第 N 周，显示对应文案。
- **关闭加密先验主密码 + 维护结果补日志清理 + 标签就地新建（G16）**：关闭加密增加主密码校验（错误即中止，不迁移库）；维护卡补「日志清理 N」；新建表单标签抽屉顶部可直接输入创建并选中（对齐桌面 TagsField），新标签随任务挂载。
- **测试与文档**：`desktop_parity_align_test` 扩到 10 例（完成引擎三入口含新建即完成 / 已完成→进行中 / 筛选器项目+标签 / 自定义时长 / JSON+CSV 导出开关 / 持续 chip 双向 / 关闭加密密码错误中止），`form_labels_subtasks_test` 扩 1 例（就地建标签）；flutter 全量 932→943 绿 + analyze 零告警；桌面 `tsc --noEmit` 通过、vitest 621 绿。`docs/12` 补第三批清单、调整内容与测试/兼容性报告；`docs/07 #87` 立项收口。

### 功能：移动端对齐桌面端（第二批五项 G6–G10 + 行布局回归修复，2026-10-17）

> 双端功能对齐专项第二批（清单与差距见 `docs/12`）：严格复查推翻此前
> 「形态差异不算缺口」的误判，锁定 5 处残余缺口，全部纯 Dart（零 Rust / 零 DDL / 零协议）。
> 编号 G6–G10 为 `docs/12` 对齐清单口径（与下方品类对标批次的 G 编号互不相关）。

- **看板/表格补多选批量（G6）**：两视图补 `selectedIds`/`onToggleSelect`——选择态点卡/点行切选、勾选位换装选区指示、选中卡强调色描边，批量条/页头「已选 N 项」沿用列表档既有选区链（此前误注释「桌面看板无多选」，实则 `kanban-view.tsx:583` 有完整实现）。
- **长按菜单补「标记完成/未完成」（G7）**：共享任务操作抽屉补状态快捷项，列表档经覆写保留 ghost 退场 + 撤销本地语义。
- **行内星标/我的一天改恒显可点开关（G8）**：新原语 `OrbitRowToggle`（32dp 热区、tooltip 随态），对齐桌面 hover 开关钮的触控常驻化——未激活弱化灰、激活语义色；表格/矩阵同步（矩阵仅星标，桌面同口径）；切换 patch 纯函数 `buildFavoriteTogglePatch`/`buildMyDayTogglePatch`。
- **日历任务行长按菜单（G9）**：长按菜单从列表页私有实现重构为共享层 `logic/task_menu.dart`（13 项 + 日期/优先级/改项目/提醒/评论/标签各抽屉），五视图共用，删除走 destructive 确认抽屉；日历五类任务行全部接线。
- **日历补「周」档（G10）**：`CalendarViewMode` 四档（月历/周/议程/时间）——周档 = 周条（`CalendarFormat.week`）+ 本周 7 天按日分组列表（周一起始、跨月天不受月页裁剪），对齐桌面 `CalendarSubMode.week`。
- **行布局回归修复（G8 TDD 红→绿）**：恒显开关 +70px 曾把 360dp 窄屏任务行标题挤塌（横 Row 溢出、标题 0 宽）；对齐桌面结构将被动元信息归位标题列副标题 Wrap、右列只留截止日期 + 开关对，标题恢复 172px 零溢出；`docs/05 §4.5` 行规格随代码修订。
- **测试与文档**：`kanban_table_multiselect_test`/`row_star_myday_toggle_test` 新增、`task_menu_entry_shortcuts_test`/`calendar_screen_test` 扩展（TDD 先红后绿）；flutter 全量 899→906 绿 + analyze 零告警。`docs/12` 补第二批记录与回归修复留痕。

### 功能：待办品类对标空白点批次（G1/G2+G4/G5，2026-10-17）

> 依据《待办产品功能对标分析报告（2026-Q4）》识别的品类普遍空白点，
> 桌面端先行落地三项高价值能力（移动端对称项留后续批次，见 `docs/07` #81–#83）。

- **逾期一键顺延（G1）**：列表逾期置顶区块头加「顺延」下拉（顺延到今天/明天）——免逐条手动改期。共享纯函数 `rollover-overdue.ts` 只挑「逾期且未完成」行，目标日按本地日历日推进（跨月/年非固定 24h），时间语义沿用 `rescheduleDue`（保时刻/零点归 18:00）；写路径 `rolloverOverdueTasks` 乐观 patch + 失败精确回滚 + Ctrl+Z 撤销。纯函数 7 例 + 写路径 3 例。
- **今日上下文条（G2 情绪减负 + G4 容量规划）**：列表工具栏下新增「今日已达成 N 项」（把今天做成了什么前置为正向反馈）+「今日已排 X / 预算 Y」（超载/偏紧档色调提示，My Day 类功能普遍只回答「做什么」不回答「做得完吗」）。共享纯函数 `capacity.ts`（今日截止未完成时长合计、逾期不计归 G1 面；≥100% 归 over 警示档；`capacityHint` 双端统一措辞）；每日预算落 localStorage，未设只报已排量。capacity 13 例。
- **引导式周回顾向导（G5）**：「···」菜单加「周回顾」入口，三步引导（逾期处置→无日期排期→停滞唤醒）——每步列待处置任务 + 一键处理快捷动作（逾期档复用 G1 顺延；无日期档排今天/明天/下周；停滞档「动一动」唤醒），免逐清单翻找（GTD 周回顾产品化，OmniFocus Review 之外品类首个）。共享纯函数 `weekly-review.ts`（三组清单口径：逾期以今天零点为界/无日期/停滞阈值 7 天，可重叠去重）。weekly-review 6 例。
- **G6 提醒送达确认/升级链——有意不跟进**：经评估暂不立项（现有持续提醒已覆盖「响到完成」核心；升级链/跨端接管复杂度高且与本地优先低打扰定位有张力），见 `docs/07` #84。
- **移动端对称补齐（`docs/07` #86）**：G2+G4 今日上下文条（`logic/capacity.dart` 纯函数镜像 + `today_strip.dart` 挂列表页头下，预算落 LocalPrefs）+ G5 周回顾向导（`logic/weekly_review.dart` 纯函数镜像 + `weekly_review_sheet.dart` 三步弹层，页头 ⋮ 加「周回顾」入口）+ 预算编辑抽屉——全部纯 Dart（零 Rust / 零 DDL / 零协议），写路径走既有 `todoTaskUpdate`。flutter 全量 906→932 绿。
- 桌面 vitest 621 全绿；浏览器目检 G1 顺延入口/弹出/改期、G2+G4 渲染与数值、G5 向导全链（打开→顺延→步进→排期→完成关闭）均通过。

### 功能：移动端对齐桌面端（五项差距补齐，2026-10-16）

> 双端功能对齐专项（清单与差距见 `docs/12`）：逐项核对桌面已实现功能后，
> 补齐 5 处真实缺口，全部纯 Dart（零 Rust / 零 DDL / 零协议）。

- **列表面板补「存为视图」**：把面板当前筛选一键固化为保存的筛选器——面板「筛选」下方新增入口，映射 `filterToSavedConditions`（镜像桌面 `toolbarToForm`：状态丢 `undone` 伪档、优先级落 `priority_min`、标签落 `label_ids`、收藏视图落 `favorite_only`）→ 跳筛选器页自动开构建抽屉预填 → 命名创建落库；条件 JSON 白名单与桌面 `buildConditions` 同口径。
- **长按菜单补「设置提醒」**：相对档抽屉（`reminderPresets` 锚定截止/开始/时长，含「结束时」档）+「自定义时间…」→ 绝对时刻落库；对齐桌面任务菜单「设置提醒」，免进详情往返。
- **长按菜单补「添加评论」**：输入型底部抽屉（`onChanged` 取值，无 controller 生命周期负担）→ 评论落库；对齐桌面右键「添加评论」Dialog。
- **长按菜单补「修改标签」**：多选抽屉（勾选即建关联、取消即删，抽屉不关可连选）→ 刷新标签投影与详情；对齐桌面右键「修改标签 ▸」。
- **新建表单补「标签」「子任务」字段**：仅新建态出（桌面 `!task` 同口径）——标签勾选集 ∪ NLP 命中集去重挂载、子任务逐条建立（含模板预填合并），均「部分成功口径」单条失败不阻断保存。
- **测试与文档**：`save_as_view_test` / `task_menu_entry_shortcuts_test` / `form_labels_subtasks_test` 三组新增（10 例，TDD 先红后绿）；修 3 处测试夹具坑（表单主滚动容器定位 `Scrollable.last` 被输入框内层 EditableText 顶替、`scrollUntilVisible` 单向滚找不到已卸载目标、面板加长后条目需 `ensureVisible`）；flutter 全量 889→899 绿 + analyze 零告警。`docs/12` 新建清单与完成报告随代码落地。

### 功能：移动端对齐桌面端（九项，2026-10-16）

- **详情页截止编辑对齐桌面 `DueDateEditor`**：截止行点击由直接日期面板改为快捷档抽屉（一小时后 HH:mm / 今天晚些时候 22:00 / 明天 09:00 / 下周＝下周一 09:00，行尾时刻提示）+「选择日期和时间」含时分；自定义档选中**原样回填**毫秒、不再归一化零点——修掉「明天 09:00」被编辑成当天零点；`dueQuickIcon` 上收 `icon_map` 供详情与长按菜单共用。
- **详情页提醒删除加二次确认抽屉**：点叉先出确认（文案点名提醒时刻并说明后果），确认才删——对齐桌面提醒行 `ConfirmPopover`。
- **详情页页头补 `⋮` 任务操作弹层**：四动作对齐桌面详情标题行——我的一天（按当前态回显「加入/移出」）/ 收藏 / 复制任务（克隆后 toast 并原页替换到副本详情）/ 删除（二次确认，确认后返回列表；恢复走回收站）。
- **详情信息区补「进度」「完成时间」两行**：行序补全为 优先级/状态/项目/截止日期/开始日期/预计时长/进度/完成时间/重复；进度 `percent_done > 0` 显 `N%`（`Math.round` 同口径），完成时间取 `done_at` 口语化、空显「无」，均只读。
- **列表行元信息补「我的一天」**：`sunrise` 12px 旭日橙 `#F59E0B`（`OrbitAccents.myDayAmber`，与桌面 `MY_DAY_COLOR` 同源），仅 `my_day_date == 本地今天` 才亮、隔日自动退出；只读展示（写入口在详情页头与长按菜单，桌面同为展示位）。
- **看板/表格/四象限补提醒徽标与子任务进度**：`remindersByTask` 数据口三视图接通（`displayReminder` 同口径：未来取最近一条 / 全过期取最早一条，完成实例不警示）；看板卡脚注「铃铛 + HH:mm + N%」，表格标题列只读指示（星标/我的一天/进度）+ 截止格尾补铃铛，四象限行日期行尾铃铛 + 进度；进度统一 `0 < pct < 100` 才显示（并入列表/日历 0、100 均不显示的既有惯例）。
- **时间轴跨度档 1/3 扩至 1/3/7/14**：档名与档序收口模块常量 `timelineSpans`/`timelineSpanLabel`（日/三日/周/两周），空态主文案随档补「这一周」「这两周」——对齐桌面 `TIMELINE_SPANS`。
- **筛选抽屉语义对齐桌面**：优先级由「下限 ≥」五档下限改**等值七档**（无/低/中/高/紧急/立即处理，`t.priority === filters.priority` 同桌面 `task-filters.ts`）；状态档补「未完成」（完成位 `!done`，跨 pending/doing 的筛选伪档）、完成档双来源（done 位或 `status === 'done'`）；`TaskListFilters.priorityMin` 改名 `priority`；注：保存筛选器的 `priority_min` 下限语义不动（桌面 `saved-filter.ts` 本就是下限，两处是不同功能）。
- **长按菜单补「更换项目」**：四视图共用长按菜单在「复制任务」后新增入口，抽屉 = 未分组 + 各项目色点、当前项打勾（对齐桌面右键「更换项目 ▸」）；看板头部注释同步收正（原写「改项目/改状态」但菜单无此入口）。
- **测试与文档**：`detail_header_actions_test` 新增，菜单/筛选/时间轴/三视图卡面/列表元信息各补用例；修 `MockOrbitBridge.todoTaskList` 排序（`position` 是 REAL，按 num 比较）；flutter 全量 872→889 绿 + analyze 无问题。`docs/07 #79` 立项行、`docs/05 §4.2/§4.3/§4.5`、`docs/10 §A-4/A-5/B-2/§六/§七` 随代码修正。

### 功能：移动端对齐桌面端（三项，2026-10-16）

- **排序方向档**：`sortTasks` 增 `dir` 可选参（只翻转主键比较方向，回落键方向不变；due 档无截止恒沉底；manual 拖拽档忽略），缺省走 `baseSortDir` 各档默认方向表（due asc / priority desc / title asc / created desc，与桌面 `BASE_SORT_DIR` 同表）；页头 ⋮ 面板「排序方式」下新增「排序方向」行（手动拖拽档整行隐藏，行尾回显生效方向，就地展开升序/降序打勾；会话内存态与排序档同进退）。
- **长按菜单日期/优先级快捷行**：菜单顶部两行对齐桌面任务菜单顶部图标行——日期 = 快捷档抽屉（一小时后 HH:mm / 今天晚些时候 22:00 / 明天 09:00 / 下周＝下周一 09:00，行尾时刻提示）+ 选择日期和时间 + 清除截止（已有截止时）；快捷档为绝对时刻直接落库（`quickDateTimeOptions` 镜像桌面 `buildQuickDateTimeOptions`，不做保时刻换算；过 22:00 隐藏「今天晚些时候」）；优先级 = 六档色点单选，当前档回勾选态。`SelectItem` 补 `hint` 行尾灰字信息位。
- **表单/快捷新增「下周」语义修复**：表单快捷胶囊与快捷添加面板日期档由「今天 +7 天」改为「下周一 00:00」（`nextMondayMidnightMs`）——修掉周内错位（周四点「下周」原落到下周四），现与桌面 `buildQuickDateOptions.nextWeek`、批量改期、日历圆点改期、NLP 解析入口全部同口径。
- **测试与文档**：`task_logic_test` 三组扩展（排序方向 / 快捷日期档 / 下周口径）、`sort_direction_test` 与 `task_menu_quick_actions_test` 新增、`orbit_sheets_test` hint 渲染用例、form/quick_add「下周」落库用例；flutter 全量 851→872 绿 + analyze 无问题。`docs/07 #78` 立项行、`docs/05 §4.2/§4.5`（面板排序方向行 + 长按菜单行序）随代码修正。

### 功能：移动端对齐桌面端（七项，2026-10-15）

- **批量动作补全（对齐桌面动作全集）**：批量工具条动作集扩三项——**状态推进**（移入进行中/移回待办）、**我的一天**（加入/移除）、**收藏**（收藏/取消），达九项；一级动作横滑承载。双向动作的目标值一律由选中集当前态派生（4 个纯函数），已完成任务不因「移入进行中」被取消完成；撤销走反向补丁（`inversePatchOf` 按方向分措辞）。
- **详情页提醒补相对档快捷**：详情页「添加/编辑提醒」从直接日期面板改为两段式——先出相对档快捷（截止当天 9:00 / 截止前 1 小时·30·15 分钟 / 「结束时 HH:mm」，锚定上下文 dueDate/startDate/durationMinutes 经区块透传），末项「自定义时间…」进日期+时分单面板；与表单和桌面详情抽屉同口径，产物仍是绝对 `remind_at`（收口 `docs/07 #69`「移动端详情页仍走直接日期面板」）。
- **关联任务显示层对齐桌面**：关联行补对方任务标题（逐行单查、按 id 缓存、只补查缺行、失败不弹错——标题是增强信息）+ 类型中文标签与桌面 `RELATION_TYPE_LABEL` 同口径；桌面同步补 `related` 别名（2026-10 前移动端旧写入值）。
- **侧栏快捷视图补「未完成」**：8 键（枚举序在「全部」之后「已完成」之前，与桌面侧栏一致）；筛选 = 排除已完成，计数 badge/空态文案/图标（CircleDot）/语义色全套接上。
- **标签色板 8→10**：`labelPaletteHexes` 追加橙（#F97316）/靛（#6366F1）两色，逐色对齐桌面 `PRESET_10`。
- **表格视图补「时长」列**：七列概览（未设置显「—」占位右对齐保持列对齐）；表头首格改按 `OrbitCheckbox.minHitExtent` 布局盒占位，修掉表头与数据行列错位约 20px 的既有缺陷。
- **月历圆点改期 + 圆点溢出计数**：点按事件圆点选目标日（今天/明天/下周＝下周一/任意日）——桌面「拖拽圆点改期」的移动端形态（4dp 圆点触屏拖不精确，改为点按）；时间语义走 `rescheduleDueMs` 镜像桌面：原截止带时刻保留 H:M、零点/无截止归目标日 18:00、同日不写库。圆点 ≤4 +「+N」溢出计数；4dp 圆点外扩 10×16 隐形热区（不拦日格点按）。
- **测试与文档**：detail 提醒两用例改走新面板、`table_view_test`/`reschedule_due_test` 新增、`task_logic_test` 三组扩展；flutter 全量 851 绿 + analyze 无问题。`docs/07 #77` 立项行 + #53/#69 状态回写，docs/10 B-5/M2/一页结论、docs/05 §4.1/§4.3、docs/11 表格/月视图行随代码修正。

### 性能：下载链路零拷贝（内存专项 A13 第二拍，2026-10-14）

- **请求体/响应体统一 `Bytes`**：`HttpClient::get_with_retry` / `get_with_token` 与适配器 trait 的 `download` / `download_asset` / `download_with_token` 一律返回 `bytes::Bytes`——reqwest 的 `resp.bytes()` 本就是 `Bytes`，此前 `to_vec()` 为**每个**下载对象（数据分桶 / 清单 / 附件）多复制一份整包；附件是数十 MB 级，分桶与清单是小对象但每轮都要过一遍。
- **不复制的地方**：WebDAV 分片拼装由 `append(&mut part)` 改 `extend_from_slice` + 末尾 `Bytes::from(assembled)`（拼装是分片协议固有的复制，不再是额外的一次）；`push::read_remote_manifest_opt` 的回滚点原始密文改 `Option<Bytes>` 透传；`BasePathAdapter` 三个下载方法同步透传。
- **唯一的边界复制并注明**：`full_sync_backup_api::download_cloud_backup` 仍返回 `Vec<u8>`——备份字节要交给双端壳（Tauri 序列化 / FRB 传输）继续持有，属既有 API 契约，其中的 `to_vec()` 是边界转换而非链路内复制（已在代码注释写明）。
- **测试**：core lib 796 例、`sync_fault_matrix` 14 例（真 WebDAV / S3 适配器 + 零依赖假服务，覆盖条件写、分片通道与下载路径）全绿；桌面壳与 orbit-flutter 各自 `cargo check` 通过。

### 性能：push 行级增量装载（N52 第一拍，2026-10-14）

- **背景**：F41 把每轮 push 的代价降到「只重算脏桶」，但那只是省掉了重算与序列化——**装载没省**：每轮仍把整表存活行全量物化成 JSON 再逐桶比对，万级库每次同步都要为此产生数 MB 的行对象与 JSON。
- **落地**：桶扫描（`scan_local_buckets`）在脏桶集合之外**留存脏桶的全部存活行 uuid**（干净桶一份不留——整库 uuid 常驻会吃掉优化省下的内存）；`push::load_items_for_round` 以「脏桶 ∪ 与远端行数不一致的桶」为装载范围，经新增的 `db_loader::load_table_items_of`（分批 `IN`，每批 500 变量，兼容 999 变量上限的 SQLite 编译档）定向取行。**干净桶一行不取；无变化轮零装载**（`pushed_chunks`/`skipped_chunks` 语义不变：后者仍表示「与远端一致而未重算的分桶数」，只是判据前移到装载之前）。
- **保守分支**：force（rekey）轮、扫描不可用（水位线 ≤ 0 / 首次同步 / 扫描报错）、以及「行数已变但无脏行」的桶（回收站 purge 的物理删除或他端清理，此时手里没有该桶 uuid 清单）一律退回全量装载——宁可多加载一次，不可猜。
- **自检兜底**：装载后逐桶行数必须与扫描时的存活行数相符（`bucket_counts_match`），任一桶少行/多行/冒出意外桶即退回全量装载并告警。分桶载荷是**桶级快照**，少一行等于把他端行覆盖成子集，这是本优化唯一不可妥协的性质，故用自检把「省」与「对」绑在一起。
- **不做（结论修正）**：第六轮报告原先设想「换 change-log 表 / 加应用维护的 `bucket` 列」——本轮实测后修正：uuid 清单 + 定向 `IN` 已达成行级装载且零 schema 改动，不再需要 `bucket` 列；change-log 表只省下那次两列扫描（主成本已消），收益降为二阶，须与「每张表三条触发器」的漂移守卫同批，无排期。N39 的空桶候选集取 `live_counts`，本次判据不动，故不受影响。
- **测试**：`load_items_for_round_takes_only_needed_buckets`（装载范围精确到桶 + 两个保守分支 + force 轮）、`incremental_load_payload_matches_full_load`（**增量载荷与全量装载逐字节一致**，且脏桶内时间戳未变的行必须同载）、`dirty_uuids_retains_whole_dirty_bucket_only`、`load_table_items_of_takes_exactly_listed_live_rows`；`sync_fault_matrix` 14 例与 core lib 全量回归通过。

### 功能：应用内诊断分区（内存专项，双端，2026-10-14）

- **只读聚合 API**：新增 `orbit-core/src/api/diagnostics_api.rs`——库体积（`PRAGMA page_count × page_size`）、各表活行数（`is_deleted = 0`，顺序 = 同步白名单）、墓碑行数合计、附件本地缓存体积/文件数；**不 emit db-change、不进同步白名单**（AGENTS「只读聚合不进同步白名单」），附件目录取不到时降级为不统计（诊断页不该因权限问题打不开）。4 例单测（表清单对齐白名单 / 活行与墓碑分列且按增量断言 / 附件只数常规文件 / 目录缺失不报错）。
- **桌面**：新增 Tauri 薄命令 `diagnostics_cmd::diagnostics_snapshot`（附件目录与 `asset_cmd` 同源）+ `lib/tauri.ts` 包装 + 「设置 → 诊断」分区（本地存储与 WebView 运行时两类读数分栏，`performance.memory` 不可用时明写「当前环境不支持」而不是显 0；`diagnostics-format.ts` 纯函数 5 例单测）。
- **移动**：FRB `api/diagnostics.rs` + `DiagnosticsSnapshot` 本地镜像 + `OrbitBridge.diagnosticsSnapshot()`（Rust/Mock 双实现，mock 行数真算、体积给固定假值）+ `/settings/diagnostics` 整页（`OrbitPageHeader` + 整页 ListView，运行时档取 `ProcessInfo.currentRss`）+ 设置入口；widget 测试 2 例 + 格式化 1 例。
- **两端同口径**：读数来源与单位一致（字节/行数，格式化在 UI 层），均按需「刷新」重采而非常驻轮询——诊断分区自身不引入新的常驻开销。

### 性能：上传请求体零拷贝（内存专项 A13，2026-10-14）

- **请求体改 `Bytes`**（`sync_adapters/http_client.rs`）：`put_with_retry` / `put_conditional` 的 body 由 `Vec<u8>` 改 `bytes::Bytes`——每次尝试的 `.body(body.clone())` 从「整包复制」退化为「引用计数自增」。此前一次大附件单 PUT 在 4 次尝试下最多复制 4 份载荷。
- **所有权移交通道**：trait 新增 `upload_owned(path, Vec<u8>)`（默认退回借用版本，未覆盖的适配器行为与成本不变），`upload_asset` 入参由 `&[u8]` 改 `Vec<u8>`；WebDAV / S3 覆盖 `upload_owned`，用 `Bytes::from(Vec)` **零拷贝**接管调用方刚加密出来的缓冲区（借用的 `upload` 路径仍是「复制一次换 Bytes + 重试零复制」）。`BasePathAdapter` 同步透传所有权；两适配器的单 PUT 逻辑各自抽为 `put_object_bytes`，避免借用/移交两份拷贝漂移。
- **附件路径及时释放缓冲**（`cloud_sync/attachments.rs`）：上传的明文在加密后**立刻 drop**（原本跟着密文横跨整段网络上传），下载的密文在解密后**立刻 drop**（原本与明文一同活到 sha256 校验 + 落盘）。大附件峰值驻留由「明文 + 密文 + 请求体副本」降到「密文一份」。
- **明确不做（及理由）**：N40 原方案的「reqwest `stream` 流式下载到文件」对本项目无收益——附件是 AES-256-GCM 整包 AEAD，解密必须持有完整密文，真流式解密要手搓 GHASH（宁可不做）；真正的剩余项是 `download` 系列返回类型改 `Bytes`（省掉 `resp.bytes().to_vec()`），涉及 12 处实现 + 12 处调用，属独立批次。ADR 0010 §四对 A10/A13「指纹相等、零上传」归因信号的要求在本批不冲突：本轮只减内存复制，不改云端对象格式与上传判定。
- **依赖与测试**：新增直接依赖 `bytes`（1.12.1，本就随 reqwest 在依赖树内，无新下载）；`cargo test -p orbit-core --lib` 787 例、`sync_fault_matrix` 14 例（真适配器 + 零依赖假 WebDAV/S3，覆盖条件写与分片通道）全绿。

### 云同步：空桶清单收口（N39，2026-10-14）

- **问题**：push 的表索引以远端清单为底（防他端数据被孤儿化），本地把某桶的行全删光后条目**仍留在清单里**——他端（尤其新设备首同步）每轮都要下载这批陈旧行再靠墓碑删掉，云端对象也永久留着。
- **判据（逐行核对，不猜行数）**：新增 `push::bucket_fully_deleted_locally`——对「本机已无存活行」的分桶，下载并解密远端该桶（0x01/0x02 均兼容），要求桶内**每个 uuid 在本机都有 `is_deleted = 1` 的行**才剔除条目。行数比对不安全：远端 chunk 只记 `count/fp` 不知道 uuid，「本机该桶存活 0 行」既可能是本机删光，也可能是「他端刚推、本机还没拉到」，剔除即把他端存活行变成孤儿（该桶行全在墓碑索引里，所以全部核对通过时不可能丢存活数据）。
- **顺序约束与清单一致性**：对象删除放在**清单落定之后**（`gc::delete_orphan_chunks`，与墓碑回收同一模式）；剔除同样计入 `changed_any`，否则会出现「对象已删 + 清单仍引用」的他端 404。
- **成本上界**：每轮最多核对 `MAX_EMPTY_BUCKET_CHECKS = 8` 个桶；核对不通过的桶把当时远端指纹记入本地账本 `SyncState::undeletable_chunks`，指纹未变不再重复下载（`sync_state.json` 新增字段，`#[serde(default)]` 兼容旧账本）。
- **测试**：`push.rs` 新增 2 例（空桶剔除+对象删除，含「同桶仍有活行必须保留」对照段；他端未拉到行 → 保留 + 备忘不重复核对）+ 3 例测试助手复用；`cargo test -p orbit-core --lib` 787 例、`sync_fault_matrix` 14 例全绿。docs/03 §八 Push 步骤与账本字段、第六轮报告 N39 行同步更新。

### 文档：云同步观察项复核（N50 划线 / N39、N52 维持不做，2026-10-14）

- **N50 划线**：`manifest.prev.orsync` 存上一版旧 Key 密文的问题已随 F64（2026-10-01 第五批）收口——force 轮改写为**本版新 Key 密文**，回滚点有效性成立，用例 `force_push_tolerates_undecryptable_manifest_and_reencrypts_prev` 与 `rekey_overwrites_old_key_cloud_and_cleans_legacy_config` 锁定。第六轮报告表内此前未同步划线（同文「本轮未做」段落的「N36/N50 已随 F80/F64 顺带收口」即同一结论）。
- **N39「桶变空不清理云端活行桶对象」**：复核结论曾判「维持不做（判据必须与墓碑 GC 一并设计）」，同日改为**已落地**——判据取「逐行核对桶内 uuid 是否本机全已软删」，绕开了必须依赖 GC 的那条路（见上一条「云同步：空桶清单收口（N39）」）。
- **N52「行级增量 / change-log 表」维持不做，但已探明落地路径与两处坑**（写入第六轮报告表内，下次立项直接照此设计）：①用 SQLite 触发器逐表写变更表可自动覆盖全部写路径（含 merge 与回收站 purge 的物理删除），不必手工埋点；写入侧时钟契约已由 `generic_repo` 的 update 构造器集中保证（本轮实测确认）。②单落变更表**不消除主成本**——分桶载荷必须整桶重建，且 SQL 侧无法按「uuid 哈希桶」过滤（SQLite 无 sha256 内建），真正的行级增量需要一个应用维护的 `bucket` 列。③与 N39 咬合：N39 的空桶候选集取自 `scan_local_buckets` 的 `live_counts`，改用变更表推导时必须同步改写，否则该特性静默失效。故三处改动应作同一批设计，不挤进零散提交。

### 内存清账批：A7 去重集合有界化 + A11 墓碑水位线复核 + A12 V8 参数收口（2026-10-14）

- **A7 常驻集合有界化**（最后一组 `knownUnbounded` 登记）：双端提醒轮询各持一份「已通知去重集合」`(reminder.id, remind_at)`，只插不删、长驻会话单调增长。新增 core 纯函数 `orbit-core/src/bounded.rs::insert_bounded`（插入后收敛回上界，超限丢**最小**键——键有序，最小即最旧、其提醒行早被 `advance_fired_reminder` 处置；上界钳到 ≥1 保去重语义）＋ 5 例单测；移动 `crates/orbit-flutter/src/api/events.rs`、桌面 `notification_scheduler.rs` 改 `BTreeSet` + 常量 `NOTIFIED_REMINDERS_MAX = 5000`，双端共用同一份实现。去重口径不变（键带 `remind_at`，持续提醒顺延后再弹，docs/03 §五）。`perf-metrics/baselines.json` 的 `knownUnbounded` 据此清空（棘轮只降不升），`audit-unbounded --gate` 拦停违例 0 组、登记 0 组。
- **A11 墓碑水位线复核收口**（无代码缺口，结论入库）：判据已由 F52（第六轮）改为「所有设备 `last_pulled_at` 的最小值」，四条不变量各有用例钉住——设备数 < 2 归零、取最小值、`push_only` 不抬高水位线、任一设备从未 pull（含存量清单缺字段）归零；GC 的「先上传剔除过期条目的新清单、再删云端墓碑对象」顺序约束与「上一版清单已存在的桶才可回收」豁免都在 `cloud_sync/gc.rs` 模块文档内。剩余是**红线不是缺口**：设备注销（N15）会移出低水位线设备从而抬高水位线，ADR 0010 明示动它前必须先复核本判据。
- **A12 清掉残留 V8 堆上限参数**：`apps/desktop/src-tauri/src/lib.rs` 的 WebView2 附加参数删掉 `--js-flags=--max-old-space-size=512`，只留 `--disk-cache-size=52428800`（磁盘缓存 50MB 封顶）。依据：V8 老生代限额「治标且可能把 OOM 变成用户可见崩溃」，ADR 0006 §五已否决、ADR 0007 §四把「清存量参数」列为 A12 的全部职责；当初设它的动因（万级任务下堆只增不减）已由 A14 从源头消除，并有 `growth-curve.mjs` 门禁拦回退。
- **顺带登记当时仍不做的两项**（后续同批落地，见上「A13 附件缓冲零拷贝」与「应用内诊断分区」两条）：A13（附件零拷贝）当时维持第五轮 N40 结论；应用内诊断分区当时缺仓内规格。docs/09 的「未做且已知在下一波」清单随两批工作收敛。

### 性能：任务列表通道瘦行 DTO 收口（内存治理 A2，2026-10-14）

- **裁列**：`todo_tasks` 列表通道由 `TodoTask`（29 列）改独立瘦行 `TodoTaskListItem`（19 列），整体去掉 10 个「列表零消费」列——`uuid`、`repeat_after`、六个更细的 `repeat_*`（weekdays / end_type / end_param / from_done / month_mode / nth_week）、`deleted_at`、`version`。占位表达式只省值、省不掉键名（`"repeat_end_type":0,` 一行 20 字节），故走独立 DTO 而非 `NULL AS ...`（docs/09 §4.3 的既定路径）；桌面 IPC 与 FRB 桥两端的解码/对象分配同步变薄。
- **消费边界（全仓复核，修正文档旧口径）**：保留 `start_date`（桌面右键菜单提醒档、移动时间轴）、`repeat_mode`（移动列表/日历重复徽标判 `> 0`）、`created_at`（桌面 `sortTasks` 排序与 Logbook 分组、保存筛选器 `created_from`）、`description`（桌面搜索通道的本地收敛分支）——docs/09 §4.3 原「9 列零消费」把 `start_date` 误计入，本轮实测它有列表消费。被裁 10 列只在单行全列路径消费：`todo_tasks_get` / `todo_tasks_get_detail` / 回收站 / 同步 push-pull / 活动日志 / 事件载荷。
- **贯通**：core `business_api::list_todo_tasks` 换返回类型、`LIST_COLUMNS_TASKS` 列清单与 DTO 逐列对齐（keyword 通道走 `description` 真值分支——保住「按描述搜索」，服务端 LIKE 与本地下沉都要读原文）；桌面 Tauri `todo_tasks_list` 与 FRB `todo_tasks_list` 同名同口径；桌面新增 `TodoTaskListItem = Omit<TodoTask, 10 列>` 并把列表路径的共享纯函数与视图 props 全部收到该类型（读被裁列当场 tsc 报错，不再有「字段静默 undefined」的窗口）；移动端 `TodoTask.listRow` 统一回落被裁列默认值 + `_mapTaskRow` 直映 FRB DTO，mock 桥摘键同口径。
- **实测收益**（口径同 `perf-metrics/column-prune.mjs`：万行夹具走 mock 真实命令面 `JSON.stringify`）：瘦行 **3.41MB** vs 上一版形状（29 键）**5.22MB**，**每行省 181 字节、万行省 1.81MB（34.7%）**——10 列键名开销 ≈18 字节/列，与 docs/09 §4.3「值不要钱、键名要钱」的判断一致。
- **测试**：core 新增列清单漂移守卫 + 两档列清单差分（5 例）；桌面 `ipc-contract` ③ 改判「10 列不在行里」；移动新增瘦行契约例（列表回落默认值 vs 单条全列真值）；4 处原从列表行读 repeat 细节的旧用例改走单条通道。桌面 vitest 587 + e2e 57 + `cargo test --workspace --lib` 780 + 移动 826 全绿。

### 待办：子任务多层嵌套（M10 / B-4，2026-10-12）

- **数据层**：`0007` 迁移追加 `todo_subtasks.parent_uuid`（先例 0003 项目文件夹——树形父引用用**同步键 uuid** 而非 `parent_id`：自引用整数外键会死锁同步「父行先落库」定序，uuid 列随 `SELECT *` 载荷同步，零同步引擎改动）。限定**同任务内嵌套**（跨任务移动要牵动整棵子树 task_id 与 `_fk` 重解析，v1 明确拒绝）。
- **core 语义**：`validate_subtask_parent` 四类非法引用（自引用/跨任务/父不存在或已删/成环）一致拒绝；删除带走**整棵子树**（BFS 软删 + 逐行事件与历史）；promote 子孙**整棵随迁**（task_id 改挂新任务、直接子女提顶层）+ 新任务 percent 重算；重复任务的子任务树**拓扑序克隆 + parent_uuid 重映射**（树形随实例延续）；percent_done 口径不变（所有子孙同带 task_id，现有 COUNT 即全树聚合）。
- **双端 UI**：详情「子任务」区改树渲染（depth 缩进，容错与 project-tree 同源：悬空父/自引用/成环保底回落顶层）；每行「添加子级」内联输入、嵌套行「提到顶层」出口；删除确认带子树规模。新增双端纯函数层 `subtask-tree.ts` / `subtask_tree.dart` 各 14 例。
- **测试**：core +10 例（守卫 6/删除子树 1/promote 随迁 1/克隆保树 2，另 `subtasks_to_clone` 悬空父 1）、0007 迁移回填 1 例、桌面 vitest 587 例、移动 816 例，全绿。

### 桌面提醒 toast 登记表补手动划掉清理路径（2026-10-12）

- **修复残留**：`reminderToastIds` 原只在 snoozed/completed 事件与「完成」按钮删除条目，用户手动划掉常驻 toast 时不触发 delete，每划掉一个残留一项。补 sonner `onDismiss` 回调覆盖该路径（按钮关闭同样经 onDismiss 回调，幂等），并标 `bounded-by-data`。
- **登记表收口**：`activity-format.ts` 的 `TARGET_ACTIONS` 字面量枚举 Set 补 `bounded-by-data` 标记；两件均从 `perf-metrics/baselines.json` 的 `knownUnbounded` 摘除（棘轮只降不升），`audit-unbounded` 门禁维持 0 违例。

### 云同步：附件 hash 格式纵深防御（N51 收口，2026-10-12）

- **两个入口先拦 hash 格式**：附件 hash 是内容寻址的本地文件名（`{attachments_dir}/{hash}`）与云端对象键，异常值意味着内容寻址假设被破坏或对端数据被篡改。新增 `is_sha256_hex`（64 位小写 hex）纯函数校验，落点两处：`sync_attachments_pull` 下载前（单件记错不阻塞本轮，沿用错误隔离）、`read_task_attachment` 入口（壳层入参）。
- **口径不变**：内容正确性仍由既有 `sha256(decrypted) == hash` 背书校验兜底，本轮只补格式层纵深防御（N51，P3）。
- **测试**：新增 4 例回归——pull 拒绝云端列出的非法 hash（路径分隔符注入形态，有活跃引用也不得进入下载/落盘）、读取入口拒绝非法 hash、`is_sha256_hex` 正反 2 例。

### 桌面侧栏：小窗高度下整栏统一滚动（2026-10-10）

- **修复小屏幕侧栏内容被裁切且看不到滚动条**：旧结构快捷入口区（约 380px）不可收缩，
  小窗高度下会把项目区挤到 0 高（723×378 实测项目列表 viewport 0px、30 个项目行
  全部不可达），且项目列表的 Radix ScrollArea 滚动条是 hover 才渲染的悬浮条——
  用户感知「没有滑动条」。
- **整栏统一滚动**：侧栏根列改单滚动列（快捷入口 + 筛选器 + 项目列表一起滚），
  原生滚动条走全局滚动条标准常显可见；折叠窄条（w-12）同口径补滚动。
  取舍：「项目 +」标题与顶部「视图」头随内容滚走，不再钉住（docs/04 §7-⑥）。
- **回归测试**：新增 `e2e/sidebar-scroll.spec.ts` 三用例（小窗展开态末行可达 /
  滚动条全局标准不隐藏 / 折叠窄条末项可达）。

### 农历与节气表按天文历校准（2026-10-10）

- **农历月长修正**：lunarInfo 压缩表修正 1933 / 1996 / 2057 / 2060 四年的月长
  错位（原表闰月大小与相邻平月天数颠倒），典型症状如 1933 闰五月被算成 29 天、
  其后整月偏移一天。
- **节气表校准 + 越界修复**：sTermInfo 全表按天文历逐项校准（1900–2096，共
  197 项），修正 57 项节气日期（如 2013 立春误为 2/3）；1975 年行曾被抄短，
  解析时 `substring` 越界直接崩溃，已随校准修复；`termDay` 上界从硬编码年份
  改为按表长判定，2097–2100 查节气返回 null 而不再崩。
- **双端同源**：桌面 `lunar.ts` / `almanac.ts` 与移动 `lunar_calendar.dart` /
  `chinese_almanac.dart` 逐项一致（脚本比对 197 / 201 项全等）。
- **测试**：双端各补回归用例（1933 闰五月月长、1975 节气可解析、2013 立春、
  超表年份返回 null），桌面 573 例、移动 801 例全绿。

### 备份调度：`schedule_time` 改按本地时区解释（F89 修复，2026-10-10）

- **修复 F89（备份调度把用户填的钟点当 UTC 解释）**：`scheduler.rs` 目标时刻
  构造从 `Utc` 换成 `Local`，对齐 AGENTS.md「时间运算按本地时区」约定——
  「每天 03:00」现在落在本地 03:00（修复前 UTC+8 机器上实际 11:00 触发），
  「每月 15 日」不再漂到本地 14 日。跨日推进改为**日历日 +1**（naive 日期
  推进后再解析回绝对瞬间），DST 跳变当天挂钟不漂移 1 小时。
- **DST 口径**：春季跳变（用户填的时刻当天不存在，如 02:30 落在 02:00→03:00
  空隙里）→ 顺延到跳变后首个存在时刻，不漏备份；秋季回拨（同一挂钟时刻
  出现两次）→ 取第一次。
- **测试**：20 个既有用例的 `ts()` 构造函数改为按本地挂钟构造（输入与期望
  同口径，任何时区机器上结果一致）；新增 6 个用例——F89 复现 2 个 + DST 边界
  4 个（dev-dep `chrono-tz` 注入 America/New_York，脱离本机时区，替代原先
  「需实跑验证」的口径）。

### 云同步：S3 / WebDAV 稳定性修复（2026-10-05，第七轮探查）

本轮在既有六轮探查（S1–S12 / P0–P1 / F22–F80）基础上做了一次针对性复查，
修掉 6 处功能/性能缺陷、1 处安全问题分类丢失、1 处凭据副本分叉、3 处数据
正确性缺口（其中 1 处为本轮新代码自查抓出的回归），另留痕 1 处需实跑验证才能
修的调度时区缺陷（F89），全部补了回归用例。
加密原语与 KDF 下限挂点复查后确认无缺口（4 处不可信来源入口全部已挂
`ensure_kdf_strength`），未做改动。

- **分片清理发散式删除（P0，性能）**：`delete_parts_dir` 的「首个 404 即停」
  分支**从未生效**——`delete` 走 `check_delete_status`，它把 404 当幂等成功转成
  `Ok(())`。结果一次清单不匹配的清理会真发约 10000 次 DELETE（3 片目录 =
  3 次成功 + 9997 次 404）。触发面是任一 ≥8MiB 附件的 rekey；坚果云这类
  约 1 req/s 限流的服务上会把同步挂住数小时，且全程持有同步互斥锁（后续入口
  一律 skipped）。上界改为由「云端旧清单片数 vs 本轮片数」推导，404 改为跳过
  而非收工（编号有洞不再留残片），10000 魔数删除。
- **控制面请求无总超时（P1，可用性）**：客户端只有 `read_timeout`，只覆盖
  响应体读取；「等响应头」这段不受约束。HEAD / DELETE / PROPFIND / MKCOL 与
  multipart 的 Create/Complete/Abort 全部裸 `.send()`，服务端接受连接后不回
  字节即永久挂起并一直持锁（后续同步全 skipped）。新增
  `HttpClient::control_timeout` + `send_idempotent`（幂等动词顺带获得
  瞬断重试；CreateMultipartUpload 刻意**不**重试，重发会多出孤儿分片）。
- **时钟偏差错误被降级（P1，误诊）**：`SyncError::ClockSkew`（S3
  `RequestTimeTooSkewed`，403）漏在 `From<SyncError>` 之外，落进兜底
  `Adapter`——于是「校时」被当网络抖动白等 2/4/8s×3，tag 报 network 引导
  重试，而正确处置是校系统时间。补变体 + `is_clock_skew` + `clock_skew` tag，
  `with_retry` 显式排除。
- **rekey 后回收站永久冻结（P1，数据）**：`mark_all_unuploaded` 无 WHERE，把
  已被 LRU 逐出（本地无文件）的行也置 `is_uploaded=0`；push 读不到文件即每轮
  产出一条常驻错误，`is_uploaded` 永不回 1，`advances_ledger()` 恒假 →
  `sync_configs.last_synced_at` 冻结 → 回收站物理清理（守卫线）永久失效。
  清理范围限定 `is_local_cached = 1`，`get_unuploaded` 同步加同一条件兜底。
- **WebDAV 列举与 S3 语义不等价（P1，兼容性）**：`list_all_files` 此前
  `Depth:1` 单层且 `name` 取 basename，与 S3 的递归 + 相对路径两维不等；
  引入二级嵌套即静默漏项（返回一份看起来正常的短列表）。改为逐层
  `Depth:1` 广度优先（`Depth: infinity` 被 Nextcloud 等默认禁用），`name`
  归一为相对路径；空 prefix 仍是单层探测（对着分享根递归会遍历用户整个网盘）。
  深度/条目数越限**报错而非截断**，与 S3 侧 F73 同口径。
- **S3 连接测试列举全桶（P2，性能）**：双壳连接测试传空 prefix，S3 侧会
  递归扫完整个桶并按 1000/页翻页才数出一个数字（1 万对象 = 10 次往返）。
  空 prefix 改为一页探测并如实记录「计数已截断」；非空 prefix（备份目录）
  仍翻完所有页，避免备份列表静默少文件。
- **备份调度把用户填的钟点当 UTC 解释（F89，已留痕未修）**：`scheduler.rs`
  全部用 `chrono::Utc` 构造目标时刻，`schedule_time`（"HH:mm"）被直接当作
  UTC 小时。触发侧比对的是绝对时间戳，所以**触发瞬间是准的**，错的只是钟点
  落在哪个时区：UTC+8 下「每天 03:00」实际 **11:00** 本地触发；UTC-5 下落到
  **前一天 22:00**，「每月 15 日」落到**本地 14 日**。这与 AGENTS.md 既有
  约定（本地时区日界）相悖——同步侧统计/日历都守这条，备份调度是仅存例外。
  **本轮只留痕不修**：正确修法要换 `Local` 并处理 DST 的「不存在/出现两次」
  两个分支，而该模块 20 个既有用例全部按 `Utc` 构造输入并断言精确时间戳，
  改语义须一并重写为时区无关且会引入非 UTC 机器上的偶发 DST 失败——需要实跑
  验证，不宜盲改。（已于 2026-10-10 修复，见上方「备份调度：`schedule_time`
  改按本地时区解释（F89 修复）」。）
- **全量恢复可被残包静默清空整表（F88，数据）**：恢复流程的 DELETE 阶段遍历
  `manifest.table_counts`，INSERT 阶段遍历 `decoded.table_data` —— 两个
  **互相独立**的来源。二者不一致时（包被截断损坏，或被人为构造）：
  - **清单有、JSON 没有**：该表被物理 `DELETE` 清空、一条都没插回去。而这条
    路径**不产生任何 error**（表存在、只是 JSON 缺失，既不进 `total_errors`
    也不影响 `success_count`），恢复照样报「成功」——**整表数据无声消失**。
  - **JSON 有、清单没有**：该表不会被清空，新数据叠加在旧数据上；撞上
    `UNIQUE(uuid)` 才报错，没撞就是重复行。

  新增自洽性闸门 `ensure_backup_self_consistent`，**在 `pool.begin()` 之前**
  判定（开事务再判就晚了，DELETE 已落库）。刻意不做「取交集」——那会让残包
  静默恢复成一份不完整的数据，用户无从察觉；宁可中止。只校验白名单内的表
  （非白名单名在两阶段都会被跳过，不构成数据风险）。合法备份必然自洽：导出侧
  在同一个 `Ok` 分支同时写入 `table_counts` 与 `table_data`，且表读取失败时
  直接**中止导出**而非产出残包。
- **递归列举遇到带空格/中文的目录名会整轮硬报错（F87，回归）**：本轮新加的
  WebDAV 递归里，「排除 Depth:1 响应中的目录自身条目」判定拿**未编码**的
  `self_href` 去比对服务端**百分号编码**回传的 `href`。目录名含空格或非 ASCII
  时两者对不上（`sub dir` vs `sub%20dir`），后果不是「多查一次」——自身条目
  被当成子目录排队，而 `visited` 每层多出一段就失效，一路撞穿深度上限变成
  整轮报错。顺带同源问题：`entry_basename` 的 href 兜底分支也该吃解码值，
  否则从 href 取到 `sub%20dir` 再拼 URL 会二次编码成 `sub%2520dir`，请求打到
  不存在的路径。抽出纯函数 `is_self_entry` 收敛判定并解码，两处共用一次解码
  （**不串联**：串联会把目录名字面量 `%20` 解成空格，href 原形是 `%2520`）。
- **行级合并失败会造成陈旧覆盖云端 + 坏记录永不重试（F86，数据）**：merge 的
  行级失败（单条 UPDATE 失败 / 冲突副本留档失败 / 记录非 JSON 对象 / 缺 uuid）
  只进 `merge.errors` 而**不**返回 Err，因此此前既进了 errors 又没进
  `failed_modules`。这会同时坏掉两条防线：
  - **push 侧**：`failed_modules` 是「跳过本表、防陈旧快照覆盖云端」的判据
    （P0-6）。某条远端更新的 UPDATE 失败 → 该行本地仍是旧版本 → 该表不在
    failed_modules → push 照常跑 → 整桶上传 → **云端新版本被旧行覆盖**。
    行级失败反而比整表失败更危险（整表失败至少被 push 挡住并下轮重试）。
  - **pull 重试侧**：函数末尾「按 failed_modules 回滚桶指纹 + epoch 不推进」
    这套强制重试机制**只对 failed_modules 生效**。行级失败不登记 → 桶指纹被
    记成已消费 → 下轮 `remote_chunk_fp == chunk.fp` 命中跳过 → **那批坏记录
    永远不会被重新拉取**，静默空洞且无任何重试。
  改为行级失败一并登记 `failed_modules`，两条防线同时恢复。
- 另有三处一致性收口：`put_part_once` 的 120s 魔数改由体量预算函数产出
  （原与单 PUT 的档位只是**碰巧相等**）；PUT 预算加 1.25× 显式余量（原按
  350kbps 假设取整，余量趋近 0，一次重传即可掐断健康传输，最坏挂起时间已在
  注释中写明）；`list_all_files` 的 trait 默认实现由「静默返回空列表」改为
  报错（2026-09-07 报告 P1-9，「未实现」伪装成「云端为空」是一条无声的
  数据覆盖路径）。
- **凭据两份副本在编辑路径上无声分叉（F84）**：桌面「保存同步配置」把口令
  回填进 DB（编辑既有配置时输入框为空，真值来自 DB），却让
  `write_config_file` 仍从原始输入取值写 `sync_config.json` —— 于是每次编辑
  都会把文件里的凭据清空而 DB 那份完好。移动端不写该文件，故仅桌面受影响。
  改为写入解析后的凭据/令牌。顺带说明：`sync_config.json` 的明文降级是
  ADR 0001 已裁决、PRIVACY.md 已披露的设计（Android 无钥匙串 CEK），本轮
  **不动**；文件侧目前只被读 `device_name`，不读凭据。
- 内存门禁：`dir_cache` 补 `bounded` 标记并改为 512 条 FIFO 淘汰（条目数随
  「≥8MiB 附件个数」单调增长且进程生命周期内永不回收），同步从
  `baselines.json` 的 `knownUnbounded` 摘除。
- 测试：`sync_fault_matrix.rs` 增三条网络级钉子（DELETE 放大、递归列举、
  连接测试只发一次 PROPFIND），单元侧覆盖错误分类透传、附件账本两态、
  黑洞服务器超时、CAS 重试、目录缓存有界性、分片清理上界、「空 prefix
  不下探」、F86 行级失败必须登记 `failed_modules`、F87 自身条目判定在
  百分号编码/非 ASCII/字面 `%20` 三类 href 下均成立且不误伤合法子目录、
  F88 自洽性闸门 5 例（自洽/空包放行、缺 JSON 拒、多余 JSON 拒、非白名单
  不误伤）。另修正 `tests/common` 夹具一处根列举 bug（`prefix="/"` 被拼成
  `"//"`，导致根目录一条子项都反推不出来）。

### 移动端时间轴：长按拾起拖拽时段（2026-10-05）

- **长按 500ms 拾起后纵向拖动改时刻**：与列表重排同款手势仲裁，长按获胜前
  整页滚动/横滑翻月照常，拾起后接管位移，滚动手感零变化；15 分钟吸附，
  落点夹在当日内（块完整落进这一天）。
- **落库口径与桌面逐字一致**：显式排程块改 `start_date`；由截止倒推的块
  **只改 `due_date`**（起点 + 时长），不种 `start_date`（否则任务从「截止收拢」
  漂移成「显式排程」）；半格内位移吸回原格则不写库。
- **刻意不做横向跨天与底边 resize**：移动端日维度是竖向堆叠，跨天需拖过整日
  高（手指出屏）且跨天属月历/议程档职责；改时长走表单既有 8 档抽屉。
- 拖拽中实时回显吸附后的新起点。纯 Flutter 手势 + 镜像纯函数，零 DDL、
  零同步面。收口 docs/07 #74「拖拽手势留独立批次」。

### 移动端时间轴：页内第三档「时间」（2026-10-05）

- **页内视图档由两档扩为三档**：月历 / 议程 / 时间，入口改为**档位抽屉**
  （三选一无法用二元切换钮表达，按交互约定走底部抽屉）。
- **24 小时时段网格**（新增原语 `orbit_timeline_day.dart`）：整点刻度列 +
  网格线 + 时段色块（项目色竖条、重叠自动分车道）+ 当前时刻红线，
  点按进详情；带时长的任务按「显式开始优先 / 截止倒推」起算，纯日期任务
  不出块（属日格不属时段）。
- **跨度 日 / 三日**；数据源按**时段起点日**分桶，显式排程块不会被截止日期
  过滤掉。
- 时长已有字段直接消费，零 DDL、零同步面。**拖拽手势见上一条**
  （已独立落地）。

### 时间轴时段拖拽 + 多日/多周跨度档（2026-10-05）

- **拖拽改排程**：按住时段块竖移改起点、横向跨列改日、拖底边改时长；
  15 分钟吸附，跨列落点夹在面板边界内（不产生跨周落点）。
- **落库口径分三种块来源**：显式排程写 `start_date` + `duration_minutes`；
  由截止倒推的块**只改 `due_date`**（起点 + 时长），不种 `start_date`；
  纯日期任务不渲染块，也不会被拖拽臆造出时刻字段。
- **多日 / 多周**：时间档新增跨度档 **日 / 三日 / 周 / 两周**
  （一维覆盖 TickTick 日/三日/周视图），列头、标题区间、初始滚动与空态文案随跨度自适应。
- 纯前端 + 既有写库路径，零 DDL、零同步面。移动端时间轴同日闭环
  （页内第三档 #74 + 拖拽手势 #75，见上）。

### 重复规则月高级语义：每月第 N 个星期 X（2026-10-05）

- **新增两列**（`0006_repeat_monthly_nth.sql`，`NOT NULL DEFAULT 0` 存量零迁移）：
  `repeat_month_mode`（0=日号 / 1=第N个星期X）+ `repeat_nth_week`（1-5 / 6=末）。
  星期几复用 `repeat_weekdays` 单 bit（月档多选无意义，引擎取最低位）。
- **引擎分支**：第 N 个不存在时**跳过该月**而非截断（截断会把「第 5 个」
  偷换成「末个」）；时刻沿用锚点本地时刻；非法配置回落日号语义，序列不断。
- **双端 UI**：月档加「日号 / 第几个星期X」二选一 + 序数 chips + 单选星期
  chips（桌面表单/详情抽屉、移动重复编辑抽屉）；徽标、「下次具体日期」预览、
  活动轨迹规则快照同步渲染。收口 docs/07 #34「月末高级规则留后续」。

### 筛选器维度扩展：十四键（2026-10-04）

- **白名单 7→14**：截止区间 `due_from/due_until`（绝对毫秒，左闭右开）+
  创建/完成下限 `created_from/done_from`（未完成恒不命中 done 维）+
  存在三态 `has_reminder/has_attachment/has_open_subtask`
 （true 仅有 / false 仅无）。
- **只读存在旗标投影**（零 DDL、零同步面）：core 新增
  `task_attachment_flags` / `task_open_subtask_flags`，桌面两命令 +
  移动 FRB 双桥 + 双端缓存（写事件精确失效）。
- **双端构建器**：桌面日期区间 + 创建/完成下限 + 存在三态 chips
  （区间与窗口/逾期互斥）；移动端日期行 + 三态单选 + 条件摘要短语。
  顺手收敛移动端 `label_ids` 静默忽略的双端口径漂移。

### 看板自定义分组：对标 TickTick 看板多维度分组（2026-10-04）

- **分组由两档扩为五档**：项目 / 状态 / 优先级（P5→P0 固定六列）/
  标签（有任务标签各一列 + 未贴标签，多标签按最小 id 单归属）/
  截止日期（逾期 · 今天 · 本周 · 以后 · 无截止日期五桶）。
- **桌面跨列拖拽改归属**：优先级档改 priority；标签档换主标签
  （删源挂目，其余标签不动）；截止档改期到桶代表时刻
  （昨天/今天/+3 天/+14 天 18:00，恒落自家桶）。
- **移动端展示性分组**（看板本就不支持跨列拖拽，改归属走长按菜单）；
  非项目分组卡片补项目名。纯双端 UI + 共享纯函数，零 DDL、零同步面。

### 结束时间提醒预设：对标 TickTick end-time notification（2026-10-04）

- **提醒相对档组首新增「结束时 HH:mm」一键项**：`start_date` 带时刻 +
  `duration_minutes > 0` → `start + 时长`；否则 `due_date` 带时刻 → `due`
  本身；否则无此项。**不套用默认 30 分钟**——通知是动作时刻，不能按
  时间轴渲染占位凭空捏一个结束点。
- **双端口径逐字一致**：桌面 `reminderEndMs`（`lib/quick-dates.ts`）/
  移动 `reminderEndMs`（`task_logic.dart`）；带时刻判定收敛
  `lib/date-utils.ts` 单一出口 `hasTimePart`。
- **桌面四入口**：详情抽屉提醒区、任务表单编辑态（打开时快照）、右键
  设置提醒（顺手补其缺失的相对截止档）、快捷新增；**移动端表单**
  `_pickReminder`（编辑态保留真实时刻则出现）。产物仍是绝对 `remind_at`，
  走既有提醒到期通道，零 DDL、零同步面。

### 日历时间轴档：M9 时间轴阶段二（2026-10-03）

- **日历新增第五档「时间」**：整幅 7 列（周一→周日）× 24 小时网格，任务渲染为时段色块，
  对标 TickTick Timeline。时段起算口径：任务 `start_date` 带时刻 → 直接作块起点；
  否则 `due_date` 带时刻 → 按截止**倒推 due − 时长**；纯日期任务不出块
  （仍归月/周档日格）。未设时长的带时刻任务给默认 30 分钟最小可视块。
- **重叠分车道**：同列同时段任务贪心分栏并排（`assignLanes` 纯函数），不再互相遮挡；
  跨零点倒推贴顶渲染、跨午夜截断，完整时段走悬停提示。
- **今天列**：主色日期徽标 + 浅底 + 当前时刻红线（60s 步进）；初始滚动锚定当前时刻
  上一小时半（无今天列落 7:00）。块色取项目色（16% 底 + 左边条），点击块进详情抽屉，
  完成态弱化划线。
- 布局口径全部纯函数化（`shared/time-block.ts`，14 用例）；移动端时间轴与
  时段拖拽均已同日补齐（见上，docs/07 #74/#75）。

### 任务预计时长：M9 时间轴阶段一（2026-10-03）

- **任务可记录预计耗时（分钟）**：`0005_task_duration.sql` 给 `todo_tasks` 加可空列
  `duration_minutes`（NULL = 未设置；可空而非 NOT NULL DEFAULT 0——云同步 merge 是列驱动，
  对老版本设备载荷缺失字段绑 NULL，NULL 与「清空时长」语义一致无回填歧义；
  `todo_tasks` 已在同步白名单，新列随行同步、零同步引擎改动）。
- **双端编辑**：桌面任务表单新增「预计时长（分钟）」数字字段（空 = 不设置）；移动端表单
  新增「预计时长」行 → 常用档位单选抽屉（15/30/45 分钟、1/1.5/2/3 小时、不设置，
  对标 TickTick）。详情页（桌面属性网格 / 移动信息区）同步展示。
- **双端行内徽标**：列表行元信息与移动任务行右侧图标列新增时长徽标（时钟图标 +
  紧凑文案）；时长格式化双端同口径纯函数（`45m` / `1h30m` / `2h`，未设置不显示）；
  桌面表格视图扩为七列（截止与优先级间插「时长」列）。
- **克隆/复制语义**：重复任务生成下一实例与「复制任务」均透传时长；「子任务转任务」
  有意不带时长（子任务无时长概念）。
- **存量库零影响**：增量迁移原地完成，老任务行回填 NULL，语义零变化
  （`migration_incremental_upgrade` 新增回填守护用例）。
- 时间轴/时间块视图（周/日档 + 拖拽时段）为 M9 阶段二，待启动
  （docs/07 #67 / docs/10 B-2 / docs/11 M9）。

### 云同步第六轮盘查：三条 P1 + 十条 P2/P3 收口（2026-09-30）

- **失败轮次不再推进增量水位线（P1）**：`push_all_impl` 引入 `round_clean =
  failed_modules == 0`，仅干净轮次才写 `last_pushed_clock_ms`（「无变化」早退分支同样只
  在干净轮次落盘）。此前单次限流/瞬断后，**行数不变的编辑**（改标题、勾选完成等）会
  因为水位线被推进而永久漏传云端，且后续轮次一路报「成功」——静默数据丢失且不可自愈。
- **rekey 不再产出密钥混合态（P1）**：`push_all_force_full` 新增
  `require_all_tables_ok`，任一分桶上传失败即**在写清单之前**中断。此前部分表失败仍会写入
  「已换成新 Key」的清单，导致云端出现「新 Key 清单指向旧 Key 分桶」，全体设备（含本机）
  一律 `KeyMismatch`。
- **清单 CAS 在弱 ETag 服务端可用（P1）**：`get_with_token` 改走与列举侧同源的
  `normalize_etag`——剥掉 `W/` 弱校验前缀、空 ETag 归 `None`。此前弱 ETag 的 WebDAV
  服务端上 `If-Match` 恒不匹配，合并重试耗尽后**清单永不落盘**。
- **S3 签名与请求 URL 统一按 AWS UriEncode 编码（P2/F51）**：`s3/url.rs` 新增
  `uri_encode`，`build_url` 成为唯一编码点。此前路径裸拼进 URL 由 `Url::parse` 按 WHATWG
  规则归一：`base_path` 含 `#`/`?` 时路径被**截断到另一个对象**，含 `+`/`=`/`[` 时
  canonical URI 与 AWS 重算结果不符 → 整包 403 `SignatureDoesNotMatch`。
- **墓碑回收水位线改用「已拉取位置」（P2/F52）**：`DeviceCheckpoint` 拆出
  `last_pulled_at`（水位线只取它），pull 成功路径回写；只推送不拉取的设备不再抬高水位线。
  同时修掉「本轮刚写入的墓碑分桶在同轮被回收」的窗口（`prune_expired_tombstones` 增
  `already_known` 过滤 + 按 `(table, bucket)` 精确回收）。
- **合法清空全部数据可以上云了（P2/F53）**：空数据覆盖守卫前置「本地留有软删墓碑 ⇒ 合法
  删除」判据。此前「逐条软删清空」被误判为删库重装而阻断 Push，删除永远传不到云端，下一轮
  pull 又把远端活行拉回来——用户看到的是「删了还会自己回来」。
- **全量备份导入后失效同步账本（P2/F54）**：导入提交后清 `sync_state.json` 并重置激活配置
  的 `last_synced_at`，与「断开同步」同口径。此前恢复出的行 `updated_at` 早于旧水位线、
  桶内行数又与远端一致时被判「干净」而漏推；陈旧守卫线还会让恢复出的软删行被提前物理清理。
- **部分失败不再谎报「同步完成」（P2/F55）**：表级错误隔离产生的 `Ok` 但 `errors` 非空的
  轮次，在 `Done` 帧之后补发一帧带摘要的 `Error`（最多列 3 条）。此前 UI 说「同步完成」、
  历史表说 `failed`，而后台调度路径不把返回值交给 UI，用户唯一可见信号就是进度帧。
- **两处 KDF 迭代下限补挂（P2/F62、F63）**：`rotate_key` 与 `unlock_master_auth` 补
  `ensure_kdf_strength`。本地 meta 文件属不可信来源，此前被篡改降迭代即可解锁 / 把整套云端
  密文重新包到降级强度的密钥下。
- **错误信息与提示方向修正（P2/F67、F68）**：MKCOL 深度超限 arm 改走脱敏（credentials 不再
  进错误串，F34 收口）；附件上传读文件改 `match`，区分「读取失败（带 IO 原因与路径）」与
  「内容为空」——IO 故障不再被吞成「文件为空」把用户引向错误排查方向。
- **明确可重试的状态码不再放弃（P3/F79）**：`from_http_status` 增 `408` / `425` 可重试 arm。
- **WebDAV 存在性判定改按状态码（P2/F57）**：新增 `remote_exists`（只看 HEAD 状态码），
  `exists` 两处判据改走它。此前复用 `remote_file_size`，服务端对 HEAD 不回 `Content-Length`
  （部分实现如此）时返回 `None` → 存在的对象被判「不存在」，后果不是报错而是**静默走错分支**：
  附件差集每轮空跑重传、首传三分叉探测误放行、pull 活跃引用判定失真。
- **分片目录清理不再「清一半就继续」（P2/F59）**：`delete_parts_dir` 改为**先删清单**再尽力删
  分片，清单删除失败即上抛；逐片「大小相等即跳过」的续传判定加 `reusable` 前置（只在清单已
  证明目录同源时启用）。此前 rekey 后（同一明文跨 Data Key 的密文长度必然相同）陈旧分片会被
  整片跳过，写出「清单声明本轮密文、目录里却是旧密文」的对象 → 读侧拼装 sha256 校验永久失败，
  每轮重试都被同一判据（`retryable: false`）拒掉。
- **普通 PUT 发送阶段首次有超时（P2/F60）**：按请求体大小给 per-request 总超时（每 5MiB 给
  120s，小体量下限 120s，8MiB 单 PUT 为 240s）。此前只配了 `read_timeout`（仅覆盖响应体读取），
  服务端接受连接后停止读取时 socket 写阻塞、PUT 永不返回——整轮同步挂死并一直持着同步互斥锁。
- **WebDAV 路径按 RFC 3986 编码（P2/F61）**：`build_url` 对路径做百分号编码，复用 S3 的
  `uri_encode`（同一实现，避免两协议在「哪些字符必须 `%XX`」上漂移）。此前路径裸拼进 URL，
  `#` / `?` 处截断成 fragment / query → 请求打到**另一个路径**上且状态码看着正常。
- **全量备份导出不再静默丢掉整张表（P3/F71）**：导出循环区分「表不存在（迁移前旧库）→ 跳过
  并记 warn」与「表在但读取失败 → `log::error!` + 中止导出」。此前一律 `eprintln!` 后
  `continue`，出口仍是一份「成功」的备份：文件名、大小、云端上传、`sync_history` 全部正常，
  唯独缺一整张表的数据——用户要等到用这份备份恢复时才发现，而 `keep_latest` 很可能已把上一份
  好备份删掉。同步域壳层残留 `eprintln!` 一并收口（桌面改 `log::*`；移动端一条**刻意保留**，
  因为 `orbit-flutter` 未安装任何 logger，改为 `log::*` 等于删掉该端唯一输出通道，另记 F81）。
- **备份导入不再信任文件自述长度（P2/F65）**：`decoder` 新增 `MAX_ENTRY_BYTES`(512 MiB) /
  `MAX_TOTAL_BYTES`(2 GiB) 与 `read_entry_bounded`，去掉 `String::with_capacity(file.size())`。
  ZIP 中央目录里的 `size` 是随文件进来的元数据：伪造成 8 GiB 时旧代码第一行就发起 8 GiB 分配
  （分配失败即进程中止），即便报得小也会无上限读到内存耗尽；总量上限另防「每条都不越界但条数
  极多」的 ZIP 炸弹。越界判定按「多读 1 字节」实现，等长条目不受误伤。
- **撤销主密码元数据不再可能写出半截文件（P2/F69）**：`save_master_auth` 改走
  `fs_util::write_atomic`（同目录 tmp + rename）；`load_master_auth` 解析失败（含非法 UTF-8）
  先留证 `.corrupt-*` 再上抛明确错误。留证用**复制**而非既有 `quarantine_corrupt_file` 的改名：
  `master_auth.json` 的存在性本身就是状态机输入（`has_master_auth()` 决定是否显示解锁页、
  `master_auth_init` 是否拒绝重复初始化），改名会把「损坏」读成「未设置主密码」，从而放过
  重新初始化——那会生成全新 DB Key，旧加密库再也打不开。
- **同步合并不再把类型漂移静默写成 NULL（P2/F58）**：`merge` 批量 INSERT 的
  `normalize_value` 失败由「折成 `Value::Null`」改为上抛（与同文件 UPDATE 路径同口径）。
  此前「对端把 `deleted_at` 序列化成本地化日期串」这类漂移会把可空列静默写成 NULL——不报错、
  不进 `sync_conflicts`，而 version 已随本轮合并推进，用户只看到「字段同步后凭空被清空」
  且查无线索。
- **桶指纹不再把嵌套同名业务字段当同步元数据（P3/F70）**：`canonicalize_value` 增 `top_level`
  形参，`updated_at`/`id` 白名单与 `_fk` 外键排除**只在顶层记录生效**（递归分支传 `false`）。
  嵌套对象（JSON 列里存的 `{"id":…,"updated_at":…}` 快照）里的同名字段此前被静默摘掉，后果是
  **少算而非多算**：嵌套内容怎么改桶指纹都不变，下一轮 `bucket_is_unchanged` 判「干净」直接跳过，
  那部分编辑永远传不上云端且每轮报成功。原实现把排除写在递归分支内，与本函数文档「仅作用于顶层
  Object」自相矛盾。
- **分片 ETag 不再被当成并发令牌归一化（P3/F72）**：`put_part_once` 改 `trim()`（只去首尾空白、
  保留引号），`complete_multipart_body` doc 明确入参必须是 UploadPart 响应头原文。协议要求
  CompleteMultipartUpload 清单里的 Part ETag 与 UploadPart 回传值**逐字节一致**，剥引号会被
  严格校验的服务端以 `InvalidPart` / `MalformedXML` 拒绝整份清单——而分片此时已全部传完，
  重试代价是整文件重传。归一化那套（剥 `W/` 与引号）服务的是**并发令牌比较**，与「回传服务端
  回执原文」是两件事。
- **S3 列举不再把半页当成完整列举（P3/F73）**：`parse_list_objects_xml` 解析 `<IsTruncated>` 并
  落到 `ListPage.truncated`；空 `<NextContinuationToken/>` 归 `None`（空游标不是游标）；
  `IsTruncated=true` 却拿不到游标时**直接报错**。此前 `IsTruncated` 从不解析，适配器在 `None`
  分支 `return Ok(entries)` 把半页当完整列举（pull 拉不到第 1001 个附件、push 按「云端缺文件」
  误判）；空游标则让服务端按「无游标」重发第一页，条目重复堆积直到 1000 页上限才报错。
- **WebDAV 列举不再丢掉「存在但属性取不到」的资源（P3/F74）**：`propfind` 支持 RFC 4918 的
  `(href, status)` 形态（`<status>` 直属 `<response>`，无 propstat 包装）。此前只在 `in_propstat`
  时记录 status，该形态下 `merged` 恒 false → **整条被丢**，存在的资源从列举结果里消失
  （`url_exists` 判「不存在」、`list_assets` 少对象）。资源级非 2xx 仍按「不存在」剔除，
  F31 口径不回退。
- 回归：`cargo test --workspace` 全绿（orbit-core 新增用例含 F48/F49/F50/F51/F52/F53/F57/F59/F60/F61
  与 F58/F65/F69/F71、F70/F72/F73/F74 的定向用例；F59 因附件差集会「看见」分片目录而无法在集成级构造，改用适配器内的最小内存
  WebDAV 假服务直测 `upload_asset_parts`；F58/F65/F71/F70/F72/F73/F74 八项均以「临时回退修复点 → 用例立即红 →
  恢复」验证过用例有效；期间修掉测试夹具 `spawn_header_server` 的请求体竞态——它读完请求头就回响应并关连接，
  换成带请求体的 PUT 用例后会撞 RST 报 `error sending request`，属与被测逻辑无关的时红时绿，F72 的先红证据
  因此另跑一次取得）；详细清单与逐项证据见
  `docs/同步功能第六轮全面盘查报告-2026-09-30.md` §八。

### 云同步第六轮盘查：剩余 9 项全部收口（2026-10-01）

至此第六轮报告 P1/P2/P3 全部编号清零。

- **条件写先补齐父目录（P2/F56）**：WebDAV `upload_conditional` 与普通 `upload` 同口径先
  `ensure_directory`。此前父目录链缺失时服务端回 409 AncestorsNotFound，被「带前置条件的
  409 → 前置条件不满足」折叠分支折成 CAS 失败，调用方反复重读重试直至报「并发冲突重试 N 次」，
  真实成因（目录缺失，可自愈）被掩盖，清单永不落盘。
- **rekey「以本机为准」真正可达，旧 Key 密文残留清除（P2/F64）**：处置时以临时探针实证
  「云端非空时 rekey 第一步读清单即报 KeyMismatch」——v2 改密 / v1→v2 迁移 / KeyMismatch
  恢复三场景的覆盖此前根本不可达。现 force 轮容忍清单解不开（按空清单起步、并发令牌保留供
  条件写覆盖）；force 轮索引不再以远端清单为底（「远端有、本机无」的桶条目指向 rekey 不重加密
  的旧 Key 密文，保留即混合态）；`manifest.prev` 改存本版新 Key 密文（原样另存上一版 = 旧 Key
  残留 + 无效回滚点）；rekey 后清理老版本遗留的根目录 `crypto/config`。
- **密钥材料换手前 zeroize 原地覆写（P2/F66）**：引入 `zeroize`，`SyncCryptoService` 的
  Data Key 与缓存密码在锁定/替换前显式擦除——直接 drop 只把内存标记回收，密钥字节仍留在
  已释放内存里（堆复用 / core dump / swap 可旁观）。
- **asset 三方法收口为 trait 默认实现（P3/F75）**：S3 与 WebDAV 各自一份逐字相同的拷贝删除，
  `BasePathAdapter` 的覆盖保留（base_path 语义唯一落点）并补注。
- **退出同步的外层超时随空闲窗走（P3/F76，移动端）**：`waitForIdleMs=15000` 的空闲等待窗此前
  永远被恒 6s 超时截断，且超时路径直接跳过业务缓存失效——本轮已拉到的数据不刷新 UI。
- **两端契约与 mock 口径对齐 core（P3/F77）**：`SyncResultJson` 两端补 `conflicts`（S28 冲突
  裁决数，core 一直下发、两端壳都未解析）；mock 桥与 core 同口径填 `changedTables`；mock 同步
  历史 `scope='all'` 对齐 core（三种增量类型并集而非「不过滤」），sync_type 真值修正（此前移动端
  标签映射与 mock 种子用的都是臆测字符串，真数据永远落不到标签上）；桥层默认值双端对齐；移动端
  on-change 推送遇密钥失配不再静默，弹恢复引导（对齐桌面端行为）。
- **403 时钟偏差不再误导为密钥错（P3/F78）**：S3/OSS 的 `RequestTimeTooSkewed` /
  `RequestExpired` 与真签名错共用 403，现按协议错误码分流为独立 `ClockSkew` 变体——文案直接
  给出处置方向（校准系统时间），不再引导用户乱改 AccessKey / 重新解锁同步密钥。
- **卫生批次 14 分项（P3/F80）**：DB Key hex 不再穿过 webview（Rust 进程内暂存，解锁/初始化/
  迁移三命令改编排式调用）；`MasterAuthMeta` 去掉 `Debug` 派生（防包装密钥进日志与 core dump）；
  数据库加密迁移失败清理半成品明文 tmp；备份删除前校验命名规范（防误传路径删任意文件）；
  `download_crypto_bundle` 404 语义对齐同族 API；配置加密存储去掉无条件二次写；删除无调用方的
  legacy 确定性 nonce 附件路径；分片清单头加版本字段（防新客户端头被旧客户端静默误解析）；附件
  列举并集去重去掉 O(n²) 探测；确定性 nonce 有效熵文档口径修正（48-bit，非 96-bit）；
  `validate_config` 拒全空白 endpoint；**S3 STS 会话令牌贯通**（新增 0004 迁移
  `sync_configs.session_token`，SigV4 canonical/signed headers 与请求头三处同步携带，两端配置
  表单与契约字段齐备，留空沿用已存）。
- **移动端日志落地（P3/F81）**：`orbit-flutter` 经 `#[frb(init)]` 钩子在库加载时安装
  `android_logger`（logcat，级别对齐桌面端 Info）——此前 core 侧全部 `log::*`（含 F35/F37
  「失败改 `log::warn!`」的成果）在移动端静默丢弃，排障只能靠 stderr。F71 保留的一处
  `eprintln!` 顺势改回 `log::error!`，两端日志口径一致。
- 回归：`cargo test --workspace` 全绿；F56/F64/F77/F78/F80（空白拒绝）均以「临时回退修复点 →
  用例立即红 → 恢复」验证过用例有效（F64 处置中的前置阻断以临时探针用例实证后转为正式回归）；
  F66 的 zeroize 效果在 Rust 语义内不可观测，以行为钉子用例保锁定语义；FRB codegen + fmt 复跑
  diff 为空；flutter analyze 零问题；桌面 vitest 487 全绿。详细清单与逐项证据见
  `docs/同步功能第六轮全面盘查报告-2026-09-30.md` §八。

### 节假日记账展示收口 + 旧口径文档复原（2026-09-30）

- **记账文案单一出口**：桌面新增 `features/todo/shared/holiday-meta.ts`（配 9 例单测）——
  同一份 `holiday_meta` 要喂设置页概览与日历页两处 tooltip，此前各自拼字符串，于是「每日固定
  时刻 → 每月一次」口径一动就漏三处；现在口径短句 / 时间戳 / 失败态判定集中一处，文案改一次
  即全端生效。
- **失败态从「一个数字」变成可诊断**：`failure_count > 0` 时同时亮出「上次尝试：…」并把
  「连续失败 N 次（旧缓存保留可用）」提为警示色（双端同口径）。原来只有计数，用户分不清调度器
  还在重试还是早已放弃；正常态两行都不出现，不占版面。
- **时间戳口径统一**：桌面设置页由 `toLocaleString()`（「2026/9/29 15:04:00」）改为与日历页
  tooltip 同款「9月29日 15:04」，**跨年自动补 `YYYY年`**——`last_update_ms` 只在自动更新范围内的
  年份成功后才推进，跨年才开机的用户看到「12月31日」无法判断是哪一年。
- **日历页 tooltip 补失败后缀**：失败态追加「，连续失败 N 次」，正常态不出现。
- **旧口径文档复原**（`docs/07 #24`、`docs/10 §A-5`、`docs/11 §G3`）：三处仍在用「每天固定
  时刻（0–23 可配）」当现行口径或当先例引用，已划线并注明 2026-09-29 随 `docs/07 #66` 改「每月一次」。
- **补上节假日零浏览器级覆盖**：新增 `e2e/calendar-settings.spec.ts`（2 例）——正常态只出
  「上次成功更新」、失败态补出「上次尝试」并用警示色亮出计数（`var(--warning)` 探针取色）；
  造态经 `ipc-mock` 的 `__orbitMock.setHolidayFailure` 写 localStorage（mock 是页面模块，
  内存态跨 `goto` 会丢，而用例需要「先设态 → 再进设置页」两步导航）。
- 回归：桌面 vitest 487 全绿（新增 `holiday-meta` 9 例）、`pnpm typecheck` 干净、
  e2e `calendar-settings.spec.ts` 2 例全绿；移动端本地分析器 0 issue（沙箱内 `flutter test`
  不可用，`holiday_cache_page_test` 新增 1 例失败态 + 正常态两条反向断言未在沙箱内执行）。

### 桌面端持续提醒补齐 UI 入口（2026-09-30）

- **详情抽屉提醒区补写入路径**：Rust 侧 `todo_reminders.is_constant` 与迁移
  `0002_reminder_constant.sql` 早已落地，桌面端却一直没有入口——调度层按「响到完成为止」
  在跑、UI 上却无处开启或关闭，等于功能对用户不可达。新增两处：新建 / 编辑提醒时的
  「持续提醒（响到完成为止）」开关（随行落库 `is_constant`），以及已开启行上的「持续」
  徽标（点按即翻）。
- 徽标翻转走「删旧建新、时刻不变」：提醒面只有 create / delete 两个命令，为翻转单加
  一条 Rust update 分支不划算；`remind_at` 原样带回，用户「下一次响铃」的感知不变。

### 移动端日历页/年视图按竞品版式打磨（2026-09-30）

- **月历去卡片化**：月历不再包白卡（描边 / 圆角 / 内衬），直接铺页面底色，左右 space12
  与页头上方 space8 留白保留（周条收起态同口径）。
- **页头改「月份大字 + 相对天数小字」**：小字锚定**选中日**距今天（点日格即变），翻月
  未重新选中时回落当月 1 号——竞品小字表达的是月份口径（「10月 5天后」），锚今天会在
  翻月浏览时产出「10月 今天」的错位文案。
- **横滑翻月的页码回调原样接回**：周档收到的是 ±7 天的逐字日期，中途归一化到 1 号会把
  周条拽回月初周，表现为「网格已经翻页、标题还停在旧月份」。
- **年视图收紧版式**：日格高 30 → 24（原值 12 个月挤不出一屏）、页边距 8 → 16、年份块
  上收进页头行并改为点击返回（省掉整行返回栏）。
- 测试：`test/orbit_month_calendar_test.dart`（新增）、`test/calendar_screen_test.dart`
  （重写）、`test/year_overview_page_test.dart`（新增）；本地分析器 212 文件 0 issue
  （沙箱内 Dart VM 无法 spawn 带管道的子进程，`flutter test` 不可用，未在沙箱内跑单测）。

### 同步故障矩阵入 CI + 夹具 absolute-form 容错（2026-09-30）

- **`sync_fault_matrix` 单独点名进 CI**：rust-core job 原口径 `cargo test --workspace --lib`
  只跑库内单测，`tests/` 整份不执行——这套 10 例是 F22（清单乐观锁条件头真的上过线）与
  F23（≥8MiB 附件真的走分片协议）的**唯一网络级证据**，长期只在本地跑，回归会静默溜过。
  它自带零依赖假服务（`tests/common`，std `TcpListener` 内存假 WebDAV/S3），干净机器可全绿，
  故与「要真 WebDAV 的 `m4_sync_e2e`」区别对待：新增步骤 `cargo test -p orbit-core --test
  sync_fault_matrix`（本机约 4.5 分钟，耗时来自用例自身的重试退避）。
- **夹具容忍 absolute-form 请求行**（`tests/common/mod.rs` `normalize_target`）：本机常驻
  `HTTP_PROXY` 时 reqwest 按代理约定发 `PUT http://127.0.0.1:PORT/base/... HTTP/1.1`，
  夹具此前把请求行 target 原样当对象键，键带上 `scheme://host:port` 前缀，导致
  `webdav_large_asset_uses_chunked_parts_protocol` 与 `truncated_and_stalled_bodies_are_not_accepted`
  在**本机红、CI/无代理机器绿**（一度被误判为既有仓库缺陷——换 worktree 复现只证明既有，
  环境变量会跟着一起复现）。真服务端必须容忍两种形态（RFC 7230 §5.3.2），故修夹具而非断言；
  断言路径口径与生产实现均未改动。
- 同批修正该模块头部过期描述（原写「短连接（响应恒带 `Connection: close`）」，实现早已是
  keep-alive）。

### 清单层级补齐：拖拽跨层级改父 + 父清单聚合子清单任务（对标 TickTick List Folder）

- **父清单聚合子清单任务**（选中父清单时，任务列表含其全部后代的**直接**任务）：
  - 核心侧新增**集合谓词** `ListFilter.project_ids: Option<Vec<i64>>`（`build_task_predicate_clause`
    拼 ` AND project_id IN (?, ?, …)`）。三条口径显式写死，写错会静默出错：① 空集合 = 「该视图不覆盖
    任何项目」→ ` AND 1 = 0`，**不能退化成「不加子句」**（那会把全库任务当成聚合结果）；② 集合非空时
    **优先于** `project_id`（二者不叠加）；③ 归档排除（`archived_exclude_clause`）在 `project_id`
    **与** `project_ids` 皆空时才生效——集合是用户主动指定的视图范围，含归档子清单时须放行。
  - 前端单一口径源 `projectIdsWithDescendants(projects, id)`（= 自身 + `collectDescendantIds`），
    桌面 `features/todo/shared/project-tree.ts`、移动 `modules/todo/logic/project_tree.dart` 各一份。
    桌面由壳层算好后**同时**喂给查询谓词（`todo-shell.tsx::taskPredicate`）与面板本地过滤
    （`task-panel.tsx::filterTasks`）——两层必须同源，只改一层会表现成「聚合不生效」。移动端数据层是
    「全量拉取 + 客户端过滤」，故只落 `TaskFilterInput.projectIds` 一路；`sub_list_screen._listQuery`
    刻意与入口语义分开——页头标题 / 空态 / 新建落点仍按被点中的**单个**清单解释。
- **拖拽跨层级改父**（桌面 + 移动同手势语义）：横向位移即意图——右拖 ≥ 20px **内嵌**为落点行的最后
  一个子项、左拖 ≥ 20px **提升一级**（挂到当前父的父下、紧跟原父之后）、位移不足阈值 **同级重排**。
  - 判定与落库顺序全在纯函数 `planProjectDrop`（双端逐字同口径，各带 12 例单测）：改层级必须在**树上
    做手术**（从原兄弟数组摘除 → 插入目标兄弟数组），再把手术后的树按前序展平取 id 序列。反例说明为何
    不能在旧展平序列上做下标算术：把节点插到某子树之后时，兄弟组落位由**父节点自身 `sort_order`**
    决定，下标算术会让被拖项漂到同层末位。单测用 `displayAfter()`（模拟落库后重拉：按新 `sort_order`
    排序 → 按新 `parent_uuid` 构树 → DFS）断言真实消费路径，而非只断言返回值。
  - 成环拒绝：落点落在被拖项子树的 DFS 连续区间内即视为成环 → 回落同级重排；空 uuid 的项目不当父。
  - 落库顺序口径改为**未折叠全量 DFS 序**（折叠只是浏览态，不该影响编号），缓存只覆盖 `sort_order`
    与被拖项的 `parent_uuid`（列表含折叠隐藏项，整表替换会把它们从缓存抹掉导致展开后闪空）。
  - **桌面**：dnd-kit `DragEndEvent.delta.x` 作横向信号；行 transform 由 `translateY` 改 `translate3d`
    让横向位移有可见反馈；把手加 `title` 承担可发现性（Lucide 图标不接 `title`，故挂在外层 `span`）。
  - **移动**：`ReorderableListView` 只支持纵向，横向层级由行体 `GestureDetector.onHorizontalDrag*`
    表达（手势竞技场按轴分流，不夺 `InkWell` 点击/长按与纵向重排），右移落点取「上一个可见行」
    （DFS 序里必不在自身子树内，天然不成环）；另给长按菜单加「移入上一项 / 移出上一层」——拖动无提示、
    无障碍不可达，这两条是显式可达路径（图标取 `OrbitIcons.indentIncrease/Decrease`，仍单口取图标）。
- **FRB 镜像同步**（`crates/orbit-flutter/src/api/dto.rs::ListFilter` 加 `project_ids`）并用
  `flutter_rust_bridge_codegen`（2.12.0，与依赖锁定同版本）重生成 `frb_generated.rs` /
  `frb_generated{,.io}.dart`：镜像结构变更**必须与生成物同批**，否则 Dart 侧 `SseEncode` 与 Rust 侧
  `SseDecode` 字段错位——`todo_projects_list` / `todo_tasks_list` 等 8 个入口共用该结构，错位即全线崩。
  生成后按仓库惯例 `cargo fmt --all` 并做**二次生成幂等校验**（改动文件 md5 零差异）。
- **mock IPC 边界修正**（`apps/desktop/src/test/ipc-mock.ts`，本批 e2e 的前置）：`todo_projects_update_sort_order`
  长期只在 `ipc-contract.test.ts` 的 `MOCK_ALLOWLIST` 占位、**从未实现**——拖拽在 mock 下第一条落库调用
  即 reject，`handleDragEnd` 整个中断（改层级因此永远走不到）。现补实现并移出 allowlist；同时
  `todo_projects_list` 补 `ORDER BY sort_order ASC, id ASC`（此前返回插入序，与真实链路排序不一致，
  重排结果在 e2e 里根本看不见）；`todo_tasks_list` 补 `project_ids` 集合谓词（含归档放行口径）。
- 验证：Rust `cargo test --lib` **663 passed / 0 failed**；桌面 `vitest` **478 passed / 48 files**
  （基线 457 → +21）；新增 `e2e/project-drag-reparent.spec.ts`（内嵌 / 提升 / 位移不足阈值不改层级）
  与 `e2e/project-aggregation.spec.ts`（父清单聚合）**共 4 passed**，并回归
  `e2e/project-folder.spec.ts` **3 passed**；移动端新增 `task_logic_test.dart` 的 `projectIds`
  集合过滤 4 例（与桌面 `task-filters.test.ts` 同口径）+ `project_tree_test.dart` 的
  `planProjectDrop` 12 例；移动端进程内 analyzer `ANALYZED_FILES=212 ISSUES=0`
  （沙箱内 `flutter analyze` / `flutter test` 不可用，新增用例留 CI 执行）。
  **提交范围**：桌面 `task-filters.ts` / `task-panel.tsx` / `task-filters.test.ts` 与并发会话的
  「工具栏排序方向档 + 收拢双菜单」改动同处 hunk，按「冲突文件不提交」约定留在工作树——故面板
  **客户端**过滤层的聚合（`filterTasks` 的 `projectIds` 分支）与其 UI 层 e2e 一并随该批落库；
  服务端谓词（`ListFilter.project_ids`）、侧栏拖拽与移动端聚合已随本批生效。

### 清单文件夹分组（对标 TickTick List Folder）

- **`todo_projects` 新增 `parent_uuid`**（`0003_project_parent.sql`，`TEXT DEFAULT NULL`，行尾中文注释）：
  指向父项目的**同步主键 uuid**，NULL = 顶层。刻意不用 `parent_id INTEGER`——云同步对整数外键走
  `SYNC_FK_COLUMNS` → `_fk: {列: 父行 uuid}` 标记翻译，其正确性依赖两条前提：「父表先于子表定序」
  （`fk_parent_order_ok()`，**仅表间成立**）与「落库时从本端已落库行建 uuid→id 映射」。**自引用同表
  会同时破坏两者**：父行未到 → `resolve_foreign_keys` 整表 `Err` → 事务回滚 → 父行永不落库 →
  永久死锁。改存 uuid 后父行悬空只是「回落顶层」，双端树构建按顶层渲染；父从回收站恢复后层级自动
  复现，无需级联改写子行。也不声明自引用外键——父行软删不牵连子行。加列零 `sync_registry` 改动
  （`todo_projects` 已在 `SYNCABLE_TABLES`，白名单为行级同步、天然覆盖新列）。
- **写入侧三类守卫**（`business_api::validate_project_parent`，create / update 两路径统一前置）：
  拒自引用、拒指向不存在或已软删的父、拒成环（沿父链上溯，上限 64 跳防异常数据）；守卫通过后
  再委托 `generic_repo`，DTO 三态（缺键 = 不改 / `null` = 移到顶层）沿用既有 `nullable` 反序列化口径。
- **双端侧栏层级树**：项目按 `parent_uuid` 构成层级树后展平渲染（父在前、子紧随其后），逐层缩进
  14px，有子项者带折叠箭头（折叠收起整棵子树）。纯函数层双端各一份、口径完全一致——桌面
  `features/todo/shared/project-tree.ts`、移动 `modules/todo/logic/project_tree.dart`：
  **孤儿（父不存在 / 父已软删）回落顶层**，自引用与成环整体回落顶层（保证递归终止且行不丢），
  同层沿用 `sort_order` 顺序。
- **双端编辑入口提供「上级文件夹」选择**：候选**排除自身与全部后代**（否则成环，Rust 侧必拒），
  文案带祖先路径（"父 / 子"）避免不同层级同名歧义；移动端为当前层级行 + 候选面板，桌面端为 Select。
- **拖拽排序语义**（本批）：拖拽仍只改同级 `sort_order`、**不改层级**（跨层级改父留后续批次）；
  折叠隐藏的后代不在可见序列内、保留原编号——它们只与自身兄弟集比较，不受影响。
  **后续批次已扩展**：横向位移可改父，见上节「清单层级补齐」。
- **mock IPC 边界修正**（`src/test/ipc-mock.ts`）：浏览器 / e2e mock 的 invoke 参数此前直传对象，
  与真实 Tauri IPC 的 **JSON 序列化边界**不一致——值为 `undefined` 的键在真实链路会被丢弃，在 mock 里
  却会让 `Object.assign(entity, input)` 把字段覆盖成 `undefined`（实测：编辑项目只改颜色 → 项目标题
  被清空）。现于命令分发入口统一做一次 JSON round-trip，与真实链路字段语义对齐。
- **未做**（本批）：拖拽跨层级改父、父清单聚合子清单任务。**均已补齐**（2026-09-30），见上节
  「清单层级补齐」。

### 日历周视图（对标 TickTick Week View）

- **桌面日历新增第四档「周」**（月 / 周 / 年 / 议程）：月历组件
  `components/business/month-calendar.tsx` 新增 `mode="week"`，日期网格由 6×7 月网格
  换为**锚点周 7 格（周一→周日）**，其余全部沿用月档同一套实现——今天/休息日/选中态色块、
  休班徽标、农历副标签、任务圆点行、右键快捷新增、**圆点拖拽改期**（落点 id 仍是
  `day:<ms>`，`rescheduleDue` 原样复用），零交互分叉。
- **周档锚点 = 选中日**，翻周即选中日 ±7 天（头部前后按钮与周条滚轮走同一回调），
  不新增视图态——与月档「右栏跟随视图月、选中日高亮定位」同一心智模型，档位来回切换不丢选中日。
- **右栏口径换为「本周任务」**：复用月档的虚拟化分组列表，区间按 ymd 字典序过滤
  （周一 00:00 ~ 周日 24:00 闭区间）；空态与加载骨架同月/年档口径。
- **「回到今天」在周档保留档位**（语义为「回到本周」），月档/议程档维持原有「回今天并切回月档」。
- **周档视觉独立于 fillHeight 拉伸**：7 格拉伸到整屏高度会退化成细长条，故周条恒为
  单行自然高度 + 在左栏内垂直居中（`cellWeek` / `gridWeek` / `numberWeek` / `titleWeek`
  四组尺寸令牌，与 42 格网格分开调校）。
- **日期工具收敛**：新增 `lib/date-utils.ts` 作为本地时区日期计算的单一出口
  （`startOfDay` / `addDays` / `startOfWeek` / `formatYmd` / `dayKey` / `relativeLabel` /
  `dayLabel` / `weekRangeLabel`），替换原先散落在月历、日历视图、快捷日期、NLP 解析的
  4 份 `startOfDay` 与 2 份 `formatYmd`；网格构造抽为 `lib/calendar-grid.ts`
  （`buildMonthGrid` / `buildWeekGrid`）使纯日期计算可被单测直接覆盖。
- **移动端无需改动**：`table_calendar` 的周档（`CalendarFormat.week`，上滑月历收成单行周条）
  已随日历页老版本落地并带专项测试（收展对齐选中日所在周 / 跨月周补位不弱化 / 横滑翻周 ±7 天），
  本次仅核验确认，未改并发会话正在重构的日历页。
- 测试：新增 `lib/date-utils.test.ts`（17 例）+ `lib/calendar-grid.test.ts`（10 例，含
  周日锚点归属本周、跨年周不裁剪、逐格递增无空洞等边界）；新增 e2e `e2e/calendar-week.spec.ts`
  （7 列网格 / 周区间标题 / 翻周 ±7 天 / 回到今天留档 / 切回月档 42 格）。桌面单测 430 passed。

### 每日摘要提醒（对标 TickTick Daily Reminder）

- **新增每日摘要提醒**：每天固定时刻一条汇总通知「今日 N 项 · 逾期 M 项（· 已完成 K 项）」。
  core 新增 `digest_api`，**无新增表 / 无新增迁移**——计数是 `todo_tasks` 上的只读聚合
  （今日截止 / 逾期 / 今日完成三档，本地时区日界，与 `stats_api::local_day_index` 同口径）。
- **配置落 `cfg_kv` 三键**（本机偏好，不随云同步）：`digest_enabled`（默认 **0=关**，
  打扰型功能需显式开启）、`digest_time`（`"HH:mm"`，默认 `08:00`，小时 0–23 / 分钟 0–59
  校验与备份调度同源）、`digest_last_day`（上次**已处置**的本地日，防同一天重复判定）。
- **每日一次判定**（`take_due_digest`）：开关开 + 当天目标时刻已过 + 当天未处置才返回；
  同一天内迟到超过 12 小时补弹窗口（`CATCHUP_WINDOW_MS`）则静默跳过当天并照样记账，
  避免「目标 08:00、21:00 才开机」时深夜补弹当日摘要。
- **文案单一真相源**：`summary_body` 在 Rust 侧生成（今日与逾期皆 0 给鼓励语、今日有完成
  追加尾巴），桌面系统通知与移动系统闹钟取同一份实现，避免双端措辞漂移。
- **桌面**：`digest_scheduler` 60s tick 调 `take_due_digest` → `notify-rust` 系统通知
  （无 action、默认超时；正文点击唤起主窗）+ 写 `notification_log`（kind `digest`，
  通知历史页新增「每日摘要」标签与图标）；设置页「待办」分区新增开关 + 时刻选择器 +
  当前口径预览（`digest_prefs` / `digest_set_prefs` / `digest_summary` 三个命令）。
- **移动**：不走 Rust tick（手机进程会被杀）而走**系统闹钟每日重复**本地通知——
  `NotificationService.syncDailyDigest` 用 `zonedSchedule` + `matchDateTimeComponents:
  DateTimeComponents.time`（AlarmManager 持有，应用被杀/Doze 均准时；独立渠道
  `todo_digest`、独立 id `2000000000`，与提醒三域互不覆盖）；新增 `DigestScheduler`
  在启动与 `dbChanges`（任务表）后防抖重排，让正文跟上最新计数；设置页新增卡片
  （开关 + 时刻选择 + 当前口径预览）。
- FRB 新增 `crates/orbit-flutter/src/api/digest.rs` 桥（`digest_prefs` /
  `digest_set_prefs` / `digest_summary` / `digest_body`），DTO 镜像 + codegen 产物已重生；
  `stats_api::local_day_index` 提升为 `pub(crate)` 供 digest 复用（同口径不漂移）。

### 持续提醒（对标 TickTick Constant Reminder）

- **新增持续提醒**：`todo_reminders.is_constant`（迁移 `0002_reminder_constant.sql`）——
  到期触发后任务仍未完成时，**同一行原地顺延 5 分钟**（`CONSTANT_REARM_INTERVAL_MS`）
  再次提醒，直至完成或提醒被删：「响到完成为止」。不软删、不克隆，天然无雪球；
  锚点取 `now + 间隔` 而非「原时刻 + 间隔」，应用离线数小时补扫时不会连发。
- **完成即停**：完成命令软删存活提醒行 + `list_due_reminders` 的 `done` 过滤双重收口；
  重复任务的持续标记随实例平移（`complete_todo_task` 克隆提醒行时继承），
  下一实例继续「响到完成为止」。
- **双端轮询去重键改 `(id, remind_at)`**（桌面 `notification_scheduler` / 移动 `events.rs`）：
  按 id 去重会把顺延后的后续几轮全部挡掉。
- **桌面系统通知新增「完成」action**（仅持续提醒挂载，排在三档推迟之前）→ 直调
  `complete_todo_task` + emit `todo_reminder:completed`，前端关闭常驻 in-app toast 并
  失效任务列表/计数/详情缓存；正文标注「持续提醒 · 完成后停止」。
- **移动端**：闹钟通知标题/正文标注持续语义；推迟落地（`landSnoozeInDb`）额外替换
  已顺延的持续链并继承标记——否则「顺延链 + 推迟行」会双份提醒。
- **双端编辑入口**：桌面表单/详情抽屉给开关（勾选即持续），行内显示可点击「持续」徽标；
  移动表单给开关行（仅在已设提醒时出现）、详情页给「持续」徽标。
- 提醒 CRUD 的 `is_constant` 带 `#[serde(default)]`（老壳传旧 JSON 按一次性落地），
  加列零 `sync_registry` 改动；FRB DTO 镜像与 codegen 产物已同步重生。

### 节假日更新能力对齐 PiggyCount（每月口径 + 自动开关 + 按年补写）

- **自动更新口径改月度**：原「每日固定时刻（`fixed_hour` 0–23 可配）」下线，改为
  `should_update_now` 月度判定——从未成功即更、上次成功所在自然月 ≠ 当前月即更；
  跨月后下次启动首轮 tick 即补更。随之移除 `holiday_set_fixed_hour` 桥位
  （core / Tauri command / FRB / `tauri.ts` / 移动 `OrbitBridge` 四实现）、
  `HolidayMeta.fixed_hour` 字段与双端「每日更新时刻」UI 及其测试。
- **新增自动更新总开关** `holiday_auto_enabled`（缺省开启，`cfg_kv` 无键按 1 处理）：
  关闭后 Rust 调度器不再联网，仅保留手动更新与按年补写；双端设置页给出开关行。
  **无 DDL 迁移**——全部新状态落 `cfg_kv`（`0001_init.sql` 保持冻结、未新增迁移文件），
  `sync_registry.rs` 白名单与同步表计数断言不动。
- **新增按年 / 按年范围联网补写**：`holiday_fetch_year(year)` 单年整年替换（可选
  2013 ~ 明年，`HOLIDAY_FETCH_YEAR_MIN = 2013`）；`holiday_fetch_range(start, end)`
  两阶段补写——阶段 1 分片并发（`RANGE_CONCURRENCY = 4`，保序 yield）纯网络拉取，
  阶段 2 串行落库（`sqlx` 事务不可并发），连续失败 3 次熔断（`RANGE_ABORT_AFTER`），
  整次操作 `failure_count` 只 +1；取消走 `AtomicBool` 单会话守卫（`RANGE_ACTIVE` CAS）
  + RAII `RangeGuard` 在 Drop 复位，支持并发拒绝与 panic 安全。
- **逐年进度跨端管线**：core 新建独立 `tokio::sync::broadcast` 通道（**刻意不复用
  `EVENT_BUS`**——节假日是只读缓存表，铁律要求不 emit `DbEvent`）；桌面侧
  `holiday_scheduler.rs` 新增一次性进度泵 `app.emit("holiday-progress", ..)`，前端
  `useHolidayProgress()`（`listen` + `useEffect` 清理）驱动设置页进度条与取消；移动侧
  FRB `subscribe_holiday_progress(StreamSink)` → Dart 单个 `StreamProvider` 收口
  （避免重复订阅产生多份监听），承载为可取消的进度弹层。
- **读取按年合并兜底**：`list_holidays` 以 DB 已覆盖年份为准、预置表只追加未覆盖
  年份；`is_holiday_on` 在该年已被 DB 覆盖时严格以 DB 为准（无行即 `None`，不回落预置）。
  修掉「补写任一历史年份 → 2026 预置徽标整体消失」的旧整表回落缺陷。
- **记账正确性 AC-E6 / AC-E7**：历史年份补写只写 `last_attempt_ms`、不动
  `last_update_ms`（否则会静默抑制当月自动更新，属隐性新鲜度 bug）；空响应按成功
  处理并清空该年，UI 明确提示「该年无数据」而非静默当作已更新。
- **双端设置页/缓存页**：桌面「日历与节假日」重构为概览 + 每月自动更新开关 +
  立即更新 + 按年份范围获取（两个 Select，`start <= end` 校验）+ 进度区（内联 bar，
  桌面无 `ui/progress.tsx`）+ 年份分组「更新该年」；移动设置页同款开关，缓存页新增
  范围入口（两次 `showSelectBottomSheet`）、单年「更新该年」与进度弹层（含取消）。
- 回归：`cargo test --workspace --lib` 636 全绿（节假日 29 例：月度三分支 / 按年合并 /
  覆盖年不回落 / `fetch_year` 三分支 / AC-E6 记账差异 / 熔断 / 取消恢复记账 /
  进度广播序列 / 并发范围被拒）；桌面 `pnpm typecheck` + vitest 398 全绿（新增
  `use-holiday-progress` 6 例）；移动端本地分析器 208 文件 0 issue。文档同步：
  `docs/02 §五` 查询键与进度流、`docs/07 §五` backlog、`docs/10` 桥表与 M11、
  `PRIVACY.md`、`docs/adr/0005`。

### 桌面端工具栏收拢为「↑↓」+「···」双菜单

- **12 控件收拢为 5**（TickTick Web 同款，prd/desktop-toolbar-dropdown）：工具栏右侧保留
  搜索框 / 新增 / 模板下拉，原状态 Select、优先级 Select、视图切换五联钮、看板分组
  Select、标签管理钮、存为视图、Ctrl+P 等低频入口全部并入两枚图标菜单——
  **「↑↓」排序与筛选菜单**：分组（仅看板显示）/ 排序五档 / 顺序（升降）+ 状态/优先级
  筛选 Sub 就地展开，段尾回显当前档；**「···」更多菜单**：顶部视图图标排（点按即切不关
  菜单、当前档高亮）+ 隐藏已完成开关 + 存为视图 / 搜索或跳转（Ctrl+P）/ 标签管理。
- **新增排序方向档**：`todo_sort_dir` localStorage 键（`asc`/`desc`，未存过 = 各档
  现状默认方向，存量顺序零变化）；方向只翻转主键比较，回落键不翻、due 档无截止恒
  沉底、manual 档忽略方向。`sortTasks(tasks, sortKey, dir?)` 第三参为可选——所有既有
  调用点语义不变。
- 回归：vitest 新增 6 用例（各档方向翻转 / manual 忽略 / 默认方向快照，64 用例全绿）；
  e2e 新增 2 用例（排序菜单升降序切换 + 视图图标排点按即切菜单不关）并把日历/看板/
  存为视图/标签管理 4 处入口断言平移到菜单路径；全量 smoke 28 用例绿。
  `docs/04 §二骨架图 / §四排序语义 / §七 localStorage 键全集` 规格同步。

### 标签管理弹窗整体高度钉死

- **LabelManager Dialog 固定 `h-[380px]`**（≈3 张标签卡 + 底部新建行，对齐参考图）：
  标签多于 3 条时列表区内部滚动（`flex-1 min-h-0 overflow-y-auto`），弹窗不再随内容
  无限长高；0 条时高度不变，新建行 `shrink-0` 钉底。
  `overflow-hidden` 覆盖 Dialog 原语非交互路径的 `overflow-y-auto`（弹窗自身不滚，
  滚动手势全交列表区）。
- 回归：e2e 新增「标签管理弹窗整体高度钉死」——真实创建链路灌 5 个标签，断言
  弹窗高度=380±2px、列表区 `scrollHeight > clientHeight`、新建输入框仍钉底可见；
  旧代码（无钉高）跑同用例判红。`docs/04 §3.8` 规格同步。

### 桌面端完成态勾选框灰化（对齐移动端）

- **完成 checkbox 去蓝**：列表行 / 看板卡 / 表格行 / 矩阵行 / 详情标题行 / 子任务共 6 处，
  完成态由 `border-primary bg-primary`（待办蓝）改为 `muted-foreground` 弱化灰实底
  （白勾保留），与已完成行的灰色划线标题同调；移动端 `OrbitCheckbox` 早已走
  `deactivatedText` 弱化灰，本次为跨端同源收口。
- 回归：e2e 新增「完成态勾选框灰化」——以 `var()` 探针读同名 token 解析值作基准，
  断言完成态底色等于 `--muted-foreground` 且不等于 `--primary`（oklch 计算值序列化
  不稳定，故不做字符串硬比）；`docs/04 §3.2` 完成 checkbox 规格行同步。

### 桌面端评论输入改为「点击占位框就地展开」

- **详情抽屉评论区**：常显的单行输入框换成「添加评论」占位框，点击才就地展开
  固定高度输入区（160px）；内容超出时走内部滚动条，不再随输入无限增高。
  `Ctrl+Enter` 发送、`Esc` 或取消钮收起（Esc 拦在 Radix DismissableLayer 之前，
  只收输入区、不连带关闭抽屉）。
- **右键「添加评论」弹窗**：Textarea 由 `field-sizing` 自适应增高改为固定高度 +
  超出内部滚动，与抽屉同口径。
- 回归：e2e 新增「详情评论：点击占位框就地展开固定高度输入区」（折叠态无输入控件 /
  展开即聚焦 / 灌 20 行后 `scrollHeight > clientHeight` 且控件高度不变 / 发送后收起并落库）；
  `docs/04 §3.4-8` 评论区块描述同步。

### 移动端清单侧栏与日历卡片化对齐今天列表

- **清单侧栏整卡化**（今天任务列表同款 `OrbitCardSegment` 口径）：
  快捷视图 7 行一卡、搜索/筛选器/回收站三行一卡、项目行 + 「新建项目」
  行一卡、已归档组一卡、「未分组」独立单段卡；卡外缘左右各让 12，
  卡间 `cardGap`。项目行按压水波盖在卡面上（行内自带圆角摘掉，
  外缘圆角归卡片）；重排把手与长按菜单行为不变。
- **日历月历整卡**：整张月历是一张单段卡（外缘 12、卡内垫 8），
  月 ⇄ 周收展只改变卡内高度；选中日描边/今天实心块口径不变。
- **议程档分组卡**：每组日期头作卡内首段（选中日高亮底保留，
  只取上圆角与卡片同弧）+ 任务行作续段；任务行去掉自带灰底圆角
  （卡面由段统一铺 `surface`），行高收敛到 `touchTarget` 不随内容跳动。
- **选中日列表去缝**：卡片/时间线两档段间 2px 间隙取消（整卡不断开，
  与今天列表同口径），外缘 16 收至 12；「当天没有任务」与议程档空态
  改为单段卡。
- 回归：新增 `sidebar_calendar_card_test`（侧栏裸行兜底 + 月历单段 +
  选中日空态卡 + 议程组卡首段）；既有日历/侧栏/冒烟用例全绿。

### 移动端任务行勾选框收至 20px

- **任务行 checkbox 由 24 下调到 20**（列表/看板/表格/矩阵/日历卡行统一，
  与桌面端任务行 `h-5 w-5` 跨端同源；相对 15px 标题更协调，热区仍外扩到
  44 不变）。看板/表格改用 `taskCheckboxSize` 口径（原误用子任务档）。
- 详情标题 28 / 子任务 22 不动；`orbit_checkbox_test` 锁定默认 20。

### 移动端快加面板工具栏不抢键盘

- **锚点小卡片改 Overlay 直挂**（优先级/项目/标签/「更多」）：原来走
  `showGeneralDialog` 路由，弹出即抢走输入框焦点致输入法下沉；直挂后焦点
  全程留在输入框，可边选边打字。定位/动效与路由版同源（`orbitFloatCardLayout`
  + `OrbitOverlayCard`），卡外点按关闭；卡片开着时返回键先关卡片（PopScope
  保住输入草稿）。
- **共享层**：定位计算抽取 `orbitFloatCardLayout`（路由/Overlay 同值防错位）；
  下拉面板内容公开为 `OrbitDropdownPanelView`（`onClose` 覆写关闭动作，默认
  路由 pop，既有调用方行为不变）；底部大抽屉（截止日期/图片管理）仍走路由，
  关闭后显式恢复焦点。
- 回归：`quick_add_sheet_test` 新增「工具栏不抢键盘」3 例（优先级/更多菜单
  打开时输入法不消失、截止抽屉点选后焦点回来，修前两例变红）；
  `orbit_dropdown_panel_test` 跟进公开类名定位。

> **0.1.0 条目口径**：0.1.0 是项目整体首个版本，本条目由 2026-08-23 初始提交至
> 2026-09-26 的**全部工作**归并总结——首批至 2026-09-24 的 git 记录（543 次提交：
> 222 feat / 130 fix / 32 perf / 84 docs，余为 chore / refactor / style / test 及其他；
> 计数口径为提交主题前缀，`git rev-list --count` 与 `findstr` 实测，PowerShell 原生
> 管道会吞掉含中文主题的行故不用它计数）加上 2026-09-25/26 的移动端对标优化批次；
> 按模块归并——合并同源提交、剔除过程性改动，不逐条罗列中间过程；逐条明细以
> git 历史与 `docs/07` backlog 为准。历史 `v0.1.0`（2026-09-15）tag 及其后的全部
> 未发布工作（云同步存储结构重构、第五轮探查收口、内存门禁入库、移动端快速添加
> 面板与抽屉口径收口等）已一并并入本条目。

## [0.1.0] - 2026-09-26

### 移动端底部抽屉统一走根路由（2026-09-26）

- **全项目 `showModalBottomSheet` 补 `useRootNavigator: true`**：页签分支各持
  Navigator 后，落在分支路由的抽屉会被壳的悬浮钮/底栏盖住（FAB 与底栏是
  Scaffold 兄弟层，抽屉困在 body 内）——走根路由抽屉才盖住底栏全屏可点。
  共 15 处（确认/单选/更多动作三共享弹层 + 快加/表单/模板/日期/颜色/密码/
  标签/筛选器/详情区/侧栏/同步状态/子列表面板）。
- **单选弹层行首语义图标位**（`SelectItem` 新增 `icon` + `iconColor`，与色点
  二选一）：快捷视图切换等行语义来自图标而非颜色的场景（与清单页快捷行
  图标同源），`orbit_sheets_test` 锁图标色值与尺寸。
- 回归：`quick_add_sheet_test` 新增「抽屉盖住导航」用例——分支 Navigator 内
  开快加面板，壳 FAB 点位点不透、面板经遮罩可正常关闭。

### 移动端 UI 对标优化批次二：竞品版式收编（2026-09-25）

- **逾期区一键「顺延」**：今天/列表视图逾期区块头行（manual 档为列表上方横幅卡）新增
  「顺延」——整组逾期任务一键改期到今天 18:00 收工时刻（18:00 已过则到明天 18:00，保证
  任务真的离开逾期桶）；走批量写库单次收敛刷新，可撤销。
- **日历月档下方列表改选中日口径**：点日格即看当天任务——头行为日期语义头（今天 /
  M月D日 周X + N天后/前 + 农历节日副标签 + 休/班徽标），任务列同一张卡（勾选框优先级
  描边环 + 标题 + 右列时刻与重复/提醒/描述图标，可直接勾选完成）；当天无任务居中提示。
  议程档保持整月按日分组不变（整月浏览走议程档或翻月点选）。
- **四象限更名对齐竞品（双端）**：象限名由行动短语（立即做/计划做/抽空做/可延后）改为
  「重要且紧急 / 重要不紧急 / 不重要但紧急 / 不重要不紧急」，格头 = 罗马徽标Ⅰ-Ⅳ彩底
  圆标 + 象限色名称；桌面端补齐罗马徽标与色名（原「名称 + 轴副标」去重）、第四象限
  识别色由中性灰改绿（与移动端/竞品同源：红/琥珀/蓝/绿）。
- **完成按钮方角化对齐 TickTick（双端）**：任务勾选框由圆形改 4px 圆角方框
  （移动端 `CircleCheckbox` 更名 `OrbitCheckbox`，全应用 7 处列表/看板/表格/
  四象限/详情/日历统一；桌面端列表/看板/四象限/详情抽屉四处完成钮同改）；
  **桌面端紧急度改为以完成按钮颜色为准**——未完成描边 = 优先级色（P0「无」
  回落中性灰），与移动端既有口径同源，列表/四象限的优先级左缘竖条随之移除
  （日历右栏行无勾选框、竖条保留）；完成态保持主题色实底白勾不变。
- **日历选中日任务卡行内元信息图标补全**：描述图标此前的数据位因列表通道
  列裁剪恒为空（`description` 在 list 投影置 NULL，万级列表省 47% IPC 体积）
  而永不渲染——新增「有描述」行元信息投影（`task_description_flags`，只出
  description 非空的存活行 id，不回传原文不破裁剪）贯通 core → FRB 桥 →
  移动镜像，B7 表级失效链挂 `todo_tasks`（描述编辑即时点亮/熄灭）；重复与
  提醒图标沿用既有口径（提醒走 A4 投影），无元信息的行不出图标列。
- **日历月档上滑收成单行周条**：月历网格上滑收成一周条（选中日所在周，列表随之上顶）、
  下滑展开回整月——周条内横滑翻周（跨月周日期不弱化、标题跟随焦点月）、点格切换选中日
  任务卡，农历副标签/休班徽标/事件圆点在周条同渲染；「回到今天」在周档跳回本周。
  `OrbitMonthCalendar` 新增受控档位参数（calendarFormat/availableCalendarFormats/
  onFormatChange/focusedDay/dimOutsideMonth），单档调用方（日期选择面板等）手势与
  原行为不变；周档 focusedDay 须回传 onPageChanged 原样日期（归一化到月初会拽回
  月初那一周）。
- **底部导航可配置（功能模块）**：对齐竞品「功能模块」——「更多」面板标题行新增「编辑」入口，
  进全屏配置页管理八个模块（今天/清单/日历/四象限/统计/搜索/回收站/设置）：红圈减号停用、
  绿圈加号启用、段内拖拽手柄重排（触感与抬起动效同任务列表口径），最后一个启用模块不可停用；
  底栏 = 启用序前 4 个模块 + 固定「更多」位，其余启用模块收进「更多」面板，配置即写即落盘
  （`LocalPrefs`，键 `bottom_nav_modules`）并实时跟随重建。路由从 4 分支扩为 8 分支（统计/搜索/
  回收站/设置改为页签分支：面板/侧栏/设置页入口改 `go` 切分支，底栏常驻、切页不丢栈；冷启动
  落点随配置落到启用序第一个模块），默认配置与改造前导航完全一致。
- **底部导航重构**：四页签 + 中央添加钮改五页签均分 + 右下悬浮新建钮（今天 / 清单 / 日历 /
  四象限 / 更多）；「更多」动作位不切页——就地弹出锚在页签上方的次级目的地面板（统计 /
  搜索 / 回收站 / 设置），点面板外关闭、下层照旧可读。
- **四象限升级主导航页签**：新增 `/todo/matrix` 页签分支（全量任务落桶，桶内截止升序）；
  统计页退出页签改「更多」面板推入（补返回键），页面内新建入口统一右下悬浮钮（落点仍随
  `QuickAddContext` 预填，长按直达模板新建）。
- **四象限改版**：弃「概览 2×2 计数 → 点格下钻」两态，改为整幅 2×2 恒在——四象限卡同屏
  等分、任务行直接列在格内（标题 + 截止日期纵排两行）、超出格高格内自滚，空象限居中
  「没有任务」；象限识别色改罗马数字徽标口径（Ⅰ 红 / Ⅱ 琥珀 / Ⅲ 蓝 / Ⅳ 绿）。
- **批量选择入口收敛到列表档**：选区行只在列表档渲染，看板/表格/矩阵档的「批量选择」
  面板入口隐藏（此前进入后无视觉落点）。

### 移动端 UI 全面优化批次：语义收敛与几何收正（2026-09-25）

- **语义色单一来源**：逾期红统一 `OrbitAccents.overdueRed`（任务行 / 看板 / 表格 / 多选行 /
  逾期段头，此前与 `colors.destructive` 两套红并存）；计数角标统一红；星标统一星标黄。
- **几何收正**：看板 / 矩阵视图补左右 12 页边（列卡此前贴死屏幕边缘）；批量工具条收到页尾
  8px、选择态列表底部动态让位（末行不再被遮）；页签分支内各屏页尾 80px 手势兜底让位收敛为
  16px（底栏页签接管手势区后的遗留口径）。
- **触控与完成态**：`CircleCheckbox` 布局盒外扩到 `max(size, 44)`、图形居中（视觉直径不变）；
  完成态标题全视图统一「划线 + 置灰一档」。
- **视觉收敛**：看板卡 / 表格行优先级改由勾选框描边环承载（五种优先级形态收敛为两族）；
  侧栏功能行图标改次要文字色、计数徽标底色回归 token；共享段头原语 `OrbitSectionHeader`
  上收（侧栏 / 搜索单一来源）；项目拖拽把手热区补足 48。
- **搜索结果行重排**：与主列表任务行同一信息层级（状态图标描边承载优先级 / 项目名按色着字 /
  口语化日期右列 / 完成态划线置灰），日期由裸 `YYYY-MM-DD` 改口语化；搜索初始态补引导空态。
- **空态与加载**：回收站初次加载补骨架（不再闪「回收站是空的」）；日历空月文案改口（新建
  入口已上移底部导航中央添加钮）；日历月份标题回归字阶（w800→w600）、工具条按钮热区回 48、
  任务卡补水波反馈。
- **件杂**：关于页补右滑入转场；筛选器优先级档补全 P5；快速添加胶囊 / NLP chip 内边距回
  4pt 网格；统计总览卡栅格间距统一 `cardGap`。
- **文档**：docs/10 重命名为《移动端对标差距分析》并全文竞品名中性化（对齐批次文档口径）；
  docs/05 §4.5 完成态口径、§七常量（热区下限 44）、§十热区条目同步。

### 视图命名收尾：e2e 定位与规格文档同步（2026-09-25）

- e2e 冒烟 #39 用例的侧栏入口定位改「今天」（exact 匹配防任务行子串误中）；
  docs/04 / docs/05 规格中「今天截止 / 本周截止」视图名同步为「今天 / 近7天」。


### 重排档渲染流逾期置顶（2026-09-25）

- 拖拽重排（manual 档）此前按数据原序平铺，今天/近7天视图纳入逾期后逾期行
  会混在流中：渲染流改为逾期置顶平铺（`_manualReorderStream`，与标准分支的
  逾期置顶段同序），重排落库 `_reorderTasks` 消费同一流保证槽位索引一致；
  头行/分隔行不进流（会打破 ReorderableListView 槽位数学），无逾期时与旧
  口径逐字节一致。


### 日期展示口语化——列表/看板/表格/详情/表单全链（2026-09-25）

- **新增共享格式化**（`task_logic`）：`formatDueShort`（相对日期，带非零时刻时补
  `HH:mm`；本地零点纯日期不带时刻——时刻判定取本地字段，UTC+8 下
  `ms % 86400000` 恒非零的坑）与 `formatStampLabel`（历史/提醒戳：今天 / 昨天 /
  M月D日 / 跨年带年份，恒带时刻）。
- **消费面**：任务行右列（「今天 18:00」替代裸「今天」丢时刻）、看板卡与表格
  截止列（原 ISO `2026-09-24` → 「昨天」，表格列宽 64→76 容纳时刻）、详情属性行
  截止/开始日期、详情提醒行与历史时间戳（原 `2026-09-25 07:18` → 「今天 07:18」，
  历史行同步去掉 monospace）、新建表单日期/提醒值行与 NLP 解析 chip。
- `formatDueShort` / `formatStampLabel` 纯函数单测注入固定时钟覆盖边界。


### 项目视图行内去重项目名（2026-09-25）

- 列表 / 矩阵 / 多选行与看板「按状态」分组的卡片在**项目视图内**不再重复显示
  项目名（页头已是该项目，行内重述是噪音）；快捷视图、未分组、搜索等跨项目
  语境保留项目名着色段。表格视图保留「项目」列（结构化网格列位恒定）。


### 今天/近7天视图纳入逾期任务（2026-09-25）

- **视图窗口口径**：今天 / 近7天两个聚合视图改为「截止 < 窗口上界即命中」——逾期
  未完成任务进入「今天」页签与「近7天」视图，由既有逾期置顶段自然承接渲染
  （此前逾期任务只出现在项目列表，主聚合视图反而看不到）；与图标角标
  「今天截止或已逾期」计数口径统一，双端（移动 filterTasks / 桌面 task-filters）
  同步同口径。
- **命名随语义**：「今天截止」→「今天」、「本周截止」→「近7天」（视图已含逾期，
  原名不再准确）；逾期区下的分隔行按视图语境显示「今天 / 近7天」，项目等
  其余入口维持「其余任务」。
- 移动 603 项 flutter test、桌面 381 项 vitest 全绿（today/week 边界用例随新
  口径更新：昨日截止命中、明日零点起不命中）。

### 移动端列表显示详细与显示设置（2026-09-26）

- **页头 ⋮ 面板补两项**（「这个列表」组由六项扩为八项）：「显示详细」开关（关 =
  行内只剩标题 + 右列时刻的紧凑形态）与「显示设置」入口（底部抽屉：显示详细 +
  所属清单 + 标签三开关，写即落盘；主关关闭时另两位开关置灰禁用）。
- **三位显示偏好**（`logic/display_prefs.dart`，本机 `LocalPrefs` 键
  `todo_show_detail` / `todo_show_project` / `todo_show_tags`，缺省全开、零 DDL、
  不进同步）：分别门控任务行副标题整行 / 其中的所属清单名 / 标签段；搜索等未接
  偏好入口的复用面保持原渲染。
- 测试：新增 `test/display_prefs_test.dart`（控制器默认与落盘 2 例 + 行渲染门控
  4 例 + 卡片段位 1 例）；`flutter analyze` 零告警。

### 移动端日历页头收敛与选中日双样式（2026-09-26）

- **页头收敛**：移除「日历」文字标题——月份导航（`< 年月 >`，点标题进年视图）与
  回到今天 / 议程切换 / 节假日更新三个动作直接落在页头（标题槽 + 动作槽）；
  窄屏下标题等比缩字不断行（既有 FittedBox 口径），图标保持 48 热区不压缩。
- **选中日列表双样式**（月档，竞品同款切换钮在日期语义头右侧）：卡片（默认，
  勾选 + 标题 + 右列时刻/元信息）⇄ 时间线（`HH:mm` 左置列 + 右侧卡片行，
  无时刻留空对齐）；档位落本机偏好 `todo_calendar_day_compact`（缺省卡片，
  零 DDL、不进同步），议程档分组列表不受影响。
- 测试：`calendar_screen_test` 页头断言跟进（`日历` 文字 → 年月标题，翻页改
  tooltip 定位）+ 新增样式切换用例（卡片 ⇄ 时间线往返 + 时刻左置）。

### 移动端底栏去文字与功能模块页顶预览（2026-09-26）

- **底栏纯图标**：移除五枚页签文字（竞品同款），选中态只剩主题强调色图标；
  读屏文案走语义标签（button + selected），角标与「更多」锚点面板不变。
- **功能模块页顶加底栏预览**（编辑操作页顶部预览同口径）：启用序前 4 个模块 +
  固定「更多」位，与真实底栏同形（56 高 + 表面 + 描边 + 均分 + 22 图标），
  只读、启停/重排实时跟随；底部说明补「上方为底栏预览」。


### 移动端功能模块配置页横滑换段与跨段拖拽（2026-09-26）

- **行左右滑动在两段间移动**（与行首圆形加/减钮同语义的快捷路径）：滑动方向
  不区分左右、归属只看所在卡片；`Dismissible.onUpdate` 手势进度驱动预览图标
  跟手位移（滑出段淡出让位、滑入段幽灵图标淡入占位），过阈值一次触感确认，
  取消回弹沿原路跟回。
- **手柄拖拽跨段直移**（`NavModulesController.move`，槽位越界钳制、同段退化为
  区内重排、最后一个启用模块不可停用）：手指可在两张卡片之间直拖，悬停段/
  槽位按列表高度比例折算实时映射（行内带简介高度不一，不用整除口径），预览
  按落位结果预演、跨段翻越触感确认、松手提交即落盘，落位行播一次入场动画。
- 行内启停走 tooltip 按钮（横滑底衬加减图标不再承担定位）；`home_shell_test`
  跟进 tooltip 定位 + 懒构建段滚动断言；`nav_modules_test` 新增跨段移动 6 例
  （槽位插入/越界钳制/末模块保护/同段退化/落盘）。

### 移动端今天页签快捷视图切换（2026-09-26）

- **今天页签根标题即切换器**（点标题开单选抽屉）：在我的一天 / 今天 / 明天 /
  全部任务 / 已完成 / 收藏 / 无日期之间切换，切到哪标题就叫哪（行首语义图标
  与清单页快捷行同源、当前档打勾）；列表/空态/分隔行/Logbook 分组/新建落点
  同步跟随，切回今天即清覆写；会话态不持久化（下次进页签回到今天本位）。
- 页签栈内入栈的今天视图与项目/未分组列表不挂切换器（标题即入口语义）；
  覆写到别的视图时日期副标同步消失。
- 单选弹层图标位用例进 `orbit_sheets_test`（图标色值与尺寸断言）。

### 移动端已完成行整行置灰（2026-09-26）

- **完成态统一走弱化灰**（`deactivatedText`）：标题划线色、日期短标签、标签
  色点与文字、项目名、重复/提醒/进度/关联/星标图标全部置灰，不再保留主题蓝、
  逾期红、星标黄、优先级色环与标签原色（已完成实例不再警示）；未完成态渲染
  口径不变。勾选框填充同步置灰（`OrbitCheckbox.activeColor` 改弱化灰，
  完成态描边不再传优先级色环）。
- 回归：新增 `done_gray_test.dart`（标题/日期/星标/勾选框/四元信息图标统一
  置灰）；`orbit_checkbox_test` 跟进填充色断言。

### 双端节假日数据缓存查看（2026-09-26）

- **移动端新增缓存页**（`/settings/holidays`，设置页日历区「节假日数据缓存」
  入口）：缓存概览卡（总数放假/补班拆分 + 覆盖年份 + 更新记账 + 立即更新，
  走既有 `holidayUpdate` 桥位）+ 按年分组行（日期 + 休/班徽标 + 假日名，
  徽标配色与日历页同源）；只读聚合、不进同步白名单。
- **桌面端日历分区加数据缓存卡**：同源汇总与按年分组（`details` 折叠，最新年
  默认展开）+ 立即更新按钮；纯函数 `calendar-cache-format.ts`（汇总/分组/
  日期标签）与单测共置。
- 测试：移动 `holiday_cache_page_test` + 桌面 `calendar-cache-format.test.ts`。

### 移动端设置页视觉收敛（2026-09-26）

- **关于/外观/通知历史三页改 SectionCard 分组**（与缓存页同口径）：裸
  ListTile/SwitchListTile 改分组卡 + 值行/开关行；列表顶距统一按状态栏 +
  页头行高 + 16 计算、水平内边距统一 `pageInline`、底垫手势区 + 32。
- 统计页与其骨架屏同补 `pageInline` 水平内边距（原 16 硬编码）。

### 移动端拖拽浮层底面随抬起实色化（2026-09-26）

- **侧栏项目行 proxyDecorator 补实色渐变**：扁平行本身透明，常驻透明会透出
  页面底色变成灰块——底面随抬起 `elevated` 从透明渐变为实色 surface（与任务
  列表 manual 档 / 编辑操作页同口径，`Clip.antiAlias` + medium 圆角 + 6 高度
  阴影不变）。
- 口径入库：AGENTS.md 新增拖拽浮层统一口径条（scale + 实色底 + 起止触感，
  `elevated` 取 `AppMotion.standard.transform`）。

### 移动端底部页签主导航（2026-09-25）

- **底部导航栏落地**（`OrbitBottomNav` 原语 + `HomeShell` 壳式主导航）：今天 / 清单 /
  日历 / 统计四个一级页签经 `StatefulShellRoute.indexedStack` 各自持栈，切页签互不丢栈、
  页签内入栈（任务列表 / 搜索 / 回收站等）底栏常驻；任务详情、设置等根级路由覆盖
  全屏、底栏随之隐藏。页签选中态主题色高亮 + 切换触感反馈。
- **中央凸起添加钮承担全局新建**：48px 主题色圆钮（`OrbitFab` 新增 dimension 小档），
  新建落点跟随当前列表（`QuickAddContext` 登记页面筛选入参，预填项目 / 视图标记），
  长按直达模板新建；各一级页右下 FAB 统一上收，页面不再另设悬浮钮。
- **「今天」页签**：`/today` 成为启动默认落点，页头「今天 + M月D日 周X」日期副标
  （无返回键），完整复用今日截止视图的逾期置顶 / 完成进度线 / 已完成折叠卡能力；
  页签图标挂今日未完成计数角标（>99 折叠 99+）。
- **清单页信息架构收敛**：日历 / 统计升级页签后移除清单页对应入口行；快捷方式
  「今天」直达 `/today` 页签根。
- 全量 601 项 flutter test 通过（新增底部导航壳 4 用例：页签切换 / 中央添加 /
  角标计数）；模拟器目检页签切换、新建落库、详情全屏隐藏底栏、暗色模式。

### 桌面端四象限视图与完成进度线（两端对齐）（2026-09-25）

- **桌面视图档增至五档**（`ViewMode` 新增 `matrix`，工具栏第五钮 + localStorage 白名单 +
  内容区分支）：2×2 恒定四象限（宽屏无下钻态），每格色带/计数 + 格内独立 `useVirtualizer`
  虚拟化列表；行复用 TaskRow 信息层级（优先级竖条/勾选/标签/项目/提醒/截止/子任务进度），
  交互收敛为勾选完成 + 开详情 + 收藏（拖拽/多选在象限分桶下语义不成立）。`groupEisenhower`
  纯函数与单测同移动端逐字对齐；视图循环快捷键顺带修掉漏 table 档的既有缺陷。
- **任务面板完成进度线**（对齐移动页头）：工具栏底缘 2px 主题色通栏线，宽度 = 完成占比
  （width 过渡补间），Tooltip「已完成 x / y」；仅在既有未完成又有已完成时出现。
- **内存口径两端确认**：桌面 React Query 默认 gcTime 10min + 大列表 key 10s 收敛 +
  `perf-metrics` 双门禁（audit-unbounded 0 违例、growth-curve 阈值在 CI），与移动端
  autoDispose 改造对等，无需改码。
- 桌面 380 项 vitest + 37 项 Playwright e2e 全绿；浏览器目检（mock 四象限数据）验证
  矩阵渲染、进度线出现与勾选联动（20%→30%）。

### 移动端内存收口（2026-09-25）

- **五个 family provider 改 autoDispose**（`taskDetailProvider` / `taskActivityProvider` /
  `searchProvider` / `statsProvider` / `todoTasksSearchProvider`）：riverpod 3 的 family
  默认不自动回收，浏览过的每个任务详情/活动轨迹、搜过的每个关键词（含结果快照）、
  翻过的每个统计年份（含 365 天聚合）都常驻到进程结束；改后仅当前在看的实例驻留，
  离开即释放。
- **图片解码缓存封顶**：`imageCache` 从默认 1000 张/100MB 收到 300 张/60MB
  （`main.dart`，解码侧本有 cacheWidth 降采样，此处补缓存总量上限）。
- 全量 597 项 flutter test 通过——无用例依赖跨页缓存常驻语义。

### 移动端列表页头完成进度线与未完成计数（2026-09-25）

- **页头新增完成进度线**（`OrbitPageHeader.progress` 可选槽）：
  页头底缘 2px 主题色线通栏覆盖在 1px 描边之上，完成占比变化走隐式补间；只在
  「既有未完成又有已完成」时出现（看板/表格档隐藏完成行、Logbook 恒为完成集，不出线）。
- **标题旁未完成计数**：列表页标题右侧灰字小计数（Logbook 态不渲染），长标题与
  计数同行 `Flexible` 防溢出。
- 页头结构微调：水平内边距从 Container 移到标题行，进度线通栏；状态栏避让几何
  不变（既有几何测试全绿）。

### 移动端四象限视图（Eisenhower Matrix）（2026-09-25）

- **视图档新增第四档「矩阵」**（`TaskViewMode.matrix`；纯视图层实现，
  不动 Rust、不进同步）：页头 ⋮ 面板「视图」就地展开选档，编辑项目页视图示意图同步补齐。
- **轴口径**：重要 = 优先级 ≥ 高(3)，紧急 = 截止 ≤ 今天末（含逾期，本地日界）；
  已完成不入桶（`groupEisenhower` 纯函数 + 单测）。
- **概览 + 下钻两态**：概览 2×2 象限格（象限色带 + 行动短语 + 轴文案 + 计数 +
  前三条标题预览），点格下钻该象限全量任务列表，行复用列表档 `TodoTaskTile`
  （勾选/侧滑/提醒徽标全功能），返回行回概览。
- 象限识别色全部取既有 token（逾期红/待办蓝/琥珀/次要文本灰），零新增色值。

### 首批能力（2026-09-24 起，与上段同属 0.1.0 条目）

### 移动端快速添加面板档位改锚点卡片（2026-09-24）

- **共享浮层卡片原语** `OrbitFloatCard` / `showOrbitFloatCard`（`orbit_dropdown_panel.dart`）：
  锚点上方 / 页头下方双形态，页头下拉面板改走同一壳（不再各包一层边框）；右沿钳制修掉
  左置按钮右对齐时 240 宽卡片滑出左屏的"窄条"假象；宽度统一走 `orbitFloatCardWidth`
  （屏宽 - 32 钳制）。
- **档位交互改锚点卡片**：优先级 / 项目为锚在触发钮上方的单选卡片（点选即回填关闭），
  标签为锚点多选卡片（点行即选中/取消，无确认尾栏）；日期改快捷抽屉
  （今天 / 明天 / 下周 / 选择日期…/ 清除日期，与桌面 `QuickDateMenu` 同口径）。
- **选中态只落底部图标**：已选档位展开为「图标 + 具体值」文字胶囊（日期/项目/标签/张数
  直接可见，优先级只旗子变该档色），输入框上方的 chips 行删除；术语「清单」改「项目」。
- **触感只给勾选确认**：勾选框与左滑完成只在未选→已选时震（docs/05 §9.1），滑回来恢复/
  取消完成不震。
- 测试：`quick_add_sheet_test` 档位交互改新口径（含卡片落屏内断言）+ `calendar_screen_test`
  长按预填跟进为图标态；全量 590 例绿 + `flutter analyze` 零告警。

### 移动端密码输入抽屉与 AlertDialog 清零（2026-09-24）

- **新增密码输入共享口径** `orbit_password_sheet.dart`（`OrbitSheetScaffold` 骨架，1–3 个
  obscure 字段 + 可选说明，长度下限与两次一致校验原样保留）。
- **设置页 3 处**（改主密码 / 开启加密 / 指纹密码确认）与**同步页 3 处**（改同步密码 /
  升 v2 / 密钥包密码）改走该抽屉。
- **`AlertDialog` 全量清零**（仅剩附件图片预览用透明 `Dialog`，非选择/确认/输入不算违规）；
  `AGENTS.md` 与 `orbit_sheets` 分工注释同步终态：选择走底部抽屉（页头列表操作例外走
  下拉面板）、确认走确认抽屉、输入走输入型抽屉。

### 移动端编辑操作页直拖换段与实时预览（2026-09-24）

- **跨段直拖**：手柄行可跨卡片直接拖过「更多」标题换段（标题行不可拖起但会被实时挤开），
  落点槽位即插入位并提交；拖拽中顶部预览实时预演（插入撑开 / 闭合），跨段翻越给触感确认。
- **横滑跟手**：行左右滑动由 `Dismissible.onUpdate` 进度归一驱动预览让位与幽灵占位；
  跟手期间时长切 `AppMotion.instant`（图标与手指 1:1 零拖尾），松手后切回常规时长收尾；
  顺带修掉落位入场动画从未播过的问题（只播换段落位行）。
- 双卡片加滑动换段动画：行滑动与加/减圆钮同语义换段，段内手柄拖只调顺序不换段；
  纯逻辑 `reorderQuickActions` 单测覆盖。

### 移动端新建统一入口与输入型底部抽屉（2026-09-24）

- **新建统一走列表页快速添加面板**：侧栏 FAB、桌面快捷方式、日历 FAB、日格长按改调
  `showQuickAddSheet`（同一入口）；面板新增 `initialDueDate` 预填（日历长按口径）；
  完整表单仅留编辑态 / 全屏展开 / 模板套用三条路。
- **新建项目 / 新建编辑标签改输入型底部抽屉**（名称输入 + 色板 + 固定尾栏，与模板/
  筛选器表单同口径；空名屉内拦截 toast，控制器交抽屉子树释放）。
- 测试口径跟进（侧栏 FAB 断言改面板、`todo_screens_smoke_test` 同步）。

### 重复任务完成推进提示（2026-09-23）

- **完成桥返回下一实例**：移动 `todoTaskComplete` 改返回手写镜像 `CompleteTaskResult`
  （task + nextInstance，Rust / Mock 同口径）；详情页 / 列表页勾选与通知「完成」动作弹
  「已完成，已生成下一期：M月d日（周X）」（后台静默）；批量完成单槽汇总，
  「已为 N 条重复任务生成下一期」并入撤销浮层副文案。
- **桌面同口径**：单条 toast + 批量汇总（`formatCnDate` 由 `repeat.ts` 导出复用）。
  背景：单实例链模型下完成即克隆下一实例，无提示用户会对列表多出的一条感到茫然。
- 测试：`todo_complete_test` 补 nextInstance 契约断言。

### 移动端底部快速添加面板 + 「编辑操作」设置页（2026-09-23）

- **底部快速添加面板**（新文件 `apps/mobile/lib/modules/todo/quick_add_sheet.dart`）：任务子列表右下加号
  点击即弹（空态「新建任务」同一入口）——输入框「准备做什么？」+ 已选条件 chips（日期/优先级/清单/标签/图片数，
  点 x 单项清除）+ 快捷操作图标行 +「...」更多 + 发送圆钮。Modal 抽屉承载（`OrbitSheetScaffold` 骨架，
  键盘避让 + 0.7 屏高上限），**不做常驻输入栏**（窄屏会吃掉列表可视区，docs/05 §八）。
- **七档快捷操作**（`logic/quick_actions.dart`）：日期 / 优先级 / 标签 / 清单 / 图片 / 模板 / 全屏。
  默认工具栏四档，图片·模板·全屏收在「...」菜单（尾部固定「设置」入口）。**语音输入与「转换为笔记」不做**：
  本仓无语音插件、无笔记实体，不摆无后端支撑的假功能。图片走「先建任务再挂附件」（单张失败不阻断任务本身）；
  模板复用既有「模板选择 → 表单预填」链（与长按加号同源，`showTemplateCreateFlow` 抽出共用）；
  全屏=携当前草稿打开完整新建表单；标签为多选抽屉（本地勾选态 + 底部确定，任务未创建不能勾选即落库）。
- **提交口径与桌面 `QuickAddBar` 一致**：NLP 解析（`parseQuickInput`）显式值 > 面板手动选择 >
  当前快捷视图默认值（#39 视图标记；今日/本周截止归一 18:00）；标签取 NLP ∪ 手动选择的并集。
- **「编辑操作」设置页** `/settings/quick-actions`（设置 → 组织 → 编辑操作）：面板形态预览（只读）+
  **一张连续可拖列表**——段标题「更多」之上 = 工具栏直显档、之下 = 收进「...」菜单的档，
  **拖拽越过标题行即换段**（标题行不可拖起，但会被拖拽项实时挤开，分界线随落点移动；
  重排切段抽成纯逻辑 `reorderQuickActions` 可单测），同段内拖拽只调顺序；行内圆形加/减按钮
  是跨段移动的快捷路径。落本机偏好键 `todo_quick_actions`（未知名忽略、缺档补「更多」，
  跨版本新增档不丢）。零 DDL、不进同步。
- **本页动效**：预览行图标用 `AnimatedPositioned` 按槽位定位——换序/换段时**平滑滑到新槽位**；
  拖拽抬起走项目既有口径（1.02 放大 + elevation 6 + surface 底 + 起止轻触反馈），
  行内加/减圆钮底色与图标随归属渐变，抬起中的档位在预览里着强调色。
- 文档：docs/05 新增 §十二 规格 + §4.2 FAB 描述与 §八 不对称条目；docs/01 §3.2「快速输入栏」由
  「桌面专属」改为两端。
- 测试：新增 `test/quick_add_sheet_test.dart`（档位读写 3 例 + 跨段重排 4 例 + 面板交互 5 例 +
  设置页 2 例）；全量 575 例绿 + `flutter analyze` 零告警。

### 移动端页头下拉面板 + 「编辑项目」整页（2026-09-23）

- **页头 ⋮ 改为顶部下拉面板**（新原语 `shared/widgets/shadcn/orbit_dropdown_panel.dart`）：锚在页头下沿、
  不铺遮罩、条目成组带 1px 分隔线；带子项的条目**就地展开**（子项缩进到文案列、当前档打勾），
  展开期间其余顶层条目置灰且不可点（点它们只收起子菜单）；点面板外关闭。六项两组——「这个列表」：
  编辑项目（仅项目视图，push 编辑页）/ 视图（就地展开列表·看板·表格）/ 看板分组（仅看板档）/
  隐藏已完成（开关项，与已完成卡头行同源同态）；「怎么操作」：筛选（行尾回显已启用档数）/
  排序方式（就地展开五档）/ 批量选择（进多选并预选首条未完成任务）。
- **「编辑项目」由对话框升级为整页**（`apps/mobile/lib/modules/todo/project_edit_page.dart`，路由
  `/todo/projects/:id/edit`）：页头 `X` + 标题 + `✓`（无改动置灰、保存中转圈）+ `⋮` 更多；
  主体 = 名称行（文件夹图标按当前色染色 + 无边框输入）/「清单颜色」（无颜色 + 10 色预设 + 自定义取色）/
  「视图类型」（列表·看板·表格三张灰底线框预览卡，选中 accent 描边 + 右上打勾）。删除 / 归档与侧栏
  长按菜单**共用** `logic/project_actions.dart`（写路径不再两处各写一份，色板同理上收
  `logic/project_palette.dart`）。
- **自定义取色**（新原语 `orbit_color_picker.dart` 的 `showOrbitColorPickerSheet`）：shadcn `ColorPicker`
  承载（默认 HEX 档、alpha 关掉），新增 `hex_color.colorToHex` 落库；「无颜色」写空串——下游本就回落
  中性表现（侧栏项目图标取强调色、列表行项目名回落次要文本色）。
- **每项目视图档**：进某个项目按「该项目上次用的档位」渲染（本地键 `todo_view_mode_project_<id>`，
  未设过回落全局档 `todo_view_mode`），在项目上下文切档只写项目档；桌面视图档仍为全局单键（docs/05 §八）。
- **约定同步**：`AGENTS.md`「选择类交互统一底部抽屉」补例外条款——页头「当前列表操作」入口走下拉面板，
  面板内单选集就地展开、不再二次弹层；只有表单类入口（筛选）仍开底部抽屉。
- 测试：新增 `orbit_dropdown_panel_test`（6 例）与 `project_edit_page_test`（7 例），a11y 的色板热区例
  改挂整页；全量 560 例绿 + `flutter analyze` 零告警。

### 移动端任务列表版式重排（2026-09-23）

- **任务行改左右两列**：右列 = 截止日期（相对化：今天 / 明天 / 昨天 / `M月D日` / 跨年带年份；未来与今天主题蓝、
  逾期红）+ 元信息图标行（重复 / 提醒 `HH:mm` / 子任务进度 / 关联 / 星标），左列只留标题 + 标签 + 项目名——
  纯标题行不再被空白副标题撑高，行高统一 `minHeight: 48`。
- **优先级移到勾选框描边**（P1–P5 六档语义色，P0「无」回落中性灰），副标题里的 8px 色点退役：同一信息不再两处呈现。
- **任务区卡片化**：新增原语 `shared/widgets/shadcn/orbit_list_card.dart`（`OrbitCardSegment` 按段画描边与段间分隔线
  ——列表是懒加载 `ListView.builder` / `ReorderableListView`，整卡包裹会把万行任务一次性实例化，且非均匀 `Border`
  与 `borderRadius` 不能共存），整列未完成任务拼一张圆角白卡；逾期区块头与「其余任务」分隔行同为卡内段，
  标准列表条目由「按下标反算 od/rest」改为显式条目表（顺带消掉 od 为空时 `rest[-1]` 的越界隐患）。
- **列表尾部「已完成 N ⌄」折叠卡**取代页头 eye 开关：完成时刻倒序、直显上限 20 条 + 「查看全部」进 Logbook，
  manual 重排档挂 `footer` 不与可拖行混排；展开态落本机偏好新键 `todo_done_section_open`
  （旧键 `todo_hide_done` 只作一次性回落：老用户上次把已完成显出来过，首次进入即展开）。
- **页头收敛成 返回 + 标题 + ⋮**：视图模式 / 筛选 / 排序三档进底部抽屉，菜单项回显当前档位，筛选生效时 ⋮ 挂角标；
  多选态标题栏（已选 N 项 + 全选 / 退出）不变。
- **有意边界**：卡片与已完成卡只覆盖列表两档（标准列表 / manual 重排档）——看板与表格没有承接位，维持
  「隐藏已完成」口径；Logbook（done 快捷视图）本身即完成集，不再叠一层折叠卡。
  测试：新增 `orbit_list_card_test` / `done_section_test` 与日期相对化、优先级描边、勾选框描边覆写用例；
  全量 547 例绿 + `flutter analyze` 零告警（自绘描边另用一次性 golden 目检后删除）。

### 移动端长按拖拽修复（2026-09-23）

- **长按拖动后不再误弹操作菜单**：manual 档（拖拽顺序，默认档）整行长按拾起后，只要手指移动过
  （`Listener` 原始指针位移 > `kTouchSlop`）就只落位排序、松手不弹菜单。此前位移标记挂在
  `onReorderItem` 上，而它只在真换过槽位时才触发（拖开一圈又落回原槽位全程无回调），拖动后松手
  会凭空弹出操作菜单；原地纹丝未动仍是长按，菜单入口不变。

### 小而实用批次（2026-09-23，A 类四项）

- **移动端附件图片缩略图（docs/09 A9 落地）**：详情附件区图片行显示 32px 行内缩略图（新增原语
  `shared/widgets/shadcn/orbit_image_thumb.dart`），只对「已在本机落地且 ≤ 2MB」的图片读字节，
  解码按 `size × dpr` 降采样；字节缓存 12 条 / 16MB 双上限 + 插入序 FIFO 淘汰 + 区块 dispose
  整体清空。全屏预览加双指缩放（内置 `InteractiveViewer`）。此前只能靠文件名分辨截图。
- **Android 长按图标静态快捷方式**：新建任务 / 今天 / 搜索三档（`res/xml/shortcuts.xml` +
  三个自绘矢量图标 + Manifest `android.app.shortcuts`），原生只暂存动作 id、Dart 侧
  `ShortcutReceiver` 统一落点（侧栏处理器承接，冷启动动作先暂存后补发），语义不跨端重写。
- **列表行「关联」徽标（A4 投影的 C7 消费）**：双端列表行在任务有关联时渲染链环徽标（桌面
  `use-task-dependencies` + `task-list-view` 元信息行、移动 `taskDependencyFlagsProvider` +
  `TodoTaskTile`），关联行写事件经 db-invalidation 精确失效该投影。「被阻塞」档不做——双端详情
  抽屉的「添加关联」固定写 `relates_to`，没有入口写 `blocks` / `blocked_by`。
- **同步状态可视化（双端接 `cloud_sync_get_state`）**：设置页新增「同步账本」卡——各表各桶的
  指纹前 8 位、push / pull 水位线、远端清单 epoch、本机设备标识；桌面展开才拉取并随同步完成
  刷新，移动端进入页面 + 刷新按钮回读。移动抽象桥补 `cloudSyncGetState` + `SyncStateView`
  镜像 DTO（JSON 串解析），`ipc-mock` 的 `cloud_sync_get_state` 修正为 SyncState 结构。

### 桌面端补齐批次（2026-09-23，docs/07 #60–#63）

- **桌面两处对称（#60）**：①设置页新增「日历」分类，值行读 `holiday_meta.fixed_hour` → 0-23
  整点下拉写 `holiday_set_fixed_hour`，日历页两处更新按钮 tooltip 带上当前固定时刻（与移动端
  #59 同口径）；②`tauri.ts` 补 `fullBackupDeviceInfo` 包装，备份卡导出区显示「本机设备标识」
  （与备份清单 `device_id` 同源，恢复预览的「来源设备」即此值），`ipc-mock` 补同名命令。
- **桌面提醒相对档（#61）**：移动端 #53 的对称项。`lib/quick-dates.ts` 新增
  `buildReminderDueOptions`（截止当天 09:00 / 前推 1 小时·30·15 分钟；同刻去重、过期不过滤），
  `QuickDateMenu` 加可选 `dueDateMs` 前置「相对截止」组、`DateTimePicker` 透传；三处提醒入口全覆盖
  ——快速输入栏、详情抽屉提醒区、任务表单（经 `FieldDef.relativeDateField` 从同表单截止值实时取锚点）。
  产物仍是绝对毫秒 `remind_at`，零 schema 变更。
- **应用内更新兜底出口（#62，`docs/07 #50` 残余收口）**：新增 `lib/update-fallback.ts`
  纯函数 `resolveReleaseFallbackUrl`；检查/下载安装两条失败路径的 toast 加「复制下载链接」action。
  **安装方式识别（MSI/NSIS/便携/dmg）有意不做**：`bundle.targets="all"` 但 `latest.json` 只发布
  nsis/mac-app/appimage/deb 键、不发布便携产物，可靠区分 MSI/NSIS 需注册表查询或真机安装器验证，
  启发式误判会挡住本可升级的用户——故只交付可验证的兜底出口。
- **内存治理三连（#63，docs/09 A6/A8/A2 首步）**：①回收站列表加 `LIMIT 1000`，并把
  `purge_all_trashed_tasks` 改走独立 id/uuid 投影查询（原本复用列表函数推事件，加限后会静默漏发
  db-change；新用例锁边界）；②连接池上限提为常量 `MAX_CONNECTIONS = 3`（同步已串行化，池上限即
  内存下界）；③瘦行首步：列表通道裁剪列清单加 `'' AS uuid`（约 450KB/万行，必须空串不能 NULL——
  DTO 非空 String；消费方核实后双端零依赖），双端 mock 同口径，契约测试与桥一致性用例同步加断言。

> 本轮环境限制：JS 侧门禁（`pnpm typecheck`/`test`/`build`、Playwright）在本机不可用
> （node_modules 的 pnpm 重解析点无法穿透，离线无法重建），桌面 TS 改动以 IDE 类型诊断 + 人工复核
> 验证，最终以 CI 为准；**`docs/09` 的 cold-start 基线取数（P3）因此未执行**（需先 `pnpm build`）。
> Rust 侧 `cargo test --workspace --lib` 617 全绿、移动端 `flutter analyze` 零问题 + 516 全绿。

### 移动端日历节假日更新时刻可配（2026-09-23，docs/07 #59）

- 桥位 `holiday_set_fixed_hour` **双端早就绪**（移动 FRB 生成物 `holidaySetFixedHour` + Rust
  `api/holiday.rs`；桌面 `holiday_cmd.rs` 已注册命令），但两端 UI 均零消费、`HolidayMeta.fixedHour`
  也无处展示——每日自动更新时刻只能吃 core 缺省 08:00。本轮移动端接线：抽象桥暴露该方法（Rust 侧
  转发 FRB 既有函数，**零 codegen**）+ Rust/Mock 两实现（mock 落 `MockStore.holidayFixedHour`，
  clamp 0-23）；设置页新增「日历与节假日」卡（值行读记账 → 0-23 整点单选抽屉 → 落库 + toast），
  日历页更新按钮 tooltip 带上当前固定时刻（与设置页同一份 `holidayMetaProvider` 记账）；新增
  `_valueRow` 值行原语（形制同回收站「保留时间」行）。测试 2 例。桌面侧接线留后续。

### 移动端体验对齐批次 P1（2026-09-23，docs/07 #55–#57）

- **同步密钥治理三入口（#55）**：桥位 `sync_crypto_meta_version` / `sync_crypto_upgrade_v2` /
  `cloud_sync_rekey` 早已存在且桌面 `sync-recovery-page` 有入口，移动端此前**零调用**——v1 老用户
  无法在移动端升级密钥方案、「以本机为准重置云端」不可达、也看不到自己是 v1 还是 v2。本轮在同步
  密码卡补「本机密钥方案」版本行 + v1 设备才出现的「升级密钥方案到 v2」（密码对话框）+「以本机为准
  重置云端」（destructive 二次确认，解析 `result_to_json` 后给出推送模块/附件数）。Mock 桥三方法由
  「Mock 未实现」补齐同口径实现（store 新增 `syncKeyVersion`）。测试 4 例。
- **日历议程档（#56）**：桌面 `CalendarSubMode` 有 `month|year|agenda` 三档，移动端只有「月历网格 +
  当月按日列表」一屏。本轮补工具栏月/列表切换：议程档隐藏网格、整页让给按日分组列表、切入时一次性
  定位今天、日期头带休/班徽标（月档不带，对齐桌面 `showHolidayMark`），提示与空态文案随档位改口；
  「班」徽标底色抽为 `ChineseCalendarColors.workdayBadge` 单一来源。测试 2 例。
- **备份导出区本机设备标识（#57）**：`full_backup_device_info` 桥位双端均零消费；恢复预览已有「来源
  设备」，导出侧却无从知道本机标识。本轮在导出卡补一行「本机设备标识：<id>」（读取失败静默不渲染、
  不阻断备份链路），与恢复预览「来源设备」同值可直接对号。桌面侧同步接线留后续。

### 移动端「修改后立即同步」生效（2026-09-23，docs/07 #58 / docs/10 §A-2）

- **写路径触发 `push_only`**：新增 `services/sync_on_change_scheduler.dart`（进程级单例），由
  BootGate 唯一的 dbChanges 订阅转发——业务写路径落库 → **5s 滑动防抖**（对齐桌面
  `sync_scheduler.rs` 的 `ON_CHANGE_DEBOUNCE_SECS`）→ 门控（已配置云同步 && `sync_on_change`
  && `is_auto_sync` && 有同步密码且已解锁 && 引擎空闲）→ `cloudSyncPushOnly(origin: background)`。
  不做表过滤（引擎增量指纹未变时秒级跳过，无放大效应），配置每轮现读，开关改动下一轮即生效。
- **两处有意差异（移动端无后台调度器所致）**：①桌面 60s tick 兜底在移动端不存在，故推送
  进行中收到的写入在出窗后**补排一轮**，避免漏推只能等下一次编辑或切前台；②移动端无
  sync-progress 事件流，后台推送不占用标题栏「同步中」指示，仅成功后失效
  `syncConfigProvider` 刷新「上次同步」。
- **耗电/流量口径**：触发只来自用户真实编辑，每窗口至多一次推送，引擎忙 / 指纹未变时零上传，
  不做后台轮询（进入 / 退出前台的 `cloudSyncForce` 兜底保持原状）。设置页开关文案改口（标注
  移动端已生效 + 依赖「定时同步」总开关）。测试 10 例（调度器 9 例 + BootGate 接线 1 例），
  flutter 514 全绿。

### 移动端体验对齐批次 P0（2026-09-23，docs/07 #52–#54）

- **ICS 日历导入打通（#52）**：`ics` 预设此前只有 orbit-core（`CsvImportPreset::Ics` + `map_ics_rows`）
  与桌面导入卡接通，移动端预设停在 orbit/todoist/ticktick、文件选择器只放行 `csv/txt`——本轮补
  「ICS 日历」档、按档位放行 `.ics`、导入卡标题改口为「导入文件（迁移）」并补 ICS 文案；文件读取由
  `String.fromCharCodes`（Latin-1 逐字节转码，中文标题必乱码）改为 `utf8.decode(allowMalformed)`。
  Mock 桥按 core 口径补 VTODO 解析（unfold / TEXT 反转义 / PRIORITY 逆表 / DUE 三种形态 /
  VEVENT 忽略 / 块级跳过），`csv_import_test` 新增 5 例。
- **提醒相对档快捷（#53）**：提醒字段由「点行直进日期时间面板」改两段式——先给相对档（有截止：
  截止当天 9:00 / 前推 1 小时·30·15 分钟；无截止：今天·明天 9:00），末项「自定义时间…」进原面板。
  产物仍是绝对毫秒时刻（`remind_at`），**零 schema 变更**；同刻档位去重、过期档位不过滤（与日期
  面板允许选过去同口径）。纯函数 `reminderPresets` + 单测 4 例，表单交互回归 2 例。
- **任务行元信息补齐（#54，对齐桌面）**：列表行副标题原本只有「优先级色点 + 项目名 + 截止」，本轮补
  标签段（6px 色点 + 名，超 3 折叠 `+N`）、提醒段（铃铛 + `HH:mm`；未来取最近一条 / 全过期取最早一条、
  已完成实例不警示、到期未完转逾期红）、子任务进度段（`listChecks` + `N%`，0/100 不显示）。新增
  `displayReminder` 纯函数镜像桌面 `reminder-meta.ts`；桥位 `taskRemindersProjection` 由「零调用」
  转为接线，并在 `db_invalidation.dart` 为 `todo_reminders` 补提醒投影失效目标（增删提醒后徽标立即跟随）。
  `docs/05 §4.5` 任务行规格随之同步。

### 移动端 UI 批次（2026-09-22）

- **字号档（全局 TextScaler）**：外观字号档从逐处覆写 `fontSize` 改为全局 `TextScaler`，
  硬宽度列（表格 / 看板列 / 热力图）加保护，放大后不再挤断。
- **空态引导**：`EmptyState` 支持主行动按钮，接通任务列表与筛选器的空态出口。
- **下拉刷新**：主列表 / 侧栏 / 统计 / 回收站接 `RefreshIndicator`（本地重读 + 已配置时跑一轮
  云同步）；看板（横滑）与表格（定表头横滚）**有意不接**——与横向拖拽抢同一手势。
- **骨架屏**：自绘 `OrbitSkeleton` 原语（`surfaceSecondary` + `skeletonPulse` 呼吸），只铺首屏
  四处初次加载（详情 / 统计 / 主列表 / 侧栏），**有旧值可守时不出现**；二级页与按钮内 loading
  保留 spinner。
- **视图切换过渡**：列表 / 看板 / 表格三态切换加淡入 + 上滑 3%（200ms），key 只跟视图走——
  任务增删、骨架落定、下拉刷新不重播整列表。
- **卡片去阴影**：卡片统一收口 `OrbitCard`，去掉 v2 阴影，回到「1px 描边 + 表面分层」口径。
- **行退场动画**：标准列表的删除 / 离场型完成播 300ms 高度收起 + 淡出；写库仍立即落库
  （ADR 0005），只延迟主列表那次失效，其余缓存即时刷新；边界与取舍见 docs/05 §9.2。
- **无障碍**：操作按钮补读屏标签（`IconButton.tooltip`），色点热区统一补到 48（`touchTarget`）
  且视觉直径不变——口径见 docs/05 §十，回归 `test/a11y_test.dart`（顺带修掉标签色板抽屉的
  色点仍是 40 裸点、未补热区）。
- **动效 token 收口**：路由转场与滚动定位的硬编码时长 / 曲线收进 `AppMotion` 别名
  （`pageInCubic` / `pageOutCubic` / `scrollSettle*`，数值零变化，`app_motion_test` 锁值）；
  删除零引用的 `pageIn` / `pageOut`。
- **依赖瘦身**：删除热力图副本与三个零引用依赖。
- **底部抽屉口径收口（`OrbitSheetScaffold` / `OrbitSheetActions`）**：新增抽屉骨架原语——手柄 +
  标题 + **可滚内容区** + **固定底部按钮行**，确认/取消类按钮一律钉在抽屉底部且标签居中
  （shadcn 按钮内标签盒子与按钮同宽，默认 `TextAlign.start` 会贴左，观感"字不在按钮中间"；
  圆角/高度未动，仍为 `AppShapes.medium`／shadcn `radiusMd` = 14）。已迁移：确认弹层、
  日期时间选择器、描述编辑、筛选器新建、模板新建/编辑、云同步面板、重复规则「确定」、
  列表过滤「清除全部筛选」（后两者原先在滚动区内，会随内容滚走）；口径与回归见 docs/05 §十一。
- **任务行样式收敛 + 拖动排序改整行长按**：任务行去卡底 / 去阴影 / 去描边，仅保留下沿 1px
  分隔线（与多选态行同形制，整列不再是一摞白卡），行尾拖拽把手图标移除；manual 档（拖拽顺序，
  默认档）拖动排序由「行尾把手」改为**长按 500ms 拾起整行**（不再与上滑滚动 / 左右滑抢手势），
  **拾起后原地松手仍弹操作菜单**——菜单入口与功能零损失（其余排序档 / 看板 / 表格长按照旧）。
  口径见 docs/05 §4.5 / §9.2。
- **破坏性按钮实心化**：`sh.Button.destructive` 常态填充原是 shadcn 默认的 50% 透明
  `destructive`（白字淡粉，被用户读成「按钮不可点」）→ 全局覆盖为 token 实色
  （`shadcn_theme.buildDestructiveButtonTheme`：悬停/按下混白 10% 变浅、禁用回落中性表面），
  与桌面 `bg-destructive text-white hover:bg-destructive/90` 同口径。

### 移动端撤销浮层常驻修复（2026-09-20）

- **症状**：批量改优先级等操作后，「已调整 N 个任务的优先级 / 撤销」浮层一直不消失。
- **根因**：`WaitToast` 对带动作按钮的条目特意不启动自动收起定时器（原意是等用户
  处置），而撤销浮层本就只在 5s 窗口内有效——窗口过后仍长驻挡住内容。
- **修复**：`WaitToast` 新增 `autoDismissAfter` 参数与 `defaultDwell`（2.6s）/
  `undoDwell`（5s）常量；撤销类调用点（任务列表 `_offerUndo`、回收站彻底删除）
  显式传窗口时长到期自动收。顺带修掉撤销浮层描述写死「已移入回收站的任务可在
  回收站恢复」——非删除类操作的撤销不再显示该指引。
- **回归**：新增 `test/wait_toast_test.dart` 4 例（撤销条自动收 / 纯提示自动收 /
  提醒条与错误引导条按设计保持常驻）。

### 移动端提醒「推迟」丢失修复（2026-09-20）

- **症状**：通知上点「推迟 10 分钟」后，任务里的提醒直接消失、且到点不再提醒。
- **根因**：引擎到期处置（`todo_api::advance_fired_reminder`）会把非重复任务的
  提醒行软删，而移动端推迟通道只重排系统闹钟**不写 DB**（后台 isolate 无法重入
  FRB 的历史约束）——于是提醒行被引擎清掉，紧随其后的 db-change 重排
  （`cancelAllPendingNotifications` + 按 DB 排）又把刚排上的推迟闹钟一并取消。
- **修复**：推迟落成 DB 事实（软删旧时刻行 + 新建推迟时刻行，与桌面
  `reminder-snooze.ts` 删旧建新同语义），新增 `lib/services/reminder_snooze.dart`：
  ① 前台（主 isolate）经 `NotificationService.onSnoozeAction`（BootGate 注入）
  点即落库；② App 不在前台时 action 由独立后台 isolate 回调（主 isolate 注入的
  静态回调与 FRB 在隔离区都不可见），意图写入 `dart:io` 暂存文件
  （`SnoozeSpool`），回前台（resumed）/冷启动时 drain 写回；③ **孤儿闹钟落地**
  为主通道（真机复验后调整）：Android 上后台 isolate 的 `Directory.systemTemp`
  实际不可写、且 DB 旧行多已被引擎清理，故改为重排前与回前台时读系统 pending，
  对「任务存活未完成 + 无提醒行 + 时刻在 (now, now+24h]」的闹钟补建提醒行；
  配套 `NotificationService.cancelAlarmFor`——用户手动删提醒时同步撤闹钟，
  避免残留闹钟被误判为推迟产物而复活。
  另修正推迟起算点为 `max(现在, 原时刻)`（补扫场景不再把新时刻排到过去），
  过期意图丢弃不补建（避免闹钟响过之后再弹一次）。
- **回归**：`test/reminder_snooze_test.dart` 20 例（计划纯函数各分支含孤儿四态、
  前台落库删旧建新/幂等/不误删其他时刻行/过期丢弃、暂存文件往返与脏行容错、
  补齐执行）；ADR 0002 §决策语义变化同步修订「后台不写 DB」旧口径。

### 移动端多选崩屏修复（2026-09-20）

- **多选进入即红屏**：`sub_list_screen` 非重排列表分支（选择态强制回落、切出
  「拖拽顺序」档后即走该分支）的逾期置顶 item 索引，在**无逾期任务**时算成
  `rest[-1]` → `RangeError (length)` 整屏红；改为逾期区为空时直接映射
  `rest[index]`，并修正逾期区偏移（旧实现把 `od[0]` 渲染两次、丢掉最后一条逾期行）。
- **回归守卫**：`todo_screens_smoke_test` 新增两例——无逾期任务进多选不崩、
  非重排档下逾期区每行只渲染一次（旧实现在 ≥2 条逾期时重复首行）。

### 移动端确认类交互统一底部抽屉（2026-09-20）

- **新增确认抽屉原语** `shared/widgets/confirm_bottom_sheet.dart`：`showConfirmBottomSheet` =
  拖拽手柄 + 标题/说明（长预览体走 `content`）+「取消 / 确认」按钮行，破坏性操作 `destructive`
  红底；返回 `bool`——确认 `true`，取消 / 点遮罩 / 下滑一律 `false`，纯告知场景 `cancelLabel: null`
  只留一个按钮。
- **确认类 `AlertDialog` 全量迁移到抽屉**：回收站彻底删除与清空、任务单条与批量删除、
  项目删除与删除保护提示、保存筛选器/模板/标签删除、子任务/评论/附件删除、
  同步冲突恢复与清空、备份恢复/版本不一致/删除、通知历史清空、关闭加密（二次确认）
  与清除主密码、明文导出与 CSV 导入确认、断开云同步与清除同步密码缓存。
- **`AlertDialog` 仅保留带 `TextField` 的输入表单**（新建/编辑项目与标签、改主密码/
  改同步密码/输密钥包密码）；口径写入 `AGENTS.md` 移动端约定与 `docs/05 §4.1`，
  `sync_settings_page_test` 的确认定位随形态由 `AlertDialog` 改为 `BottomSheet`。

### 移动端动效对齐微软 To-Do（2026-09-20，仅动效层）

- **动效 token 单一来源**：新增 `core/theme/app_motion.dart`（时长/曲线/缩放档）；
  `AppDimens` 移除旧时长常量，`wait_toast` / `sync_status_button` 迁移至新 token。
- **勾选反馈**：`CircleCheckbox` 加底色渐入 + 对号缩放淡入（构造签名不变，7 处调用点零改动）
  + 点按触感反馈。
- **完成态标题**：新增 `AnimatedStrikethrough`——保留真实 `Text` 节点，其上按行度量自左向右
  绘制删除线并过渡文字色，控制器初值即终态故滚动入场不重播；接入列表行/选区行/详情标题/
  子任务/看板/表格/日历/搜索/筛选预览共 9 处。
- **行入场与拖拽**：标准列表分支新行高度展开 + 淡入（只播"新出现"的任务，不整表重播）；
  任务行与侧栏项目拖拽加抬起放大 + elevation 与起止触感。
- **底部抽屉**：选择类/更多操作/表单三类统一 `sheetAnimationStyle` 轻快入场（入 250ms / 退 150ms）；
  日期选择器视图切换时长收口 `AppMotion.viewSwitch`。
- **零视觉漂移**：布局/间距/字阶/色值/圆角/直径/信息架构/路由全部未动，桌面端与 Rust 侧零改动。
  动效清单与五条有意边界记 `docs/05 §九`，竞品口径同步 `docs/07 §2.1/§2.3`。

### 移动端补齐（对照桌面命令 + 新页面）

- **FRB 桥补齐 10 函数缺口**：`todo_labels_get` / `todo_task_labels_get` /
  `todo_tasks_recalc_percent` / `business_count` / `todo_projects_get_by_uuid` /
  `todo_tasks_get_by_uuid` / `cloud_sync_force`（进入/退出应用专用）/
  `ping` / `crypto_sha256` / `crypto_random_hex`；Dart 侧 OrbitBridge 抽象、
  Rust/Mock 两实现、mock_store 同口径，BootGate 生命周期改走 `cloudSyncForce`。
- **保存筛选器七键可视化构建抽屉**：状态/最低优先级/天内截止/项目/标签/
  仅逾期/仅收藏七键，替代手写条件文本框；行内编辑钮支持更新已有筛选器。
- **详情页**：关联任务搜索增删（全局搜索选人 + 跳详情 + 解除）、子任务完成
  进度条、附件拍照（相机）与文件双来源（分享文本建任务仍由 ShareReceiver 覆盖）。
- **外观设置页**：主题三态（跟随系统/浅色/深色）+ 字号/字重三档，全走
  LocalPrefs 字符串读写，写后即时重建主题；app_theme 注释口径同步。
- **通知历史页**：类型过滤/分页（50 步进，上限 200）/清空 + 提醒总开关
 （`reminder_enabled`，关后仅记历史不弹窗）；开机经 `db_maintenance`
  清理过期通知日志（30 天 TTL）。
- **关于页**：package_info_plus 真实构建版本 + 更新日志分区 + 开源许可入口；
  设置页关于卡版本号同源；组织卡新增外观/通知历史入口；安全卡新增清除主密码
  入口（二次确认后路由到关闭加密库迁移流程）。

### 产品与平台

- **本地优先、零遥测、端到端加密**的跨平台任务管理应用：桌面 Tauri 2（Windows /
  macOS / Linux）+ 移动 Flutter（Android / iOS，ADR 0003），无账号、无订阅；应用显示名
  「循迹」（进程名 `orbit`）。
- **业务逻辑全量下沉 Rust 核心**（`crates/orbit-core`）：CRUD、重复规则引擎、提醒到期
  处置、回收站 TTL、统计聚合、CSV/ICS 导入导出、附件内容寻址、节假日；双端壳只保留
  薄 UI 与桥接（桌面 Tauri command + `src/lib/tauri.ts`；移动 `OrbitBridge` 抽象 →
  FRB `RustOrbitBridge` / `MockOrbitBridge`），桥接签名双端同名同参、mock 同口径。
- **事件总线**：db-change 单播双端壳（桌面 Tauri event / 移动 FRB event stream），
  前端缓存失效链统一依赖；桌面事件泵只传 `table` + `op` 精简载荷，广播溢出（`Lagged`）
  时补发全量失效哨兵而非终止转发。
- **monorepo 重组**（omnipass 模式）：根 Cargo workspace 只管 `crates/*`，
  `apps/desktop/src-tauri` 为嵌套独立 workspace，移动端经 cargokit 复用 core；包名统一
  `orbit-core` / `orbit-flutter`，pnpm lockfile 上收仓库根；Rust 工具链与 FRB codegen
  版本双双锁定（1.96 / 2.12.0）。
- **品牌资产管线**：`scripts/generate_icons.py` 一次产出桌面 PNG/ICO/ICNS（手写 ICNS
  容器，无 iconutil 依赖）+ Android 五密度图标 + 通知剪影；图标定标改**短轴撑满**
  （主体放大约 21%，任务栏小图标不再显小），v5 透明底「圆环轨道」全族重生成——ICO
  十槽结构与首帧 256px（任务栏取用位）不变。

### 任务核心

- 任务 / 子任务 / 项目 / 标签 / 评论 / 任务关联（6 类关系）/ 六档优先级（含「无」档
  全程着色）/ 多提醒 / 开始日期 / 完成进度 / 收藏。
- **重复任务**：规则编辑器（每周几掩码、结束条件、when done、完成后推进锚点）+
  「下次 M月d日（周X）」具体日预览（Things 口径）+ 推进引擎下沉 core 单事务（完成后
  自动生成下一实例，三端同一入口）；滚周期双轨迹——原实例记「已滚动下一周期」、新实例
  记 `create(from=repeat, parent_id)` 使自身历史可溯源，幂等再完成不重复记。
- **子任务转独立任务**（承接父任务项目 / 优先级 / 日期，完成事实保留）+ **一键复制任务**
  （克隆字段与子任务，副本紧邻原位）+ **项目归档**与项目颜色（侧栏圆点 + 全展示位按色渲染）。
- **任务模板**（同步表第 11 张：周报 / 报销单 / 差旅清单免从零搭）；**保存的筛选器** +
  可视化构建器（裸 JSON 手填退役，工具栏「存为视图」一键固化）。
- **回收站**：软删墓碑 → 列表 / 恢复 / 彻底删除 / TTL 守护，双端同语义；彻底删除与清空
  支持延迟提交 + 5s 撤销窗口（ADR 0005）。
- **通用撤销**（Ctrl+Z 全局栈，完成切换 / 批量操作 / 删除全接入）；删除类操作统一确认与反馈。
- **活动轨迹三段可读**：任务活动日志（对标 Todoist Activity log）——update 轨迹追加前后值
  变更集 `changes`（日期→本地日串、项目 id→项目名、长文本 60 字截断；重复规则六字段合并
  为单条 `repeat_rule` 快照），子任务 / 评论 / 关联 / 提醒 / 附件从属对象新增独立轨迹
  （附件按 hash 幂等挂接、子任务提升双埋点），老行无 changes 自动回退字段名清单；双端历史
  区块固定取最近 30 条，满档显「仅显示最近 30 条」+「显示更多」一次展到 core clamp 上限
  100；移动端详情页新增「十、历史」区块（FRB 只读桥 `task_activity_list`，格式化纯函数
  镜像桌面 `activity-format.ts`）。
- **列表逾期置顶分组**（未完成逾期任务永远先被看见，双端）+ 行内子任务进度百分比 +
  行内提醒徽标四视图贯通。

### 视图与交互

- 五套桌面视图：**列表**（全量虚拟化 / 拖拽排序 / 固定 57px 行高 / NLP 快速输入）、
  **看板**（列内虚拟化 + 卡片多选批量 + 键盘可达）、**日历**（月 / 议程 / 年三档，农历
  副标签、节假日徽标、圆点拖拽改期、右键新增预填日期）、**表格**（第四态，六列概览 +
  多选 + 键盘导航）、**Logbook**（完成历史按完成日分组回看，默认隐藏已完成）。
- **「我的一天」**置顶快捷视图（数据层 `my_day_date` + 四入口 + 视图内新增自动带视图标记；
  今日 / 本周视图内创建的截止时刻统一归一 18:00）。
- **全局搜索**（Ctrl+K，跨任务 / 项目 / 评论；后升级 FTS5 短语级全文检索）+ 命令面板
  （新建任务 / 切主题 / 切视图）+ 全局快速捕捉热键 `Alt+Shift+O` + 快捷键帮助面板
  （`?` 呼出 + 设置页常驻入口）。
- **多选批量**：shift 区间选 + 底部工具条（批量改期 / 优先级 / 项目 / 删除，图标按钮
  紧凑形态即点即执行）+ 键盘批量（x 选中 / Esc 退选）。
- **日期选择器与日历视图统一（双端）**：日期弹层与日历视图共用同一套日格（农历 / 节日 /
  节气副标签、休班徽标、周末蓝字、今天实心强调块、选中描边）与同一份节假日缓存，失效后
  两处同步刷新；桌面新增 `PickerCalendar`（复用 `MonthCalendar` md 档，`DatePicker` /
  `DateTimePicker` / 详情抽屉三处内联日历与快捷新增条两处全部替换，删除 react-day-picker
  封装与依赖）；移动端 `WaitDatePicker` 日视图由 mini 圆格改 `AppMonthCalendar` medium
  档并整面板可滚。
- **日历滚轮步进**：日期弹层整体滚轮切月、日历视图月历滚轮翻月、工具栏年 / 月分段各滚各、
  年视图滚轮切年；阈值 24px + 前后沿节流（单击零延迟、连滑零丢步），下拉展开时滚轮只滚
  列表，Ctrl+滚轮仍是浏览器缩放；同批修掉月份下拉 10~12 月「月」字截断与日格数字垂直偏移。
- 交互口径统一：tooltip 主题色底白字、滚动条全项目标准、空状态垂直居中、弹层飞入与
  行高 / 溢出的全库排查。

### 提醒与通知

- 提醒到期处置**下沉引擎**（已完成实例不再提醒、僵尸行清理）+ 详情页 / 快加栏 / 表单 /
  移动端全入口接线；新增任务不再默认填「一小时后」提醒。
- 桌面：三平台系统通知（右下角弹窗）+ **推迟 10/30/60 分钟**按钮 + 点击通知直达任务
  详情 + **Windows 计划通知**（托盘退出后提醒仍可达）+ AUMID 身份注册（DisplayName=Orbit）。
- 移动：**后台闹钟托管**（精确闹钟授权引导、AOT 可达性修复）+ 通知**推迟 / 完成**双
  action + 灵动岛类别 + 双通道去重。
- **通知历史中心**：提醒呈现轨迹可回看。
- Android 存在感链条补全：**桌面小组件** + **快捷设置磁贴** + **图标角标**（今日 +
  逾期未完成数，双口刷新）。

### 加密与安全

- **SQLCipher 本地库** + 主密码体系（设置 / 解锁 / 修改 / 清除）；Android 明文降级
  平台边界记入 ADR 0001 与 `PRIVACY.md`；`PRAGMA` 逐连接注入 + 每连接 `cache_size` 封顶
  （修复 SQLCipher 多连接读出密文的数据损坏级隐患）。
- 移动端**生物识别解锁**：指纹代替主密码解锁加密库。
- **云同步端到端加密**：AES-256-GCM + zstd 压缩、PBKDF2 600k 单调不降级；客户端密文
  上行、密钥不出本机；`crypto/config`（明文 JSON，存储端可改写）、本地 meta、
  `.orfullsync` 文件头三入口统一走 `ensure_kdf_strength` 下限 guard（下限取历史最小值
  200k，避免挡存量），关闭「存储端把迭代降到 1 次」的降级路径。
- **同步密钥方案 v2**：Data Key 由密码确定性派生，结构性消灭 KeyMismatch 分叉态；
  配套双向 rekey / 迁移命令与恢复页（含「以本机为准重置云端」5s 冷静期确认）。
- **错误串脱敏** `brief()`：截 200 字符并丢弃含 `Authorization` / `Credential` /
  `<StringToSign>` 的行，S3 原始响应体回显与用户输入 endpoint 的 userinfo 不再落
  `sync_history.error_message`、`app_log.log` 与 UI tooltip。

### 云同步

- **三协议适配器**：WebDAV / S3（含阿里云 OSS 兼容）+ 传输层条件写（ETag `If-Match` /
  `If-None-Match` 与 HEAD 存在性探测，S3 / WebDAV 各自实现，不支持条件写的服务端由写后
  回读校验兜底）；不再为判断「远端有没有数据」而下载整个模块文件。
- **存储结构：表级分桶差量 + 单一清单 CAS**。云端布局为 `manifest.orsync`（唯一真相源：
  epoch + 表分桶索引 + 墓碑水位线）+ `tables/{表}/{桶}.orsync` + `tombstones/{表}/{YYYY-MM}.orsync`；
  数据按 uuid 稳定哈希分 64 桶，**单行编辑只重传 1 个分桶**；清单写入带前置条件 + 写后
  回读校验，多设备并发写从「静默覆盖」变为「可检测冲突并自动收敛」；Push 采用「远端清单
  拷贝 + 本地变化桶覆盖」，不再删除他端桶条目，消除「后写者抹掉前写者新增行」的窗口。
- **墓碑水位线回收**：墓碑按本地时区月份分桶，按所有设备同步检查点最小值安全回收（只删
  已确定被全部设备看到的墓碑，设备数 < 2 时不回收），清单不再无限膨胀。
- **增量同步 + 账本持久化**：模块指纹 + 单模块失败隔离，启动 / 定时 / 修改后立即 / 手动
  四路触发；重启不再每启必全量；**增量同步历史**（成败 / 耗时 / 冲突数）可回看。
- **大附件传输**：内容寻址 + S3 原生 multipart 分片 + WebDAV 自造分片协议（>8MiB 起分片、
  断点续传）；确定性 nonce 派生（同明文同密文，续传前提）；HTTP 超时语义由「总超时」改
  「读超时」——慢而在动的大传输不再被 30s 线掐断。
- **进入 / 退出应用强制同步**（桌面 + 移动）：只要「已配置云同步 + 已解锁」即执行，
  忽略自动同步开关 / 同步间隔 / 修改后立即同步设置；桌面进入延迟 1.5s 触发，托盘退出与
  系统真退出路径在退出前阻塞同步（上限 15s，超时放行并留日志），前端显示退出遮罩；
  移动端 `resumed` 进入同步、`paused` 尽力同步（6s 超时，被系统冻结则放弃）。
- **逻辑时钟（HLC）裁决**：业务写路径时间戳改为单调逻辑时钟（推进 `max(wall, last+1)`、
  合并时按远端时间戳推进、`cfg_kv` 持久化跨重启不回退），LWW 比较键由裸墙上时钟换成逻辑
  时钟——同毫秒写入不再平局、时钟回拨不倒退，设备间时钟漂移造成的**系统性**偏置在首次
  同步后即被消除；实现**折叠进既有 `updated_at` / `deleted_at` 列**，零 schema 变更、
  向后兼容旧行（决策见 `docs/03` §八）。
- **冲突败方副本 + 查看 / 恢复 UI**：LWW 裁决丢掉的败方整行快照不再静默消失，落本地表
  `sync_conflicts`（与合并同一事务、容量上限 500 条）；只留档**真并发**冲突（双方记录都晚于
  上次同步基线）；双端设置页新增「冲突记录」：字段级差异对照、一键恢复为败方版本（发起新的
  本地写入，下一轮同步胜出）、忽略与清空。该表为纯本地表，不随同步、不进备份。
- **左上角云同步状态图标**（桌面 TitleBar 左端 + 移动首页标题栏左端）：同步中主题色旋转环、
  成功后对勾回弹（约 1.8s 回落待命）、失败红点常驻并可查看原因；桌面悬浮提示显示「当前状态 /
  上次同步 / 下次自动同步（估算）」，点击立即同步；未配置云同步或密码未解锁时点击直达设置页
  引导。原右下角「后台同步中」悬浮指示条移除，同步状态与进度统一由云图标承载。
- **完成提示与失效链诚实化**：无任何推拉且无错误时显示「已是最新，无需同步」（此前显示
  「推送 0 模块」，易被误读为失败），并修复清单 CAS 并发重试耗尽时模块计数丢失；pull 回报
  `changed_tables`，双端按真正写入的表精确失效缓存（未知表回退全量），修掉「只拉附件」那轮
  `pulled_modules == 0` 导致界面不刷新。
- **失败可见性**：后台自动同步与「修改后立即同步」失败改走 `log::warn!`（此前 `eprintln!`
  在打包 GUI 丢失，`app_log.log` 无痕）；多表失败合并入同步历史单条；进度事件的模块名取
  真实模块定义。
- **推送性能（docs/09 A10）**：新增 push 专用水位线 `SyncState.last_pushed_clock_ms`（与
  pull 的冲突判据基线刻意分离——后者在 pull 结束推进到本轮结束时刻，复用会把「本轮开始前的
  本地编辑」判成非脏而漏传），配合「存活行数与远端清单条目比对」检出 merge 应用墓碑造成的
  软删这类时间戳早于水位线的集合变化；非脏桶零指纹重算、零序列化、零载荷构造——10k 行库
  「改一行后同步」的本地序列化从万级行降到 1 个桶（~156 行）；同一轮同步内 raw / 包装适配器
  共享同一底层实例（一 run 一 Client，phase 间复用热连接）。
- **五轮系统性探查收口**：① 前三轮（09-07 / 09-13 / 09-14）——附件首传空列表三分叉（解
  死锁）、pull 漏拉窗口封堵、附件 GC↔pull 打架循环终结、rekey 中断一致性、push 模块级错误
  隔离、WebDAV PUT 409 自愈、附件存在性探测错误分类（403/5xx 不再被当「不存在」）、冲突裁决
  计数全链透传；② 第四轮（09-18）——push 组装清单时整体替换远端索引致他端同轮桶条目被孤立
  （改桶级合并）、换密 rekey 后桶指纹密钥无关致增量全跳与云端停留旧 Key 密文（新增强制全量
  重传）、pull 存在失败表时不再推进清单 epoch、merge 表级失败回滚事务并向上抛错、push_only
  与 rekey 补业务级网络重试、S3 错误体中文截断 panic；③ 第五轮（09-19）——清单乐观锁
  （ETag CAS）**在生产链路从未发出过条件请求**（`BasePathAdapter` 漏转发
  `download_with_token` / `upload_conditional` / `exists` 三个 trait 方法，落到 mock 友好
  退化默认而单测 mock 恰实现了真方法，长期假绿；已补转发并以契约测试钉住「包装器与两适配器
  覆写同一组方法」）、WebDAV 大附件分片协议（>8MiB）自落地起从未执行（包装器先拼 `base_path`
  而分片判定要求 `path.starts_with("assets/")`；改按「上一段目录名 == assets」判定并把分片根
  随路径推导，分片落在 `{base_path}/assets_parts/`）、回收站物理清理守卫线被非干净轮次推进
  （记账收口到引擎唯一回写点 `advances_ledger()` = 非跳过且无错误，删除四处壳层回写）；
  ④ 减熵——删除死代码 `AdapterType`、`SyncAdapter::list_files` 及全部实现、
  `gc::collect_garbage` / `missing_tombstone_buckets`、恒 0 的 `RemoteFile.lamport_version`、
  空目录 `src/manifest/` 与 `src/sync_bundle/`。
- **协议合规小修**：S3 列举补 `Size` / `LastModified`（云端备份列表「最新在前」此前在 S3 上
  退化为最旧在前）、multipart 失败补 `AbortMultipartUpload`（孤儿分片不再长期占桶）、Complete
  请求体转义服务端 ETag；WebDAV href 百分号解码（中文 / 空格备份名不再乱码）、PROPFIND 207
  按 propstat 状态码取舍、补申请 `<getetag/>`（列举侧并发令牌与条件写同源）；适配器错误判定改
  typed variant（不再按错误串嗅探 409 / AncestorsNotFound）；跨设备整数外键改由父行 uuid
  承载、桶指纹排除本端 id。
- **ADR 0010 第一拍**（AAD 绑定两拍发布的前置拍）：布局版本门禁 `!=` → 大小判定（可区分
  「未来版本」与「上古版本」）；新错误码 `PayloadVersionMismatch`（tag `payload_version`，
  双端归类为「升级应用」提示，不跳密钥恢复页）；`DeviceCheckpoint.app_version` 能力协商位
  （清单为加密 JSON + serde default，零迁移）；AAD 绑定代码入库（`PAYLOAD_VERSION=0x02`，
  只绑表桶对象路径、附件永不做），写侧由「清单内全部已登记设备 ≥ 0.2.0」门控、本版默认关闭
  ——第二拍发布后自动打开，门禁代码无需再改。
- **两个上线阻塞修复**：首同步补传 `crypto/config`（第二台设备入环 KeyMismatch）与 Android
  release 构建补 `INTERNET` 权限（真机云同步 / 云端备份全线静默失败）。
- **合并事务原子化**：单表「数据合并 + 墓碑应用」收敛为同一事务，消除半合并窗口。
- **故障注入假服务 + 稳定性矩阵**：零依赖 `TcpListener` 假服务（7 种故障注入：5xx / 限流 /
  半截体 / 停滞 / 列举截断 / 412 冲突 / 忽略条件头）与 `tests/sync_fault_matrix.rs`（四类
  操作 × 故障矩阵，含 9MiB 分片双用例）替代本机真 WebDAV 依赖；`cargo test --workspace` 在
  干净机器全绿，原活体用例降级为 `#[ignore]` 的真服务端方言专用。

### 备份与恢复

- 本地全量备份（定时 / 手动）+ 云端全量备份（上传 / 列表 / 取回）**融合为单入口**（云端为
  默认，本地显式导出）；备份包 AES-256-GCM（`.orsync`，与同步载荷格式区分；历史 `.waitsync`
  全链路迁移）。
- **恢复安全确认**：五秒时停、恢复预览（自预览解密落定起算）、危险操作分级与两段式确认；
  备份列表云端 / 本地视觉区分与缺失元数据兜底。
- 备份文件名消毒（URL 危险字符）、失败不再「假成功」（本地写失败不推进账本并如实上报）、
  附件图片预览 blob 泄漏修复。
- **密钥派生强度对齐**：`.orfullsync` 的 PBKDF2 迭代由硬编码 200k 改为引用同步链路常量
  （600k，单一来源，旧包按容器头 iterations 解密仍兼容）；**同步前自动备份默认开启**（本地
  安全副本，可在设置关闭），push 前另存上一版清单作为回滚点辅助。

### 附件

- **内容寻址 + E2E 同步**：附件二进制走 `assets/{hash}.orsync` 加密通道；关联表入同步
  白名单，账本表保持本地（pull 侧按缓存标志差集重拉）。
- 守卫与治理：单任务 20 × 50MB 上限、本地 GC（无引用清理文件与账本）、**磁盘缓存 2GB
  上限 + LRU 逐出**（`is_uploaded=0` 的 pending 源绝不逐出）。
- 交互：桌面拖放文件直添、`Ctrl+V` 粘贴截图、行内 32px 缩略图、应用内 lightbox 预览；
  移动降采样解码预览与描述区 Markdown 渲染。

### 数据迁移与导出

- **CSV 导入**（orbit / Todoist / TickTick 三档预设）；**CSV/JSON 导出**（UTF-8 BOM，
  Excel 双击打开中文不乱码）。
- **ICS 日历导出**（VTODO，供日历软件导入 / 订阅）与 **ICS 文件导入**（VTODO 迁移入轨）。
- **明文数据导出**（JSON 结构化全量 + CSV 任务主视图，本地优先的「数据主权」路径）。

### 统计与分析

- 统计仪表盘：**完成热力图**（按年视图 + 年份切换 + 比例分档色阶，对齐 wait-home）、
  连续完成天数、分布条（项目自选色 / 优先级语义色，未完成段同色弱化）。
- **节假日数据层** `cfg_holidays` + 自动更新守护（60s tick）+ 日历徽标与手动更新。

### 桌面端（Tauri 2）

- 窗口：自绘标题栏 + 窗口控制三键（移植 Win11 规范，macOS 原生红绿灯 / Linux 材质回退）
  + **Mica 云母材质** + 启动白屏消除（`visible:false` → 前端就绪后 `show()`）+ 启动
  动画节奏调优。
- **托盘 + 关窗驻留**（守护不中断，托盘真退出放行；托盘图标独立按 shell 尺寸下采样并紧致
  裁剪撑满方格）+ **窄窗侧栏自适应折叠**（断点自动折叠 + 手动覆盖持久化）。
- **开机自启动（07 backlog #51）**：设置页「通用」分类读写系统启动项（Windows
  `HKCU\...\Run` / macOS LaunchAgent / Linux XDG `.desktop`，由 `tauri-plugin-autostart`
  承担），**不做本地状态副本**——开关状态以系统为准；自启进程带 `--hidden` 照常启动
  （托盘 + 四个后台守护齐全）但**不弹主窗**，壳层接上隐藏回收链（WebView2 降档 + 超时销毁），
  常驻内存回落宿主档（~330MB → ~40MB）。已知口径：安装路径含空格时 Windows 注册项会被系统
  解析坏（插件底层拼注册值不加引号），卸载前建议先关闭本开关。
- 设置面：安全 / 主题 / 待办 / 同步与备份 / 快捷键 / 任务模板 / 通知历史 / 冲突记录 /
  通用 / **关于与更新**（手动检查更新 → 下载 → 安装重启三步，不自动轮询）。
- 主题：六套 OKLCH 配色（含自定义强调色）+ 字号字重档位 + 双强调色 token 体系
  （`TODO_ACCENT` / `themeAccent`）。
- 关于页四分区：应用信息 / 更新日志 / 开源许可 / 开源组件。
- 壳层健壮性：双层错误边界保壳层监听与标题栏存活、虚拟列表焦点项无障碍播报、详情抽屉历史
  区块实时刷新（轨迹落库后自发 `todo_activity_log` Insert 事件并按表精确失效）。

### 移动端（Flutter）

- Flutter + flutter_rust_bridge 2.12（**显式 DTO 镜像**，core 类型不外泄）+ cargokit
  真机构建链路（NDK / SQLCipher 攻坚结论入 ADR）。
- 复刻 wait-home/mobile 观感：LiquidGlassTitleBar、玻璃 FAB、物理动画 Spinner、
  snap-spring 底部表单、toast/alert 皮肤、整页滚动布局。
- 功能对齐桌面：任务列表 / 子列表 / 详情 / 表单 / 日历 / 回收站 / 统计 / 全局搜索 /
  排序选项 / 长按拖拽重排 / 侧滑完成删除 / NLP 快速输入（实时解析 + 预览 chips）/
  描述 Markdown / Android 分享接收 / 云同步设置与密钥包导入恢复 / 冲突记录页 /
  详情页历史区块。

### 性能与内存

- 渲染：双端**全量虚拟化** + 路由级懒加载 + vite vendor 分包 + Material Symbols 子集化
  （首屏 chunk 985KB → 63KB；图标字体 5.1MB → 7KB）；**逾期置顶段并入任务列表同一条
  `useVirtualizer` 流**——万级驻留 76MB → **37MB**、DOM 节点 9980 → **863**（三档恒定）、
  切视图峰值 267MB → **61MB**、勾选峰值 327MB → **83MB**、进程树 RSS 433MB → **354MB**，
  置顶段外观不变但键盘 j/k 与 Enter 首次可达（旧实现既不能拖拽也不能键盘导航），顺带修掉
  按 `tasks` 取索引而行来自 `rest` 的焦点错位。
- 数据：谓词下推 SQL + 列表通道列裁剪（万级 IPC 体积 **-47%**）+ FTS5 全文索引 + 三条
  软删前缀组合索引 + db-change 表级失效（双端）+ **缓存驻留收敛**（主列表与两条全表投影
  `gcTime` 10min → 10s 并摘掉 `placeholderData`，换来「按谓词分叉的万行缓存不再长期挂着」，
  换视图 / 换项目首帧改短暂骨架）+ 纯字段写路径缓存 patch 提前 paint（真值仍由 db-change
  失效链收敛，且不从 TS 复刻引擎规则）。
- 投影与取数：列表标签 / 提醒改 **core 侧一次往返瘦投影**（`task_labels_projection` /
  `task_reminders_projection` / `task_dependency_flags`）；移动端任务列表收成**单份万行缓存
  + 派生过滤**，关键词单开服务端通道保住「按描述搜索」（`todo_tasks` 工具栏关键词下沉服务端，
  修复列裁剪后搜描述静默无结果）；万行列表命中单次加载上限时显式提示「列表不完整」。
- 资源：桌面**驻留内存优化**（隐藏降档 Low + 超时回收主窗，ADR 0006）+ release profile
  （LTO / strip / codegen-units，嵌套 workspace 补齐）+ devtools 摘除 + 连接池收紧。
- 治理：日志表 30 天 TTL + 附件缓存上限 + **数据库维护一键化**（WAL checkpoint /
  附件 GC / PRAGMA optimize / VACUUM，双端设置页可触发）。
- 度量口径入库并接 CI（`perf-metrics/`）：`growth-curve.mjs`（1k/5k/10k 三档 × 3 次中位、
  强制 GC 采真实驻留、切视图与勾选两类峰值、20 次写后泄漏、进程树 RSS 按 pid 子树收敛）、
  `audit-unbounded.mjs`（无界累加容器审计 `bounded*` 标记 + 棘轮登记）、冷启动改应用自报首屏
  marker；**更正历史基线**——旧报告 10k 档「169MB used / 257MB total」采自未强制 GC 的
  采样点（量到的是分配量），同档位强制 GC 后真实驻留为 76MB / 128MB。

### 发布工程与质量门禁

- **CI 四 job**：web（typecheck + vitest + build + Playwright 冒烟）/ rust-core
  （`cargo check --workspace --all-targets` + `cargo test --workspace --lib`）/
  flutter-mobile（FRB codegen 一致性门禁 + analyze + test，Flutter 锁 3.44.2）/
  perf-gate（无界容器审计 + 内存增长曲线）。
- **Release 流水线**（tag 触发）：桌面三平台（tauri-action）+ Android APK + `SHA256SUMS`；
  应用内更新清单 `latest.json` 单点合成（`includeUpdaterJson` 恒 false 避开矩阵并发竞态）；
  `workflow_dispatch` dry_run 预演；发版前置门禁（版本一致性 / tag 对齐 / updater 签名私钥 /
  依赖审计）。
- **签名与分发决策** ADR 0004：未签名平台明示 + 用户侧校验指引；updater 产物签名
  （minisign）+ 应用内更新（07 backlog #20）。
- **版本单一来源** + `pnpm bump` / `pnpm bump:check` + 发版一致性护栏（vitest 断言五处
  清单 / 两个 lock / 应用内日志，e2e 断言关于页版本徽标）。
- 测试规模（2026-09-24）：Rust 617 / vitest 377 / Flutter 590（`flutter analyze`
  零告警）/ Playwright 19（基线数，以 CI 为准）。

### 文档与规范

- `AGENTS.md` 全项目规则单一真相源（含版本发布与更新流程、内存口径与有界容器、FRB 生成物
  判据、迁移增量策略等规范节）；`docs/01-09` 编号文档（产品需求 / 技术架构 / 数据模型与同步 /
  UI 复刻规格桌面 + 移动 / 里程碑 / 竞品 backlog / 发布与更新流程 / 内存与性能治理专项）。
- ADR 0001-0007、0010（SQLCipher 策略 / 移动通知 / 双端拆分 / 发布工程 / 回收站边界 /
  桌面驻留内存 / 内存度量门禁 / 同步载荷 AAD 绑定）。
- 7 份专项审查与优化报告入库（同步域五轮 + 性能与 UX + 桌面开机自启动探索）；`docs/07`
  竞品 backlog：50 项基线收口后新增的 #51–#63（开机自启动、移动端对标 P0/P1、
  修改后立即同步、日历更新时刻、桌面补齐批次等）亦全部落地，见上文 dated 条目。

### 破坏性口径与明确不做

- 移除 `todo_tasks.end_date`（迁移 / 模型 / 仓储 / CSV / FRB / 双端 UI 全链路收窄）。
- 迁移文件合并为单文件 `0001_init.sql`（多轮并回；**存量库升级口径 = 删库重初始化**）。
- 仓库重组：`orbit_core` → `orbit-core`、`flutter-plugin-orbit` → `orbit-flutter`、
  pnpm lockfile 上收仓库根、React 移动端移除（移动端改由 Flutter 承载）；云同步去 V2 化
  （存储结构重构即初始版本）。
- 明确不做：协作 / 指派、番茄钟 / 习惯追踪、i18n / Web 版、自动更新轮询（更新时机归用户）。
