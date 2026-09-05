# ADR 0002 — 移动本地通知策略（风险 R2 技术验证）

- **状态**：已采纳（Accepted；2026-09-05 α→β 演进落地，见 §七）
- **日期**：2026-08-24
- **关联**：M4 Task 16 / 06 文档 §三 风险 R2、§二 任务 4.7；实施依据 docs/superpowers/plans/2026-08-24-m4-mobile.md「Task 16」

## 一、背景

### 1.1 风险原文（06 文档 §三 风险表 R2）

> **Tauri 2 移动通知调度能力不成熟**（桌面 show() 不支持定时已是既成事实）。影响：中：提醒功能移动端不可靠。缓解：4.7 双方案预研：scheduled API 若可用则调度化；否则前台服务轮询 + 权限拒绝降级应用内 toast。

### 1.2 现状事实：提醒轮询守护已全平台生效（α 基线）

Rust 侧无任何平台门控，桌面与移动共用同一条提醒链路：

- `src-tauri/src/lib.rs:48` 无条件注册 `tauri_plugin_notification::init()`；`lib.rs:70` setup 阶段无条件调用 `notification_scheduler::todo_reminder_start_poller(...)`；
- `src-tauri/src/commands/notification_scheduler.rs`：立即扫一次 + 每 **20s** 一轮前台轮询；专用 SQL `WHERE is_deleted=0 AND remind_at <= now AND now - remind_at <= 24h`（BATCH_LIMIT=100 防堆积）；进程内 HashSet 去重；触发双通道 = ① 系统通知（`NotificationExt` builder show()，尽力而为）+ ② emit `"todo_reminder:due"` → 前端 sonner warning toast 兜底（duration 10s，`src/hooks/use-todo-reminder-listener.ts`）；
- 该守护对平台无感知：移动端 WebView 前台/可见期间与桌面行为完全一致。

α 基线的已知边界：Android 应用退后台后进程可能被冻结/杀死 → 轮询停摆，到期提醒静默（重启后仅补扫 24h 内项）；Doze 模式下即使存活也不保证 20s tick 准时。此为 MVP 接受度评估对象（见 §四）。

## 二、API 能力核查记录（静态）

### 2.1 前端 npm 包

实际解析版本：`@tauri-apps/plugin-notification@2.3.3`（node_modules/.pnpm 路径确认）。

`dist-js/index.d.ts` 全部导出：

| 类别 | 导出 |
|---|---|
| 权限 | `isPermissionGranted(): Promise<boolean>`、`requestPermission(): Promise<NotificationPermission>` |
| 即时发送 | `sendNotification(options: Options \| string): void` |
| **调度/待定** | **`Options.schedule?: Schedule`**；`Schedule.at(date, repeating?, allowWhileIdle?)` / `Schedule.interval(interval, allowWhileIdle?)` / `Schedule.every(kind, count, allowWhileIdle?)`；**`pending(): Promise<PendingNotification[]>`**、`cancel(ids: number[])`、`cancelAll()` |
| 活动通知管理 | `active()`、`removeActive([{id, tag?}])`、`removeAllActive()` |
| Android 渠道 | `createChannel(channel)`、`removeChannel(id)`、`channels()`；枚举 `Importance`、`Visibility` |
| 交互/事件 | `registerActionTypes(types)`、`onNotificationReceived(cb)`、`onAction(cb)` |
| 类型 | `Attachment / Options / Action / ActionType / PendingNotification / ActiveNotification / Channel / ScheduleInterval` |

### 2.2 Rust 侧

`Cargo.lock:5029` `tauri-plugin-notification version = "2.3.3"`——与前端包同版本线。

### 2.3 β 可用性结论

**API 面（d.ts 层）：β 存在且形态完整**——`Schedule.at` + `pending/cancel/cancelAll` 足以支撑"创建提醒时调度系统通知 + 取消重排"，并带 `allowWhileIdle` 参数应对 Doze。

**但当前工程接入面有两处缺口，β 并非零成本可用：**

