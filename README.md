# Orbit（循迹）

跨平台任务管理应用：待办（项目/任务/子任务/标签/提醒/评论）+ 云同步 + 全量备份。
业务逻辑全量下沉 Rust 核心，各端仅保留薄壳 UI 与桥接层。

> 本地优先 · 端到端加密 · 无账号 · 无遥测。许可证：[MIT](LICENSE)。隐私承诺见 [PRIVACY.md](PRIVACY.md)。

| 端 | 技术栈 | 位置 |
|---|---|---|
| 桌面 | Tauri 2 + React 19 + Vite | `apps/desktop`（Rust 壳：`apps/desktop/src-tauri`） |
| 移动 | Flutter + flutter_rust_bridge 2.12 | `apps/mobile`（FRB 桥：`crates/orbit-flutter`） |
| 核心 | Rust（SQLCipher / 云同步 / 备份 / 事件总线） | `crates/orbit-core` |

## 目录结构

```text
orbit/
├── crates/                  # 根 Cargo workspace 成员
│   ├── orbit-core/          # 业务核心（零 FFI 依赖）
│   └── orbit-flutter/ # FRB 薄壳，导出 API 给 Flutter
├── apps/
│   ├── desktop/             # Tauri 桌面端（src-tauri 为嵌套独立 workspace）
│   └── mobile/              # Flutter 应用（不入任何 Cargo workspace）
├── docs/
│   ├── NN_主题.md           # 编号文档（01 产品需求、02 技术架构…）
│   └── adr/                 # 架构决策记录
├── Cargo.toml               # 根 workspace：单点管控 crates/* 依赖版本
├── package.json             # 仅声明 packageManager，pnpm workspace 入口
└── pnpm-workspace.yaml
```

## 快速开始

前置依赖：Rust ≥ 1.96、Node 22、pnpm（由 corepack 按 `packageManager` 字段自动锁定）、Flutter stable、Tauri 2 CLI。

```bash
# 前端依赖安装（在仓库根执行，lockfile 在根）
pnpm install

# 桌面端开发 / 构建
pnpm --filter orbit dev        # Vite 开发服务器
pnpm --filter orbit tauri dev  # Tauri 完整桌面应用

# Rust 检查（仓库根覆盖 crates/*；desktop 壳需单独进入其目录）
cargo check --workspace --all-targets
cd apps/desktop/src-tauri && cargo check

# FRB codegen（移动端桥接产物一致性由 CI 门禁校验）
flutter_rust_bridge_codegen generate \
  --config-file crates/orbit-flutter/flutter_rust_bridge.yaml
```

## 安装与更新

- **安装包**：桌面 NSIS/MSI、DMG、deb/AppImage，Android APK——发布渠道
  为 GitHub Releases（打 tag 后归档）。
- **更新方式**：MVP 阶段**手动下载覆盖安装**（各桌面安装器与 Android
  `cn.wait.orbit` 覆盖安装均自带升级语义，本地数据目录不受影响）；
  自动更新（updater/Play 渠道）延后至 M6+ 评估（docs/02 §六）。
- **版本与变更记录**：版本号语义化（semver），每版本变更见
  [CHANGELOG.md](CHANGELOG.md)；版本单点为三处发布配置
  （`apps/desktop/src-tauri/tauri.conf.json`、`apps/mobile/pubspec.yaml`、
  根 `Cargo.toml [workspace.package]`），发版时同步 bump。
- **签名**：正式签名/公证流程与证书清单见
  [docs/adr/0004-release-engineering.md](docs/adr/0004-release-engineering.md)。

## 隐私

本地优先、端到端加密、零遥测零崩溃上报、无账号体系——完整承诺与
平台加密边界（Android 明文库降级）见 [PRIVACY.md](PRIVACY.md)。

## 工程约定

- **crate 命名**：`<产品>-<模块>` kebab-case，目录名与包名一致；
  lib 名用 snake_case（如包 `orbit-core` → lib `orbit_core`），依赖方代码统一以 lib 名 import
- **包管理器**：只允许 pnpm；lockfile 固定在仓库根，禁止 npm / yarn；
  版本由根 `package.json` 的 `packageManager` 字段单点锁定
- **Cargo workspace**：根 workspace 只管 `crates/*`，内部依赖版本一律
  `[workspace.dependencies]` 单点声明、成员以 `xxx.workspace = true` 引用；
  desktop 壳为嵌套独立 workspace；mobile 不入任何 workspace
- **测试位置**：单元测试写在对应 crate 内（`#[cfg(test)]`）；e2e 放 `apps/*/e2e`
- **文档**：`docs/NN_主题.md` 编号递增；架构决策写 `docs/adr/`；
  PRD 定稿后归档至 `prd/archive/`
