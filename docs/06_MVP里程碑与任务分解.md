# 06 MVP 里程碑与任务分解

> 工作量口径：S <2 天 / M = 2–5 天 / L >5 天（单人）。关键路径 **M0 → M1 → M2 → M3**；M4 仅依赖 M1，可在 M2/M3 期间穿插；M5 收尾。

## 一、里程碑总览

| 阶段 | 名称 | 出口判据（Gate） |
|---|---|---|
| M0 | 脚手架与资产平移 | 五端空壳可跑；CI 产出五端产物；主题体系与 ui 基元就位 |
| M1 | 数据链路贯通 | 加解锁流程可用；全部 todo 命令经 devtools 验证通 |
| M2 | 桌面 UI 复刻 | 04 文档 §八 清单全过 |
| M3 | 安全与同步 | 双实例同步收敛 DoD（01 文档 §五） |
| M4 | 移动端复刻 ✅ 代码完成（Android） | 四屏观感对照通过 + C 级验收（01 文档 §四） |
| M5 | 发布工程 | 五端产物签名/分发就绪 |

> M4 说明：代码完成以 Android 为准（release APK 已产出并通过全量自动化门禁）；iOS 因签名证书/macOS 构建前置延后，真机验收清单见 [superpowers/plans/2026-08-24-m4-device-checklist.md](superpowers/plans/2026-08-24-m4-device-checklist.md)。

## 二、任务分解

### M0 脚手架与资产平移
| # | 任务 | 量 |
|---|---|---|
| 0.1 | 仓库初始化：Cargo workspace + Tauri 2 项目 + Vite React 模板 + `tauri android/ios init` | S |
| 0.2 | `orbit_core` 裁剪平移（02 文档 §四 A 类清单），编译通过、单测绿（modules.rs 断言改单模块） | L |
| 0.3 | 前端基座平移：index.css token 体系 / design-tokens / color-theme / theme 三层 / ui 基元全套 / wait-calendar + date-picker / entity-form-sheet / use-entity-list / use-confirm-delete | M |
| 0.4 | AppShell 复刻：TitleBar / Sidebar(精简单组) / Mica hook / page-transition / sonner 配置 | M |
| 0.5 | CI 五端构建矩阵 + lint/typecheck 门禁 | M |

### M1 数据链路贯通
| # | 任务 | 量 |
|---|---|---|
| 1.1 | 迁移重组 0001/0002（03 文档 §二，含 uuid UNIQUE 并入与种子改写规则） | M |
| 1.2 | db_cmd/pool/lifecycle/AppState 平移；数据目录采用 orbit.db 族 | S |
| 1.3 | master_auth 全流程：设置主密码 / 解锁页 / 免密模式 / 修改密码（v2 verify_hash） | M |
| 1.4 | business_cmd(todo 44) + todo_cmd(7) 注册；前端 typed invoke 层重建（保留 UpdateInput 缺省键=跳过语义） | M |
| 1.5 | sync_registry.rs 白名单集中化 + IMPORTABLE_TABLES 补缺口（03 文档 §六） | S |

### M2 桌面 UI 复刻（04 文档为验收规格）
| # | 任务 | 量 |
|---|---|---|
| 2.1 | list-page 三栏骨架 + 工具栏 + 筛选/搜索/排序语义 + TaskListView 行 | M |
| 2.2 | ProjectSidebar：快捷视图/拖拽重排/内联新增/删除保护 | M |
| 2.3 | TaskDetailDrawer 八区块 + LabelAdder + SubtaskList + CommentList | L |
| 2.4 | QuickAddBar（三快捷 Popover + 连续录入焦点） | S |
| 2.5 | TaskFormSheet 九字段 + EntityFormSheet 接线 | S |
| 2.6 | KanbanView：@dnd-kit 分列/跨列/position 取中值算法/DragOverlay | M |
| 2.7 | 通用 ContextMenu 基元（⚖ 替代两套手写菜单）+ 全菜单项接线 | M |
| 2.8 | LabelManager 10 色板 | S |
| 2.9 | 提醒轮询守护改造（专用 SQL 版）+ `todo_reminder:due` 监听 toast | M |
| 2.10 | ⚖ 五项规范化落地（03④ react-query 收编、③命令面板死链修复等） | S |

