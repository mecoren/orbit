# Changelog

本文件记录 Orbit 的所有显著变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

P1 体验能力包补记（#8/#9/#10/#11/#12/#13，8/26 落地未记账）+ P2#19 冒烟接入 CI + **我的一天（My Day）三端落地**（07 报告新增 #23）+ 标题栏窗口控制键重制。

### Added

- **标题栏窗口控制键重制**（移植 qraft 同款实现，替换 lucide 内联版）：
  新建 `window-controls.tsx` 组件 + `lib/window.ts` 封装（useMaximized
  钩子订阅 onResized 切换最大化/还原图标）。Win11 规范：命中区 46×32px、
  内联 SVG 图标统一 10×10 居中盒 + 1.25 描边（三键视觉大小/粗细一致，
  还原图标为前层方块 + 后层 L 形描边，遮挡部分不绘制避免"链环"观感）、
  hover 仅背景 alpha 提升无缩放抖动、active 加深、focus-visible 内缩
  2px ring；关闭键 hover 红底白图标反色警示（`--destructive`，
  active 再压暗 15%），替换原硬编码 `#E81123`。非 Tauri 环境
  （测试/浏览器 mock）安全降级不抛错。
- **窗口控制三平台分支**（移植 qraft platform.ts，为 mac/Linux 构建铺路）：
  - 新建 `lib/platform.ts`：UA 运行时检测（isMac/isWindows/isLinux +
    useCustomWindowControls），main.tsx 启动时在 `<html>` 挂
    `.platform-{win|mac|linux}` 类
  - macOS：`WindowControls` 渲染 null 用原生红绿灯；tauri.conf.json
    加 `titleBarStyle: "Overlay"`（mac 专属字段，无边框下保留红绿灯）；
    CSS `.platform-mac .title-bar` 左侧留 78px 红绿灯位
  - Linux：自绘三键同 Windows；无原生 Mica/vibrancy，CSS
    `backdrop-filter: blur(20px) saturate(125%)` 回退（标题栏 + main，
    避免透明背景露底）
  - 平台判定与让位规则已浏览器实测（win 类挂载 + mac 78px padding +
    linux backdrop 三态）

- **我的一天 My Day**（07 报告 §五新增 #23，对标微软 To Do 每日聚焦视图）：
  - 数据层：迁移 `0002_my_day.sql`——todo_tasks 加 `my_day_date` 列
    （加入当天本地零点 ms；NULL = 不在任何一天的 My Day）+ 部分索引。
    列随行同步（SYNCABLE_TABLES 白名单内自动路由，旧客户端忽略未知列）。
    「次日自动清空」是视图侧按日判断（my_day_date == 今天零点），
    不改数据——昨天加入未完成的任务回到原项目可再次加入，微软 To Do 同款语义
  - 桌面端：「我的一天」置顶快捷视图（Sunrise 图标，琥珀色）；
    任务行 hover Sunrise 按钮（今天已加入时常显实心）；右键菜单
    「加入/移出我的一天」；详情抽屉头部按钮；批量工具条「加入我的一天」；
    筛选语义与其它快捷视图同源（状态/优先级筛选叠加生效）
  - 移动端：快捷视图七键（wb_sunny 置顶）+ 任务长按菜单加入/移出；
    `isInMyDay` 按日 getter；FRB 桥 DTO 镜像（含手工展开的 TodoTaskDetail）
  - 测试：task-filters my_day 5 用例（今天命中/昨天退出/null 不命中/
    完成态保留/状态筛选叠加）+ 移动端 3 用例 + smoke e2e 全链用例
    （行内加入 → 视图出现 → db 断言今天零点 → 移出 → 视图清空）
- **e2e 冒烟接入 CI**（#19 尾巴）：web job 追加
  `playwright install chromium` + `pnpm e2e` 步骤——纯浏览器 mock IPC
  与 web job 同一依赖面，免 Rust 工具链；新增根 `pnpm e2e` script

### 补记（此前落地未记账，07 文档已同步回写 ✅）

- **P1 体验能力包**（8/26 完成，commit 357d4d5…9f65acf）：
  #8 键盘可达性行 + 命令面板扩容、#9 全局搜索三路聚合、
  #10 重复任务真引擎（完成时生成下一实例，替代重建 reminder）、
  #11 列表拖拽排序（中值落位）、#12 移动端 go_router 方向性转场、
  #13 修改后立即同步（EVENT_BUS 订阅 + 5s 防抖 push_only，60s tick 兜底）

