# ADR 0006 — 桌面驻留内存优化：WebView 超时回收与唤起重建

- **状态**：已采纳（Accepted）
- **日期**：2026-09-11
- **关联**：07 报告 #16（托盘驻留）；实施为桌面 `commands/webview_low_power.rs` + `commands/window_recycler.rs`

## 一、背景

2026-09-10 实测（debug 构建 + dev 前端）：关窗驻留托盘后 WebView2 整树
约 330MB 提交内存**纯闲置**（渲染器 121MB + GPU 117MB + browser 48MB），
且隐藏 75 秒后不降反微升（479→541MB 工作集）——Chromium 在 Windows 上
对隐藏窗口不做后台内存裁剪。而四个后台守护（同步 60s tick / 提醒 20s
轮询 / 回收站 TTL / 节假日）全在 Rust 宿主（约 40MB）里跑，WebView 在
驻留期的作用只剩「点托盘秒开」。

## 二、决策：两层回收

1. **即时降档（隐藏即生效）**：关窗隐藏时调
   `ICoreWebView2_19::SetMemoryUsageTargetLevel(Low)`（WebView2 ≥114；
   更老运行时 no-op），唤起恢复 Normal。档位只影响内存策略不暂停 JS，
   sync-progress / db-change 事件仍实时可达——适用于几分钟内的驻留。
2. **超时回收（长期驻留）**：隐藏 5 分钟仍未唤起即物理销毁主窗
   （进程与四守护不动），常驻内存回落到宿主 ~40MB；托盘/热键唤起时
   按 tauri.conf 窗口配置 `WebviewWindowBuilder::from_config` 重建
   （window-state 恢复位置/尺寸/最大化态，Mica 重应用，前端冷启动）。

## 三、隐性成本与闭环（事件不排队的兜底）

Tauri emit 是「喊话」不是「留言」：窗口销毁期间守护 emit 的事件无人
接收属预期，逐通道兜底：

| 通道 | 销毁期行为 | 自愈路径 |
| --- | --- | --- |
| sync-progress / db-change | 丢失 | 重建=冷启动：React Query 空缓存全量重拉，useStartupSync 重跑 pull_then_push 补一轮同步 |
| sync-key-mismatch | 丢失 | useStartupSync 冷启动重新捕获 key_mismatch 并导航恢复页（**延迟从实时变为唤起时**，可接受：同步本身持续静默跳过，不产生数据损坏） |
| tray-quick-add（托盘菜单） | 无人监听 | 销毁态分支走 `mark_pending_quick_add()` 标志 → 重建后 2s 补发事件（消费方与实时路径同源） |
| 热键 Alt+Shift+O（前端注册） | hook 随窗消亡 | 销毁时壳层 Rust 侧注册兜底 handler（唤起+意图标志）；重建后前端 hook 重新注册接管 |
| 提醒通知 / 同步 / 备份本身 | **不受影响** | 全在 Rust 宿主，不经 WebView |

## 四、唤起路径统一

此前「显示主窗」散落三处实现（托盘菜单/托盘单击直调 window API、热键
走前端 getCurrentWindow().show()），销毁态无一能处理。现统一收口
`show_or_create_main_window`：窗口在→显示+档位恢复+取消回收排程；
不在→重建。全局热键改走 `show_main_window_cmd` 命令（窗口销毁后前端
窗口 API 无兜底）。

## 五、权衡与备选

- **5 分钟阈值**：短于此打断「午休回来看一眼」的常见驻留节奏，长于此
  回收收益名存实亡（单测锁 300s）。
- **唤起代价**：重建 = 冷启动（1-2s vs 秒开）。任务管理器属低频唤起
  工具，换来长期驻留 330MB→40MB，性价比成立。
- **备选否决**：`--max-old-space-size` 类 V8 限额治标且可能 OOM；前端
  路由 lazy 化仅省 JS 堆零头；换栈（Flutter 130MB / Dioxus）重写 25k
  行不值（既有探查结论）。

## 六、实施勘误与实测结论（2026-09-11 落地轮）

- **tauri 默认退出行为的坑**：窗口回收销毁最后一窗时，tauri 事件循环
  会发出 `ExitRequested`（默认接受）——首个实现实测中 destroy 成功但
  **进程随之退出**，四个后台守护全灭，与托盘驻留的产品语义直接冲突。
  修复：`App::run` 回调里拦截 `ExitRequested`，非真退出态一律
  `prevent_exit()`；托盘菜单「退出」经 `quit_app` 先置 `mark_quitting`
  原子标志放行。此为托盘驻留应用的标准模式，但也说明「销毁主窗」比
  听起来更接近一次应用退出的边界。