### M3 安全与同步
| # | 任务 | 量 |
|---|---|---|
| 3.1 | sync_crypto 平移验证：meta 生命周期/200k→600k 升级/损坏隔离/Fix-10 守卫 | M |
| 3.2 | 同步设置 UI：WebDAV/S3 表单 + 同步密码卡 + 立即同步/定时开关 + SyncIndicator 进度 | L |
| 3.3 | crypto bundle 上传下载（crypto/config 路径）+ KeyMismatch 恢复引导页 | M |
| 3.4 | .orsync 备份导出/导入（ORSN magic + payload_len 校验 + 导入补齐五表） | M |
| 3.5 | SyncEngine 三模式接线 + 60s tick 调度 + keyring 缓存(service=orbit.sync-crypto) | S |
| 3.6 | 双实例收敛联调（新增/编辑/删除/墓碑/同毫秒平局用例矩阵） | M |

### M4 移动端复刻（05 文档为验收规格）
| # | 任务 | 量 |
|---|---|---|
| 4.1 | **Spike R1**：Android SQLCipher 启用策略验证（见风险表）；产出决策记录 | M |
| 4.2 | 移动壳：栈式导航路由 / 安全区 / 状态栏适配 / 手势条兜底 48px | M |
| 4.3 | 玻璃组件库：LiquidGlassTitleBar(含 mask 渐变降级)/GlassFab/字段盒 blur10/高光线三件套 | L |
| 4.4 | 侧栏首屏 + 任务子列表 + TodoTaskTile（长按弹层） | M |
| 4.5 | 详情全屏八区块 + 底部选择弹层 | L |
| 4.6 | 表单抽屉（snap 弹簧 + 键盘避让）+ WaitDatePicker 日历 sheet | M |
| 4.7 | **Spike R2**：移动本地通知方案（scheduled API 可用性 / 前台轮询兜底 / 权限拒绝降级 toast） | M |
| 4.8 | 同步开关最小 UI（沿用 3.2 表单的移动布局） | S |

### M5 发布工程
| # | 任务 | 量 |
|---|---|---|
| 5.1 | 应用图标/启动屏（五端尺寸族） | S |
| 5.2 | Windows 签名 + macOS 公证 + Linux 打包校验 | M |
| 5.3 | 版本号/更新日志机制 + README + 隐私声明（E2E 承诺表述）+ 更新方式说明（手动覆盖安装，02 文档 §六） | S |
| 5.4 | MVP 打 tag，归档产物 | S |

## 三、风险登记

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | **Android 无 SQLCipher**：wait-home 中 libsqlite3-sys 的 sqlcipher feature 明确排除 Android 目标（移动端走 FRB 时另有处理）。新项目 Android 端加密策略未验证 | 高：M4 数据层阻塞 | 4.1 spike 先行。候选：sqlcipher-android 系统库接入 / net.zetetic:sqlcipher-android AAR / Android Keystore + 明文库降级（需在隐私承诺上让步，最后手段） |
| R2 | Tauri 2 移动通知调度能力不成熟（桌面 show() 不支持定时已是既成事实） | 中：提醒功能移动端不可靠 | 4.7 双方案预研：scheduled API 若可用则调度化；否则前台服务轮询 + 权限拒绝降级应用内 toast |
| R3 | WKWebView `-webkit-mask-image` 对 backdrop-filter 遮罩支持不稳 | 低：标题栏渐变模糊降级 | 05 文档 §三分段 blur 兜底方案已内置 |
| R4 | iOS 签名证书/开发者账号成本与流程周期 | 中：iOS 端交付延后 | iOS 列 C 级手动触发；不阻塞桌面 MVP |
| R5 | WebView 内看板拖拽性能（若未来移动端要接看板） | 低：MVP 已排除 | 保持移动端无看板决策 |
| R6 | 范围蔓延（重复任务引擎等诱惑） | 高：MVP 失焦 | 01 文档非目标清单为准；任何新增先进 docs 提案评审 |
| R7 | 单人带宽 | 中：进度波动 | 关键路径只有一条；M4 可降级延后而不伤桌面 MVP |

## 四、建议执行顺序（两周节拍示例）

```
W1-2   M0 全部 + M1.1
W3-4   M1 其余 → Gate1
W5-7   M2.1–2.6（桌面主体）
W8     M2.7–2.10 → Gate2（04 §八 清单走查）
W9-10  M3 全部 → Gate3（双实例联调）
并行窗 W5-W10 任一空档：M4.1/R1 spike → M4 组件库
W11-12 M4 屏幕组装 + M5 发布工程 → MVP tag
```