- **#19 Playwright 冒烟主链路**（纯浏览器 e2e，不启 Tauri 壳）：
  `src/test/ipc-mock.ts` 在页面加载时伪造 `__TAURI_INTERNALS__` 接管
  invoke/listen（真实 Tauri WebView 注入 internals 时为 no-op），
  内存库模拟 Rust 后端——五张表 CRUD + 启动三命令 + kanban/global_search
  + mica/sync 静默路径，写命令广播 db-change 与真实 EVENT_BUS 链路同构
  （events 层 invalidateQueries → UI 刷新）。
  `e2e/smoke.spec.ts` 覆盖主链路：快速新建（NLP 输入栏）→ 列表出现 →
  行 checkbox 完成 → 右键删除（5s 撤销窗口）→ toast 撤销恢复。
  排查中沉淀的三个 mock 保真度修正（均为「同步假 IPC 偏离真实异步时序」
  的还原，对齐 Rust IPC 的 JSON 值语义）：
  1. 读命令出参深拷贝（`ipcClone`）——活引用会被 react-query 的
     structuralSharing 判等，`data` 引用恒定，UI 永不刷新；
  2. 写命令的 db-change 广播推迟到 `setTimeout` 宏任务——同步/微任务
     广播会被 React 19 离散事件批处理吞掉（子树渲染执行但不提交 DOM），
     真 Tauri 下 Rust 事件转发天然异步不复现；为此 e2e 环境经
     `VITE_E2E_NO_STRICT=1` 关闭 StrictMode（开发期检查工具，
     不影响日常开发与生产行为）；
  3. 删除后断言用任务行 aria 角色而非裸 `getByText`——删除 toast 文案
     「已删除任务「…」」含任务名，会污染 toHaveCount(0) 造成永久假红。
  e2e 用专用端口 5273 起隔离 dev server（`reuseExistingServer` 直连已占
  端口会跑在同机其他项目的页面上——实测踩过 5173 被 GoNavi 占用）。
- **#7 NLP 快速输入 v1**（07 报告 §五-P1#7，此前落地未记账）：
  `parse-quick-input.ts` 纯函数规则引擎（中文优先，大小写仅限拉丁 token）：
  今天/明天/后天/大后天、周X·星期X·礼拜X（未来最近）、下周X（下周一为
  首周）、M月d日（今年已过顺延一年）；!1-5 优先级（!6+ 原样保留）；
  #项目 @标签（标题精确匹配优先 → 首个前缀命中，多标签去重）。所有命中
  区间互斥——长词先命中保护内部短词（「下周三」中的「周三」不被二次解析），
  未匹配的 #/@ token 原样保留在标题。桌面 QuickAddBar 接线
  （占位文案「支持「明天 #项目 @标签 !3」」），17 用例单测。

- **#14 日历视图（月/议程两档）**：列表页第三视图 `calendar`——
  月档 7×6 周格（周一始，今日高亮，格内优先级色点 + 截止时刻 +
  截断标题，逾期红；超 3 条折叠 `+N` 弹层看全天）；议程档按日期
  分组滚动列表（sticky 日期头 + 自动滚到今天组）；共用工具栏
  （今天回位 / 翻月跨年正确）。视图切换钮扩为三联，命令面板
  「切换视图」同步循环三态，viewMode 持久化键兼容旧值。
  筛选语义与列表/看板同源（同一 visibleTasks 注入）。
- **#17 多选批量操作（shift 区间选）**：任务行 hover 勾选框 +
  shift 区间选择（最近勾选为锚）；选中态下点行 = 切换勾选、拖拽
  手柄隐藏防误触。底部居中批量工具条：完成/未完成（与单条
  completeTask 三字段联动口径一致）、收藏/取消收藏、设优先级、
  移入进行中/移回待办、移动到项目（含目标尾位 position 落位）、
  删除（复用 5s 可撤销删除语义，整批恢复）。批量写操作提纯
  `shared/batch-actions.ts`（顺序提交 + 条目失败不中断 + 部分成功
  warning 口径，4 用例单测）；`PRIORITY_LABELS` 上收 shared/constants
  与右键菜单共用。

