# ADR 0004 — M5 发布工程：签名/公证/分发决策

日期：2026-09-03 ｜ 状态：已采纳（证书物料清单待用户补齐）

## 背景

MVP 发布（06 文档 §二 M5）要求五端产物签名/分发就绪。现状：

- `tauri.conf.json` 的 macOS `signingIdentity: null`（未签名）；
- Windows 无代码签名证书，NSIS/MSI 未签名；
- Linux deb/AppImage 未校验；
- Android APK 以 debug 密钥签出（release 签名密钥未配置）；
- 桌面图标为 Tauri 默认图，移动端为 Flutter 默认图。

## 决策

### 1. 图标/启动屏（2026-09-08 v5 换版，产物入库）

- 品牌设计（v5，现行）：**透明底 + AI 生图「圆环轨道」构图（加强版）**
  ——加粗正圆环（#246CF6，环带宽 ~165px、内嵌带拖尾的卫星球）、左上
  月牙形行星（被环咬出缺口）、彗星自中心越环、环内柔光 glow。全族无
  底板（用户口径「扣成透明背景」）：桌面任务栏/Android 桌面/关于页
  背景由宿主提供；Android 启动屏深色由 `launch_background.xml` 的
  `launch_bg` 承载，图标层透明直贴。
  - 源图：`scripts/icon-source-2026-09-08b.png`（1254²，ChatGPT 生图
    自带透明通道）。质量实测后**直接栅格使用、不重描**：主环外缘段内
    圆度 ±1px（左右长轴椭圆 rx 364 / ry 347，段内 std≤1.2）、主体蓝
    std<3 纯色、glow 99.7% 集中环内、al≥15 主域单连通（散噪共
    ~250px 剔除）。
  - 资产管线：最大连通域去散点 → 裁主体紧框 920×816 固化
    `scripts/icon-asset-2026-09-08b.png`（solid 915×812 几乎填满，
    glow 仅边缘 23..44px 柔边）；`generate_icons.py` 以 solid bbox
    （画布 80%，PAD=0.10）对齐缩放 alpha 合成；通知剪影取 alpha>128
    二值化（剪影按 solid 紧框铺放）。
  - 小尺寸特调（2026-09-08，任务栏模糊反馈）：≤32px 走 SMALL_TIERS
    分档（16/20: PAD 0.05 + alpha [160,235]→[0,255] 陡化；24: 0.06/
    [150,240]；32: 0.08/[140,245]）——全构图在小尺寸下环带仅 ~2px 且
    半透明灰雾 21-28%，任务栏显示发灰模糊；特调后实蓝像素 +28%、
    32px 灰雾降至 13.8%。ICO 改手写多槽容器（Pillow sizes 不支持
    20px 槽且为二次缩放）：16/20/24/32/40/48/64/96/128/256 十槽，
    覆盖任务栏 96-200% DPI 取值，每槽独立从母版渲染。
  - 历史版本：v1 渐变椭圆轨道 → v2 手绘描摹（`icon_shapes.json`，
    波纹被否）→ v3 高斯平滑重阈值（`extract_icon_shapes.py`）→
    v4/v4.1 AI 生图圆环+透明底（`icon-asset-2026-09-08.png`）→ v5
    现行。v2/v3 脚本与 v4 资产仍入库（换源图可复用）。
- 全族由 `scripts/generate_icons.py`（Pillow，含生成后自检）一次产出：
  - 桌面 `apps/desktop/src-tauri/icons/`：PNG 全尺寸族 + `icon.ico`
    （10 槽含 DPI 缩放档，手写容器）+ `icon.icns`（ic07–ic10，Pillow 手写 ICNS 容器，无需
    macOS iconutil）+ Windows Store Square 族；
  - 桌面关于页 `apps/desktop/public/app-icon.png`（256，透明底同主图）；
  - Android `mipmap-*/ic_launcher.png`（48–192 五密度）；
  - 通知小图标 `drawable-*/ic_stat_orbit.png`（主体白色剪影，
    API 21+ alpha 语义），`notification_service.dart` 已接线（初始化
    小图标 + 文档注明 22.x 无 channelIcon 参数）。
