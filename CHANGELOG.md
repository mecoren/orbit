# Changelog

本文件记录 Orbit 的所有显著变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本遵循[语义化版本](https://semver.org/lang/zh-CN/)。

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