1. **ACL 权限未放行**：`src-tauri/capabilities/default.json` 仅含 `notification:default / allow-notify / allow-is-permission-granted / allow-request-permission` 四项，未包含 scheduled 系列所需的 `allow-schedule`（及 `allow-pending / allow-cancel / allow-cancel-all` 等）。前端直接调用会被 capability 层拒绝，接入须改 capabilities（计划 Task 16 Files 已预留该项为"视结论"改动）；
2. **调度生命周期联动缺失**：需在提醒创建/删除/任务编辑（remind_at 变更）/任务完成等全部变更点做 cancel + 重排，id 映射到 32-bit 正数域（现 Rust 侧已有 `reminder_id % 2_147_483_647` 先例），并与轮询去重集合协调避免双通道重复弹。

另注：现状系统通知由 Rust 侧 `show()` 发出（走 Rust API 不受前端 ACL 约束），若切 β 可评估改在 Rust 侧用 builder 的 schedule 能力，但同样绕不开第 2 点的联动成本。

## 三、决策矩阵

| 方案 | 内容 | 成本 | 收益 / 风险 | 结论 |
|---|---|---|---|---|
| **α 维持前台轮询（现状）** | 20s 前台轮询 + 系统通知尽力 + emit toast 兜底，双端同链路 | **0**（已上线运行） | 前台场景到达率等同桌面；退后台/被杀静默（MVP 接受）；无新增维护面 | **采纳（MVP）** |
| **β scheduled API 调度化** | 创建提醒时 `Schedule.at` 调度系统通知，变更点取消重排 | capabilities 放行 + 全变更点 cancel/reschedule 联动 + id 映射 + 与轮询去重协调（约 M 级改造）+ 真机回归 | 杀进程后仍可达（AlarmManager）；引入双通道去重复杂度与调度漂移新故障面 | 备选（回滚条件触发后启用） |
| **权限拒绝降级** | 探测被拒 → `waitToast.destructive("通知权限未授予","提醒将在应用内展示")` 提示一次，事件 toast 兜底照常 | 极小（listener 一处分支） | 用户预期管理；不崩溃、不阻塞兜底通道 | **随 α 一并落地** |

## 四、决策与影响面

### 决策

**MVP 采用 α（维持前台轮询基线）+ 移动端权限拒绝 toast 降级**；β 记录为备选目标态，本次不改 capabilities、不接 Schedule 调度。

理由：轮询守护已全平台生效且零边际成本；β 的 d.ts API 虽完整存在，但 ACL 未放行且需在全量提醒变更点补取消/重排联动——接入成本非"极低"（计划预设的 β 启用条件不成立）。移动端 MVP 场景以前台使用为主，20s 轮询窗口内触发率与桌面一致（01 文档 DoD 同源承诺）。

### 本次最小改动（已完成）

- `src/hooks/use-todo-reminder-listener.ts`：监听器初始化处新增移动端专属探测——`isMobilePlatform()` 分支内 `isPermissionGranted()` → 必要时 `requestPermission()`；被拒则每会话提示一次 `waitToast.destructive("通知权限未授予", "提醒将在应用内展示")`。所需 IPC 权限（is-permission-granted / request-permission）已在现有 capabilities 内，无需改动。
- **桌面无害性**：探测整体被 `isMobilePlatform()` 短路，桌面不发起任何新增调用，事件监听与 toast 行为一字未动。

### 影响面

- 双端 Rust 代码零改动；`capabilities/default.json` 零改动；
- 移动端首启会触发一次 Android 通知权限系统弹窗（requestPermission），拒绝路径有明确降级文案，满足 01 文档 DoD「通知权限拒绝 → 应用内 toast 降级不崩溃」；
- 已知让步：应用退后台/被杀期间到期提醒静默（重启后补扫最近 24h），写入 T18 验收预期而非缺陷。

## 五、真机验证清单（T18 验收项；本次 spike 无在线设备，降级记录如下）

`adb devices` 于 2026-08-24 执行返回空列表（无在线设备），以下各项**待真机验收（Task 18 执行）**：

| # | 场景 | 操作 | 预期 |
|---|---|---|---|
| 1 | 权限首次请求 | 全新安装启动应用 | 弹出通知权限系统对话框；授权后前台设 1 分钟提醒 → 20s 内收到系统通知 + 应用内 toast |
| 2 | 权限拒绝降级 | 系统设置中拒绝通知权限后重启应用再触发提醒 | 首次进入出现一次 destructive toast「通知权限未授予 · 提醒将在应用内展示」；到期仅应用内 toast，**不崩溃** |
| 3 | 杀进程行为 | 设提醒后从最近任务划掉/`adb shell am force-stop cn.wait.orbit` | 到期静默；重新启动应用 ≤20s 内补弹（24h 内项）——记录实际表现 |
| 4 | Doze 模式 | 应用后台 + 设备息屏静置至提醒时刻 | 预期不保证触发（α 已知边界），实测记录偏差供后续 β 重估引用 |

