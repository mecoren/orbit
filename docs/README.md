# 循迹（Orbit）规划文档

> **循迹（Orbit）** —— 从 wait-home 待办模块独立出来的跨平台待办应用。桌面优先、本地优先、端到端加密。
> Orbit 意为「轨道」：数据以本地为主轴运转，云端仅存端到端加密镜像；循迹，即数据始终循此轨迹而行，不出轨、不旁落。

## 一、项目定位

| 维度 | 决策 |
|---|---|
| 产品 | 独立待办应用（任务 / 子任务 / 项目 / 标签 / 提醒 / 评论 / 关联 / 看板） |
| 平台 | Windows / macOS / Linux 桌面三端 **+** Android / iOS 移动双端 |
| 重心 | **桌面端**（验收主体），移动端完全复刻现有观感但 MVP 验收标准放宽 |
| 差异化 | 本地优先 + SQLCipher 本地加密 + 云端仅存端到端加密同步包 + 免注册免订阅 |
| UI 策略 | **完全复刻** wait-home 现有两端 UI（桌面 React 版照搬规格；移动端用 React 重现 Flutter 版观感） |
| 许可证 | ⚠ 待决策：仓库公开前须在 MIT / Apache-2.0 / 专有之间选定（私有阶段暂按专有处理） |

## 二、选型决策记录（ADR）

**决策：采用 B 方案 —— Tauri 2 全五端单前端（React）+ 共享 Rust 核心。**

### 背景
wait-home 现状是 Flutter（移动）+ Tauri/React（桌面）双前端共享 `wait_core`。独立成产品后若维持双框架，单人维护两套 UI 的成本不可持续。

### 备选方案对比结论

| 方案 | 结论 |
|---|---|
| A. Flutter 五端单代码库 | 否决——重心在桌面时优势消失，且放弃现有高完成度 shadcn 桌面 UI |
| **B. Tauri 2 全五端** | **采纳**——桌面 UI 几乎整体平移；Rust 核心（todo_api / 加密 / 同步）零结构性改动复用；单一 React 前端 |
| C. 维持双框架抽仓 | 否决——正是本次要摆脱的负担 |
| D. Compose Multiplatform | 否决——无 Kotlin 存量技能，Rust 核心作废重写 |

### 已知代价（接受）
1. 移动端为 WebView 渲染：手势手感低于 Flutter 原生。缓解：移动端 MVP 不做看板拖拽（现有移动端本就未接线看板），列表滚动接受原生物理。
2. Tauri 2 移动侧插件生态较年轻：通知/后台任务需在 M4 初做技术验证（见 06 文档风险表）。
3. 安装包比纯原生大，但桌面优先场景下可接受。

### 后续决策记录约定

后续重大决策（含 M4 的 R1/R2 spike 产出）以一页纸 ADR 记入 `docs/adr/NNN-标题.md`，四段式：**背景 / 备选 / 决策 / 后果**，只增不改；格式与本文 §二 同构。首批 ADR 即 R1（Android SQLCipher 策略）与 R2（移动通知方案）。

## 三、文档导航

| 文档 | 内容 |
|---|---|
| [01_产品需求-MVP范围.md](01_产品需求-MVP范围.md) | 目标 / 非目标、功能范围清单、MVP 验收标准 |
| [02_技术架构.md](02_技术架构.md) | 技术栈、monorepo 结构、Rust 资产裁剪清单（平移/小改/重写）、构建矩阵 |
| [03_数据模型与同步.md](03_数据模型与同步.md) | 表结构、迁移重组策略、双层密钥加密体系、云同步管线、白名单裁剪 |
| [04_UI复刻规格-桌面端.md](04_UI复刻规格-桌面端.md) | 桌面端像素级复刻规格：布局层级 / 设计 token / 组件映射 / 不一致点规范化 |
| [05_UI复刻规格-移动端.md](05_UI复刻规格-移动端.md) | 移动端复刻规格：信息架构、逐屏规格、Flutter→CSS 换算、常量速查卡 |
| [06_MVP里程碑与任务分解.md](06_MVP里程碑与任务分解.md) | M0–M5 里程碑、任务清单、验收门禁、风险登记 |

## 四、与 wait-home 的资产关系

```
wait-home                          Orbit
├─ rust_core/src/api/todo_api.rs      ──► orbit_core（平移）
├─ rust_core/src/db/migrations        ──► 重组为新 0001（仅保留所需段）
├─ rust_core/src/{crypto,sync_*}      ──► orbit_core（平移，白名单裁剪）
├─ desktop/src/modules/todo/*         ──► UI 复刻蓝本（重写到新仓 src/features/todo）
├─ desktop/src/components/ui|business ──► 直接平移（ui 基元全套）
├─ desktop/src-tauri/commands/*       ──► 平移精简（todo_cmd + business_cmd todo 段）
├─ mobile/lib/modules/todo/*          ──► 仅作视觉/交互规格来源，代码不迁移
└─ mobile/rust_frbbindings            ──► 丢弃（全 Tauri command 单通道）
```

## 五、命名约定

| 项 | 值 |
|---|---|
| 项目名 / 仓库名 | Orbit / orbit |
| 中文名 / 应用名 | 循迹（用户可见的应用显示名：标题栏、关于页、安装包等处使用） |
| 命名语言约定 | 代码、文档、标识符用 Orbit；面向用户的界面文案用「循迹」 |
| Rust 核心包名 | `orbit_core` |
| 数据库文件 | `orbit.db` |
| 全量备份包后缀 | `.orsync`（格式同 `.waitsync`，magic 改为 `"ORSN"`） |
| 同步载荷 magic | `"OSZS"`（沿用 wait-home 的 `"WSZS"` 格式骨架，仅换 Orbit 标识） |
| 钥匙串 service | `orbit.sync-crypto` |
| 云端路径根 | `{base_path}/orbit/` |
