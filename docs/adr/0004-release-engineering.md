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

### 1. 图标/启动屏（2026-09-07 换版，产物入库）

- 品牌设计（v3，2026-09-07 两轮迭代）：深色 squircle 底（#1A1A21）+
  **卫星绕行星构图**——左上月牙形行星、左下扫至右上的变宽轨道弧
  （末端卫星球）、中部小彗星；主体蓝 #3974F7。
  - v2 描摹轮廓：`scripts/PixPin_2026-09-07_20-16-46.png` 经 cv2 轮廓
    提取 + RDP/Chaikin 平滑固化 `icon_shapes.json`——轨道弧残留手绘
    波纹（用户反馈「下面的不够圆，太乱了」）；骨架/中轴/单圆拟合等
    理想化路线被数据否定（宽带区细化产生环状骨架、弧率处处变化）。
  - v3 尺度分离（现行）：`scripts/extract_icon_shapes.py` 以「2x 超采样
    + 高斯模糊 σ=5 + 127 重阈值」滤除周期 <10px 的笔触波纹，宏观形状
    （走向/变宽/收笔）完整保留——三部件 IoU 0.994/0.998/0.994；卫星球
    按质心+中位半径理想化为正 64 边形。生成器读 JSON 的 `bbox` 数据
    驱动铺放（宽高比不再硬编码）。
- v1（渐变椭圆轨道 + 白色中心/卫星点）→ v2（描摹）→ v3（平滑重阈值，
  现行）；后续设计变更走 `scripts/extract_icon_shapes.py`（提形状）/
  `generate_icons.py` 参数，重跑即全族再生成。
- 全族由 `scripts/generate_icons.py`（Pillow，含生成后自检）一次产出：
  - 桌面 `apps/desktop/src-tauri/icons/`：PNG 全尺寸族 + `icon.ico`
    （7 尺寸）+ `icon.icns`（ic07–ic10，Pillow 手写 ICNS 容器，无需
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
| 安装包完整性（ updater 备用） | tauri 自身 artifacts 签名密钥（`tauri signer generate`）暂不生成——M5 无 updater，M6+ 启用时再建 | 与 updater 决策合并评估 |

> 原则：**没有证书物料的环节一律明示「未签名」并给出用户侧校验/放行指引**，
> 不静默伪装已签名。证书到位后仅改配置/环境变量，无需动流程。

### 3. 分发与版本机制

- 分发：GitHub Releases。触发：push tag `v*`。
- 版本单点三处（发版 checklist 同步 bump）：
  `apps/desktop/src-tauri/tauri.conf.json#version`、
  `apps/mobile/pubspec.yaml#version`、根 `Cargo.toml [workspace.package]`。
  MVP 维持 0.1.0；MVP tag 定为 `v0.1.0`（真机清单通过后打）。
- 更新日志：`CHANGELOG.md`（Keep a Changelog 1.1.0 + semver），发版时将
  `[Unreleased]` 段落改为版本号段并归档；Android 端 pubspec 版本
  `major.minor.patch+build` 中 build 号每次发版 +1。

### 4. Release CI 脚手架

`.github/workflows/release.yml`：push tag `v*` 触发——

1. 桌面矩阵（windows/msvc → NSIS+MSI；macos-aarch64 → DMG；ubuntu →
   deb+AppImage），tauri-action 打包，产物上传 Release；
2. Android APK（ubuntu，java 17 + flutter stable，`flutter build apk`，
   cargokit 内构建 orbit-flutter；release 签名就绪后自动生效）；
3. `sha256sum` 汇总 `SHA256SUMS` 附 Release（未签名产物的主要完整性依据）。
4. 证书类环境变量未注入时全部走未签名路径并打 `unsigned` 标注，
   Release 模板注明校验方式。

## 后果

- 正面：发布链路无外部工具依赖（图标脚手架/ICNS 手写容器可跨平台复现）；
  证书环节解耦，随时可升级签名而流程不变。
- 负面/已知让步：Windows SmartScreen / macOS Gatekeeper 首次运行提示
  需用户手动放行（Release 说明缓解）；Android 正式签名前不可上架商店。
- 遗留：MVP tag（v0.1.0）待 M4 真机清单全过后打（06 §一 M5 Gate）。

## 证书物料 TODO（用户操作项）

- [ ] Windows：决定是否购买 OV 代码签名证书（否 → 维持哈希校验过渡）
- [ ] macOS：Apple Developer Program 账号（$99/年）→ Developer ID 证书
- [ ] Android：`keytool` 生成 release keystore + `android/key.properties`
- [ ] （M6+）tauri artifacts 签名密钥 + updater 公钥