抽样观察命令参考：

```powershell
adb logcat -d | Select-String -Pattern "notify|notification"
```

## 六、回滚条件（切换 β 的触发点）

满足任一条即重开本决策，按 §二结论先放行 capabilities 再实施调度化：

1. **产品要求升级**：移动端提醒必须在杀进程/退后台后可靠到达（如面向外部用户发布），届时按「创建/删除/更新/完成四类变更点 cancel+reschedule」清单接入 β；
2. **α 实测不可接受**：T18 清单 #3/#4 实测显示前台轮询在前台场景也频繁漏触发（WebView 冻结策略收紧等系统行为变化）；
3. **上游能力演进**：tauri-plugin-notification 后续版本提供 Rust 侧一等 schedule 调度或官方后台提醒模板，使 β 联动成本降至 L 以下；
4. **顺带改造窗口**：其他任务已必须触碰 reminders 写路径时，可搭车评估 β（避免单独为通知调度开辟回归周期）。

## 七、α→β 演进落地（2026-09-05）

**触发条件：§六-1 兑现**——产品要求移动端提醒在杀进程/退后台后可靠到达（P2 用户需求「移动端在后台不会提示，需要优化」）。实施范围与 §六预设的「四类变更点 cancel+reschedule」略有偏差，记录如下：

### 实施形态（commit fb46661 / 8bd700f / ff26afb）

移动端自 Flutter 拆分（ADR 0003）后已脱离 Tauri 通知栈，β 的载体是
**flutter_local_notifications 22.3 系统闹钟**而非 §二核查的
tauri-plugin-notification schedule API（该核查随移动端拆分归档失效）：

1. **调度面**：`ReminderScheduler`（apps/mobile/lib/services/reminder_scheduler.dart）
   启动 + dbChanges 防抖 2s → DB 全部未来提醒（join 任务标题）全量
   重排 `zonedSchedule(AndroidScheduleMode.alarmClock)`；无精确闹钟
   权限逐级回落 exactAllowWhileIdle → inexactAllowWhileIdle。
   全量重排天然覆盖「四类变更点」——不需要逐点 cancel/reschedule。
2. **后台可靠性的机制转移**：闹钟由系统 AlarmManager 持有，到点由
   插件原生 `ScheduledNotificationReceiver` 构建通知展示——Dart
   进程不存活即弹；重启由 `ScheduledNotificationBootReceiver`
   （manifest 已声明 BOOT_COMPLETED）自动恢复全部 pending 闹钟。
3. **推迟操作**：通知带三档推迟 action，点击走插件
   `onDidReceiveBackgroundNotificationResponse` 后台 isolate 回调
   （应用被杀可达）。后台不写 Rust DB（FRB 库不可在后台 isolate 重入）：
   重排系统闹钟 + 静默确认通知；DB 收敛靠前台——旧行到期时
   `handleReminderDue` 检测系统闹钟面存在更晚排程（推迟产物）即
   静默删行不弹。
4. **双通道去重**：α 前台轮询通道保留（双保险），与闹钟通道同 id
   （taskId 派生）show() 覆盖合并；僵尸识别不可用时保守放行。
5. **小米灵动岛**：category=alarm + Importance.high 渠道——
   焦点通知对闹钟类高优通知以灵动岛胶囊呈现（真机表现待 §五清单验收）。

### 决策语义变化

- §四「β 记录为备选」→ **β 已实施**（移动端）；α 前台轮询保留为
  双保险通道，两者同 id 去重共存。
- §五真机验收清单**仍然有效**：#3/#4 的预期从「到期静默」改为
  「闹钟准点弹出（Doze 免疫）」，#1/#2 权限语义不变（新增
  SCHEDULE_EXACT_ALARM 权限引导为可选路径，未授予回落非精确）。
- 桌面端不在本 ADR 范围：桌面推迟走 sonner toast 自定义卡片
  （reminder-snooze.ts 删旧建新），关窗驻留托盘轮询语义不变。