- Android 启动屏：`launch_background.xml`（含 -v21）品牌深色底
  `@color/launch_bg` + 居中 `@mipmap/launch_image`（xxxhdpi 512，
  全出血无圆角版），亮暗共用深色底（避免启动瞬间明暗跳变）；桌面
  窗口 `visible:false` + 前端就绪后 `getCurrentWindow().show()`
  （main.tsx），消除原生空窗白闪。
- 源图：`docs/adr/assets/orbit-icon-master.png`（1024px）。

### 2. 签名矩阵

| 平台 | MVP 决策 | 证书物料（用户待办） |
|---|---|---|
| Windows | **暂不购买证书**：OV 代码签名证书年费成本 + 单人维护量，MVP 以「下载后校验哈希」过渡；README/Release 注明未签名 + SmartScreen 提示的处理说明 | 若购证：配置 `TAURI_SIGNING_PRIVATE_KEY` 环境变量 + tauri-action 自动签名（参考 `.github/workflows/release.yml` 注释段） |
| macOS | **不签名不公证发布 MVP**（ad-hoc 签名仅本机构建）；Gatekeeper 提示 xattr 处理说明写入 Release 模板 | Apple Developer ID（$99/年）到位后：`signingIdentity` 填 "Developer ID Application: …" + `APPLE_ID/APASSWORD/TEAM_ID` 公证三件套 + `tauri.conf.json` `entitlements` |
| Linux | deb/AppImage 无签名惯例（仓库/镜像分发），CI 产出即发布；校验哈希随 Release 附 `SHA256SUMS` | — |
| Android | release 签名密钥**已留配置位**：`android/key.properties`（gitignore）+ `build.gradle.kts` signingConfigs 读取；未配置时回落 debug 签名（开发装真机可覆盖安装） | 生成正式 keystore：`keytool -genkey -v -keystore orbit-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias orbit`，写入 key.properties |
| 安装包完整性（ updater） | **已落地（2026-09-15 修订）**：`tauri signer generate` 生成 minisign 密钥对，公钥入 `tauri.conf.json` 的 `plugins.updater.pubkey`，私钥入 Secrets；`bundle.createUpdaterArtifacts: true` 使每个平台产出 `.sig`，由 `publish-updater-manifest` 合成 `latest.json` | 私钥已生成（Secrets 待用户配置）；轮换会让旧客户端拒升级，口径见 `docs/08` §3.6 |

> 原则：**没有证书物料的环节一律明示「未签名」并给出用户侧校验/放行指引**，
> 不静默伪装已签名。证书到位后仅改配置/环境变量，无需动流程。

### 3. 分发与版本机制（2026-09-15 修订：版本单点口径改为「唯一数据源 + 脚本同步」）

- 分发：GitHub Releases。触发：push tag `v*`；发版前可用
  `workflow_dispatch(dry_run)` 预演（详见 `docs/08_发布与更新流程.md`）。
- **版本收敛（2026-09-15）**：历史 `v0.1.0` / `v0.1.1` 两个 tag 的全部工作内容
  并入单一 **0.1.0** 条目（`CHANGELOG.md` 与应用内更新日志同源双写），清单各处
  统一为 `0.1.0`。
- **版本唯一数据源**：`apps/desktop/package.json#version`。其余五处由
  `scripts/bump-version.mjs`（`pnpm bump X.Y.Z`）同步，**不手改**：
  `apps/desktop/src-tauri/tauri.conf.json#version`、
  `apps/desktop/src-tauri/Cargo.toml [package]`、
  根 `Cargo.toml [workspace.package]`、`apps/mobile/pubspec.yaml#version`、
  以及两个 `Cargo.lock` 的本地包版本行（漏改会让 `cargo --locked` 失败）。
  前端版本经 `vite.config.ts` 构建期注入 `__APP_VERSION__`，源码不硬编码。
  修订动因：2026-09-15 发现 `apps/desktop/package.json`（0.1.0）与其余处
  （0.1.1）已实际漂移、关于页版本徽标停在 0.1.0——手工三处同步不可持续。