- **实测数据**（debug 构建 + dev 前端，隔离数据目录，探针日志逐环断言）：
  关窗 WM_CLOSE → `CloseRequested` 拦截 → hide + 档位 Low + 排程 →
  300s tick → destroy Ok → 进程存活（prevent_exit 生效）→
  orbit 专属 WebView2 子进程 **5→0** → 宿主单进程 53MB 工作集 /
  10MB 提交（优化前整树 300+MB，达成本档预期）。
- **构建口径坑**：裸 `cargo build --release` 编出的二进制走
  `devUrl`（tauri 的 dev/prod 判定由 tauri CLI 注入，非 cargo profile
  决定），内嵌前端不可用、窗口不显示——release 端到端验证必须走
  `tauri build`。
- **遗留人工验收项**：托盘单击/托盘菜单/全局热键「触发重建」的最后一
  跳无法自动化验证（SendInput/mouse_event 注入对 Win11 Shell 托盘的
  命中不可达；真实键盘流可注册但 handler 触发链未观察到）。Rust 侧
  逻辑已逐环探针断言（hotkey fallback register Ok、show_or_create
  分支就绪），待人工点一次托盘收口。

## 七、唤起置前勘误（2026-11-25，用户反馈「点托盘/任务栏再也打不开界面」）

- **现象**：关窗驻留超过 5 分钟（主窗被回收销毁）后点托盘图标，窗口确实被重建，
  但停在 IDE / 微信等窗口**后面且不聚焦**——观感「点了完全没反应、界面打不开」，
  反复点也一样；右下角提醒横幅弹出时最容易撞上（提醒在后台照常弹，用户顺手点托盘，
  此时窗口往往已被回收）。
- **实测证据**（release 0.1.2，脚本注入托盘单击消息 + 进程/窗口读数）：
  回收销毁后托盘唤起 → 新 `Tauri Window` 出现且 `visible=true`（webview 子窗口齐全、
  后台同步正常），但 `GetForegroundWindow()` 始终是别的应用；`SetWindowPos` 之外的
  `show()` 只是把窗口显示在 z 序原位。
- **根因**：重建窗口沿用冷启动的「前端首帧后 `show()`」显隐口径（`visible:false`
  防空窗闪白），而 Windows 前台锁只放行「持有前台权」的进程调 `SetForegroundWindow`；
  托盘单击与通知正文点击的输入事件都发生在 shell / 通知宿主进程里，本进程不是前台
  进程 → `show()` 显示后拒绝激活，Tauri 的 `set_focus()` 同样被静默拒绝。
  §六 的「遗留人工验收项」正是这一跳，从未被真实点托盘覆盖。
- **修复**（`window_recycler::activate_window` / `watch_rebuilt_window`）：
  ① 唤起统一入口先 `show + unminimize`，Windows 上再 `SetWindowPos(HWND_TOP)` 置前
  （即使前台锁拒绝激活也保证「看得见」）+ AttachThreadInput 临时附加前台线程后
  `SetForegroundWindow`（经典前台锁绕行，随后立即解除附加）+ `set_focus`；
  ② 重建分支不提前 show（保留防闪白口径），改由守候泵在窗口可见后补置前/聚焦，
  180ms 后复核未聚焦再补一次；5s 仍不可见则壳层兜底 show（对齐冷启动 8s 兜底），
  10s 超时留痕；③ 顺带修掉两处实测缺口——window-state 插件在重建窗口上**不恢复
  最大化态**（销毁前记 `is_maximized`，可见后补回，一次性消费）与重建并发防护
  （托盘连点 / 通知同时唤起只允许一个重建者，失败按「窗口是否真的不在」重试一次）；
  ④ 唤起链路改 `log::info!/warn!/error!` 落 `app_log.log`（此前 `eprintln` 在
  release 下不可见，重建失败等于无声悬案）。
- **回归**：`cargo test --lib window_recycler`（守候泵单拍决策/时长关系/最大化态
  一次性消费/回收阈值）；实机链路按「隐藏 → 超时回收 → 托盘唤起」复核窗口可见、
  最大化恢复与前台归属。

## 八、重建窗口挂死勘误（2026-11-28，用户反馈「有时候点不开软件，托盘也点不开」）