### 模拟器实测记录（2026-09-05/06，Pixel 9 Pro XL AVD / API 36）

**第一轮（2026-09-05 深夜）**：APK 构建（aapt2 dump：6 权限 + 3 receiver）✓、
启动链路（`[ReminderScheduler] 闹钟重排 N 条`）✓、精确闹钟授权弹窗✓、
alarmClock 排程 pending✓、dbChanges 单播流二次订阅丢事件（复现→已修）。

**第二轮（2026-09-06，全新干净模拟器 + 纯 App APK 全链路）**：

| # | 命题 | 结果 |
|---|---|---|
| 1 | App 表单创建任务+未来提醒 → dbChanges 转发 → 防抖重排 | ✅ 保存 2s 后 `[ReminderScheduler] 闹钟重排 1 条` |
| 2 | 系统闹钟注册（dumpsys alarm） | ✅ `RTC_WAKEUP ... ScheduledNotificationReceiver, Alarm clock: triggerTime=20:24:00, exactAllowReason=permission` |
| 3 | **后台核心**：HOME + `am kill`（系统级杀，等价划掉后台）→ 闹钟到点 | ✅ logcat `20:24:00.020 Start proc for broadcast ScheduledNotificationReceiver`——**Dart 进程死亡状态下原生 Receiver 准点（偏差 20ms）弹通知** |
| 4 | 到期通知形态 | ✅ `channel=todo_reminder_due, category=alarm, importance=4, actions=3`；actions 明细 `[0]推迟10分钟 [1]推迟30分钟 [2]推迟1小时`（PendingIntent 各自独立） |
| 5 | 前台通道到期通知（同刻轮询） | ✅ id=2 通知（20:13 场景） |
| 6 | 通知 action 点击（App 存活前台） | ✅ 确认通知「已推迟 10 分钟 / REM_BG_TEST · 20:34 再提醒你」弹出——payload 解析+原点+10min 计算+时钟格式化全链路正确 |
| 7 | 通知 action 点击（App 进程被杀后） | ✅ 后台 isolate 拉起（FlutterEngine 新建 + libflutter 加载）**无 AOT 错误**（类级 @pragma 修复，commit 282a708）；确认通知弹出 |
| 8 | 后台推迟后的新闹钟注册 | ⚠️ 确认通知弹出但 pending 未观察到 20:34 条目——三级回退（alarmClock→exact→inexact）在后台 isolate 的失败点待复现定位（已加 debugPrint 留痕）；进程内等价 API 实测排程成功（snooze_reschedule_test） |
| 9 | flutter test 产物陷阱 | ⚠️ `flutter test integration_test` 会把 build/app/outputs/flutter-apk/app-debug.apk **覆盖为 test-harness 变体**（ext.flutter.integrationTest）——此后用该 APK 走 `am start` 永远停在等测试指令，表现酷似「启动卡死」。排查手段：VM service getIsolate 的 extensionRPCs 含 `ext.flutter.integrationTest` 即中招；重跑 `flutter build apk --debug` 覆盖回来即可 |
| 10 | force-stop 清闹钟 | ⚠️ Android 系统语义（清除应用全部 PendingIntent），非缺陷；用户下次打开 App 全量重排自愈 |

遗留：~~#8 后台 isolate 排程失败点~~ **已闭环（2026-09-06 终验）**：
sqlite3 预置 DB（任务+22:46 提醒）push 进 App → 启动即 `[ReminderScheduler]
闹钟重排 1 条` + `Alarm clock: triggerTime=22:46:00`（dumpsys）→ HOME +
`am kill`（进程死、闹钟活）→ **22:46:00.022 原生 Receiver 弹通知**（logcat）
→ 点「推迟10分钟」（进程死状态下）→ 后台 isolate 拉起 + 确认通知
「已推迟 10 分钟」+ **新闹钟 `RTC_WAKEUP triggerTime=22:56:00` 注册**
（exactAllowReason=permission，Next wake from idle）——后台推迟→
新闹钟重排的完整闭环实测成立，UTC 构造修复（9e13f4d）生效。
（此路径同时覆盖：seed 预置 DB 方案可复用为无 IME 环境的测试基建。）

仍需用户侧硬件：灵动岛形态（小米 HyperOS 真机）、Doze 息屏精度。
模拟器长跑后 IME/logd 间歇失活，UI 驱动测试建议短会话+干净快照。