- 一致性由 `pnpm bump:check`（发版门禁）与
  `apps/desktop/src/test/release-consistency.test.ts`（回归护栏）双向守护。
- 更新日志**两份同源双写**：`CHANGELOG.md`（Keep a Changelog 1.1.0 + semver，
  发版时把 `[Unreleased]` 改为版本段并归档）+ `apps/desktop/src/lib/changelog.ts`
  （应用内「关于 → 更新日志」），同一次提交写完；Android 端 pubspec 版本
  `major.minor.patch+build` 中 build 号每次发版 +1（由脚本自增）。

### 4. Release CI 脚手架（2026-09-15 修订：作业拆分与更新清单单点化）

`.github/workflows/release.yml`：push tag `v*` 触发（`workflow_dispatch` 可预演）——

1. **`audit` 发版前置门禁**（廉价 job 先失败）：`pnpm bump:check` 版本一致性、
   tag 名 = 清单版本、updater 签名私钥就位、`cargo audit`×2 lock + `pnpm audit`
   （观察期不拦截，转硬拦截条件见 `docs/08` §6）；
2. 桌面矩阵（windows/msvc → NSIS+MSI；macos-aarch64 → DMG；ubuntu →
   deb+AppImage）tauri-action 打包并创建**公开** Release（草稿态会让
   `latest.json` 的 `latest/download` 地址 404），产物与 `.sig` 由本平台上传；
   `includeUpdaterJson: false`——全平台清单改由第 4 步单点合成（矩阵并发
   读改写 manifest 会撞 PATCH 竞态）；
3. Android APK（java 17 + flutter，cargokit 构建 orbit-flutter；release 签名
   就绪后自动生效）只构建传 artifact，上传 Release 交给第 5 步，避免与
   tauri-action 抢建 Release 造成草稿化；
4. `publish-updater-manifest`：读各平台 `.sig` 合成唯一 `latest.json`
   （平台键含安装方式后缀 + 基础键双写，写法依据 tauri-plugin-updater 的
   查找顺序），临时名 → 删旧 → 改名三步上传（崩溃安全、可重跑）；
5. `publish-extras`：上传 APK 并汇总 `SHA256SUMS`（未签名产物的主要完整性
   依据，覆盖含 APK 与 `latest.json` 在内的全部资产）。
6. 证书类环境变量未注入时全部走未签名路径并打 `unsigned` 标注，
   Release 模板注明校验方式；但 **updater 签名私钥必填**
   （`bundle.createUpdaterArtifacts: true` 下缺失即构建失败，刻意保护）。

## 后果

- 正面：发布链路无外部工具依赖（图标脚手架/ICNS 手写容器可跨平台复现）；
  证书环节解耦，随时可升级签名而流程不变。
- 负面/已知让步：Windows SmartScreen / macOS Gatekeeper 首次运行提示
  需用户手动放行（Release 说明缓解）；Android 正式签名前不可上架商店。
- 遗留：MVP tag（v0.1.0）待 M4 真机清单全过后打（06 §一 M5 Gate）。
- 修订（2026-09-15）：版本单点与 Release 作业拆分口径见 §3/§4 修订段，
  完整流程（触发条件/步骤/角色/异常处置）以 `docs/08_发布与更新流程.md` 为准。

## 证书物料 TODO（用户操作项）

- [ ] Windows：决定是否购买 OV 代码签名证书（否 → 维持哈希校验过渡）
- [ ] macOS：Apple Developer Program 账号（$99/年）→ Developer ID 证书
- [ ] Android：`keytool` 生成 release keystore + `android/key.properties`
- [x] tauri artifacts 签名密钥 + updater 公钥 —— 2026-09-13 落地（07 #20）：
  `plugins.updater.pubkey` 入库、`release.yml` 开 `includeUpdaterJson`；
  2026-09-15 进一步开 `bundle.createUpdaterArtifacts` 并把清单合成单点化。
  私钥需在 repo Secrets 配置（`TAURI_SIGNING_PRIVATE_KEY[_PASSWORD]`），
  轮换口径见 `docs/08` §3.6
