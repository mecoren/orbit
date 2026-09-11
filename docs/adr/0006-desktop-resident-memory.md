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