- **现象**：关窗驻留超过 5 分钟（主窗被回收销毁）后，再点托盘图标或再双击 exe，
  界面**永不出现**；托盘单击/菜单此后完全无响应；之后每双击一次 exe 就多一个
  应用进程，任务管理器里越积越多（现场 11 个，父进程都是 explorer，每个 ~18MB
  工作集 / 2 线程、0 CPU）。
- **实测证据**（安装版 0.1.3 + 现场进程/堆栈取证 + 脚本复现）：
  - 现场：`Tauri Window` 已重建且存在，但 `visible=false`；`tray_icon_app` /
    `global_hotkey_app` / 单实例窗口 `cn.wait.orbit-siw` 与主窗同属主线程，
    `IsHungAppWindow` 全体为 true；主线程 RIP 落在
    `ntdll!ZwWaitForAlertByThreadId`（Rust std futex 等待），即**主线程自锁**，
    不是慢 IO。二次实例全部卡在向该窗口的同步 `SendMessageW` 上。
  - 复现（0.1.3 安装版，脚本：启动 → WM_CLOSE 关窗 → 等 335s → 起第二个实例
    等同双击图标）：回收销毁已生效（主窗 hwnd 消失），唤醒 15s 后主窗重建出来
    但 `visible=false`、`hung=true`、`WM_NULL` 探测超时，第二个实例进程不退出。
  - 历史日志：两次「隐藏 300s 未唤起，回收销毁主窗」都成功，但 `app_log.log`
    里**从未出现过**「主窗重建成功」——重建路径在本机一次都没走通过。
- **根因**：唤起入口被**窗口过程**同步调用——托盘图标的 WndProc、单实例插件的
  `WM_COPYDATA` WndProc、全局热键的 WndProc 都跑在主线程消息派发里，而不是 tao
  的事件回调里。此时 tao 的 `send_event` 判定「不在回调内」，会把窗口几何变化
  （Moved/Resized 等）**内联**派发进 tauri 的事件链；而 `create_main_window` 在
  `build()` 之后立刻调 `restore_state()`，该函数持有 window-state 插件的
  `WindowStateCache` 互斥量并连续 `set_position` / `set_size` / `maximize`，
  内联回来的窗口事件再进插件 `on_window_event` 的 `cache.lock()`——std Mutex
  不可重入 → 主线程卡在 futex 上永不返回。是否触发取决于旧状态是否真的改变了
  窗口几何（状态与默认一致时不产生事件）——这就是「有时候」；而 §七 的置前修复
  把唤起路径做得更重，掩盖了这条真正的死锁。
- **修复**（`window_recycler` + 新增 `single_instance_guard`）：
  ① `show_or_create_main_window` 只做原子量状态切换（取消回收排程、清「静默驻留」），
  窗口侧动作改成「工作线程 → `run_on_main_thread`」投递进事件循环——
  `run_on_main_thread` 只有在**非主线程**调用时才是投递（主线程调用会内联执行），
  故先进一条线程再投递，保证建窗/恢复几何落在 tao 事件回调上下文里，窗口事件
  走排队而不是内联；
  ② 单实例插件在 Windows 用**同步** `SendMessageW` 转交 argv（无超时），首实例
  卡死时二次实例既启动不了也退不掉。新增启动看门狗：30s 未完成 setup 且首实例
  `IsHungAppWindow` + 1s `WM_NULL` 探测**双条件**成立才判定卡死 → 结束首实例
  并重新拉起本程序（用户这一次点击就能拿回界面）；判不出来只留痕不动手，宁可
  多等也不误杀正常启动/正在同步的实例；
  ③ 主线程心跳：setup 后每 5s 投递一拍，连续 4 拍（>20s）没执行即写一条
  `crash.log`——窗口与托盘全依赖主线程，卡死时用户侧本来没有任何可反馈线索；
  ④ 冷启动 8s 兜底 show 不再重弹「用户自己关掉的窗口」（`mark_user_close`），
  否则启动 8s 内关窗会被重新弹出、还会让回收排程误判「用户在用」而取消。
- **回归**：单元测试 `cargo test --lib single_instance_guard`（看门狗决策三条件、
  期限与心跳阈值）；实机链路按「启动 → 关窗 → >300s 回收 → 二次实例/托盘唤起」
  复核主窗可见、可聚焦、二次实例进程正常退出、`app_log.log` 出现
  「主窗重建成功」。
