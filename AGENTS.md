# AGENTS.md

> 本文件是本项目 AI 编码工具的**单一真相源**。其它工具入口若存在，只应引用本文件，不要重复维护规则。

Orbit（循迹）是本地优先的跨平台任务管理应用：待办（项目/任务/子任务/标签/提醒/评论）+ 云同步 + 全量备份。业务逻辑全量下沉 Rust 核心（`crates/orbit-core`），桌面 Tauri 壳与移动 Flutter 壳只保留薄 UI 与桥接。无账号、无遥测、端到端加密。

## 快速原则

- **中文工作**：对话、commit message、文档、CHANGELOG 全部中文。commit 格式 `type(scope): 中文描述`（Conventional Commits + 中文正文要点列表），如 `feat(stats): 完成热力图重构对齐 wait-home——按年视图+年份切换`。
- **只做待办域，不做生活记录域**：功能面锁死在「项目/任务/子任务/标签/提醒/评论 + 日历 + 统计 + 云同步/备份」（首段与下方[架构边界](#架构边界)的「明确不做」清单是同一口径的两处落点）。蓝本 wait-home 里的非待办业务模块一律**不复刻、也不新造**。判据一句话：**挂不上「任务」或「任务的日期」就是生活记录域**——日历视图的农历/节气/节假日底座**不算**（它是任务日期的语义，不是用户另记的一本账）。**蓝本里有 ≠ 本仓要做**；查蓝本是否存在某功能必须**中文模块名与英文符号并用**（wait-home 的倒数日叫「重要日期 / important_date / important_events」，只 grep `Countdown|倒数|纪念` 会误判成「蓝本零覆盖」——2026-10-05 倒数日被误建、误写「本仓自订规格」的根因）。要加这类模块先在 `docs/07` 立项对照本条；已撤回项见 `docs/07` 的 ⛔ 行。
- **单一功能单一 commit**：一批工作内每个功能独立成 commit；动 git 前先 `git status --short` 核对全清单，**逐文件 add**（目录通配会混入并发会话 WIP），add 后必查 `git diff --cached --name-only` 再 commit；commit 后核对 `git log` 归属防重复提交。
- **业务全部下沉 Rust 核心**：新功能逻辑写在 `orbit-core` 的 `api/*_api.rs`，桌面 Tauri command（`apps/desktop/src-tauri/src/commands/`）与移动 FRB 桥（`crates/orbit-flutter/src/api/`）都是薄壳转发，不写业务。命令在 `src-tauri/src/lib.rs` 的 `invoke_handler` 集中注册。
- **只读聚合不进同步白名单**：统计类新表/新读路径不改 `sync_registry.rs`；新增可同步表必须同步更新 SYNCABLE_TABLES + modules.rs 计数断言。
- **软删语义**：业务表全带 `uuid`（同步主键，UNIQUE 索引防僵尸行复活）/`is_deleted`/`version`/毫秒时间戳三件套；删除一律软删墓碑进回收站，物理 DELETE 只存在于回收站 purge 路径（ADR 0005 延迟提交边界）。
- **日期分桶按本地时区日界**：毫秒时间戳在 Rust 侧用 chrono::Local 换算本地日期后再分桶（`local_day_index`），前端 Date/Dart 本地语义对齐；不要在 SQL 里按 UTC 天分组。
- **迁移文件增量策略**：DDL 只在 `orbit-core/src/db/migrations/`，`0001_init.sql` 为冻结基线永不改；新增结构默认追加 `NNNN_xxx.sql`（sqlx 按文件名顺序执行，老库只跑新增文件，不删库）。加列必须带 `DEFAULT`，加表/加索引用 `IF NOT EXISTS`，破坏性变更走重建表；未发布的多文件可合并为一个，已发布文件永不改/删。新字段补行尾中文注释（DDL 注释随 sqlite_master 落库，GUI 可见），存量库升级靠增量迁移原地完成（仅大版本基线重建才走删库+云同步/`.orsync`恢复）。
- **双强调色体系勿混用**：待办模块色 `TODO_ACCENT = #3B82F6`（checkbox/选中态/图表）与全局主题色 `themeAccent = #4E8CFF`（OrbitFab/Spinner，shadcn `primary` 角色）两个 Context 并存（docs/05 §2.1）。
- **悬浮提示统一主题色底白字**：桌面所有 tooltip 对齐 `ui/tooltip.tsx` 原语口径 `bg-primary text-primary-foreground`（手搓 Portal 提示也不得用 `bg-popover` 灰白弹层色——2026-09-10 热力图曾踩坑）；移动端原生 `Tooltip` 由 `app_theme.dart` 全局 `tooltipTheme` 统一（强调色底白字），不逐处覆写。
- **滚动条全项目标准**：桌面全局 `index.css` 定义 `::-webkit-scrollbar` 10px 透明轨道主题色圆角滑块，原生 `overflow-auto` 容器自动继承——**禁设 `scrollbar-width` 非 auto 值**（会禁用 webkit 自定义退化为系统原生条）；需隐藏的用三件套 `scrollbar-width:none + -ms-overflow-style:none + ::-webkit-scrollbar display:none`。移动端全局 `ScrollbarThemeData`（app_theme.dart）只对显式 Scrollbar 生效，`SingleChildScrollView` 惯例不挂。
- **UI 一律走组件库/原语层，缺件自造同风格原语**：桌面先取 `components/ui/` 原语（shadcn 体系）；移动先取 flutter_miuix（`Miuix*`，2026-11-01 起为组件主体，经 `shared/widgets/shadcn/orbit_*.dart` 原语层使用）；库内无等价物就**自绘一个与既有设计语言一致的组件并沉淀进原语层**（桌面 `components/ui/`、移动 `shared/widgets/shadcn/orbit_*.dart`），吃主题 token、不写裸魔法值。业务/页面层禁止裸用系统原生控件外观（`<input type="number">` 原生 spinner、`<select>` 原生下拉、`<input type="date">` 原生日期面板等）与手搓灰白弹层——2026-10-22 每日容量数字输入用原生 number spinner、与主题完全不搭，改 `NumberInput` 原语收口。
- **设置/配置页的档位选择统一参考移动端「外观」页**（2026-11-04 起，细则见「移动端约定（Flutter）」）：判据是「点开前就得看见当前档」——一律走 `shared/widgets/shadcn/orbit_dropdown_preference.dart` 的 `OrbitDropdownPreference<T>`（行内当前值 + 上下双箭头 + 就地展开下拉，当前档蓝字打勾），**不要**手搓灰底胶囊浮动标签行 + 右箭头，也**不要**对这类行调 `showSelectBottomSheet`；下拉展开时的按压灰底（"阴影"）必须横贯整卡撑满，不能让卡片内边距把它缩成一小块。
- **所有弹出选择/菜单统一「今天」页头样式**（2026-11-05 起）：卡面与条目行一律与任务列表页头 ⋮ 菜单（`OrbitGlassMenu`）同源——`MiuixGlassPanel` 玻璃卡（24 圆角、`floating` 阴影、`puredThinGlass` + blur 32；无采样器时库内退实色白卡）+ `MiuixGlassPopupItem` 行（44 最小行高、24 图标位、选中转强调色并在行尾打勾、组间 0.5 分隔线 indent 20）。设置项走 `OrbitDropdownPreference`、通用选择走 `showOrbitSelectPopup`、**锚在任意触发钮上且需 Overlay 直挂（输入框焦点/键盘全程不落）+ 多选常驻连选的菜单走 `shared/widgets/shadcn/orbit_menu_popup.dart` 的 `showOrbitMenuPopup`**（承载**与底栏「更多」同款**：传 `transformAnchor` + `anchorContent` 时走 `MiuixGlassTransformPopup`，卡片从按钮轮廓连续形变长出，关闭同样播逆形变、退场完成才移除；宿主销毁/路由开始退出时用会话 `dispose()` 立即清理，不在失效锚点上续播；只给矩形 `anchor` 时退 `MiuixGlassDropdownPopup`。卡面/行与上述同源；快速添加的日期 / 优先级 / 标签 / 项目 / 更多五处已接入；底部表单与排程作息 6 处走 `showOrbitSelectMenu` Overlay 版，宿主补 `PopScope` 兜底返回键）、下拉面板走 `OrbitDropdownPanelView`（多选传 `closeOnTap: false`）、底部动作菜单 `showMoreActionsSheet` 亦同套行渲染；**不要**再直用库内 `MiuixWindowDropdownPreference` / `MiuixWindowListPopup`（白卡小圆角 + `MiuixDropdownImpl` 行），不要自绘实时模糊卡面（无采样器时会糊成灰白半透明），也不要另手搓条目行。
- **所有底部弹层一律浮起圆角卡片 + 间距统一口径**（2026-11-04 起，数值与例外见「移动端约定（Flutter）」）：不再有贴边顶圆角抽屉——承载底色透明、遮罩 0.32，卡片由 `OrbitFloatingSheetCard` / `OrbitGlassSheet` / `OrbitSheetScaffold` 自绘（左/右/下各 16 留白、四角 `AppShapes.xl`=28）；形状/动效走 `bottomSheetTopShape`/`bottomSheetMotion`，内容内边距与字段间距一律取 `AppDimens`，离散色板走 `OrbitColorSwatches`；页面不自写 padding、不写裸间距数字、不逐弹层另设档。
- **无 prettier 约定**：仓库不配 prettier，`npx prettier` 现跑会重排整文件产生巨型噪音 diff；已跑坏的用 `git checkout HEAD --` 恢复后手工重放。
- **文档同步链**：完成 07 竞品报告任一编号 backlog 项时——07 文档对应行划线补 `✅ 已完成（日期+一句话要点）`、CHANGELOG Unreleased 补条目、文档内过时描述随代码一并修正（07 是 backlog 唯一状态源）。
- **版本发版走流程而非改数字**：版本真值只在 `apps/desktop/package.json`，同步走 `pnpm bump`；「改版本号」请求按下方[版本发布与更新流程](#版本发布与更新流程改版本号时自动执行)全流程执行（脚本 + 两份更新日志 + 守护测试绿），详见 `docs/08_发布与更新流程.md`。
- **尊重并发会话**：同一仓库常有并行会话 WIP；暂存区改动可能被并发 commit 带走或清空，收尾必须核对 HEAD 归属；不回滚非本批改动。**同一文件混有双方改动时按「本批功能可编译的最小完整集」逐文件提交**——交织到同一 hunk、无法拆分的 WIP 一并带入并在回复说明，纯并发 WIP 文件留在工作区不纳入；提交后说明 HEAD 与工作区可能存在的视觉差异（2026-11-04 确认弹层提交踩坑）。

## 技术栈

| 维度 | 选型 |
| --- | --- |
| 桌面 | Tauri 2（Windows / macOS / Linux），嵌套独立 Cargo workspace `apps/desktop/src-tauri` |
| 前端 | React 19 + TypeScript（strict）+ Vite |
| UI | shadcn/ui 风格（Radix 原语）+ Tailwind CSS v4（CSS-first，无 tailwind.config） |
| 状态 | React Query（queryKey 约定见下）+ 局部 zustand；localStorage 持久化视图态 |
| 移动 | Flutter（stable，CI 锁 3.44.2）+ flutter_rust_bridge 2.12（codegen 锁 2.12.0） |
| 状态(移动) | Riverpod；移动 UI 组件体系 = **flutter_miuix 1.3.0（精确锁版，HyperOS/OS4 玻璃，组件主体）** + shadcn_flutter 0.0.53（精确锁版，**仅 LucideIcons 图标字体源**）+ table_calendar/fl_chart，库内无等价物的组件自绘同风格并沉淀 `shared/widgets/shadcn/` |
| 核心 | Rust edition 工具链锁 `rust-toolchain.toml` 1.96，clippy + rustfmt |
| 加密 | SQLCipher 本地库 + AES-256-GCM 云同步 E2E（PBKDF2 600k 单调不降级） |
| 质量 | tsc / vitest 4 / Playwright 冒烟 / cargo test / flutter analyze+test；内存门禁（`perf-metrics/`）；CI 四 job（web/rust-core/flutter-mobile 含 FRB codegen 一致性门禁/perf-gate） |

## 架构边界

**明确不做（生活记录域，2026-10-05 复核）**

下列蓝本模块**不复刻**，也不以「竞品有所以我们也要」的名义新造：重要日期/倒数日（`important_events`；蓝本侧含农历、多档重复、多档提醒、卡片墙四段分组、沉浸式详情页、日历联动、桌面提醒钩子，移动端 15 个文件）、会员卡·礼品卡、经期·孕期、习惯打卡、番茄钟、记账·工资、收藏（书/影/游/卡）、家庭成员·公司设备、速记·抽奖、出行行程。新增模块前先对 `docs/02 §四` 裁剪清单与本清单；确有必要的诉求走 `docs/07` 立项，判据仍是上方「挂得上任务或任务的日期」。

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
      shared/widgets/    # 跨模块组件：controller_disposer 等生命周期工具 +
                         # shadcn/（设计系统 v3 原语层，orbit_*.dart）
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
cargo test --workspace    # 同上（云同步用例走 tests/common 的零依赖假服务，干净机器必须全绿；
                          # 需要真 WebDAV/MinIO 的活体方言用例带 #[ignore]，手工 --ignored 跑）
cargo test -p orbit-core --test sync_fault_matrix   # CI 同名步骤（零外部依赖，本机约 4.5 分钟）
# 注：本机若常驻 HTTP_PROXY/HTTPS_PROXY，reqwest 会按代理约定发 absolute-form 请求行；夹具已按
# RFC 7230 §5.3.2 归一为路径。日后若再见到「服务端对象键/请求行里出现完整 URL」的断言失败，
# 先查代理环境变量，不要改断言、也不要给生产 HttpClient 加 no_proxy（会剥夺用户的公司代理能力）。
# 注：若大批用例同时死在 `tempfile`/`write_atomic`/`backup_*` 且报
# PermissionDenied（形如 %TEMP%\.tmpXXXX 拒绝访问），是本机 %TEMP% 对测试子进程
# 拒写（PowerShell 自己能写、cargo 子进程不能），不是代码回归：把 TEMP/TMP 指到
# 仓库内目录复跑即可（`$env:TEMP="$PWD\target\tmp"; $env:TMP=$env:TEMP`）。
cd apps/desktop/src-tauri && cargo check   # 桌面壳单独检查（嵌套 workspace）
# 桌面壳**不是 rustfmt-clean**（HEAD 即有数个文件不合规）：在该目录跑裸
# `cargo fmt` 会顺手重排 9+ 个他人文件产生噪音 diff；只格式化自己改的那个文件用
# `rustfmt --edition 2021 src/commands/xxx.rs`（根 workspace 的 `cargo fmt --all`
# 是 FRB codegen 的既定步骤，两者不要混用）
flutter_rust_bridge_codegen generate \
  --config-file crates/orbit-flutter/flutter_rust_bridge.yaml   # FRB codegen 后须 cargo fmt --all
pnpm frb                  # 上面两步 + 仅格式化生成物 + git 差异自检（等价 CI 门禁，改了桥层就跑这个；
                          # 漏跑 fmt 时 CI 必红的差异永远只是那两行 use 排序，见 scripts/frb-codegen.mjs）

# 移动端（apps/mobile）
flutter analyze
flutter test
flutter test test/xxx_test.dart          # 定向用例
# vitest 必须在 apps/desktop 内跑（根目录跑会因路径解析假红）

# 内存门禁（详见 docs/09_内存与性能治理专项-2026-09-18.md）
node perf-metrics/audit-unbounded.mjs --gate   # 无界累加容器审计（零依赖，秒级）
node perf-metrics/growth-curve.mjs --gate      # 1k/5k/10k 增长曲线与泄漏判据（需先 pnpm build）
node perf-metrics/growth-curve.mjs --record    # 采纳新基线：只回写 baselines.json 的 measured
node perf-metrics/operation-probe.mjs --gate   # 操作级四场景（备份导出/导入、CSV 导入、附件写入）；首次会构建 release example
node perf-metrics/operation-probe.mjs --record # 只回写 operation-baselines.json 的 measured/datasets，不动 thresholds
node perf-metrics/memory3.mjs --gate           # 真机 Tauri exe 口径（Windows 本地，不入 CI；缺 exe/dist 时 exit 2）
node perf-metrics/memory3.mjs --record         # 回写 baselines.json#desktopExe.measured

# 双端一致性门禁（入 CI perf-gate job；零依赖，秒级）
node perf-metrics/mobile-bridge-audit.mjs      # 禁止新增「整文件 List<int> 跨桥」的桥接口
node perf-metrics/bridge-parity.mjs            # 桌面 Tauri 命令 vs 移动 FRB 函数：禁止单端能力未登记

# 发版（详见 docs/08_发布与更新流程.md）
pnpm bump 0.2.0           # 升版：写源 + 同步五处清单 + 两个 Cargo.lock
pnpm bump:check           # 只校验一致性（零写入，CI/本地通用）
```

- CI（`.github/workflows/ci.yml`）四 job：web（typecheck+vitest+build+e2e）/ rust-core（cargo check --workspace --all-targets + cargo test --workspace --lib + `cargo test -p orbit-core --test sync_fault_matrix`）/ flutter-mobile（FRB codegen 一致性 + analyze + test）/ perf-gate（无界审计 + 内存增长曲线）。提交前本地跑通同等检查。
- `sync_fault_matrix` 单独点名入 CI 的原因：它自带零依赖假服务（`tests/common`，std `TcpListener` 内存假 WebDAV/S3），干净机器必全绿，且是 F22 条件头上线、F23 分片协议的**唯一网络级证据**；`--lib` 口径下整份 `tests/` 都不执行，故与「要真 WebDAV 的 m4_sync_e2e」区别对待——后者仍是本机口径的已知非回归失败。夹具的请求行解析必须容忍 origin-form 与 absolute-form 两种形态（本机常驻 `HTTP_PROXY` 时 reqwest 发后者）。
- e2e/Playwright 专用端口 **5273**（非 vite 默认 5173，防撞其他项目 dev server）；strictPort 双保险。内存门禁端口 **5275**（`growth-curve` 自起 dist 静态服务）。

## 版本发布与更新流程（改版本号时自动执行）

用户说「改版本号 / 升版本 / bump 到 X.Y.Z / 发版」时，按下列顺序**完整执行**，不是只改数字。流程权威文档 `docs/08_发布与更新流程.md`（优化蓝本 = qraft 的发布流程），签名矩阵见 `docs/adr/0004-release-engineering.md`。

- **版本单一来源**：只在 `apps/desktop/package.json#version` 维护真值，其余四处 + 两个 `Cargo.lock` 一律由 `scripts/bump-version.mjs` 写入，**不要手改**；前端版本靠 `vite.config.ts` 构建期注入的 `__APP_VERSION__`（关于页等不得硬编码版本号）。
- **发版六步**：
  1. `pnpm bump X.Y.Z`（同步 `tauri.conf.json` / 桌面壳 `Cargo.toml [package]` / 根 `Cargo.toml [workspace.package]` / `pubspec.yaml`（`+build` 自增）/ 两个 lock），确认输出 `VERSION_SYNC_OK`；
  2. 提炼变更：`git log v<上一 tag>..HEAD --oneline`，按功能合并同类提交，忽略 docs/chore/style 噪声；
  3. **两份更新日志同一次提交写完**：`CHANGELOG.md`（`[Unreleased]` 段改为 `## [X.Y.Z] - YYYY-MM-DD`）+ `apps/desktop/src/lib/changelog.ts`（`CHANGELOG_VERSIONS` 头部插入同版本条目）。只写一处 → 应用内关于页永久缺版本（qraft 0.2.7 的历史事故）；
  4. 本地跑通 CI 等价检查：`pnpm typecheck` / `pnpm test` / `pnpm e2e` / `pnpm lint:rust` / 内存门禁（`perf-metrics/audit-unbounded.mjs --gate` + `growth-curve.mjs --gate`）（`src/test/release-consistency.test.ts` 会把「版本与日志漂移」直接判红）；
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
- FRB：改桥接 API 后必须跑 codegen + `cargo fmt --all` 再提交（CI 门禁校验生成物一致性；直接 `pnpm frb` 一次跑完 codegen + 生成物格式化 + 差异自检）；codegen 会顺带同步 rust 源注释到 dart 产物。
- FRB 生成物不只看 `pub` 函数面：`api/<domain>.rs` 里**增删/改名任何函数（含私有 fn）**都会改写 dart 产物首行那句「ignored because they are not marked as `pub`」注释清单，漏重生成即门禁红（F24 删桥层私有 `now_ms` 未重生成踩坑）。判据：跑完 codegen 后 `git diff apps/mobile/lib/src/rust crates/orbit-flutter/src/frb_generated.rs` 必须为空；收尾**只 add 生成物路径**——`cargo fmt --all` 会顺带重排 orbit-core 若干既有非 rustfmt-clean 文件（噪音 diff，不属于本批改动）。

## 桌面前端约定

**React 与组件**

- React 19 函数组件 + hooks；import 类型用 inline `type` 修饰符；路径别名 `@/*`。
- 非显然设计决策写中文块注释在文件/函数头部（仓库既有惯例）；不写历史残留注释、不引用 TODO 阶段号。
- 视觉复刻蓝本是 wait-home（docs/04 像素级规格）：布局尺寸/间距/字阶/色值/交互时序原样保留，不做"顺手优化"；仅 docs/04 §7 列出的不一致点允许偏离。新视图组件先读对应 04/05 章节。

**状态与数据**

- 服务端状态一律 React Query；queryKey 见架构边界节；`staleTime` 2min + `placeholderData: (prev) => prev` 防切 key 闪骨架。
- 桌面写路径可先 patch 缓存提前 paint（`lib/query-patch.ts`，**只改已存在行字段，不增删不重排**），但 db-change 失效链仍是真值收敛者，不得以 `setQueryData`/`select` 替代；重复任务完成等**派生新行**的场景禁止在 TS 复刻引擎规则（沿革：桌面 `db-change` 转发器每次改主密码多一条，`spawn` 出的常驻任务须由进程级 `AtomicBool`/`Once` once-guard 保护，审计脚本看不见任务泄漏）。
- localStorage 键全集（04 §七）：`todo_view_mode`、`todo_sidebar_ungrouped_after`、`color_palette`、`custom_palette_accent`、`theme_mode`、`font_family/font_size_level/font_weight_level`；新键遵循同风格命名。

**样式与 UI**

- Tailwind v4 CSS-first：语义 token 全在 `src/index.css`（OKLCH 主题变量），className 合并用 `cn()`；图标 lucide-react。
- **先取 `components/ui/` 原语，缺件自造并沉淀**：新增 UI 一律先找现有 shadcn 原语（`Button`/`Input`/`Select`/`Popover`/`NumberInput`…），**没有等价物的自绘一个与 shadcn New York 语言一致的组件放进 `components/ui/`**——吃 `index.css` 语义 token（`border-input`/`ring-ring`/`bg-accent`…）、`cn()` 合并、`data-slot` 标记，可纯函数化的逻辑抽出来 + 同目录 `.test.ts`；业务/页面层禁止裸写一次性样式或系统原生控件外观（原生 number spinner、原生 `select`/`date` 面板、手搓 `bg-popover` 灰白弹层——2026-10-22 每日容量踩坑）。
- 双强调色：`TODO_ACCENT` 等常量上收 `features/todo/shared/constants.ts`（硬编码不走 cfg 动态读取——04 §5.1 决策）；优先级六档色 `PRIORITY_COLOR`、状态色 `STATUS_COLOR` 同文件单口径。
- 共享纯函数（排序/分档/日期/位置）放 `features/todo/shared/` + 同目录 `.test.ts` 共置。
- 满高预览区不嵌 Radix ScrollArea（viewport 的 table 包裹打断高度链——qraft 同款坑），用 `div.min-h-0 flex-1 overflow-auto`。
- PopoverContent 内禁嵌自带 Popover 控件（Radix 焦点陷阱），两段式避嵌套。
- **右键菜单里的操作确认一律「菜单内联」，不得先收菜单再弹外部小窗**：项目右键的「归档项目 / 删除项目」点击后菜单保持展开（`DropdownMenuItem.onSelect` 里 `event.preventDefault()`，用 `ContextMenuBase.onOpenChange` 复位内联态），在原菜单位置展开确认区（说明 + 取消/确认）。两条硬理由：①先收菜单再弹小窗，视觉上菜单「缩回去一下」再冒出第二个弹层，锚点漂移；②Radix 菜单 `modal` 关闭会把焦点还给右键哨兵，同一次交互里新开的 Popover 会被判 focusOutside 立即自关（现象＝「点了没反应」，2026-10-29 归档踩坑）。语气口径：归档/恢复用主题色（可逆操作），删除用红色；项目下有未完成任务时删除确认区只告知「无法删除」不给确认钮。行内图标直接触发的确认（筛选器删除、已归档行恢复）仍走 `ConfirmPopover` 原语。

**测试**

- Vitest（jsdom）：纯函数测试为主，UI 状态逻辑抽 hook/纯函数测；测试与源文件共置 `*.test.ts`。
- 浏览器目检：`pnpm dev`（或 vite --port 5273）+ `window.__orbitMock` 直改内存库 + `emitDbChange()` 触发刷新（绕 IPC 链）；几何断言用 `page.evaluate` 读 getBoundingClientRect 对齐（IAB 里 Playwright click 常超时，改 evaluate 直点；hover 需 cua.move 真实移动触发合成事件）。
- e2e 冒烟（根 `e2e/smoke.spec.ts`）跑 mock IPC 纯浏览器环境；改 IPC 契约必须同步 `src/test/ipc-mock.ts`。

## 移动端约定（Flutter）

- 路由 `core/routing/app_router.dart`（栈式导航）；页面结构 = OrbitPageHeader（Stack 顶部，**OS4 液态玻璃页头**，`shared/widgets/shadcn/orbit_page_header.dart`）+ 整页 ListView 滚动（**必须整页滚动，不要 Column+Expanded 固定高度**——曾致内容溢出）。页头几何（56dp 单行 + 状态栏避让 + `titleWidget` 槽 + 进度线）**逐像素保留**，只换表面材质（见下条 OS4 玻璃）。
- Riverpod：Provider 按 `modules/todo/providers/`；`FutureProvider.family` 家族化参数缓存（如 statsProvider(year)）；db-change 后 `invalidateBusinessCaches` 统一失效。
- 主题 token 全在 `core/theme/`：`AppColors.ofContext(context)` 取语义色（分层表面 `background`/`surface`/`surfaceSecondary`/`surfaceElevated` + `outline` 描边 + 三级文字）、`AppDimens` 间距（刻度 `spaceN` + 语义 `pageInline`/`cardPadding`/`cardGap`/`sectionGap`/`rowInline`/`rowVertical`）、`AppShapes` 圆角（`xs`/`small`/`medium`/`large`/`xl`＝6/10/14/20/28，特殊值 `AppShapes.of(n)`）、`AppElevation` 阴影（`e1`~`e4`）、`OrbitAccents.todoAccent/themeAccent` 双强调色——**不写裸魔法值**。
- **设计系统 v3（2026-09-21）视觉语言 + 双主题装配（2026-11-01 收口）**：对比靠 **1px 描边 + 表面分层**，阴影只留给浮层；玻璃三件套已删（`AppDimens` 的 4 个模糊 token 一并移除），OS4 玻璃由 flutter_miuix 提供。`MaterialApp.router` + builder 内 **Material 主题（`app_theme.dart`，服务 Scaffold/弹层/输入基建）+ Miuix 主题（`miuix_theme.dart` 的 `OrbitMiuixTheme`）** 双主题并存，两者从同一份 `core/theme` token 派生；`ShadcnLayer` / `core/theme/shadcn_theme.dart` 已随组件面全量 Miuix 化删除，**不要再引入 shadcn 组件**（`shadcn_flutter` 仅剩 LucideIcons 图标常量，见 `icon_map.dart`）。保留 v2 的分层白卡思想与 8pt 网格。
- **新组件优先 flutter_miuix，缺了自绘同风格件沉淀原语层**：新增 UI 一律先取 flutter_miuix 的 HyperOS 组件（`Miuix*`，squircle/弹簧/OS4 玻璃）并优先经原语层暴露；shadcn_flutter 已退为图标字体源，**禁止新增 `sh.*` 组件用法**；库内没有等价物的（看板、热力图、带农历/休班语义的月历等），**自绘一个与既有语言一致的组件，并沉淀进 `lib/shared/widgets/shadcn/`**——文件名 `orbit_*.dart`、吃 `core/theme` token、不写裸魔法值；页面只允许依赖该原语层与 miuix 基础组件，禁止在页面里裸写一次性样式。迁移时高频符号保留原名（`WaitToast`/`SectionCard`/`SelectItem` 等，避免数百处无谓 diff），新组件一律 `Orbit*` 命名。
- **原语层的承载 = flutter_miuix（2026-10-31 起）**：卡片 `OrbitCard`→`MiuixCard`（squircle 超椭圆）、勾选框 `OrbitCheckbox`→`MiuixCheckbox`（圆形描画对勾，**完成态仍取弱化灰**、优先级圆环本层自绘）、加载态 `OrbitSpinner`→`MiuixInfiniteProgressIndicator`；按钮/图标钮/开关/进度条/筛选标签/分割线一律走 `OrbitButton`/`OrbitIconButton`/`OrbitSwitch`/`OrbitProgressBar`/`OrbitFilterChip`/`OrbitDivider`（**页面层禁止再裸用 Material `FilledButton`/`IconButton`/`Switch`/`LinearProgressIndicator`/`Divider`/`ChoiceChip`**，`flutter analyze` 不拦但口径已定）。`OrbitIconButton` 保留 `tooltip`/`visualDensity`/`constraints`/`padding`/`iconSize` 兼容参数——`tooltip` 内部仍是 Material `Tooltip`（64 条 `find.byTooltip` 断言依赖），不要换成 `MiuixTooltip`。
- **OS4 玻璃（`MiuixGlass*`）接线约束**：①玻璃消费方（页头/底栏/浮层）**必须**在 `MiuixLayerBackdropCapture` 捕获树**之外**且为兄弟节点，否则自采样（栏体把自己拍进背景、越糊越实）；壳的接线见 `home_shell.dart`（捕获树只包页面内容，`OrbitGlassScope` 向下暴露同一 backdrop）。②没有采样器时页头自动回落实时 `BackdropFilter`，底栏回落实色，**不会黑屏**。③`MiuixGlassNavigationBar` 自身**不吃** `viewPadding.bottom`，底栏必须自己补手势区让位（`orbit_bottom_nav.dart`）。④OS4 shader 在 `packages/flutter_miuix/shaders/`，构建后会进 APK；`MiuixGlassRendering.loadError` 可查降级原因。组件映射与取舍全表见 `docs/16`。
- **根级推入页玻璃壳**（2026-11-05）：`app_router.dart` 的 `pageSlideFromRight` 默认用 `OrbitGlassPage` 包住页面，自建 `MiuixLayerBackdropCapture` 并向下暴露 `OrbitGlassScope`——通知历史/备份/诊断等 `/settings/*` 与任务详情这类根级路由与 HomeShell 是兄弟，不包会取不到采样器、锚定弹层只能退实色白卡。页签栈内的入栈页已在 HomeShell 捕获树里，显式传 `glassPage: false`，避免嵌套采样；页面若自己已包 `OrbitGlassPage`（外观页）也传 false。
- **动效口径参考微软 To-Do 移动端**（勾选确认、完成划线、行入场、拖拽抬起、抽屉轻快入场、触感反馈）；动效参数统一收口 `core/theme/app_motion.dart`（时长/曲线/缩放档；视图内禁裸 `Duration(...)` 与裸 `Curves.*`），清单与有意边界见 docs/05 §九。视觉蓝本仍是 wait-home——该章只加"动作过程"，不改任何像素规格。
- **拖拽浮层（`proxyDecorator`）统一口径**：`Transform.scale(1 + (dragLiftScale-1) * elevated)` + `Material(elevation: 6 * elevated, medium 圆角, Clip.antiAlias, color: lerp(transparent → surface, elevated))` + 起止 `HapticFeedback.selectionClick()`。底面必须随抬起渐变为实色 surface——扁平行本身透明，常驻透明会透出页面底色变成灰块（2026-09-26 清单项目行与功能模块行两次实测）；`elevated` 取 `AppMotion.standard.transform(Tween(0→1).evaluate(animation))`。
- 日历今天/选中强调色统一取 `OrbitAccents.themeAccent`（#4E8CFF，与桌面端日历 `--primary`＝themeAccent 体系同源）：`modules/todo/calendar_screen.dart`（月历今日实心块与选中描边、右栏选中日高亮底、今日文字与「今天」徽标）和 `year_overview_page.dart`（迷你历今日实心格/周末数字/当前月标题）。主题由 token 派生（`miuix_theme.dart` 的 `primary`/`secondary` 分别取 themeAccent/todoAccent），组件仍建议显式取 `OrbitAccents.themeAccent` 以绑定语义。
- 图表：统计页条形/环形占比用 `fl_chart`（1.2.0 精确锁版）；**热力图 fl_chart 不支持**（shadcn `tracker` 只是单行条带，承载不了 7 行 × 53 列年历网格），由 `shared/widgets/shadcn/orbit_heatmap.dart` 用 token 色阶自组网格——色阶取 `OrbitAccents.todoAccent` 的 22/45/68/90% 四档。
- 布局对齐坑：行标签/占位格与实际格必须同 padding 规则（末行不加尾距，否则固定高 Column 溢出 3px）；`Text.rich` 在 widget 测试 `find.text` 不可见——标题行用 Row + 独立 Text。
- 测试：`MockOrbitBridge` 注入 `orbitBridgeProvider.overrideWithValue` 冒烟渲染；纯 Dart test 直接调 bridge 排除 UI 层（widget 卡死超时先分离归因）。
- toast 用 `WaitToast`（`shared/widgets/shadcn/orbit_toast.dart`，底层 = miuix `MiuixSnackbarHost` 队列 + squircle 毛玻璃卡面，支持 action 钮与横滑关闭；宿主 `OrbitToastHost` 挂在根装配 `app.dart` 的 Stack 里）；空态用 `EmptyState`（`shared/widgets/shadcn/orbit_empty_state.dart`，让出页头后剩余视口垂直居中）。**测试壳必须与生产根装配同构**——统一用 `test/support/orbit_test_app.dart` 的 `orbitTestApp` / `orbitTestAppRouter`（含 `OrbitToastHost`；toast 相关用例收尾用 `drainToastTimers`）；miuix 队列按宿主挂载实例隔离，不要在用例间共享。
- **弹层体系现状（2026-11-01 复核）**：底部抽屉一律 `showModalBottomSheet(useRootNavigator: true)` + `OrbitSheetScaffold`（2026-09-21 从 shadcn `SheetConfiguration` 回退，见 `orbit_sheets.dart` 头注释）；抽屉在根 Navigator Overlay 之内，内容里的 Material `Tooltip` / `showModalBottomSheet` / `showDialog` 均正常可用。旧「shadcn 弹层三坑」（`DrawerOverlay` / `showOverlay` / `sh.closeOverlay`）已随 shadcn 弹层退场作废，**不要再按旧文档挂 `DrawerOverlay`**。
- **测试收尾推掉 toast 计时器**：`WaitToast` 的停留时长交给 shadcn 库内 `Timer`（`showDuration` 非空，底层 `ToastEntry.showDuration = null` 的「常驻」公开入口传不进去，故「不自动收」用 `WaitToast.holdForever` 代理），该 Timer 在条目 dispose 时不取消——用例若在它触发前结束会命中 flutter_test 的「A Timer is still pending」，收尾调 `drainToastTimers(tester)`（`test/support/orbit_test_app.dart`，常驻档传 `holdForever: true`）。
- **品牌图与启动屏同源**：移动端启动器图标（`mipmap-*/ic_launcher.png`）、原生启动屏图（`mipmap-xxxhdpi/launch_image.png`）、Flutter 等待画面资产（`assets/app_icon.png`）三处均出自 `scripts/generate_icons.py`，与桌面端**同一枚图标**——换版一次产出全平台，不手改单端位图；启动屏与 `BootGate` booting 态同口径：白底 + 居中品牌图（`AppDimens.splashLogoSize`），亮暗主题共用白底（`launch_bg` 双 values 同值）；API 31+ 还须在 `values-v31`/`values-night-v31` 显式 `windowSplashScreenBackground` 锁白（night 限定符优先于 version，两份缺一即深色下变黑），并显式 `windowSplashScreenAnimatedIcon`＝自适应前景层 + `windowSplashScreenIconBackgroundColor`＝`@color/ic_launcher_background`；启动器图标**必须走自适应分层图标**（`mipmap-anydpi-v26`，背景层 `@color/ic_launcher_background` **透明** + `ic_launcher_foreground` 前景层，Manifest 带 `roundIcon`，脚本产出）——**透明底与桌面端一致，不铺白底/底板**：缺分层时系统会给 legacy 位图自造模糊底板（发灰脏底），铺白底则出现白色圆角方块（2026-09-19 两次实测反馈）；图标像素一律按 **2x 规格**给（如 48dp 图标给 96px、108dp 画布给 216px）——Android 按目录 bucket 换算 dp 后自行缩放，给足像素只赚清晰度，而启动器与系统/OEM 启动画面都会放大绘制，1x 像素会被放糊。
- **单选类交互统一用页头菜单同源玻璃浮层**（2026-11-03 起，取代旧「一律底部抽屉」口径）：单选「从一组值里挑一个」一律走 `shared/widgets/shadcn/orbit_select_popup.dart` 的 `showOrbitSelectPopup`（兼容名 `showSelectBottomSheet` 保留并直接转发，21 处存量调用点零改动；底部表单/弹层 6 处已迁 `showOrbitSelectMenu`，宿主补 `PopScope` 兜底返回键）——行渲染复用页头 ⋮ 菜单的 `MiuixGlassPopupItem`（24 图标位 / 44 最小行高 / 选中转强调色并在行尾打勾），卡面走库内 `MiuixGlassPanel`（`puredThinGlass` + blur 32，与 ⋮ 菜单同档；无采样器退实色白卡，不叠实时模糊）；**贴触发行下沿弹出**（承载 = 库内 `MiuixGlassDropdownPopup`，落位/翻转/进场形变都由库内 dropdown motion 承担；点选先播逆形变、完成后再消费库内的 `LocalHistoryEntry` 并 pop；回调里 push 新页时只摘弹层路由），不铺遮罩、点面板外即关、不画标题行（`title` 仅读屏语义），**不再从底部升起玻璃抽屉**；选项带色点/图标/副标题时走同一 API（`SelectItem` 的 `colorDot`/`icon`/`hint`）。**不用** `PopupMenuButton` / `DropdownButton` / `AlertDialog` 列表做选择（`AlertDialog` 已清零，见下条）。**需要 Overlay 直挂（底部输入面板的工具栏按钮，键盘/焦点全程不落）或连选常驻时走 `orbit_menu_popup.dart` 的 `showOrbitMenuPopup`**（2026-11-05：传触发按钮的 `MiuixGlassPopupAnchor` + `anchorContent` 即**与底栏「更多」完全同款**的 `MiuixGlassTransformPopup` 形变；只给矩形则退 dropdown 形变。不新建路由、不抢焦点；`closeOnTap: false` 连选、`groupsBuilder` 每次重建重取勾选态；快速添加五档已接入）；两个入口共用 `OrbitMenuPopupBody`（卡面/行/方向判定/动效单点）。多选（标签 / 云端文件）与色板仍走底部抽屉——勾选清单不是下拉选择，不与单选混用。页面内的二级面板仍可用 Material `showModalBottomSheet`，但其形状/动效常量必须从 `shared/widgets/shadcn/orbit_actions_sheet.dart` 取（`bottomSheetTopShape` / `bottomSheetMotion`），保证与共享弹层族同口径。**例外（2026-09-23）：页头的「当前列表操作」入口走顶部下拉面板**——`shared/widgets/shadcn/orbit_dropdown_panel.dart` 的 `OrbitDropdownPanelView`（只出行；卡面/动效由 `orbit_menu_popup.dart` 的 `OrbitMenuPopupBody` 或 `OrbitGlassMenu` 承担，原手搓 `OrbitFloatCard` / `orbitFloatCardLayout` / `OrbitOverlayCard` 已于 2026-11-05 删除）：锚在触发钮下方、条目成组带分隔线、**带子项的条目就地展开**（展开期间其余条目置灰且不可选，点它们只收起子菜单）、点面板外关闭（不铺遮罩，列表照旧可读）。它承载「对这个列表做什么」（编辑项目 / 视图 / 隐藏已完成 / 筛选 / 排序 / 批量选择），**单选集（视图档 / 排序档 / 看板分组）在面板内就地展开、不再二次弹层**；只有表单类入口（筛选）仍开底部抽屉。理由：免遮罩可见上下文，且「就地展开子项」的层级感是抽屉表达不出来的（参考竞品列表页版式）。
- **档位选择例外（2026-11-04，细化上条「单选类交互」口径）**：上条 `showOrbitSelectPopup` 只管「点开临时挑一个」；**设置/配置页里当前值要常驻行内的档位选择**一律走 `shared/widgets/shadcn/orbit_dropdown_preference.dart` 的 `OrbitDropdownPreference<T>`（与移动端「外观」页 `/settings/appearance` 四行逐像素同款：标题在左 + 尾随当前值 + `MiuixDropdownArrowEndAction` 上下双箭头，点行就地展开玻璃卡并播逆形变、当前档转主题色并打勾）。判据一句话：**点开前就得看见当前档 → 下拉偏好行；只为临时挑一个 → 锚定玻璃浮层**。**承载 = 与「今天」页头 ⋮ 菜单完全同款的 `MiuixGlassTransformPopup` 形变**（2026-11-05 收口：走 `showOrbitMenuPopup` 的 `transformAnchor` + `anchorContentBuilder` 路径，卡片从本行轮廓连续长出、关闭播逆形变、退场完成才移除条目；材质继承锚点表面，不走「无快照退实色」分支）。**不要给整行宽的触发件传 `simplified: true`**：那会在展开期同时隐藏行内容与副本，只剩一块行宽的空白玻璃条从行位置收缩到右侧菜单卡（观感＝「先到中间再到右边」、不流畅，2026-11-05 实测）；页头「今天 ▾」传 true 是因为其触发件只有标题那么窄。副本必须**复用同一个 `MiuixBasicComponent`**（库内行是自定义测量布局，手搓 `Row`+`Expanded` 的弹性分配规则不同，形变期文字会跳位）。**不要**退回 `showOrbitSelectMenu` 的 `MiuixGlassDropdownPopup`（贴行下沿揭开 + 退场叠 `(1-fade)*30` 整卡高斯模糊）——云同步「引擎」弹层曾因此看着像实色白卡、退场「模糊着闪没」，与页头菜单观感不一致。参考图的「外观」页是 Flutter 移动端 `appearance_page.dart`，**不是 Tauri 桌面端**（桌面设置只有「主题」分类、用 pill 按钮）。约束：`current` 必须命中 `items`（存量非档位值补一项「当前」，否则尾随值与对勾双双落空）、禁用态走 `enabled: false`；**按压灰底撑满整卡**（2026-11-04）：外层 `OrbitCard` 传 `padding: EdgeInsets.only(bottom: 16)`（零水平内边距）、行自带 16 水平 `insideMargin`、其余表单字段分组补回 16，行外总开关要作为 `startAction` 并入同一偏好行（否则灰底只盖开关右侧那段），表单列 `crossAxisAlignment: stretch` 保证行拿到整卡宽；几何回归见 `test/sync_settings_page_test.dart`。与旧 `OrbitDropdownTile`（自绘玻璃锚定下拉行）分工明确，设置项不要用它。已接入外观页四行、设置/备份/诊断/模板/通知历史/筛选等设置项；新增设置项直接复用该组件。回归用 `test/support/orbit_test_app.dart` 的 `dropdownPreferencePopupRows()` / `selectedDropdownPreferenceLabels()`（选中态读 `MiuixGlassPopupItem.selected`，不按图标数断言）。**表单里的所有条件行统一同款行样式**（2026-11-05，筛选器构建抽屉实测）：一个表单内不得混排「下拉偏好行」与手搓的「`标签：值` + `chevronRight` 右箭头」两种样式——状态/优先级早已走偏好行，而项目/标签/提醒/附件/未完成子任务五行曾是各自手搓值行（前三行还是底部三态抽屉），同屏两种行语言观感割裂。**取值是三档离散（不限/仅有/仅无）→ 直接用 `OrbitDropdownPreference<T>`**（它就是单选，点行就地展开玻璃菜单，无需另开抽屉）；**取值是多选集合（项目/标签这类勾选多个再确认）→ 只复用行外观、交互仍归多选抽屉**：用 `MiuixBasicComponent` + `MiuixDropdownArrowEndAction`（双箭头）+ 尾随 `MiuixText` 自绘一行（筛选器页的 `_FilterMultiRow`），**不要**把多选硬套进单选原语（会退化成单选、功能倒退）。判据一句话：**同一表单里每一行的「标题 + 尾随值 + 上下双箭头」必须一致**，只有「点开后是单选玻璃菜单还是多选抽屉」按数据形态区分。**行尾动作规则（2026-11-05）**：无值 → 上下双箭头；**有值且该维度可清除（日期/多选这类）→ X 顶替箭头位置，不并排、不占两格**——用户改完立刻能在原位清空，不必再瞄一个额外的叉号（筛选器日期行曾把 X 与 `chevronRight` 并排，被反馈「X 应该把右向图标覆盖」）。实现上统一走筛选器页的 `_FilterConditionRow`（`MiuixBasicComponent` + 可选 `onClear`：非空出 X、为空出双箭头），日期行与项目/标签行都复用它。回归见 `test/saved_filters_screen_test.dart` 的「五行统一为下拉偏好行样式」（断言 `MiuixDropdownArrowEndAction` 数量 = 行数，防止残留右箭头）。
- **确认类交互（尤其删除）统一走 `showConfirmBottomSheet`（兼容名，浮起卡片形态见下条）**：删除 / 清空 / 恢复 / 覆盖导入 / 断开云同步 / 关闭加密等一切「二次确认」一律走 `showConfirmBottomSheet`（`shared/widgets/shadcn/orbit_confirm_sheet.dart`，返回 `Future<bool>`）——`title` + `message`（长预览体走 `content`）+ `confirmLabel`，破坏性操作 `destructive: true`（红底），返回 `bool`（确认 `true`；取消 / 点遮罩 / 下滑一律 `false`），纯告知场景传 `cancelLabel: null` 只留一个按钮；按钮行 = 取消 `OrbitButton.outline` + 确认 `OrbitButton.primary`（原语层，圆角取默认的项目统一档 `AppShapes.medium`＝14，不为弹层单设档）。**确认不再用 `AlertDialog`**（2026-09-20 全量迁移：回收站彻底删除/清空、任务单条与批量删除、项目删除与删除保护提示、筛选器/模板/标签删除、子任务/评论/附件删除、冲突恢复/清空、备份恢复/版本不一致/删除、通知历史清空、关闭加密与清除主密码、明文导出与 CSV 导入确认、断开云同步与清同步密码缓存）——`AlertDialog` 已清零（2026-09-24：最后 6 处密码输入迁入 `orbit_password_sheet.dart` 共享抽屉；普通文本输入如新建项目/新建编辑标签/模板/筛选器走输入型底部抽屉，骨架见 `orbit_sheet_scaffold.dart`）；仅剩附件图片预览用透明 `Dialog`（非选择/确认/输入，不算违规）；理由与选择类同源：抽屉落在拇指区、破坏性按钮有整行触控面积、点遮罩或下滑等同「取消」，不会误触发删除。
- **确认弹层形态（2026-11-04 对齐 miuix 对话框参考，取代上方「弹层体系现状」里的一律贴边抽屉口径）**：`showConfirmBottomSheet` 不再是贴边全宽、带拖拽手柄/左对齐标题的抽屉，而是底部锚定的**浮起圆角卡片**——左/右/下各 16 留白（底边不贴屏幕、四角圆角完整可见）、四角 `AppShapes.xl`＝28、标题与 `message` 居中、无手柄、遮罩 0.32；`content` 与按钮行水平内边距 24，按钮圆角一律走 `OrbitButton` 默认的 `AppShapes.medium`（14，与卡片/输入框同档，docs/05 口径），**不要新增圆角覆写参数、不要传 `pill` 做胶囊**。承载仍是 `showModalBottomSheet(useRootNavigator: true)`（下滑关闭与 `Future<bool>` 语义、25 处调用点不变），但 `backgroundColor` 必须透明、卡片形状由 `Container` 自绘（`confirmDialogCardKey`），并补就近 `Material(type: transparency)` 兜底 `ListTile`/`InkWell` 水波纹。**2026-11-04 起该浮起卡片形态推广到全部底部弹层**（输入型、选择型、玻璃弹层、任务主表单），不再是确认弹层专属；差异只剩确认弹层的内容/按钮行水平内边距 24。形态/圆角/底部留白回归见 `test/orbit_sheets_test.dart`、`test/sheet_spacing_test.dart`。
- **输入型底部弹层间距与承载（2026-11-04 全量收口）**：所有含文本输入 / 表单字段的底部抽屉（密码、新建编辑标签、模板、项目、筛选器、任务表单、描述编辑、重复规则、每日容量、自定义取色/时长、详情标签编辑等）一律遵守：① 承载 `showModalBottomSheet(useRootNavigator: true, isScrollControlled: true)` + `backgroundColor: Colors.transparent` + `shape: bottomSheetTopShape` + `sheetAnimationStyle: bottomSheetMotion`（形状/动效常量的唯一来源是 `orbit_sheets.dart`，页面级调用点不得漏传动效；遮罩 0.32 与承载底色由 `app_theme.dart` 的 `bottomSheetTheme` 统一，`clipBehavior` 必须 `Clip.none`，否则卡片顶角被裁）——**卡片由骨架自绘浮起圆角卡片**：左/右/下各 `space16` 留白、四角 `AppShapes.xl`=28、`popup` 底色、`Material(type: transparency)` 兜水波纹，不用骨架的自绘面板一律显式套 `OrbitFloatingSheetCard`，玻璃弹层套 `OrbitGlassSheet` 并给内部骨架传 `floatingCard: false` 防双层卡面；② 内容用 `OrbitSheetScaffold`，内边距统一交骨架 `contentPadding: EdgeInsets.fromLTRB(AppDimens.space16, 0, AppDimens.space16, AppDimens.space16)`，页面不再自写 `Padding` / `ListView.padding`；③ 骨架几何：标题 `16/16/16/8`（16sp/w600）、手柄 40×4 上距 8、按钮行 `16/16/16/20` + 双钮间隙 12、按钮高 `AppDimens.touchTarget`=48 / 圆角 `AppShapes.medium`=14；④ **字段 / 选择行 / 分区之间的纵向间距一律 `AppDimens.space12`**，`space16` 只用于分区之间，禁写 8/20/24 等其它值与裸数字（`SizedBox(height: ...)`）；⑤ 离散色板一律走 `shared/widgets/shadcn/orbit_color_swatches.dart` 的 `OrbitColorSwatches`（36 色点 / `space6` 补到 48 热区 / `space12` 间距），页面不手写 `Wrap` + 圆形 `Container`。
  - **例外（不适用上条）**：确认弹层 `showConfirmBottomSheet` 的外层自绘卡片保留（内容与按钮行水平内边距 24、无手柄、标题居中），内部骨架传 `floatingCard: false` 防双层；单选玻璃浮层 `showOrbitSelectPopup` 与页头下拉面板不走底部抽屉；即点即关的选择型抽屉无尾栏；选择 / 清单 / 向导型弹层（周回顾、规划今天预览、日期选择器、多选清单）无文本输入，保留既有自绘骨架与紧凑节奏；chip / 星期 / 色点等**控件内部紧凑网格**的 8/4 间距由原语自管，不算字段间距；任务主表单的玻璃 snap 面板保留其复刻几何（docs/05 §4.4）。`space16` 作为分区间距、`space8` 作为说明文字与标题下方的既有节奏不在此条约束内。
  - **回归**：`test/sheet_spacing_test.dart`（字段间距 + 色板几何）、`test/orbit_sheets_test.dart`（确认弹层形态）、`test/a11y_test.dart`（热区 48）；改 UI 后按通用规范实机目检。数值出处 `docs/05` §十一。

## 内存口径与有界容器（门禁：`perf-metrics/audit-unbounded.mjs --gate`）

口径决策见 `docs/adr/0007-memory-measurement-gate.md`（为什么必须强制 GC、为什么阈值只准收紧），
专项进度与归因见 `docs/09_内存与性能治理专项-2026-09-18.md`。

- **累加容器必须有界**：进程生命周期内可达的累加容器——Rust `static`/`Lazy`/`thread_local` 内集合、
  `Mutex`/`RwLock` 包裹且跨调用存活的集合（含 `Arc` 共享的 struct 字段如 `dir_cache`）、跨 hook 存活的
  模块级 `Map`/`Set`——声明行 ±3 行内必须带三选一标记：
  `// bounded: <上界+淘汰策略>` ｜ `// bounded-by-lifecycle: <何时整体清空>` ｜ `// bounded-by-data: <来源天然有界>`。
  缺标记即拦停。例外只能写进 `perf-metrics/baselines.json` 的 `knownUnbounded`（按 文件+规则 计数，
  **只许降不许升**）；`sql-fetch-all`（无 `LIMIT` 的 `fetch_all`）当前提示级，A6 落地后翻正。
- **内存结论必须可复算**：任何「省了多少 MB」的说法要能用 `growth-curve.mjs` 复现。三条口径红线：
  采样前必须 `window.gc()`（否则量到的是分配量不是驻留，09-12 报告的 169/257MB 就栽在这里）；
  峰值指标不 GC、泄漏指标必 GC，两者配对才分得清「重」与「漏」；进程 RSS 按 pid 子树收敛不按进程名全局求和。
- **渲染必须过虚拟窗**：整列表渲染一律走 `useVirtualizer`，**包括分组置顶段**（逾期/今天/收藏头等）。
  `domNodesSlope_per_1k` 阈值 30 是这条规则的哨兵——任何新增的裸 `.map()` 整列表渲染都会把斜率抬到数百而被拦下。
- **改缓存策略要连测两份**：`placeholderData` / `gcTime` 的收益只在**换 queryKey** 路径上出现，只点勾选的
  churn 测不到（`growth-curve` 的 `switchChurn` 与 `extraCopyCostMB` 就是为补这个盲区加的）。
- **阈值与目标分开存**：`baselines.json` 的 `thresholds` 是防回归判据（今天必须过），`targets` 是期望值
  （可以不过）。`--record` 只回写 `measured`，改阈值须连同理由写进 `$rationale` 并在 docs/09 留痕。

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
- 项目内权威文档：`docs/01-09`（产品/架构/数据/UI 规格/backlog/发布与更新流程/内存与性能治理专项）、`docs/adr/0001-0007`（SQLCipher/通知/双端拆分/发布工程/回收站边界/桌面驻留内存/内存度量口径与门禁）
