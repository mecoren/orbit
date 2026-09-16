# AGENTS.md

> 本文件是本项目 AI 编码工具的**单一真相源**。其它工具入口若存在，只应引用本文件，不要重复维护规则。

Orbit（循迹）是本地优先的跨平台任务管理应用：待办（项目/任务/子任务/标签/提醒/评论）+ 云同步 + 全量备份。业务逻辑全量下沉 Rust 核心（`crates/orbit-core`），桌面 Tauri 壳与移动 Flutter 壳只保留薄 UI 与桥接。无账号、无遥测、端到端加密。

## 快速原则

- **中文工作**：对话、commit message、文档、CHANGELOG 全部中文。commit 格式 `type(scope): 中文描述`（Conventional Commits + 中文正文要点列表），如 `feat(stats): 完成热力图重构对齐 wait-home——按年视图+年份切换`。
- **单一功能单一 commit**：一批工作内每个功能独立成 commit；动 git 前先 `git status --short` 核对全清单，**逐文件 add**（目录通配会混入并发会话 WIP），add 后必查 `git diff --cached --name-only` 再 commit；commit 后核对 `git log` 归属防重复提交。
- **业务全部下沉 Rust 核心**：新功能逻辑写在 `orbit-core` 的 `api/*_api.rs`，桌面 Tauri command（`apps/desktop/src-tauri/src/commands/`）与移动 FRB 桥（`crates/orbit-flutter/src/api/`）都是薄壳转发，不写业务。命令在 `src-tauri/src/lib.rs` 的 `invoke_handler` 集中注册。
- **只读聚合不进同步白名单**：统计类新表/新读路径不改 `sync_registry.rs`；新增可同步表必须同步更新 SYNCABLE_TABLES + modules.rs 计数断言。
- **软删语义**：业务表全带 `uuid`（同步主键，UNIQUE 索引防僵尸行复活）/`is_deleted`/`version`/毫秒时间戳三件套；删除一律软删墓碑进回收站，物理 DELETE 只存在于回收站 purge 路径（ADR 0005 延迟提交边界）。
- **日期分桶按本地时区日界**：毫秒时间戳在 Rust 侧用 chrono::Local 换算本地日期后再分桶（`local_day_index`），前端 Date/Dart 本地语义对齐；不要在 SQL 里按 UTC 天分组。
- **迁移文件增量策略**：DDL 只在 `orbit-core/src/db/migrations/`，`0001_init.sql` 为冻结基线永不改；新增结构默认追加 `NNNN_xxx.sql`（sqlx 按文件名顺序执行，老库只跑新增文件，不删库）。加列必须带 `DEFAULT`，加表/加索引用 `IF NOT EXISTS`，破坏性变更走重建表；未发布的多文件可合并为一个，已发布文件永不改/删。新字段补行尾中文注释（DDL 注释随 sqlite_master 落库，GUI 可见），存量库升级靠增量迁移原地完成（仅大版本基线重建才走删库+云同步/`.orsync`恢复）。
- **双强调色体系勿混用**：待办模块色 `TODO_ACCENT = #3B82F6`（checkbox/选中态/图表）与全局主题色 `themeAccent = #4E8CFF`（GlassFab/Spinner）两个 Context 并存（docs/05 §2.1）。
- **悬浮提示统一主题色底白字**：桌面所有 tooltip 对齐 `ui/tooltip.tsx` 原语口径 `bg-primary text-primary-foreground`（手搓 Portal 提示也不得用 `bg-popover` 灰白弹层色——2026-09-10 热力图曾踩坑）；移动端原生 `Tooltip` 由 `app_theme.dart` 全局 `tooltipTheme` 统一（强调色底白字），不逐处覆写。
- **滚动条全项目标准**：桌面全局 `index.css` 定义 `::-webkit-scrollbar` 10px 透明轨道主题色圆角滑块，原生 `overflow-auto` 容器自动继承——**禁设 `scrollbar-width` 非 auto 值**（会禁用 webkit 自定义退化为系统原生条）；需隐藏的用三件套 `scrollbar-width:none + -ms-overflow-style:none + ::-webkit-scrollbar display:none`。移动端全局 `ScrollbarThemeData`（app_theme.dart）只对显式 Scrollbar 生效，`SingleChildScrollView` 惯例不挂。
- **无 prettier 约定**：仓库不配 prettier，`npx prettier` 现跑会重排整文件产生巨型噪音 diff；已跑坏的用 `git checkout HEAD --` 恢复后手工重放。
- **文档同步链**：完成 07 竞品报告任一编号 backlog 项时——07 文档对应行划线补 `✅ 已完成（日期+一句话要点）`、CHANGELOG Unreleased 补条目、文档内过时描述随代码一并修正（07 是 backlog 唯一状态源）。
- **版本发版走流程而非改数字**：版本真值只在 `apps/desktop/package.json`，同步走 `pnpm bump`；「改版本号」请求按下方[版本发布与更新流程](#版本发布与更新流程改版本号时自动执行)全流程执行（脚本 + 两份更新日志 + 守护测试绿），详见 `docs/08_发布与更新流程.md`。
- **尊重并发会话**：同一仓库常有并行会话 WIP；暂存区改动可能被并发 commit 带走或清空，收尾必须核对 HEAD 归属；不回滚非本批改动。

## 技术栈

| 维度 | 选型 |
| --- | --- |
| 桌面 | Tauri 2（Windows / macOS / Linux），嵌套独立 Cargo workspace `apps/desktop/src-tauri` |
| 前端 | React 19 + TypeScript（strict）+ Vite |
| UI | shadcn/ui 风格（Radix 原语）+ Tailwind CSS v4（CSS-first，无 tailwind.config） |
| 状态 | React Query（queryKey 约定见下）+ 局部 zustand；localStorage 持久化视图态 |
| 移动 | Flutter（stable，CI 锁 3.44.2）+ flutter_rust_bridge 2.12（codegen 锁 2.12.0） |
| 状态(移动) | Riverpod；移动 UI 不引图表库（纯自绘 Row/Column） |
| 核心 | Rust edition 工具链锁 `rust-toolchain.toml` 1.96，clippy + rustfmt |
| 加密 | SQLCipher 本地库 + AES-256-GCM 云同步 E2E（PBKDF2 600k 单调不降级） |
| 质量 | tsc / vitest 4 / Playwright 冒烟 / cargo test / flutter analyze+test；CI 三 job（web/rust-core/flutter-mobile 含 FRB codegen 一致性门禁） |

## 架构边界

**必须在 orbit-core（Rust）**

- 全部业务逻辑：CRUD、重复规则引擎、提醒到期处置、回收站 TTL、统计聚合、CSV 导入导出、明文导出、附件内容寻址、节假日。
- 云同步三协议（WebDAV / S3 / 阿里云 OSS）+ 双层密钥体系 + 全量备份。
- 事件总线（`eventbus/`）：db-change 单播给双端壳（移动端经 FRB event stream；桌面 Tauri event emit）。

**壳层只做**

- 桌面 `apps/desktop`：React UI + `src/lib/tauri.ts` 包装 invoke（不要裸 `@tauri-apps/api` invoke）+ `src-tauri/src/commands/` 薄命令。
- 移动 `apps/mobile`：Flutter UI + `lib/data/api/` 桥接层（`OrbitBridge` 抽象接口 → `RustOrbitBridge` FRB 实现 / `MockOrbitBridge` 内存实现供测试）。
- FRB 桥 DTO 镜像模式：`crates/orbit-flutter/src/api/` 本地 DTO 显式镜像 core Serialize 结构，不直接暴露 core 类型——保持两端壳独立演进自由度；`PlatformInt64` 在 Web 语义下是 BigInt，转 `List<int>` 逐个 `.toInt()`。

**跨端契约**

- 桥接签名双端一一对应：Tauri command 与 FRB 函数同名同参（如 `stats_aggregate`）；mock 桥（`mock_orbit_bridge.dart` / `src/test/ipc-mock.ts`）同口径实现，口径漂移会在测试暴露。
- 前端 queryKey 约定（docs/02 §五）：`["todo_tasks", keyword, page, pageSize]`、`["count", …]`、`["nav-data"]`、统计 `["stats", "aggregate", …]`；变更后刷新沿命令式 `refetch()` 模式（复刻优先不做激进重构）。
- 同步白名单集中在 `orbit-core/src/db/sync_registry.rs` 单文件。

## 目录约定

```text
crates/
  orbit-core/            # 业务核心（零 FFI 依赖）：api/（业务 API）、db/migrations/、
                         # sync/ + sync_adapters/（云同步）、eventbus/、crypto/、models/
  orbit-flutter/         # FRB 薄壳：api/ 按域分文件（dto/todo/stats/…），codegen 产物入库
apps/
  desktop/
    src/
      features/todo/
        desktop/         # 桌面视图与页面（stats-page、task-list-view、calendar-view…）
        shared/          # 双端共享纯函数与组件（constants/position/time/heatmap…）+ 同目录 .test.ts
        store.ts         # 局部 zustand
      components/        # 应用级：layout/（app-shell 壳）、ui/（shadcn 原语）、business/
      lib/tauri.ts       # invoke 包装与 DTO 类型（唯一 IPC 入口）
      test/ipc-mock.ts   # 浏览器/e2e mock：伪造 __TAURI_INTERNALS__，window.__orbitMock 可直改内存库
    src-tauri/src/commands/  # Tauri 命令薄层；lib.rs invoke_handler 注册
    e2e                  # （根目录 e2e/）Playwright 冒烟
  mobile/
    lib/
      core/              # theme/（AppColors/AppDimens/AppShapes/OrbitAccents）、routing/
      data/api/          # OrbitBridge 接口 + Rust/Mock 两实现 + dto.dart（手写镜像）
      modules/todo/      # 视图与页面 + providers/（Riverpod）+ logic/
      shared/widgets/    # 跨模块组件（EmptyState、WaitToast、LiquidGlassTitleBar…）
    test/                # flutter test（widget/单元），与 lib 镜像目录结构
docs/                    # NN_主题.md 编号文档（01 产品需求 → 07 竞品 backlog）
docs/adr/                # 架构决策记录（0001-0005）
```

## 常用命令

```bash
# 仓库根
pnpm install
pnpm typecheck            # tsc --noEmit（-r 全 workspace）
pnpm test                 # vitest run（桌面）
pnpm e2e                  # Playwright 冒烟（自动起 5273 端口 dev server）
pnpm test:rust            # cargo test --workspace（crates/*；不含 desktop 壳）
cargo test --workspace    # 同上（含 m4 WebDAV 集成用例——本机无 WebDAV 时该用例环境依赖失败属已知非回归）
cd apps/desktop/src-tauri && cargo check   # 桌面壳单独检查（嵌套 workspace）
flutter_rust_bridge_codegen generate \
  --config-file crates/orbit-flutter/flutter_rust_bridge.yaml   # FRB codegen 后须 cargo fmt --all

# 移动端（apps/mobile）
flutter analyze
flutter test
flutter test test/xxx_test.dart          # 定向用例
# vitest 必须在 apps/desktop 内跑（根目录跑会因路径解析假红）

# 发版（详见 docs/08_发布与更新流程.md）
pnpm bump 0.2.0           # 升版：写源 + 同步五处清单 + 两个 Cargo.lock
pnpm bump:check           # 只校验一致性（零写入，CI/本地通用）
```

- CI（`.github/workflows/ci.yml`）三 job：web（typecheck+vitest+build+e2e）/ rust-core（cargo check --workspace --all-targets）/ flutter-mobile（FRB codegen 一致性 + analyze + test）。提交前本地跑通同等检查。
- e2e/Playwright 专用端口 **5273**（非 vite 默认 5173，防撞其他项目 dev server）；strictPort 双保险。

## 版本发布与更新流程（改版本号时自动执行）

用户说「改版本号 / 升版本 / bump 到 X.Y.Z / 发版」时，按下列顺序**完整执行**，不是只改数字。流程权威文档 `docs/08_发布与更新流程.md`（优化蓝本 = qraft 的发布流程），签名矩阵见 `docs/adr/0004-release-engineering.md`。

- **版本单一来源**：只在 `apps/desktop/package.json#version` 维护真值，其余四处 + 两个 `Cargo.lock` 一律由 `scripts/bump-version.mjs` 写入，**不要手改**；前端版本靠 `vite.config.ts` 构建期注入的 `__APP_VERSION__`（关于页等不得硬编码版本号）。
- **发版六步**：
  1. `pnpm bump X.Y.Z`（同步 `tauri.conf.json` / 桌面壳 `Cargo.toml [package]` / 根 `Cargo.toml [workspace.package]` / `pubspec.yaml`（`+build` 自增）/ 两个 lock），确认输出 `VERSION_SYNC_OK`；
  2. 提炼变更：`git log v<上一 tag>..HEAD --oneline`，按功能合并同类提交，忽略 docs/chore/style 噪声；
  3. **两份更新日志同一次提交写完**：`CHANGELOG.md`（`[Unreleased]` 段改为 `## [X.Y.Z] - YYYY-MM-DD`）+ `apps/desktop/src/lib/changelog.ts`（`CHANGELOG_VERSIONS` 头部插入同版本条目）。只写一处 → 应用内关于页永久缺版本（qraft 0.2.7 的历史事故）；
  4. 本地跑通 CI 等价检查：`pnpm typecheck` / `pnpm test` / `pnpm e2e` / `pnpm lint:rust`（`src/test/release-consistency.test.ts` 会把「版本与日志漂移」直接判红）；
  5. **不主动提交**：保持工作区交用户确认；提交用 `chore(release): 版本 X.Y.Z`；
  6. 打 tag `vX.Y.Z` 并推送（`git push origin main --tags`）—— **tag 名必须等于清单版本**（`release.yml` 的 audit job 强校验），推送即公开 Release。
  - **tag 漂移重定（白名单外动作，谨慎）**：若远端已存在同名 `vX.Y.Z` 却指向别的提交（常见根因：并行会话版本漂移，旧会话已先推过 tag），`git push --tags` 会被远端拒收。正确顺序：① `git push origin :refs/tags/vX.Y.Z` 删远端旧 tag → ② `git tag -f vX.Y.Z <commit>` 移动本地 tag 到正确提交 → ③ `git push origin refs/tags/vX.Y.Z` 重推。删/移远端 tag 属公开动作，先确认无下游依赖（如已发布的 GitHub Release）再执行。
- **发布流水线口径**（`.github/workflows/release.yml`）：tag 触发全链路；`workflow_dispatch` 的 `dry_run` 默认 true（只构建不发布，发版前先预演一次）。`latest.json` 由 `publish-updater-manifest` **单点合成**（矩阵并发读改写会撞 PATCH 竞态，故 `includeUpdaterJson` 恒 false）；`createUpdaterArtifacts: true` 下缺 `Secrets.TAURI_SIGNING_PRIVATE_KEY` 会直接失败（刻意保护），audit job 会提前给出配置指引。
- **应用内更新**：手动检查（设置 → 关于与更新），**不做自动轮询**（本地优先，更新时机归用户）；endpoint 取 GitHub Releases 的 `latest.json`。改动更新链路（endpoint / pubkey / 清单平台键 / 安装方式）必须同步本文件与 `docs/08`。
- **密钥轮换**：换 updater 密钥会让**已安装旧版本拒绝升级**（`pubkey` 变更），须先发一版带新公钥的常规更新再轮换；私钥丢失等价于全部用户重装。

## Rust 约定（orbit-core / orbit-flutter）

- API 按域分文件 `api/<domain>_api.rs`，文件头 `//!` 模块文档写口径（日界/软删/同步白名单等约束）；公开函数带 `///` 文档注释说明隐藏约束。
- 只读聚合（统计、备份探针）不 emit 事件、不进同步白名单；写路径完成必须 emit db-change（前端缓存失效链依赖它）。
- streak/分档/色阶类可纯函数化的逻辑抽纯函数 + `#[cfg(test)]` 单测注入固定输入（如 `compute_streak`）。
- 错误走 `CoreResult<T>` / `String`（桥层 map_err 透传给前端可读形式）；测试内 unwrap 放宽。
- 时间运算在本地时区整数域做（day index = `num_days_from_ce() - 719_163`）；**不要**用 ordinal0+year*366 拼接（跨年边界不单调，曾致 366 格错位）。
- 单元测试写对应 crate 内 `#[cfg(test)] mod tests` + 纯函数独立 `mod xxx_fn_tests`；内存库 `sqlite::memory:` + `migrate!` 建 fixture。
- FRB：改桥接 API 后必须跑 codegen + `cargo fmt --all` 再提交（CI 门禁校验生成物一致性）；codegen 会顺带同步 rust 源注释到 dart 产物。

## 桌面前端约定

**React 与组件**

- React 19 函数组件 + hooks；import 类型用 inline `type` 修饰符；路径别名 `@/*`。
- 非显然设计决策写中文块注释在文件/函数头部（仓库既有惯例）；不写历史残留注释、不引用 TODO 阶段号。
- 视觉复刻蓝本是 wait-home（docs/04 像素级规格）：布局尺寸/间距/字阶/色值/交互时序原样保留，不做"顺手优化"；仅 docs/04 §7 列出的不一致点允许偏离。新视图组件先读对应 04/05 章节。

**状态与数据**

- 服务端状态一律 React Query；queryKey 见架构边界节；`staleTime` 2min + `placeholderData: (prev) => prev` 防切 key 闪骨架。
- localStorage 键全集（04 §七）：`todo_view_mode`、`todo_sidebar_ungrouped_after`、`color_palette`、`custom_palette_accent`、`theme_mode`、`font_family/font_size_level/font_weight_level`；新键遵循同风格命名。

**样式与 UI**

- Tailwind v4 CSS-first：语义 token 全在 `src/index.css`（OKLCH 主题变量），优先用 `components/ui/` 原语；className 合并用 `cn()`；图标 lucide-react。
- 双强调色：`TODO_ACCENT` 等常量上收 `features/todo/shared/constants.ts`（硬编码不走 cfg 动态读取——04 §5.1 决策）；优先级六档色 `PRIORITY_COLOR`、状态色 `STATUS_COLOR` 同文件单口径。
- 共享纯函数（排序/分档/日期/位置）放 `features/todo/shared/` + 同目录 `.test.ts` 共置。
- 满高预览区不嵌 Radix ScrollArea（viewport 的 table 包裹打断高度链——qraft 同款坑），用 `div.min-h-0 flex-1 overflow-auto`。
- PopoverContent 内禁嵌自带 Popover 控件（Radix 焦点陷阱），两段式避嵌套。

**测试**

- Vitest（jsdom）：纯函数测试为主，UI 状态逻辑抽 hook/纯函数测；测试与源文件共置 `*.test.ts`。
- 浏览器目检：`pnpm dev`（或 vite --port 5273）+ `window.__orbitMock` 直改内存库 + `emitDbChange()` 触发刷新（绕 IPC 链）；几何断言用 `page.evaluate` 读 getBoundingClientRect 对齐（IAB 里 Playwright click 常超时，改 evaluate 直点；hover 需 cua.move 真实移动触发合成事件）。
- e2e 冒烟（根 `e2e/smoke.spec.ts`）跑 mock IPC 纯浏览器环境；改 IPC 契约必须同步 `src/test/ipc-mock.ts`。

## 移动端约定（Flutter）

- 路由 `core/routing/app_router.dart`（栈式导航）；页面结构 = LiquidGlassTitleBar（Stack 顶部）+ 整页 ListView 滚动（**必须整页滚动，不要 Column+Expanded 固定高度**——曾致内容溢出）。
- Riverpod：Provider 按 `modules/todo/providers/`；`FutureProvider.family` 家族化参数缓存（如 statsProvider(year)）；db-change 后 `invalidateBusinessCaches` 统一失效。
- 主题 token 全在 `core/theme/`：`AppColors.ofContext(context)` 取语义色、`AppDimens.spaceN` 间距、`AppShapes.small/medium/large` 圆角（特殊值 `AppShapes.of(n)`）、`OrbitAccents.todoAccent/themeAccent` 双强调色——**不写裸魔法值**。
- UI 自绘不引库：条形图/热力图纯 Row/Column/Container；组件复刻 wait-home mobile `activity_heatmap.dart` 同构。
- 布局对齐坑：行标签/占位格与实际格必须同 padding 规则（末行不加尾距，否则固定高 Column 溢出 3px）；`Text.rich` 在 widget 测试 `find.text` 不可见——标题行用 Row + 独立 Text。
- 测试：`MockOrbitBridge` 注入 `orbitBridgeProvider.overrideWithValue` 冒烟渲染；纯 Dart test 直接调 bridge 排除 UI 层（widget 卡死超时先分离归因）。
- toast 用 `WaitToast`（支持 action 钮）；空态对齐 `EmptyState` 组件模式（让出标题栏后剩余视口垂直居中）。

## 通用代码规范

- 非显然函数/方法上方写中文文档注释（TS 多行注释块 / Rust `///`）；显然一行包装可省。
- 优先早返回；hooks/声明/副作用/return 前空行分组；函数体内少注释，只解释隐藏约束或规避原因。
- 不做超出当前需求的抽象、兼容垫片或提前优化；复刻优先（复刻蓝本行为，不激进重构）。
- 改 UI 后必须实机/浏览器操作验证主路径与边界，不只靠类型检查；几何类改动补 evaluate 断言（中心坐标逐像素对齐）。
- 测试假红归因三板斧：先跑定向单用例分离环境因素（WebDAV/日期敏感/并发 WIP）→ 纯调用排除 UI 层 → `_boot` 探针归因冷启动。
- 新增数据库字段：新增 `NNNN_xxx.sql`（加列带 `DEFAULT`、行尾中文注释）+ 内存库 `executescript` 验证 + 双端 DTO 镜像链全改（core Serialize → FRB 桥 → dto.dart → mock）。

## 外部文档

- Tauri 2：<https://tauri.app/llms-full.txt>
- React 19：<https://react.dev/reference/react>
- Tailwind CSS v4：<https://tailwindcss.com/docs>
- flutter_rust_bridge：<https://fzyzcjy.github.io/flutter_rust_bridge/>
- 项目内权威文档：`docs/01-08`（产品/架构/数据/UI 规格/backlog/发布与更新流程）、`docs/adr/0001-0006`（SQLCipher/通知/双端拆分/发布工程/回收站边界/桌面驻留内存）
