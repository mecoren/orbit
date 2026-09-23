# Changelog

本文件记录 Orbit 的所有显著变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> **0.1.0 条目口径**：0.1.0 是项目整体首个版本，本条目由 2026-08-23 初始提交至
> 2026-09-19 的**全部 git 记录**（453 次提交：166 feat / 121 fix / 31 perf / 71 docs，
> 余为 chore / refactor / style / test）按模块归并总结——合并同源提交、剔除过程性改动，
> 不逐条罗列中间过程；逐条明细以 git 历史与 `docs/07` backlog 为准。历史 `v0.1.0`
> （2026-09-15）tag 及其后的全部未发布工作（云同步存储结构重构、第五轮探查收口、
> 内存门禁入库等）已一并并入本条目。

## [Unreleased]

### 移动端日历节假日更新时刻可配（2026-09-23，docs/07 #59）

- 桥位 `holiday_set_fixed_hour` **双端早就绪**（移动 FRB 生成物 `holidaySetFixedHour` + Rust
  `api/holiday.rs`；桌面 `holiday_cmd.rs` 已注册命令），但两端 UI 均零消费、`HolidayMeta.fixedHour`
  也无处展示——每日自动更新时刻只能吃 core 缺省 08:00。本轮移动端接线：抽象桥暴露该方法（Rust 侧
  转发 FRB 既有函数，**零 codegen**）+ Rust/Mock 两实现（mock 落 `MockStore.holidayFixedHour`，
  clamp 0-23）；设置页新增「日历与节假日」卡（值行读记账 → 0-23 整点单选抽屉 → 落库 + toast），
  日历页更新按钮 tooltip 带上当前固定时刻（与设置页同一份 `holidayMetaProvider` 记账）；新增
  `_valueRow` 值行原语（形制同回收站「保留时间」行）。测试 2 例。桌面侧接线留后续。

### 移动端对标 TickTick 批次 P1（2026-09-23，docs/07 #55–#57）

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

### 移动端对标 TickTick 批次 P0（2026-09-23，docs/07 #52–#54）

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

## [0.1.0] - 2026-09-19

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
- 测试规模：Rust 535 / vitest 269 / Flutter 274 / Playwright 19。

### 文档与规范

- `AGENTS.md` 全项目规则单一真相源（含版本发布与更新流程、内存口径与有界容器、FRB 生成物
  判据、迁移增量策略等规范节）；`docs/01-09` 编号文档（产品需求 / 技术架构 / 数据模型与同步 /
  UI 复刻规格桌面 + 移动 / 里程碑 / 竞品 backlog / 发布与更新流程 / 内存与性能治理专项）。
- ADR 0001-0007、0010（SQLCipher 策略 / 移动通知 / 双端拆分 / 发布工程 / 回收站边界 /
  桌面驻留内存 / 内存度量门禁 / 同步载荷 AAD 绑定）。
- 7 份专项审查与优化报告入库（同步域五轮 + 性能与 UX + 桌面开机自启动探索）；`docs/07`
  50 项 backlog 全部收口。

### 破坏性口径与明确不做

- 移除 `todo_tasks.end_date`（迁移 / 模型 / 仓储 / CSV / FRB / 双端 UI 全链路收窄）。
- 迁移文件合并为单文件 `0001_init.sql`（多轮并回；**存量库升级口径 = 删库重初始化**）。
- 仓库重组：`orbit_core` → `orbit-core`、`flutter-plugin-orbit` → `orbit-flutter`、
  pnpm lockfile 上收仓库根、React 移动端移除（移动端改由 Flutter 承载）；云同步去 V2 化
  （存储结构重构即初始版本）。
- 明确不做：协作 / 指派、番茄钟 / 习惯追踪、i18n / Web 版、自动更新轮询（更新时机归用户）。
