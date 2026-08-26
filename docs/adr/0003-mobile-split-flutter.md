# ADR 0003 — 移动端拆分为 Flutter 应用（omnipass 式 monorepo）

日期：2026-08-26 ｜ 状态：已采纳（v1 落地）

## 背景

README §二 曾采纳"Tauri 2 全五端单前端(React)"方案（ADR 于 docs/README）。
WebView 手势手感、玻璃效果性能与维护成本促使重新决策；omnipass 项目验证了
「Rust 核心 + 桌面 Tauri 壳 + 移动 Flutter 壳(FRB)」的成熟分层。

## 决策

1. **仓库布局**（omnipass 式）：根 workspace 仅管 `crates/*`；
   `apps/desktop`（React+src-tauri 嵌套独立 workspace）；`apps/mobile`（Flutter，
   不在任何 Cargo workspace 内）。旧 React 移动端一次性删除。
2. **桥接**：`crates/flutter-plugin-orbit`（FRB 2.12.0）——全局状态单例
   （parking_lot 替代 Tauri manage），api 与桌面 `#[tauri::command]` 一一对应。
   显式 DTO 镜像（防 opaque 退化）；update 走 patch JSON 三态语义
   （缺省键=跳过/null=清空，与桌面同一 serde 路径）。
3. **UI**：移植 wait-home 设计系统（双色板/玻璃三件套/AlphaIndication 无 ripple/
   EqSpinner 参数），规格基准 = docs/05。Riverpod 3 手动声明 + go_router。
4. **事件**：EVENT_BUS → StreamSink（db-change / sync-finished 由返回值直达 /
   todo_reminder:due 20s 轮询守护在桥内启动，SQL 口径同桌面）。

## SQLCipher Android 攻坚结论（时间盒）

启用 `bundled-sqlcipher-vendored-openssl` 后 cargokit build_tool 在宿主
cmd 引导阶段报"路径找不到"（非编译器错误，与 ADR 0001 工具链问题同源）。
按预案回退：Android 维持明文库 + 设置页安全卡只读（继承 ADR 0001 让步清单）。
重启攻坚的可行路径：Linux/macOS CI 构建器跑 cargokit、或预编译二进制路线
（cargokit precompiled-binaries）、或改用 rust_builder 官方模板重排引导脚本。

## 后续（未竟事项）

- ~~本地通知~~ ✅ 已落地：flutter_local_notifications 即时呈现 + 权限降级 toast
- ~~项目拖拽重排 UI~~ ✅ 已落地（把手限定，逐条落库）；~~标签管理入口~~ ✅；
  ~~表单/详情日期选择器~~ ✅（共用 showTodoDatePicker）
- 表单抽屉 snap 分档吸附（现为固定高度滚动，可后续移植 DraggableScrollableSheet snap）
- iOS 工程（podspec 已备）与签名验证
- README 架构图与 docs/02 更新以反映新布局；percent_done 回算命令面