### Removed

- **#22 死代码清理**：`use-entity-list.ts`（0 引用）与
  `use-confirm-delete.tsx`（0 引用，use-undoable-delete 未用它）删除。
  07 文档 #22 行同步修正过时描述：`use-breakpoint`（窄窗折叠）与
  `skeleton`（列表加载态）实为在用，非死代码。

## [0.1.1] - 2026-09-04

M4 复验补丁版：发布产物包含两个上线阻塞修复。

### Fixed

- **release 构建补 INTERNET 权限**（1261ff3）：Flutter 模板仅在
  debug/profile manifest 声明，release 缺失导致 app uid socket 被内核
  拦截——云同步/云端备份在真机全线静默失败。经最小 reqwest 二进制分 uid
  实验定位（shell uid 通 / app uid 拒），aapt2 验证入包。
- **首同步补传 crypto/config**（bce1904）：第二台设备入环 KeyMismatch 阻塞
  修复（0.1.0 后发现，随本补丁版进入发布产物）。
- **CI 门禁修复**（c3bb769）：flutter-action 未锁版本，runner 滚动到
  Flutter 3.47.2 后 dart format 改变 import 分组规则，FRB codegen 的
  dart 产物与仓库基准不一致，「一致性校验」自 8/26 起持续误报；
  锁定 flutter-version 3.44.2 后 CI 三个 job 全部转绿。

## [0.1.0] - 2026-09-03

MVP 发布：M0–M5 全部完成，M4 Gate 通过（模拟器环境双轮走查 + E2E，真机复核建议见清单），许可证 MIT。

### Added

- M5 发布工程落地：
  - 许可证拍板 **MIT**（根 `LICENSE` + docs/README §一 + 根 package.json
    `license` 字段 + 06 文档补记）；隐私声明 `PRIVACY.md`（E2E 承诺表述、
    零遥测边界、Android 明文库降级平台边界、权限清单）
  - 品牌图标族：深色 squircle + 蓝青渐变轨道 + 卫星点（「循迹」语义），
    `scripts/generate_icons.py`（Pillow，含生成后自检）一次产出——桌面
    PNG/ico/icns（手写 ICNS 容器，跨平台无 iconutil 依赖）全尺寸族；
    Android mipmap 五密度启动器图标；白色剪影通知小图标
    `drawable/ic_stat_orbit`（notification_service 接线）
  - Android 启动屏品牌化：launch_background 双主题改深色品牌底 + 居中
    轨道图（消除启动明暗跳变）；桌面窗口 `visible:false` + 前端就绪后
    `show()`（消除原生空窗白闪）
  - Release 流水线 `.github/workflows/release.yml`（tag 触发：桌面三平台
    tauri-action + Android APK + SHA256SUMS 完整性清单，证书 Secrets
    未注入时自动走未签名路径）；Android release 签名配置位
    （key.properties 读取，缺失回落 debug）；签名/公证决策与证书物料
    清单 ADR `0004-release-engineering.md`
  - README 发布章节（安装与更新 / 版本与变更记录 / 隐私承诺入口）
- P2 体验功能三连（07 报告 §五-P2）：
  - **#15 明文数据导出 JSON/CSV**：orbit-core `plaintext_export_api`
    （JSON 结构化全量 + CSV 任务主视图 UTF-8 BOM/项目标签聚合列，
    默认排除墓碑行，6 用例 TDD）；桌面命令组 + 设置页「数据导出」卡
    （未加密明示确认 + 系统保存对话框）；移动端 FRB api + 桥抽象
    扩展 + 设置页导出卡（应用文档目录 exports/ 落盘）
  - **#16 桌面托盘 + 全局热键**：系统托盘（显示主窗/快速新建/退出，
    TrayMenuSpec 规格驱动 + 2 单测）+ 关窗驻留（守护不中断，首次
    toast 告知）+ 全局热键 Alt+Shift+O 快速捕捉（plugin-global-shortcut，
    注册失败静默降级）；app-store quickAddIntent 意图机制跨层传递
  - **#21 窄窗侧栏自适应**：useIsNarrow 接入 ProjectSidebar，断点
    自动折叠 + 手动覆盖持久化；折叠态 12px 图标窄条（hover 提示 +
    未完成计数）；折叠语义提纯 shared/sidebar-collapsed.ts（5 用例）
- **M4 验收挖出并修复同步上线阻塞 bug ×2**：
  1. 首同步将模块数据推上云端但 `crypto/config` 从不上传（`sync_data_key`
     的 Ok(None) 分支缺自动补传决策）→ 第二台设备永久 KeyMismatch 无法入环。
     修复后新增 `m4_sync_e2e` 集成测试锁行为：双实例互推收敛 / 双向编辑
     收敛 / 墓碑不复活 / 明文配置降级，WebDAV 全序列经本机探针服务器实证
  2. **release 构建缺失 INTERNET 权限**（Flutter 模板仅在 debug/profile
     manifest 声明）→ app uid 的 socket 被内核拦截，云同步/云端备份在
     真机全线静默失败。经「最小 reqwest Android 二进制分 uid 运行」实验
     定位（shell uid 通 / app uid 拒），main manifest 补声明并以
     aapt2 dump permissions 验证入包；模拟器实测测试连接恢复
     （PROPFIND depth=1 请求真实发出）
- 移动端 AndroidManifest 开启 `usesCleartextTraffic`（用户自建局域网
  `http://` WebDAV 是文档化场景；同步 E2E 测试默认端点 127.0.0.1:8123）
- 仓库规范化：根级 README.md / CHANGELOG.md / clippy.toml（msrv 1.96）/ rustfmt.toml（edition 2024）
- 移动端云同步设置：设置页「云同步设置」入口 + `/settings/sync` 配置页
  （WebDAV/S3 引擎、凭据、定时/超时/TLS、测试连接/保存/断开确认、同步密码
  设置/解锁/锁定）——桥抽象扩展 `syncTestConnection/syncDisconnect/
  syncCryptoInit/syncCryptoLock`，移动端可在本机完成云同步配置，
  不再依赖桌面端配置

### Changed（文档）

- docs/02 技术架构同步 ADR 0003 现状：技术栈表（Tauri 仅桌面 + Flutter/FRB
  移动壳）、monorepo 结构图、IPC 双通道图、构建矩阵（Flutter 打包口径）、
  依赖清单（FRB 移出排除名单）、数据目录移动端明文降级注记；
  ADR 0003 未竟事项划销（docs/02 已同步、percent_done 已落地）

### Fixed

- 移动端测试套件恢复全绿：时间滚轮选择器用例在 23 点/59 分末项场景
  滑动方向自适应（ListWheel 无环绕语义）；颜色字段随桌面看板标签方案
  （97d3eab）移除后同步对齐详情页/表单测试断言
- CI 门禁存量债务清零：`flutter analyze` 0 issue；Rust fmt 门禁修复
  97d3eab codegen 引入的 `frb_generated.rs` import 顺序偏差；clippy
  1.96.1 存量告警 53 处清完（双 workspace `cargo clippy -D warnings`
  归零），行为零变更（workspace 285 测试 + 移动端 77 + 桌面 67 全过）

### Changed

- `crates/orbit_core` 更名 `crates/orbit-core`：目录与包名统一 kebab-case，
  lib 名保持 `orbit_core`，全部 `use orbit_core::…` 引用零改动
- pnpm lockfile 由 apps/desktop 上收至仓库根：新增根 `package.json` +
  `pnpm-workspace.yaml`，pnpm 版本由 `packageManager` 字段锁定；
  CI web job 迁至仓库根并以 `pnpm --filter orbit …` 执行
- `crates/flutter-plugin-orbit` 更名 `crates/orbit-flutter`：三层 Rust 包统一
  `orbit-*` 前缀，lib 名同步改为 `orbit_flutter`；cargokit 三平台构建参数、
  FRB 配置注释、CI 路径、`Cargo.lock` 连带更新；Dart 插件名 `rust_lib_orbit`
  与历史文档旧名保持不变

## [0.1.0] - 2026-08-26

### Added

- 桌面端（apps/desktop）：Tauri 2 + React 19 + Vite，typed invoke 数据链路
- 移动端（apps/mobile）：Flutter + flutter_rust_bridge 2.12 桥接
- 共享核心（crates）：业务逻辑全量下沉 orbit_core（SQLCipher 加密、云同步、全量备份、事件总线）
- CI 门禁：web typecheck/test/build + Rust workspace check + FRB codegen 一致性校验
