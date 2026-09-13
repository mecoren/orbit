# Changelog

本文件记录 Orbit 的所有显著变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 项目归档三端落地

- **对标 Tasks.org/Vikunja/Todoist 全标配**：项目一多侧栏不可收拾的核心痛点，此前唯一的出路是删除（连带保护弹窗与撤销窗口）。归档 = 从默认视图收起（非软删）。
- **数据层**：`todo_projects.is_archived` 列（0001 迁移补行尾中文注释；随既有白名单表行级同步，LWW 天然携带，sync_registry 零改动）。`list_todo_projects` 默认排除归档；新增 `list_archived_todo_projects`（updated_at DESC 最近归档在前）；`TodoProjectUpdateInput.is_archived` 三态字段（patch_json 直通）。**任务列表聚合视图排除归档项目任务（SQL `NOT IN` 子查询，未分组不受影响）；project_id 谓词（用户主动点进归档项目）放行——归档区点进项目仍可读任务**。归档项目任务保留在统计（历史完成数据是事实，归档不改写成就感数据）。墓碑优先：归档项目走软删后归档列表也不再显示。
- **三端 UI**：桌面右键菜单「归档项目/取消归档」+ 侧栏「已归档」折叠区（计数徽标、行点击进项目视图、行尾 ArchiveRestore 恢复钮 group-hover 显现）；移动长按菜单「归档项目」+ 侧栏「已归档」区（行尾「恢复」TextButton）；归档当前选中项目时自动跳回 /todo 防空视图误导。
- **桥链**：Tauri `todo_projects_list_archived` 命令 + FRB `todo_projects_list_archived` 镜像（codegen 产物入库）+ 手写 dto.dart `isArchived`（缺省回退 0 兼容旧 JSON）+ MockOrbitBridge/桌面 ipc-mock 同口径（含任务聚合排除谓词）。
- 测试：Rust 4 用例（归档排除/聚合隐藏+项目视图放行/恢复归零/软删优先）+ mock 桥契约 3 + 桌面 vitest 252 / e2e 18 / flutter analyze 零警告 + 271 全绿；浏览器目检四步链路（右键归档→主列表收起→归档区展开→行内恢复回位）全过。cargo fmt 顺带收编 activity_log_api.rs 等三文件历史 rustfmt 欠账。

### 桌面系统通知正文点击路由：点通知直达任务详情

- **此前断点**：Windows 系统通知点击正文后啥也不发生（`__closed` 统一丢弃，正文点击与关闭不可区分）——移动端 `onNotificationTap` 冷启动路由早已有，桌面是能力缺口。对标 MS To Do/TickTick 标配交互。
- **修复**：notify-rust `wait_for_action`（只回 action 串，正文点击与关闭混为 `__closed`）→ `wait_for_response`（`NotificationResponse` 三态区分：`Default`=正文点击 / `Action(key)`=按钮 / `Closed`=关闭）。正文点击路径：`show_or_create_main_window` 唤起主窗（window_recycler 统一入口，隐藏驻留态 show + 已回收态重建两分支全覆盖）→ 延迟 2s emit `todo_reminder:open`（对齐 PENDING_QUICK_ADD 补发口径，保证冷启动监听挂载后才到达）→ 前端写 `selectedTaskId` 打开详情抽屉（与 in-app toast 的「查看任务」同范式）。
- 关闭/超时（`Closed`）不处理——`Timeout::Never` 下主要是用户主动关横幅；macOS 内联回复（`Reply`）未启用，防御性忽略。
- 验证：cargo check 零错 / tsc 零错 / vitest 252 全绿；真机通知点击路径属 OS 交互，冒烟由 e2e 链路覆盖（18 用例无回归）。

### 任务描述 Markdown 渲染移动端对齐（桌面已有同源能力补齐）

- **移动端描述区 Markdown 渲染**：桌面详情抽屉展示态早已走 `markdown-lite` 渲染（标题/粗体/斜体/行内代码/链接/列表），移动详情页此前是裸 `Text` 原文显示——本批补齐双端口径。`logic/markdown_lite.dart` 同源移植（逐字对齐桌面解析语义：`code`/`**bold**`/`*italic*`/`[text](url)` 逐字符扫描、不成对标记原样保留、`- [ ]` 任务列表残留按原文渲染）；链接点击跳系统浏览器（`url_launcher` 官方第一方插件，平台桥接非 UI 库，不违反「UI 自绘不引库」惯例）；recognizer 生命周期由 StatefulWidget 宿主管理（纯函数层不持有 TapGestureRecognizer）。
- 编辑入口不变（底部抽屉原文编辑），展示态渲染不影响编辑语义。
- 测试：`markdown_lite_test.dart` 12 用例（行内 5 对齐桌面用例 + 块级 5 + widget 冒烟 2；Text.rich 已知坑断言走类型+谓词）；`flutter analyze` 零警告；全量 268 绿（+12）。

### 云同步专项修复：探查报告 S1-S13 三批落地（14 项）

docs/同步功能专项探查报告-2026-09-13.md 59 项问题中的 14 项按批次修复（批 A P0+高杠杆 / 批 B 可靠性 / 批 C 调度与一致性），每项带定向回归测试：

- **批 A（P0 三连 + 两小修）**：S1 附件云端命名三套口径统一为 `assets/{hash}.waitsync`（存量 `.waitsync` 对象的死循环「每轮重复下载→哈希校验失败」消除，双路径回退迁移兼容）；S2 S3/WebDAV endpoint 规范化接线（无 scheme 的 MinIO 形态不再误报认证错误）；S3 备份文件名消毒增补 `#`/`%`/空格/控制字符；S5 is_running 改 try_lock 探测并修正恒 false 方向 bug（原实现阻塞排队 + 探测失效双坑）；S10 tauri-plugin-log 注册（引擎诊断日志不再全量丢弃，stdout + app_log.log）。
- **批 B（错误结构化六连）**：S6+S19 SyncError/CloudSyncError 增 `RateLimited`/`Auth` 类型变体，弃 contains("429") 字符串嗅探（"4291 bytes" 巧合子串不再触发 120s 白等）；with_retry 认证错误首错即返（密钥配错每轮白等 ~14s → 0s）；S7 附件同步包入业务级 with_retry + 空列表防御；S9 mark_uploaded 吞错收敛可观测；S11 WebDAV PROPFIND 错误走统一状态码框架（5xx 恢复可重试、限流可识别、401/403 归认证）；S12 DELETE/HEAD 传输错误可重试。
- **批 C（调度与一致性）**：S13 定时同步账本持久化（重启不再每启必全量同步；失败保留快速重试窗口）；S8 push 模块间错误隔离（单模块失败不再中断附件等后续阶段；rekey 路径例外硬失败防新旧 Key 混合态）。
- 验证：cargo 478（WebDAV 环境用例已知非回归）/ clippy 警告与基线持平 / tsc 零错 / vitest 252 / e2e 18 / flutter analyze+test 256 全绿；报告 §六验证矩阵已回填。

### UI 细节清理（性能报告 M2/M6/L3 收尾）

- **日历/年视图 title 手搓提示换 tooltip 原语**（M2）：回到今天/更新节假日（月/年档两处）+ 年视图大年份点击返回——三组按钮统一 `bg-primary` 主题色底白字原语口径（原生 title 灰白系统弹层不再混用）；议程档空态标题与拖拽圆点 title 保留（前者是组件 prop 非手搓、后者非 hover 目标场景）。
- **今日格 +N 白字硬编码修复**（M6）：`text-white/90` → `text-primary-foreground/90`——自定义浅色 accent 主题下对比度不足问题消除。
- **dialog/sheet 关闭钮 sr-only 英文残留**（L3）：`Close` → `关闭`（屏幕阅读器中文播报）。
- 快捷键自定义与设置页 12 处纯信息性 title 保留原状（前者是独立批次体量；后者按探查报告原口径「纯信息性 title 可保留」）。
- 验证：tsc 零错 / vitest 252 / e2e 18 全绿。

### 附件行缩略图（批 7b 轻量版）：图片附件行内 32px 预览

- `AttachmentThumb`：图片附件行内 32px blob 预览替代纯文件图标（非图片仍图标）——解码内存由浏览器按渲染尺寸自动降采样管理（24px 渲染需求远小于原图），卸载即 revoke 防字节驻留；读取失败静默退回图标（缩略图是增强非关键路径）。重缩略图生成方案（image crate 服务端降采样缓存）评估后不做——单人口径下成本收益倒挂，内存大头已由批 4 lightbox/cacheWidth 解决。
- 验证：tsc 零错 / vitest 252 / e2e 18 全绿；目检缩略图 32px img 渲染通过。

### FTS5 全文索引：搜索从 LIKE 全表扫升级为短语级全文检索

批 7a（探针报告 F8 落地）——前期实证先行：运行时探针证实 bundled sqlite 带 FTS5 但 **unicode61 分词器丢弃 CJK token**（单字都不命中），中文搜索必须 **trigram 分词器**（3-gram 短语精确命中）——这一分词事实是方案根基，python sqlite 3.49 对照验证。

- **索引层**：0001 迁移新增 `fts_todo` external-content FTS5 虚表（trigram 分词；kind/ref_id/ref_uuid/task_id UNINDEXED + title/body 索引列），12 个触发器同步四源（任务标题+描述 / 子任务标题 / 评论正文 / 项目标题+描述），软删行经 UPDATE 触发器谓词从索引摘除（回收站行不参与搜索）；存量行幂等回填四段（备份导入兜底）。**FTS 虚表不可建普通索引**（迁移实证，rank 排序天然小结果集无需二级索引）。
- **查询层**：`search_all` 双路径——查询词 ≥3 字符走 MATCH 短语查询（bm25 相关度排序，子任务命中归并主任务，四源分流 join 回源表带软删双保险）；短词（中文两字高频如「评审」）与 FTS 异常静默降级原三路 LIKE——**搜索永不因索引失败而不可用**。返回结构不变（双端零改动）。
- 顺修触发器 SQL 语义坑：AFTER DELETE 集合删除下 `NEW` 不可用必须 `OLD`（trash purge 集合式 DELETE 路径实测暴露）。
- 测试：FTS 探针 1（能力守卫）+ 搜索集成 6（中文短语命中/短词兜底/子任务归并/软删摘除/描述正文命中/评论命中）；Rust 458（WebDAV 环境用例已知非回归）/ vitest 252 / e2e 18 全绿。

### 任务活动日志（F6）：操作轨迹三端可回看——对标 Todoist Activity log 的免费差异化

Todoist 把活动日志当 Pro 卖点（免费版仅 1 周），本地应用零成本提供完整历史：

- **数据层**：0001 迁移新增 `todo_activity_log`（task_id + 标题快照 + action + detail JSON + created_at 双索引）；**本地只读轨迹不进 SYNCABLE_TABLES**（口径同 notification_log——同步要结果态而非过程，跨设备合并无意义）。
- **写路径埋点**（core 层内嵌，失败不阻断主流程）：create/update/complete/uncomplete/delete/restore 六动作；update 记**实际变化字段集**（前后行比较 changed_task_fields，未命中字段的空更新不产生噪音轨迹）；complete 幂等重击不重复记。
- **查询与展示**：`task_activity_list` 命令（单任务倒序 limit 30）→ 详情抽屉第九区块「历史」（History 图标 + MM-dd HH:mm + 中文动作文案，update 括注变更字段中文名）。
- mock 同口径埋点（create/update/complete/delete）+ 查询命令；`prune_old` TTL 清理预留 db_maintenance 接线。
- 测试：activity_log API +2（写入倒序/任务隔离 + TTL 清理）；e2e +1（快加→改优先级→完成→详情历史区「标记为完成」「更新（优先级）」全链）；全量 cargo 452（+12）/ vitest 252 / e2e 18 全绿（WebDAV 环境用例已知非回归）。

### 性能与内存双批：谓词下推 SQL + WebView2 内存参数 + 缓存分层

探查报告「另立项」池中最大的两项（F4/F5 驻留数据 + F8 之外的内存手段）本批落地：

- **谓词下推 SQL（F5 主项）**：`ListFilter` 扩展六谓词键（done/status/priority_min/project_id/favorite_only/my_day_today），`generic_repo::list` 仅 `todo_tasks` 消费拼接（其他表忽略零开销）——status 文本绑定独立通道（TEXT 列不可绑 INTEGER）。壳层主查询按选中态传谓词（未完成/已完成/收藏/我的一天/项目视图各自下推），替代「万行全量拉取 + 前端过滤」的 IPC 与驻留大头；queryKey 含谓词对象，db-change 表级前缀失效天然命中。FRB DTO 镜像六键同步（codegen 产物入库）。mock `todo_tasks_list` 同口径谓词过滤。
- **WebView2 内存参数（M3）**：Windows 侧启动注入 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`（`--js-flags=--max-old-space-size=512` 老生代上限促 GC 压实——09-10 实测 WebView2 隐藏驻留不裁内存堆无界膨胀；`--disk-cache-size=50MB` 附件预览缓存封顶）；已有外部覆盖不强写，Rust 2024 set_var unsafe 语义注明单线程前提。
- **缓存分层（M4）**：详情单条查询 gcTime 10min → 5min（列表级键才配 10min，抽屉历史详情无理由驻留）。
- 测试：谓词子句纯函数 +5、内存库集成 +3（done 双向/status+priority+project 组合/favorite+my_day 零点窗口）；全链 vitest 252 / e2e 17 / Flutter 256 / cargo 448（WebDAV 环境依赖用例既有已知非回归）/ analyze+tsc+cargo check 全零告警；浏览器目检：五视图谓词精确过滤、勾选完成→视图消失→失效链刷新→隐藏开关联动全过。
- 收益口径：未完成/收藏/我的一天视图的 IPC 从万行级降到结果集行数（真机估算单次失效重拉省 50-80ms×N），JS heap 驻留随视图收窄同步下降；真机量化验收沿用 perf-metrics 工具复测。

### 搜索防抖收编 + 附件应用内图片预览（桌面 lightbox + 移动降采样）

- **工具栏搜索防抖（200ms）**：此前每击键全量 filterTasks 重跑（万任务下一键一遍过滤+分组+排序）；防抖 hook 从全局搜索对话框局部实现收编 `shared/use-debounced-value.ts` 共用（全局搜索 250ms 口径不变）。
- **桌面图片附件 lightbox**：点击图片附件从「window.open 新窗口裸图」（体验断裂、弹窗被拦时静默失败）改为应用内全屏预览 Dialog（黑底 contain + 文件名说明 + Esc/遮罩关闭）；关闭即 revokeObjectURL 防整份图片字节驻留。
- **移动端图片附件降采样解码**：`Image.file` 补 `cacheWidth`（屏宽 × devicePixelRatio）——4K 照片不再原图全尺寸解码进纹理，单图解码内存 ~45MB → ~8MB 量级。
- 验证：tsc 零错 / vitest 252 / flutter analyze 零告警 / Flutter 256 / e2e 17 全绿；浏览器目检 lightbox 开合（点图片附件 → 预览 Dialog + img 渲染 → Esc 关闭）全过。

### 筛选器可视化构建器：裸 JSON 手填退役 + 工具栏「存为视图」一键固化

对标 Todoist Filters 的创建体验（#35 落地时条件是裸 JSON 手填框，本批补齐最后一段）：

- **可视化条件构建器**（`saved-filter-dialog.tsx`）：七键白名单全部控件化——状态/优先级下限下拉、截止「已逾期 + 1/3/7/14/30/90 天内」pill 组（互斥不可同选）、项目/标签多选 pill（任意=不过滤）、仅收藏开关；空维度不落键、空表单产出 `{}`（万能视图）；损坏 JSON 防御回退空表单。条件⇄表单双向映射纯函数 `saved-filter-builder.ts` 独立可测。
- **工具栏「存为视图」**（BookmarkPlus 钮）：把当前工具栏的状态/优先级/收藏筛选一键预填进构建器（`toolbarToForm`——「未完成」档无白名单键自动丢弃），补个名字即存——把「我关心的任务切片」固化为侧栏一键可达视图的摩擦降到两次点击。
- 壳层 context 增 `createSavedFilterWith`；侧栏原「保存当前筛选」入口同享新构建器。
- 测试：构建器映射 +6 单测（七键还原/空键/往返无损/工具栏预填丢弃规则）；e2e +1（存为视图→pill 互斥→toggle 取消→保存落库 `{"due_overdue":true}`→侧栏点击生效全链）。
- 验证：tsc 零错 / vitest 252（+6）/ e2e 17 全绿；浏览器目检：构建器全控件渲染、pill 互斥切换、仅收藏落库 `{"favorite_only":true}`、逾期档互斥清天数全过。

### 批量操作扩展：批量改期三视图齐备 + 看板多选 + 键盘批量（x/Esc）

对标 Linear 批量整理流，补齐批量动作集最后两块短板：

- **批量改期 `batchSetDueDate`**：多选后一键「今天/明天/下周一/清除截止」——整理过期积压任务不再逐条改。时间语义对齐日历拖拽改期（rescheduleDue 同口径：原截止保留时分秒，零点/无截止归一 18:00；clear 档写 null）；Ctrl+Z 可撤销恢复原截止。列表/看板工具条走 CalendarClock 图标下拉，表格视图工具条走原生 select（与该视图文本钮形制一致）。
- **看板多选批量**（此前仅列表/表格支持）：卡片左上勾选圈（hover/选中态显现）→ 底部浮动工具条（完成/状态/我的一天/收藏/改期/优先级全量动作，与列表同形制）；选中态下点卡片 = 切勾选（与列表行一致）；工具条不含移动项目——看板拖拽即移动入口。
- **键盘批量（三视图一致）**：`x` 键选中/取消选中焦点行或卡片（Linear 同款），`Esc` 多选态退选全部；快捷键帮助面板补录两条。
- 测试：batchDuePresetDate 档位 2 用例 + batchSetDueDate 4 用例（保留时分秒/clear 幂等/同日跳写库/部分失败）；e2e +1（看板勾选→工具条→改期明天 18:00 落库→x 键选中→Esc 退选全链）；顺修帮助面板 Esc 键位重名（多选语境加后缀）。
- 验证：tsc 零错 / vitest 246（+6）/ e2e 16 全绿；浏览器目检：看板勾选圈浮现、工具条全按钮、改期落库明天 18:00、x 选中、Esc 退选全过（IAB 合成 click 不达 Radix 菜单项的坑走 e2e 真实事件覆盖）。

### 已完成任务治理（Logbook）：默认隐藏已完成 + 完成历史按日分组回看

对标 Things 3 Logbook 的完成治理双能力，三端落地（桌面+移动同口径）：

- **隐藏已完成开关（默认开）**：此前已完成任务在默认列表无限期平铺（划线条目长期淹没列表），只能手动切筛选消化。工具栏/标题栏新增开关（桌面 EyeOff 图标钮 + localStorage `todo_hide_done` 持久化，移动 IconButton 会话态）；`quickView=done` 完成集入口与 `statusFilter=done` 筛选档下不参与过滤（否则开关会把完成视图清成永久空列表），开关同步置灰。
- **Logbook 完成历史视图**：侧栏「已完成」在列表档升级为按完成日（done_at 本地日界）倒序分组的完成历史——最近的成就排最前，组内按完成时刻倒序；组头带完成绿图标 + 日期/星期 + 条数（「今天」高亮主色底）。桌面新视图 `logbook-view.tsx`（复用 CalendarTaskRow 行 + 日历 VirtualGroupedList 同款打平虚拟化），移动端 `_LogbookList`（单一 ListView.builder 懒加载，区块头随组首行渲染）；分组纯函数 `groupDoneByDay` 双端同口径（done_at 缺失兜底落 created_at 日）。
- **移动端拖拽落位同口径修复（真 bug 顺修）**：`_reorderTasks` 落位邻居重算 `filterTasks` 未带 `hideDone`——UI 行数（隐藏后）与计算索引（全量）错位，中值取到错误相邻行（隐藏开关引入后任何拖拽都会错位）；统一传 `_hideDone` 与 build 同口径。
- 移动端补 `OrbitAccents.doneGreen`（#22C55E，对齐桌面 STATUS_COLOR.done；完成日头图标用）。
- 测试：桌面 filterTasks hideDone 5 用例 + groupDoneByDay 4 用例；移动端 7 用例；e2e +1（Logbook 分组回看全链）；顺修 task_logic_test 历史嵌套错位（computeSidebarCounts 组意外嵌在 groupOverdueFirst 组内）。
- 验证：tsc 零错 / vitest 240 / flutter analyze 零告警 / Flutter 256 / e2e 15 全绿；浏览器目检（隐藏默认生效、开关往返切换、Logbook 分组渲染、行 48px/优先级条/划线态、done 视图开关置灰）全过。

### 全栈性能与 UI/UX 系统性优化批次（探查报告全清账）

双维只读探查（性能 15 项 + UI/UX 18 项，报告入 docs/性能与UX系统性优化报告-2026-09-12.md）后按性价比四批落地：

- **表格视图「我的一天」零点 bug（H2 真 bug）**：按钮写入 `Date.now()`（含时分秒），零点严格相等判定立即失配——图标不亮且移出分支永不触发。五处内联判定/写值收编 shared 纯函数 `todayStartMs`/`toggleMyDayValue` 单一口径，+5 单测（含脏数据对齐回归）。
- **db-change 表级失效（最大放大器）**：此前每条写事件全量 invalidateQueries——勾选一条任务 = 9+ 路查询标脏重拉（含三路万行级全量）。新增 `lib/db-invalidation.ts` 按事件 table 精确失效（11 张同步表全覆盖 + todo_tasks 联动详情/搜索/统计/回收站派生键），未知表回退全量宁多拉不漏刷，+7 单测。顺修 mock 事件契约（真实 Tauri handler 收 `{event,payload}` 包装，mock 直传裸对象）。
- **stats_aggregate 五次全表扫 → 单次**：overview/heatmap/streak/weekday/available_years 五 impl 各自拉同一全表；万任务下统计页一次点击 5 遍行解码 → aggregate 单次拉取传引用。
- **列表视图渲染三修复**：分组 useMemo 的 now 每渲染帧重建致全量重跑（拖拽/选中态 set 全触发）→ 数据变更才换基准；renderRow 每行 2 次 Date.now() 外提；TaskRow 包 memo + 自定义比较器（忽略内联箭头函数 props，业务字段精确比较）。
- **移动端侧栏单遍计数**：7 个快捷视图行各跑一遍 filterTasks（8+ 遍全量遍历/次 build）→ `computeSidebarCounts` 一遍出全部计数 + 项目 Map，+4 单测对照 filterTasks 口径锁定。
- **快加提醒弹层去 Popover 嵌套（H1）**：PopoverContent 内嵌 DateTimePicker（自身即 Popover）——portal 套 portal 同 drawer 已踩过的坑复发；照 DueDateEditor 两段式重写（QuickDateMenu ⇄ 内联日历+时分输入）。
- **三视图加载态补齐（H3）**：表格/看板/日历查询进行中误闪空态（「暂无任务/拖拽任务到此处/本月没有…」）——task-panel 统一下传 loading，三视图骨架行 + 表格空态换 EmptyState 组件。
- **看板键盘可达 + 勾选入口（H4/M5）**：卡片补 role/tabIndex/Enter 激活（对齐列表/表格行）；正面加同款圆环 checkbox 直调 completeTask。
- **常量单口径收敛（M1）**：PRIORITY_LABELS 四副本/STATUS_ITEMS 硬编码三色/两份相同 10 色板/两份不一致的标签随机色池/我的一天色三处内联，全部收 constants.ts 单源（`MY_DAY_COLOR`/`PRESET_10`）。
- **详情抽屉焦点可见（M3）**：子任务/提醒/关联/评论/附件五行内删除钮补 `group-focus-within`——Tab 聚焦不再隐形。
- **回收站集合式清理 + 墓碑索引（R2/R3）**：TTL purge 从「整行物化 + 每行 6 条 DELETE」改守卫并入 SQL + 6 条集合 DELETE（IN 子查询）；0001 迁移补 `idx_todo_tasks_trash(is_deleted, deleted_at DESC)`（回收站列表与 purge 谓词共用）。
- **generic_repo 分页 offset bug（R5）**：page_size=0 默认 20 档第 2 页起 offset 恒 0 返第一页数据——改用规范化后 page_size。
- **桌面启动链去阻塞（D1）**：AUMID 注册（PNG 编码+注册表）与计划通知清理（WinRT 遍历）从 setup 首帧关键路径挪后台线程。
- **移动端角标读缓存（M3-mobile）**：BootGate 直拉全量任务 IPC 与 provider 缓存完全重复（db-change 双份万行过桥）——改读 todoTasksProvider 缓存值。
- 顺修：calendar-view 死键 invalidate（count/nav-data 无消费方）；测试代码 lint 清零（flutter analyze No issues）；orbit-core 未用导入清理（两 workspace cargo check --all-targets 零警告）。
- **验证**：vitest 231（+12）/ Rust 440 / Flutter 249（+4）/ e2e 14 / flutter analyze+tsc+cargo check 全零告警；浏览器目检关键链（看板 Enter 开详情/勾选落库、提醒弹层两段式、失效链刷新、my_day 移出）全过。
- **指标体系与量化实测**（报告 §五，工具入库 perf-metrics/ 可复现）：冷启动 ~1.5s（pre/post 噪声带内持平）；万级任务滚动 60fps（中位/p95 帧间隔均 16ms）+ 勾选 ~250ms + 看板切换 <50ms；内存 pre/post 持平（优化消除的是冗余计算非驻留数据）——Tauri 全树 390MB 空闲 / Chromium 万级 423MB→操作峰 758MB / JS heap 169MB；对标口径沿用 09-10/11（Tauri vs Chrome vs Flutter），真机 IPC 失效链收益（估算单次勾选省 150-250ms）列验收遗留。

### Windows 通知身份修复——AUMID 注册 DisplayName=Orbit + 图标对齐

- Windows Toast 通知（提醒轮询直发 + 退出计划 Toast）横幅此前显示进程名 `orbit-desktop` + 旧进程图标缓存。根因：两条通道都以 AUMID `cn.wait.orbit` 发通知，但该 AUMID 从未在 `HKCU\Software\Classes\AppUserModelId` 注册身份——通知平台查不到 DisplayName/IconUri 时回退显示发起进程名及其图标（dev 态 exe 名即 orbit-desktop）；`productName` 本就是 Orbit，名字问题全部出在这条缺失的注册链。
- 新增启动钩子 `aumid_registry`：setup 阶段幂等写 `DisplayName="Orbit"` + `IconUri=file:///…/cache/app-icon-notification.png`；图标源用 tauri `default_window_icon`（exe 内嵌 icon.ico 首帧，45a9f50 后为 256px v5.1 高清帧）编码 PNG 到数据目录 cache/——dev/安装态同源，通知图标永远与任务栏/托盘当前版本一致，每次启动全量重写无旧缓存。
- Cargo 包名 `orbit-desktop` 是内部 crate 名不进用户可见面，保持不动（改名会牵动嵌套 workspace/gen/schemas/锁文件）。
- 验证：模块单测 2 条（探针键注册表真实写入/幂等覆盖 + 键路径与 AUMID 同口径断言）；实机探针 toast 归属 `cn.wait.orbit` 落通知平台库、注册表身份就位（Windows 渲染横幅身份的官方数据源）。

### 详情开始日期弹层宽度修复

- 详情抽屉开始日期编辑弹层原 `w-64`（256px）装不下内联日历标题行（月份 72px + 年份 112px 下拉 + 两侧翻月钮，内容宽 ~286px）——展开「选择日期」日历向右溢出弹层边界。对齐 DueDateEditor 既有口径改 `w-72`（288px）；浏览器目检几何断言：日历表格右缘 980 < 弹层右缘 981，溢出清零。

### 日历视图右栏贴边修复

- 月/年分栏右栏卡片与议程列表原直接贴视口右缘和快速输入栏顶（外层 Outlet 无 padding、右栏无外边距）——CalendarView 根层统一补右/下留白（`pr-4 xl:pr-5 pb-3`，与左半区日历侧内距同口径），三档（月/年/议程）同口径收口；月/年档 30px、议程档 20px、窄窗堆叠 30px，实测几何断言全过。

### 描述体验两连——高度封顶 + 悬浮预览

- **描述框默认高度 + 最大高度（三端）**：新增/编辑表单与详情描述框原先自适应无上限——长描述把表单/抽屉撑到无限长。现统一 `min-h-[80px]` 默认高度 + `max-h-64`（256px≈8 行）封顶内滚；详情展示态同口径封顶可滚；移动端表单 `maxLines:3` 固定行改 `minLines:3/maxLines:8` 随内容长高封顶内滚。
- **详情描述悬浮预览（防呆设计）**：描述被高度上限截断时，鼠标停留满设定时长在右侧弹全量预览浮层（宽 400px、视口 60% 封顶可滚）。默认开启 + 0.8s 延迟防误滑闪弹；设置 → 待办新增「描述悬浮预览」开关 + 五档延迟（0.3/0.5/0.8/1.5/3 秒），本机 localStorage 不随云同步。
- 探测事件用 pointerover/out（mouseenter 不冒泡在部分嵌入视图收不到）；溢出判定量内层描述节点（wrapper 自身不滚）。
- **验证**：vitest 219（+6 设置存取单测）/ tsc 0 / flutter 定向全绿；浏览器目检四路径（停满弹出/掠过不弹/移开即关/开关档位生效），设置页 GUI 操作直验 localStorage 写入。

### 日历拖拽改期 + 同步排查清账四连——增量历史/假成功/探测分类/移动恢复链

竞品交互与同步排查报告遗留问题双批次清账（07 backlog #46/#47）：

- **日历月格拖拽改期（#46）**：月历任务圆点直接拖到目标日期格改截止（Todoist/Things 标配）。时间语义纯函数 `rescheduleDue`——原截止带时刻只换日期保留时分秒；零点/无截止落到目标日 18:00（视图归一口径）；同日回拖不写库。单测抓出「零点分支先于同日判断」真 bug。
- **增量同步历史（P1-17）**：`sync_history` 表此前唯一写入方是全量备份，增量同步零历史。引擎三入口（sync_now/push_only/pull_then_push）统一记历史（skipped 不记、模块级错误按 failed、计数=模块+附件），各类型 prune 保 50 条防涨表；设置页新增「同步历史」展开卡（状态/类型/耗时/拉推计数/失败原因）。
- **自动备份假成功（P1-15）**：磁盘满等本地写入失败原报 ok:true 推进 last_backup_at——用户静默丢备份。现 local_error 检查：失败不推进时间、emit ok:false；前端区分本地失败/仅云端/未产生副本三态。
- **附件探测错误分类（P1-2）**：S3/WebDAV `asset_exists` 对 HEAD 非 2xx 一律当「不存在」——权限错触发重复上传、限流被掩盖。抽共享 `classify_head_status`：404/409 才判不存在，401/403/429/5xx 透传分类错误。
- **移动端恢复链（P1-20）**：「立即同步」key_mismatch 不再吞错——toast +「去恢复」跳同步设置页；密码卡新增「导入密钥包恢复」（读桌面导出 JSON → 结构校验 → 密码框 → importBundle force），换机/key_mismatch 自愈路径打通。
- **附件图片预览 blob 泄漏**：createObjectURL 从不 revoke，每预览一次泄漏整份图片字节——load 即 revoke + 60s 兜底。
- **验证**：cargo 440（+12）/ vitest 213（+6）/ tsc 0 / e2e 14 / flutter 245（+2）全绿；拖拽链浏览器合成指针事件目检三路径（保留时刻/零点归一/同日不写库）。

### 桌面驻留内存优化——隐藏降档 + 超时回收 WebView（ADR 0006）

实测托盘驻留期间 WebView2 整树 ~330MB 提交内存纯闲置且隐藏后不裁剪（Chromium 平台行为）。本批两层回收：

- **① release 摘 devtools**：Cargo features 去掉 devtools（debug 构建恒开不受影响），发版口径不再给用户开 F12（避免暴露 SQLCipher 数据流）。
- **② 隐藏降档**：关窗隐藏即调 `ICoreWebView2_19::SetMemoryUsageTargetLevel(Low)`（WebView2 ≥114），唤起恢复 Normal——几分钟内驻留即时生效，JS 不暂停、事件仍可达。
- **③ 超时回收**：隐藏 5 分钟未唤起即销毁主窗（四守护在 Rust 宿主继续跑），常驻回落 ~40MB；托盘/热键唤起按 tauri.conf 重建（window-state 恢复位置尺寸 + Mica 重应用 + 前端冷启动）。
- **隐性成本闭环**（事件不排队，逐通道兜底）：重建=冷启动自愈 sync-progress/db-change（useStartupSync 重跑补同步）+ key_mismatch 重新捕获导航恢复页；销毁期快速新建请求经 pending 标志补发（托盘菜单/热键同语义）；销毁期热键由壳层 Rust 兜底接管 Alt+Shift+O。
- **唤起统一收口**：托盘菜单/单击、全局热键三处散落的「显示主窗」合并为 `show_or_create_main_window`（窗口在→显示，不在→重建）；热键改走 `show_main_window_cmd` 命令（前端窗口 API 在销毁态无兜底）。
- **回收销毁后进程保活**（实测发现的连带 bug）：tauri 默认「最后一窗 Destroyed → 请求退出」，窗口回收会杀掉全部守护——`App::run` 回调拦截 `ExitRequested` 非退出态一律 `prevent_exit()`；托盘真退出经 `mark_quitting` 标志放行。实测：300s 回收 destroy Ok 后进程存活、WebView2 树归零、宿主仅 53MB 工作集 / 10MB 提交（优化前整树 300+MB）。
- **验证**：壳层 15 单测（+2）/ tsc 0 / vitest 207 / e2e 14 全绿。遗留：托盘单击/热键触发重建属人工验收项（自动化注入对 Shell 托盘不可达）；release 端到端复测须走 `tauri build`（裸 `cargo build --release` 编入 devUrl，系 Tauri dev/prod 由 CLI 注入决定）。

### 通知历史中心——提醒呈现轨迹可回看（#5）

桌面 Windows Toast 一旦错过或清掉就无处回看（Todoist 有专门通知页对照）。本批落地只读本地日志通道：

- **core**：`notification_log` 表（0001 单文件迁移；kind 类型 reminder_due/snooze/complete/boot_skip + 任务标题快照——任务后续被删仍可读 + payload JSON）——**只读本地表不进 SYNCABLE_TABLES**（各端各自记录呈现轨迹，跨端混看无意义，口径同统计表）；`notification_log_api`（log 记录-不 emit 事件 / list 倒序分页 kind 过滤 / clear / prune 30 天 TTL）+3 单测。
- **写入点**（桌面 scheduler）：提醒到期呈现处（emit 前 spawn 落库，失败静默不阻塞主链）+ 系统通知推迟 action 成功处（snooze_until 快照）。
- **桌面 UI**：设置页「通知历史」分类（倒序列表 + kind 图标徽标 + 当日/跨日时间展示 + 清空）；ipc-mock 种子三条同构。
- **验证**：cargo 428（+3）/ vitest 207 / tsc 0 / e2e 14 全绿。

### ICS 日历导出三端落地——VTODO 日历供日历软件导入/订阅（#4）

local-first 用户的任务常要"输出"到系统日历/其他日历软件订阅：写 .ics 纯导出零账号依赖，与「数据主权」叙事一致；本项目已有节假日+日历视图，数据现成。任务用 RFC 5545 `VTODO`（非 VEVENT——完成/优先级语义只有 VTODO 承载；Google Calendar 显示为任务，Apple 日历导入为提醒事项）：

- **core**：`ics_export_api`——全任务映射（标题/描述 RFC 5545 转义 / 优先级 9 级映射（任务 5 档→ics 1-5）/ 截止 DUE 带本地 VTIMEZONE 保证跨时区不漂移 / COMPLETED+STATUS 完成态 / 项目名→CATEGORIES / UID=uuid@orbit 稳定标识）；只读导出不 emit 不进白名单（同明文导出口径）+4 单测。
- **桌面**：设置页数据导出卡「导出日历」按钮（保存对话框 filters .ics）。
- **移动**：FRB 桥（counts 用 `Vec<IcsTableCount>` 规避 BTreeMap 过桥差异）+ 设置页导出卡「导出日历（ICS）」按钮（文档目录 exports/ 落盘）。
- **验证**：cargo 425（+4）/ vitest 207 / flutter 243 全绿。

### Android 桌面小组件 + 快捷设置磁贴——不进 app 勾任务（#3 存在感链条补全）

TickTick/MS To Do 的待办 widget 是安卓用户高频入口，与本应用已落地的角标计数、通知完成按钮同属「存在感」链条，唯独 widget 空白。本批三端全链落地（home_widget 0.9.4 数据面 + 自写原生交互层）：

- **Rust 核心**（`orbit-core/api/widget_api.rs`）：`widget_todo_query` 快照查询——今天截止或已逾期的未完成任务（与 B6 角标 `dueTodayOrOverdueCount` 同口径）按优先级降序取前 N 条（clamp ≤10）；`widget_todo_toggle` 勾选落库——完成复用 `complete_todo_task` 全语义（重复任务推进下一实例 + 提醒行平移），取消完成是反悔场景：普通任务裸 UPDATE 复位三件套，重复任务静默不动（完成时下一实例已克隆，取消放大成克隆连锁不可接受）。5 组单测（今日口径过滤/limit 截断/勾选双向/重复反悔幂等/NotFound）。
- **Android 原生层**（5 个 Kotlin 文件 + 资源）：`TodoWidgetProvider`（继承 home_widget HomeWidgetProvider 拿数据面；RemoteViews 列表 + 勾选模板广播 + 标题打开 app）；`TodoWidgetViewsService`（数据面 N 行展开，勾选视觉 = checked/unchecked 两份布局选一——RemoteViews 无跨进程 setChecked）；`TodoWidgetToggleReceiver` → `TodoWidgetHost`（勾选转发中枢：引擎存活 MethodChannel 直发，被杀则积压队列下次 attach 冲刷 + 拉起 Activity）；`TodoTileService` 快捷设置磁贴（副标题实时计数与 widget 共用同一数据面快照，API 34+ 一键添加反射兜底）；布局/drawable/strings 双主题资源 + widget_info（2×2 起步可调 4×3）。
- **Dart 侧**：`TodoWidgetService`（HomeWidgetApi 注入式包装——快照写入 `widget.items.N.*` + header.count、勾选 MethodChannel 监听、点击流路由；全异常吞不炸主流程）；BootGate 三口接线（ready attach+首刷 / dbChanges 重刷 / resumed 重算——与角标同款刷新链）+ 设置页「桌面小组件」卡（手动刷新 + 磁贴一键添加 + 引导文案）。
- **顺手修复（构建链断裂）**：`flutter_app_badger`（discontinued，compileSdk 29）在 AGP 9 + Java 17 工具链下无法编译——`flutter build apk` 本仓自引入角标功能以来首次真正跑通即暴露。角标替换为自写 `BadgeChannel` 原生实现（小米/华为/OPPO 主流 ROM 广播协议核心子集，ShortcutBadger 同款机制），BadgeService 注入口设计兑现（`badge_test` 零改动全过）。root gradle 补 AGP 9 迁移期 namespace 注入（无 namespace 老插件从 manifest package 属性回填）。
- **验证**：`flutter build apk --debug` 成功（原生层全链编译）；cargo 421 全绿（+5）；flutter 243 全绿（+4）；analyze 0 新增。遗留：真机验收（模拟器无桌面 widget 交互面）。

### 任务模板三端落地——第 11 张同步表（周报/报销单/差旅清单免从零搭）

竞品矩阵高价值缺口榜首：全仓 template 零命中，MS To Do 步骤列表/Vikunja Templates/Snippets 全有。周报、报销单、差旅检查清单这类多字段任务每次从零搭建（标题+子任务+提醒+标签）。本批作为第 11 张同步表落地（附件第 9、筛选器第 10 的链路成熟可复制）：

- **core**（0001 迁移单文件策略）：`todo_templates` 表（name + payload JSON + 软删三件套 + uuid UNIQUE 索引）；`template_api.rs` CRUD（payload 白名单键校验 title/notes/priority/due_offset_days/subtasks + subtasks 必须字符串数组，防任意 JSON 进库）；SYNCABLE_TABLES + SYNC_MODULES 双白名单同步收录（`modules_match_syncable_tables_exactly` 不变量断言把两处锁死）；写路径 emit db-change。
- **设计口径**：payload 自包含（不引用项目/标签实体 id——跨设备 id 不稳定，同步语义才稳定）；套用 = 前端按存在键预填表单（纯 UI 行为，不过 IPC）。
- **桌面**：任务面板头部「模板」下拉（有模板才显示）→ 套用打开表单预填标题/描述/优先级/截止偏移（模板 > 日历右键 > 视图默认的合并顺序）+ 子任务草稿整组灌入；设置页「任务模板」分类（新建/编辑五字段弹窗 + 删除，payload 摘要一行展示）；`template-apply.ts` 纯函数单测 7 例。
- **移动**：FAB 长按弹模板选择 bottom sheet → `showTodoFormSheet` 新增 `presetTemplate` 参数预填四字段，保存后逐条建子任务（部分成功口径同标签挂载）；`template_apply.dart` 纯函数单测 7 例；GlassFab/AlphaIndication 补 `onLongPress`。
- **验证**：cargo test 416 全绿（模板 API 5 新例 + 不变量断言）；vitest 207 全绿（+11）；flutter test 239 全绿（+7）；浏览器目检全链（种子模板 → 面板下拉 → 套用 → 表单标题/优先级/截止+3 天/三子任务全预填 → 设置页管理分区渲染）；e2e 冒烟 14 过。

### 数据库维护一键化 + 内存治理三连——WAL/VACUUM/附件 GC 落地双端设置页

对标 SQLite 长期运行维护最佳实践（浏览器/Signal 同款 `PRAGMA optimize` + 定期 VACUUM 路径），本批把只读维护从「用户不可达」变为设置页一键操作，同时治理三处实打实的内存/磁盘问题：

- **`db_maintenance` 一键维护命令**（orbit-core 新 `api/db_maintenance_api.rs`）：WAL checkpoint（`wal_checkpoint(TRUNCATE)` 截断 -wal）→ 附件 GC（复用 `gc_local_attachments` 清孤立文件）→ `PRAGMA optimize`（analysis_limit 采样更新查询计划统计，排序/筛选查询提速）→ VACUUM（整库重写回收软删/编辑留下的碎片页）；返回量化结果（空闲页前后对比/回收页数/附件清理数）。只读维护：不 emit db-change、不进同步白名单（与统计类 API 同口径）。桌面 `db_maintenance_cmd` 命令 + 设置页「数据库维护」卡（结果就地展示）；移动端 FRB `maintenance.rs` 镜像 + 桥三件套同口径 + 设置页维护卡；Rust 单测（碎片制造→VACUUM 归零→数据不丢）。
- **修复 PRAGMA 只进首连接的潜伏 bug**：`pool.rs` 原实现池建好后对池执行 `PRAGMA key`/`foreign_keys`——sqlx 池是惰性建连接的，该写法只命中第一条连接。SQLCipher 库在并发场景下取到第二条未解密连接会读出密文（潜在数据损坏级 bug），外键约束同理全程只对首连接生效。改为经 `SqliteConnectOptions::pragma()` 注入（sqlx 保证每条连接建立时逐条执行、key 最先），新增并发取满池连接逐条断言 foreign_keys/cache_size 的单测。
- **连接池收紧 10→6 + page cache 显式封顶**：同步 push/pull 早已串行化（WebDAV 并发 MKCOL 503 两轮踩坑后收敛），池 10 是过时口径；每连接 `cache_size` 显式封 8MB（默认下大查询会逐连接膨胀到几十 MB 不归还），多连接内存占用从「不可预期」变为「6 × ≤8MB 封顶」。
- **桌面 React Query 非活跃查询 gcTime 10 分钟**：视图切换产生的查询缓存（搜索/排序/筛选组合 key）不再无限累积驻留内存，staleTime 30s 内重进视图秒回不受影响。
- **验证**：cargo test 全量绿（新增 2 用例：池 PRAGMA 逐连接 + 维护流程）；桌面 typecheck/vitest 200 绿（ipc-mock 同口径补零值实现）；flutter analyze 0 新增 + 全量 228 绿（mock 桥零值同口径）。

### 列表逾期置顶分组——未完成逾期任务永远先被看见（双端）

Todoist/MS To Do 信息层级惯例：逾期任务是最高优先级信息，混在长列表里等于不可见。本批双端列表视图落地「逾期」置顶区块：

- **桌面**：`task-list-view` 顶部渲染红调「逾期 · N」区块头 + 逾期行（非虚拟化、量有限），其余任务照旧虚拟化渲染（数据源换 rest，行内红字/`OVERDUE_COLOR_CLASS` 语义保持）；无逾期时零视觉噪音（不渲染区块）。共享纯函数 `groupOverdueFirst` + 4 用例（分组判定/边界等于 now 不算/组内保序）。
- **移动端**：`task_logic.dart` 同口径 `groupOverdueFirst` + 4 用例；`sub_list_screen` 非重排档 ListView 单 builder 前置逾期行 + 区块头 + 「其余任务」分隔行（保持懒加载），重排档（manual 拖拽语义）维持原列表不分组。
- 判定口径与行内 overdue 一致：`due_date < now && !done`；分组纯展示拆分，拖拽 position 落位与键盘导航语义不受影响。

### 桌面快捷键帮助面板——? 呼出速查 + 设置页常驻入口

全仓审计高价值缺口：j/k 导航、Ctrl+Z 撤销、Ctrl+P/K、Shift 区间多选等一大批快捷键已落地但零 discoverability（设置页四卡无任何说明区、title-bar 只有代码注释），新用户无从知晓，快捷键等于白做。Todoist/Things 3 同款 ? 呼出帮助惯例，本批一次补齐：

- **常量表单一口径源**：`features/todo/shared/shortcut-help.ts`——全局（Ctrl+P 命令面板 / Ctrl+K 全局搜索 / Ctrl+Z 撤销 / ? 帮助）+ 任务列表（j/k 移焦点、Enter/Space 开详情、Shift+点击区间多选）+ 任务详情（Ctrl+Enter 提交评论、Esc 关闭）三组 11 条；`isHelpShortcut` 判定纯函数（Shift+/ 命中、Ctrl/Cmd 组合不劫持、纯 / 不命中防输入框误触）。
- **呼出链路**：TitleBar 全局 keydown 补 ? 分支（输入框/文本域聚焦豁免——正文打问号不误弹）→ app-store `shortcutHelpOpen` → AppShell 平级挂载 ShortcutHelpDialog（Radix Dialog + kbd 键位徽章；复合键 Ctrl+P 拆分为 Ctrl + P 徽章组渲染）。
- **设置页入口**：左导航第五分类「快捷键」（Keyboard 图标）+ ShortcutsSection 分区渲染同常量表——改键位只改一处，两入口永不漂移。
- **验证**：vitest 新增 7 用例（分组结构 / 键位唯一性 / isHelpShortcut 三类边界）全量 196 绿；浏览器目检 ? 呼出（三组 + 15 徽章 + 复合键完整）、Esc 关闭、设置页分区渲染（10 徽章）；e2e 冒烟 14 全过。

### 移动端生物识别解锁落地——指纹代替主密码解锁加密库（半成品收编）

全仓审计发现 `orbit-core/src/crypto/biometric.rs` 自初始提交就有完整实现（`biometric_unlock_db_key` 带四组单测，文件头连 Dart 侧密钥链结构都设计好了），但全仓零消费点——pubspec 无 local_auth/flutter_secure_storage、unlock_page 纯密码输入，「地基已打、房子没盖」。Tasks.org/TickTick/MS To Do 移动端全有指纹解锁，与本项目 SQLCipher 加密本地库卖点天然契合。本批纯移动端接线（core 加解密函数零改动）三端链路一次落地：

- **Rust 桥**（orbit-flutter 新 `api/biometric.rs`，消费既有 core 函数）：`biometric_setup(db_key_hex)` 生成密钥链三件套（32B 随机 Biometric Key AES-256-GCM 加密 DB Key，Base64 供 Dart 落 Secure Storage）；`biometric_unlock` 三件套解出 db_key_hex——对齐 masterAuthUnlock 契约不直通 DB 初始化，与密码路径在 BootGate 汇合保持单一路径；`biometric_disable(password)` 关闭前主密码验证（verify_master_auth，防误触）。
- **Dart 侧**：`BiometricService`（注入式 gate/store 分层，local_auth 指纹闸门 `biometricOnly: true` + flutter_secure_storage 三键存取，编排全在服务层）；OrbitBridge 抽象/RustOrbitBridge/MockOrbitBridge 三处同口径补方法（mock 闭环可测）。
- **UI**：UnlockPage 已启用且硬件可用时展示「指纹解锁」按钮（点击走闸门+解密→同 onUnlocked 回调；密钥链损坏 `[biometric_failed]` 展示错误回落密码路径）；设置页安全卡由只读文案升级为指纹开关（开启=密码确认弹窗→闸门→落键；关闭=密码确认→删键；无指纹硬件回退只读提示）。
- **平台接线**：MainActivity 改继承 `FlutterFragmentActivity`（local_auth BiometricPrompt 硬性要求）+ manifest 声明 USE_BIOMETRIC；local_auth 3.0.2 / flutter_secure_storage 10.3.2。
- **边界**：密钥链仅存本机 Secure Storage 不进云同步（设备各自启用）；改密不换 DB Key（v2 方案）无需重置三件套；主密码重置另生新 DB Key 时解锁必败，UI 引导密码路径重开。
- **验证**：cargo test 409 全绿 + FRB codegen 一致性过门禁；flutter analyze 0 新增问题；新增 20 用例全绿（桥/服务单测 14 + UnlockPage 指纹入口 3 + 设置页开关 3）+ 全量 228 例全过。

### KeyMismatch 恢复引导失效修复——错误 tag 双层方括号 `[[key_mismatch]]` 致前端正则失配

用户报告设置页「立即同步」仍弹原始 `[[key_mismatch]] Data Key 与云端密文不匹配…` 报错，没有跳恢复页。根因：`CloudSyncError::category_tag()` 返回的 tag 自带方括号（`"[key_mismatch]"`），双端桥层 `format!("[{}] …")` 又包一层，产出 `[[key_mismatch]]`；前端 `syncErrorTag` 正则 `^\[(\w+)\]` 遇双括号失配返回 null——设置页 `key_mismatch → navigate("/sync-recovery")` 引导分支永不触发，KeyMismatch 退化成裸报错（后台 `sync-key-mismatch` 事件链路正常，仅手动同步受影响）。

- **core**：`category_tag()` 返回纯 tag（`key_mismatch`/`password`/`database`/`network`/`other`，不带括号），桥层统一由 `format!("[{}] …")` 加括号——单层 `[tag] message` 格式全链一致；error.rs 四个单测断言同步修正。
- **影响面**：桌面 `cloud_sync_cmd.rs` err_tagged、移动 `orbit-flutter/api/sync.rs` 三处 category_tag 拼接点全部自然修正（无需改调用方）；移动端错误处理用 `contains` 子串匹配本就不受双括号影响，桌面正则解析恢复匹配。
- **验证**：cargo test 409 全绿 + 双壳 cargo check/tsc 0；node 复刻正则对比——修复格式解析出 `key_mismatch`、旧双层格式解析 null（即用户遇到的失效路径）。

### 悬浮提示统一主题色底白字——热力图 tooltip 不再灰白（双端口径）

用户反馈统计页热力图悬浮提示不是项目蓝。排查发现桌面热力图的手搓 Portal tooltip 用了 `bg-popover`（弹层灰白色），而全项目 shadcn `TooltipContent` 原语一直是 `bg-primary`（主题蓝底白字）——热力图是唯一偏离；移动端热力图/表单优先级的原生 `Tooltip` 也走 Flutter 默认黑灰底。本批统一悬浮提示口径并写入 AGENTS.md：

- **桌面**：`heatmap-calendar.tsx` Portal tooltip 改 `bg-primary text-primary-foreground`（去掉 border，对齐 `ui/tooltip.tsx` 原语）；Playwright 实机断言 tooltip 计算样式 `oklch(0.55 0.22 264)` 蓝底 + `oklch(0.99 0 0)` 白字。
- **移动端**：`app_theme.dart` 新增全局 `tooltipTheme`（主题强调色底白字、圆角 8、12px 字），热力图与表单优先级按钮两处原生 Tooltip 一并统一，无需逐处覆写。
- **AGENTS.md**：快速原则新增「悬浮提示统一主题色底白字」条目，桌面原语口径 + 移动端全局 tooltipTheme 单一口径，防后续新视图再踩 bg-popover 坑。
- **验证**：tsc 0 错误；vitest 189 全绿；flutter analyze 本批 0 新增（badge_test 既有 warning 非本批）；移动 stats 测试 3 绿含热力图用例。

### 同步密钥方案 v2——Data Key 由密码确定性派生，KeyMismatch 分叉态结构性消灭

后台自动同步报「Data Key 与云端密文不匹配：本地已解锁但解密云端数据失败（重输密码无效）」，根因是 v1 密钥模型：Data Key 随机生成、靠云端 crypto/config 分发——两台设备各自 init 生成两把 Key，云端数据被 A 加密而本机持 B，密码正确也无济于事。本批对齐 SiYuan 密码派生模型（同密码跨设备必然同 Key），三端落地 v2 方案 + v1 存量兼容 + 恢复路径补全：

- **v2 派生（`derive_data_key_v2`）**：`salt = PBKDF2(密码, "orbit-sync-v2-salt", 1)`、`data_key = PBKDF2(密码, salt|"orbit-sync-v2-key", 600k)`——密码即 Key，PBKDF2-HMAC-SHA256 600k 与 v1 强度一致。meta 新增 `key_derivation: "v2"` 标记（serde 兼容：v1 存量文件无此字段按 v1 读）；`encrypted_data_key` 字段保留为「验证子」——unlock 时解包装验密码 + 重派生比对双重校验，防 meta 篡改后静默换 Key。
- **v1 全兼容**：unlock/init_with_data_key/rotate_key/改密按 meta 版本分路，v1 存量设备行为不变（老云端数据继续可解）；v2 下 rotate_key 语义自相矛盾改为拒绝（换 Key=换密码）。
- **v2 改密即换 Key**：`change_sync_password` 写 v2 meta 并切换内存 Key；桌面/移动命令层编排「改密 → rekey 全量重传 → 失败回滚本机密码」，用户一次操作完成，其他设备输入新密码即可同步。
- **rekey 全量重传原语（`rekey_cloud_reencrypt`）**：清空 sync_state（全模块强制重传）→ push_all 新 Key 加密 → 附件 `is_uploaded` 清零重传（新增 `mark_all_unuploaded`）→ 上传新 crypto/config。v2 改密、v1→v2 迁移、KeyMismatch 恢复三场景共用；锁内执行 + 未解锁拒绝（不动云端）。
- **引擎 v2 分支**：本地 meta 为 v2 时跳过云端 bundle 导入（同密码必同 Key，导入无意义），一致性由既有解密探针校验——v2 下 KeyMismatch 仅剩「云端数据是另一个密码加密」一种真实成因，恢复页语义随之改写。
- **恢复页重构**：路径 1「输入加密云端的那台设备的密码」（同密码必然同 Key）；路径 2「以本机为准重置云端」（`cloud_sync_rekey`，红色危险操作，明示本机没有的数据将丢失——单设备用户此前无任何自救出口，本批补上）；v1 设备额外显示「升级到 v2」迁移入口（`sync_crypto_upgrade_v2`）。v1 时代的「导入 bundle 文件」路径移除（确定性 Key 下跨设备只需密码本身）。
- **e2e 加前置清理**：m4 双实例收敛用例此前不清理 base_path 残留，上次运行密文会让下次首推 KeyMismatch（本批开发中实际踩到）；现在每轮从已知空态起步。
- **测试**：sync_crypto 30（跨实例同密码同 Key/篡改检测/改密换 Key/v1 兼容/迁移幂等）、engine 28（v2 双设备探针通过/跨密码仍报 KeyMismatch/rekey 未解锁拒绝）、m4 e2e 双实例收敛在真实 WebDAV 验证 v2 端到端（B 同密码 init 后不依赖 config 导入即收敛）；桌面 vitest 189 全绿；移动 208 全绿。

### 完成热力图重构——对齐 wait-home 活动热力图（按年视图 + 年份切换）

统计页热力图此前是 35/182/371 天窗口档位 + 绝对计数分桶（1/2-3/4-6/≥7 五档），与 wait-home 的活动热力图（GitHub 贡献图式按年视图）观感差异明显。本批全面重构对齐，双端显示效果一致：

- **按年视图**：当前年 = 滚动 365 天（今天往前 364 天，跨年覆盖去年同日至今，不受"今年未过完"限制）；历史年 = 完整 1/1~12/31。`stats_aggregate` 入参 days→year，返回新增 `available_years`（有完成记录的年份升序去重，空则回退 [当前年]），替代原窗口档位切换。
- **色阶重设计（wait-home 同款）**：锚定最大档至少对应 4 条完成——1/2/3 条各占一档浅色，≥4 按相对比例分档（≤25%/≤50%/≤75%），alpha 22/45/68/90%；避免"仅 1~2 条完成却显示最深色"。空格用中性 muted/surfaceSecondary。
- **布局升级**：顶部月份标签（最小 4 列距防重叠）、左侧 周一/周三/周五 行标、右侧竖排年份按钮（降序、选中态强调色）、底部 少/多 图例。桌面 CSS grid + ResizeObserver 格宽自适应（≥8px 撑满可用宽度）+ Portal tooltip；移动端 12dp 格横滚 + Tooltip。悬停/长按提示「日期：完成 N 个」，副标题「{year} 年 · {N} 个完成」双端同文案。
- **core 顺带修正**：`local_day_index` 原 ordinal0+year×366 拼接在跨年边界不单调（12-31 与次年 1-1 相差 366-365 不等，滚动窗口起点直接暴露 366 格错位），改 num_days_from_ce 单调换算。
- **实现拆分**：桌面铺格/分档/月份标签过滤抽 `shared/heatmap.ts` 纯函数（vitest 7 用例：窗口口径/分档锚定/月份标签防重叠）+ `heatmap-calendar.tsx` 组件；移动端新增 `todo_heatmap.dart`（wait-home activity_heatmap 同构）。
- **放调优（同日三轮用户反馈）**：①"框太小挤、行标错位"——统计容器 max-w-3xl→5xl；双端周一/周三/周五行标由「首尾均分」改为与网格行同构的 7 槽精确对位（旧法"周三"中心落在周四行中心，格小错位明显）；移动端格 12→14dp。②"占满框框"——桌面格宽改动态撑满（测量目标=热力图块外层 w-full 容器 + clientWidth 直读/窗口 resize 双通道，规避 overflow 容器 ResizeObserver 首帧窄值上报与 minWidth 反撑自引用；floor 取整防差 1px 溢出），窄窗钳 12px 下限走横滚；实机断言 1280/1200/700 三档视口：格 14/13/12px、年份栏右缘贴卡片右缘、行标 356.5/386.5/416.5 逐像素对齐、宽屏无溢出窄屏横滚正常。③"滚动条对齐全项目标准"——热力图横滚容器去掉 scrollbar-width:thin（违反全局 index.css 禁用条款：非 auto 值会禁用 ::-webkit-scrollbar 自定义退化系统原生条），改走全局 10px 透明轨道主题色圆角滑块（实机断言横条占位恰 10px）；年份栏隐藏条三件套对齐全局 Radix viewport 同款写法；移动端 SingleChildScrollView 不挂显式滚动条维持全项目惯例（全局 ScrollbarThemeData 仅供显式 Scrollbar 用）。
- **测试**：Rust 9（当前年滚动窗/历史年完整年/available_years 回退/聚合七路）；桌面 vitest 189 全绿；移动 widget 3（总览+热力图渲染/色阶锚定 max≥4/空态）+ 全量 208 绿。门禁：cargo 391（m4 WebDAV 用例环境依赖失败为已知非回归）+ tsc 0 + flutter analyze 本批 0 + 浏览器实机几何断言（行标与网格行中心逐像素对齐 362/390/418、格 12px、年份切换/tooltip/色阶分布正确）。

### 回收站彻底删除/清空可撤销——延迟提交 + 5s 撤销窗口（双端）

回收站的「彻底删除」与「清空回收站」此前一点确认即物理落库（任务连同子任务/评论/提醒一并删除），误触无任何退路；任务列表的普通删除却早有 5 秒撤销窗口，两处心智不一致。本批对齐：purge 类操作同样乐观隐藏 + 5s 窗口内可撤销，窗口过后才真正提交。核心约束：purge 是物理 DELETE，撤销只能在**提交前拦截**——数据在窗口期内始终在库，点撤销即取消提交，不存在"删了再恢复"的后端语义。

- **桌面**：trash-page 两个 purge 动作接入既有 `use-undoable-delete`（P0#3 延迟提交同款）；清空走整批单笔（一次隐藏全部 + 一次提交，批量删除同款单槽位口径）；确认弹窗文案从「不可恢复」改为「5 秒内可撤销」。
- **移动端**：`WaitToast` 扩展 actionLabel/onAction 右侧动作钮（带动作不自动收起，同 onTap 口径）；trash_screen 自建轻量延迟提交调度（乐观隐藏 `_hiddenIds` 过滤显示 + 单槽位 Timer + dispose 兜底立即提交，同桌面卸载 flush 语义）；提交闭包捕获 bridge 而非 ref（dispose 路径 fire 时 ref 已不可用）。
- 测试：移动 trash_test +2 用例（5s 内撤销→行恢复且库未删 / 不撤销→窗口后物理删除）；e2e 回收站拆出独立 purge 用例（撤销→行回归 + 不撤销→落库空态）。门禁：桌面 tsc 0 + vitest 182 全绿 + e2e 14/14；移动 analyze 0（本批文件）+ 207 全绿。

### B6 Android 图标角标——今日+逾期未完成数，双口刷新

应用图标此前无未完成数角标，一屏外任务存在感缺失（TickTick/MS To Do 有）。本批落地：启动器图标显示「今天截止或已逾期」的未完成任务数。

- **计数口径 `badge_count.dart`**：`dueTodayOrOverdueCount`（今天截止 + 已逾期、未完成）——逾期未完成仍是"今天要做的事"，比纯"今天截止"快捷视图更贴近实际；跨零点由 resumed 口自然校正。
- **`badge_service.dart` 注入式**：默认实现走 flutter_app_badger（count<=0 → removeBadge 显式清零）；厂商 ROM 兼容由 ShortcutBadger 内部处理，任何异常全吞（角标属锦上添花绝不炸主流程）；包已标 discontinued，注入口留换实现后路（自写 MethodChannel + ShortcutBadger）。
- **BootGate 双口刷新**：`_goReady` 尾 + dbChanges 回调（本地写/同步拉取后）经 `_refreshBadge` 重拉任务集算数；`didChangeAppLifecycleState resumed` 重算——`ref.listen` 仅限 build 期，异步流程用直拉模式。
- 测试：badge_test 8 用例（计数四态 + 空列表 + 服务透传/清零/吞错）；门禁 analyze 0 + 定向 26 用例全绿。真机厂商 ROM 角标形态为手动验收遗留项（小米/华为/三星各家支持度不一）。


### B5 通知「完成」按钮——前台直完、后台横幅提示（与推迟同构）

提醒通知上的 action 此前只有推迟三档（推迟10分钟/30分钟/1小时），任务完成后仍要进 app 勾选。本批在通知 action 首位加「完成」按钮（TickTick/MS To Do 标配）。

- **前台路径**（进程存活）：`_onForegroundResponse` 命中 complete → cancel 原通知 + 经 BootGate 注入的 `onCompleteAction` 直调桥 `todoTaskComplete`——dbChanges 事件自然失效业务缓存 + 调度器重排闹钟，完成实例的提醒行由引擎软删（2090473 口径）。
- **后台路径**（进程被杀）：与推迟通道完全同构——后台 isolate 无法重入 FRB 库，不写 DB；cancel 原通知 + 静默渠道确认横幅「已标记完成，打开应用后生效」；DB 落地由用户打开应用后自然完成。
- **后台入口统一分发器**：`onSnoozeBackgroundAction` 更名 `onBackgroundAction`（@pragma vm:entry-point 保留），内部分发 snooze/complete 二路；两处 initialize 注册同步更新。
- 通知 id 三段互斥域：闹钟域 `alarmIdFor` / 确认域 `confirmIdFor` / 待完成横幅域 `pendingCompleteIdFor`（确认域 +500000000），原私有 `_alarmId/_confirmId` 公开化供测试锁定口径。
- 测试：notification_complete_test 3 用例（action 集合互斥/id 三段互斥/payload 解析）；定向 18 用例全绿（trash_test 两例超时属并发会话移动端回收站可撤销 WIP 的半成品，非本批文件）。


### B3 剪贴板截图 Ctrl+V 直粘附件——DOM paste 零依赖方案

附件此前只能经文件选择器添加，截屏工作流（截图→粘贴）断链，需先落盘再翻文件。本批打通：详情抽屉打开时**Ctrl+V 直接把剪贴板位图存为该任务附件**（Todoist/TickTick 桌面标配）。

- **零依赖**：不装 tauri-plugin-clipboard-manager——Tauri webview 的 paste 事件自带 `clipboardData.files`（截图位图是真 File 对象），配合既有 `taskAttachmentAdd(taskId, name, mime, bytes)` bytes 通道（hash 由 Rust 内容寻址计算）零新增插件/权限。
- **新 hook `use-paste-attachment.ts`**：window 级 paste 监听挂在详情抽屉附件区（范围决策：全局粘进"选中任务"错粘风险高）；焦点守卫——焦点在 input/textarea/contenteditable 时让位原生粘贴；busy 守卫防连粘重复；`extractImageFromPaste`（多文件取首个 image/*、纯文本 null、截图空 name 时间戳生成「粘贴图片_yyyyMMdd_HHmmss.png」）与 `pastedImageName`（jpeg→jpg、未知 mime 回退 png）为纯函数。
- 附件区块底部常驻提示「支持 Ctrl+V 直接粘贴截图」。
- 测试：5 用例（提取/命名/边界）；门禁 tsc 0 + vitest 182 全绿。


### B1 表格视图——ViewMode 第四态，六列概览 + 多选批量 + 键盘导航

视图切换此前仅列表/看板/日历三态，批量整理与全字段一览要逐条展开抽屉。本批补齐 Vikunja 四视图口径的**表格视图**：完成/标题/项目/标签/截止/优先级六列一屏概览，行内直接勾选完成、收藏、我的一天，逾期红字与优先级竖条与列表行同形制。

- **新组件 `task-table-view.tsx`**：`@tanstack/react-virtual` 虚拟化（行高 52）；列宽按权重 grid 模板（`gridTemplateOf` 纯函数，表头与数据行共享同一模板保证列对齐，标题列 minmax(10rem) 保底）；字段组件全复用——PRIORITY_COLOR 左缘竖条、LabelChips(max=2)、dueTextOf（±15 天相对时间与列表同口径）、ReminderChip 双态徽标、项目名按项目色。
- **多选批量**：与列表视图同语义（selected Set + shift 区间选择 + anchor 锚），批量工具条（完成/移回待办/高优先级/我的一天/移入未分组/收藏/删除）；批量删除走 use-undoable-delete 单笔整批撤销 + 确认条。
- **键盘导航**：j/k/↑/↓ 移焦点（list-keyboard 复用），Enter/Space 打开详情（IME 组合期不响应，与列表行一致）。
- **接线**：task-panel ViewMode 四态（localStorage 既有键向后兼容，table 新合法档）；四联钮第四钮 Table2 图标。
- 不做列头点击排序与表内编辑（YAGNI 留后续）；manual 档表格不可拖（与看板一致口径）。
- 测试：列模型 3 用例（六列顺序/中文名与权重/grid 模板串）；门禁 tsc 0 + vitest 175 全绿。


### 视图内新增自动带视图标记——我的一天/今日/本周/收藏四视图新建即归属

在快捷视图内新建任务，此前提交的是「裸任务」（不带任何视图口径），创建后不满足过滤条件、从当前视图**立刻消失**，用户得再去手动加标记。本批对齐项目视图 `defaultProjectId` 的既有注入链路：**视图内新建自动带本视图标记**，注入优先级 NLP 显式值 > 手动选择 > 视图默认，提交/保存瞬间重算（跨零点不落昨天）。四视图口径：我的一天静默附加 `my_day_date=今天零点`；今天截止预填 `due_date=今天 18:00`；本周截止预填 `due_date=当周周五 18:00`（周六/周日给周日 18:00，周一起始周）；收藏静默附加 `is_favorite=1`。**今日/本周视图内创建的截止时刻一律归一当日 18:00**（2026-09-09 口径修订）——NLP 日期词/手动选择/视图默认各来源均只表达日期、无时刻位，经 `atViewDueHour` 统一落 18 点。三个新建入口全覆盖：桌面 QuickAddBar 快加栏、桌面九字段表单、移动端 FAB 表单；**编辑态一律不受影响**（仅创建分支注入）。

- 实现为共享纯函数 `quickViewCreateDefaults` + `weekDefaultDueMs` + `atViewDueHour`（桌面 `view-create-defaults.ts` / 移动 `task_logic.dart` 双端同源）；core 零改动——`TodoTaskCreateInput` 早已支持 `my_day_date`/`is_favorite`/`due_date`，全链透传。
- 测试：桌面 vitest 14 用例（18 点归一幂等/周五锚点边界/四视图矩阵/跨零点重算）+ 移动纯函数 9 + widget 4（我的一天 myDayDate 落库/收藏 isFavorite/今日预填 18 点/无视图回归保护）+ e2e 3（QuickAddBar 视图内新建留在视图 + db 落 my_day_date 断言、收藏表单链路、今日视图默认与 NLP 双路 18:00）。

### A5 通用撤销——Ctrl+Z 全操作可撤销（完成切换/批量全接入）

此前撤销仅删除场景有 5 秒 toast 撤销（use-undoable-delete），完成/批量操作一旦执行无法回退。本批落地通用撤销栈：**Ctrl+Z（macOS ⌘Z）全局快捷键**，覆盖任务完成/取消完成切换与全部批量操作（状态/优先级/收藏/我的一天/移动项目）。参照 Todoist/TickTick 全操作可撤销口径。

- **撤销栈核心（`shared/undo-stack.ts`）**：30 槽位单栈只撤不复（无 redo，YAGNI）；undo 回调经 UndoOutcome 联合类型上抛成败语义，失败弹 error toast 不炸栈；`isUndoShortcut`/`undoToastText` 纯函数（ctrl/cmd+z 命中、shift 组合属 redo 语义不命中）。
- **Provider + 快捷键（`hooks/use-undo-stack.tsx`）**：ReadyShell 挂 UndoStackProvider；Ctrl+Z 监听焦点守卫——焦点位于 input/textarea/contenteditable 时让位浏览器原生撤销；撤销成功全量失效 react-query（与 db-change 同口径）+ sonner「已撤销：xxx（N 条）」。
- **非 React 模块入栈注册点（`shared/undo-bridge.ts`）**：task-actions/batch-actions 经模块级 pusher 注入（Provider 挂载时注册、卸载置空），node 测试与未挂载场景 no-op。
- **接入面**：单条完成撤销=恢复 undone+软删引擎克隆的下一实例（重复任务完成前状态完整恢复）；取消完成撤销=恢复 done；批量六函数全部注册 undo（闭包捕获旧值快照恢复原字段；批量移动项目恢复 project_id+position 双字段；批量完成收集克隆 id 撤销时软删）；部分失败只注册成功条目。
- 批量 toast 提示语补「Ctrl+Z 可撤销」description。
- 测试：undo-stack 7 用例 + undo-bridge 3 用例；batch-actions 既有用例 mock 补 todoTaskDelete 与完成命令返回形状（next_instance 读取）。门禁：tsc 0 + vitest 172 全绿。


### 空状态布局对齐「我的一天」——回收站居中修复 + 统计页补页面级空态

回收站空态此前贴在工具栏下方（视觉上「太上」），与「我的一天」列表空态的居中口径不一致；统计页则没有页面级空状态，无任务时是一堆 0 值卡片顶对齐堆叠。本批统一三处口径。

- **桌面回收站修复（根因）**：空态 div 此前写在 Radix ScrollArea **内部**用 `h-full` 居中——Viewport 内层是 `display:table` 包装（高度 auto），子级百分比高度解析不到视口高度，`justify-center` 失效退化为顶对齐。改为移出 ScrollArea、在普通 `flex flex-1 items-center justify-center` 容器中居中（TaskListView/CalendarView 空态同款口径），并复用共用 `EmptyState` 组件（顺带统一图标样式 `opacity-40` → `text-muted-foreground/40`）。
- **桌面统计补空态**：`overview.total === 0` 时以页面级 `EmptyState`（`BarChart3` 图标，与侧栏统计入口一致；标题「暂无统计数据」+ 提示语）替换整块报表，工具栏（标题/计数/档位切换）保留；有数据时结构零改动。
- **移动端统计补空态**：同判定 `stats.overview.total == 0`（PlatformInt64，IO 平台即 int），逐字复用 trash_screen 已验证模式——`Padding(状态栏+标题栏)` + `EmptyState`（`Icons.insights_rounded`，与侧栏统计入口同款图标）；标题栏与窗口切换常驻。
- **移动端回收站空态本就与「我的一天」同构居中**（SubListScreen 同款 Positioned.fill+Padding+EmptyState），无需改动。
- 测试：移动统计冒烟 +空态用例（清空 mock 种子断言空态替代报表）；e2e 回收站用例恢复断言后顺加空态可见断言。门禁：桌面 tsc 0 + vitest 162 全绿 + e2e 10/10；移动 analyze 0（改动文件）+ stats/trash 测试 12/12（工作区另有并发会话 WIP，其 `task_logic_test.dart` 编辑中报错非本批文件）。

### 侧栏项目行固定 Folder 图标——按项目自选色染色（除未分组）

侧栏项目行此前是 12×12 纯色方块，与其他视图行的图标语言不一致（未分组已是 Inbox 图标）。本批统一为**固定文件夹图标**：桌面展开态/折叠窄条 `Folder`、移动端 `Icons.folder_rounded`，图标颜色随项目自选色（`hex_color`）渲染，无色回退待办强调色 #3B82F6——Folder 在全局搜索项目行、右键「更换项目」、快速添加条已是事实上的项目图标，此番把侧栏也对齐。未分组行维持 Inbox 图标不变；其他展示位（列表行/详情/统计/选择器色点）不受影响。

- 选取口径：图标唯一固定（不随项目换形），颜色随项目设置变化；`Folder` 复用既有视觉语言，无新图标引入。
- 测试：移动端侧栏冒烟补项目行图标断言（folder_rounded 图标 + 种子「工作」#4E8CFF 染色）；桌面纯样式内联改动走既有门禁。

### 统计分布条未完成段同色弱化——进度条全程对应项目/优先级色

统计页「项目分布 / 优先级分布」的条形图，此前的口径是完成段按项目自选色 / 优先级六档语义色渲染、未完成段固定灰——任务大多未完成时整条几乎全灰，看起来颜色与项目/优先级「不对应」。本批统一为：**整条同色系，完成段实心，未完成段同一颜色 25% 半透明弱化**，完成态与未完成态仍可一眼区分，双端口径一致（桌面 DistBar / 移动 _DistSection 各一处样式改动，零后端变更）。星期分布卡本就只有完成段，不受影响。

- 移动端统计冒烟测试补颜色断言：mock 种子「生活」#2DB87A（仅未完成任务，条内只有弱化段）与优先级「高」#F59E0B@0.25 两处反向锁定弱化段=同色而非固定灰。

### 行内提醒徽标——列表/看板/日历/详情四视图贯通

带提醒的任务此前在任务行上无任何标识，只有打开详情抽屉才能看到提醒；提醒已到期与未到期在所有视图里都无差别。本批补齐行内提醒徽标，四大视图统一口径。

- **共享基建**：`reminder-meta.ts` 纯函数（多提醒行选取展示口径：有未来行取最近未来一条、全部过期取最早一条）+ `useTaskReminders` hook（全量提醒 join `Map<task_id, rows>`，`useTaskLabels` 同范式，db-change 全量失效覆盖推迟/续排/完成清理/云同步）+ `ReminderChip` 组件。
- **双态图标**：未来 = `Bell` + HH:mm（muted 元信息色）；**到期且任务未完成 = `BellRing` + 红色 + 脉冲动画**（`OVERDUE_COLOR_CLASS` 与逾期截止同色系——「响过没处理」与「逾期」同为需注意态）。完成实例不红警（P1#10 同口径）。
- **四视图消费位**：列表行元信息行（标签/项目/截止之后）、看板卡底部元信息（含 DragOverlay 浮层副本）、日历右栏/议程/年视图右栏任务行（VirtualGroupedList 全链）+ 月弹层行；我的一天为快捷视图复用 TaskPanel，自动覆盖。
- **详情抽屉提醒区块**：行图标同步双态（未来=Bell muted / 到期未完=BellRing 红色脉冲），到期行时间文字红色。
- **测试**：reminder-meta 纯函数 6 用例（软删过滤/未来最近/全过期最早回落/fired×done 矩阵/边界时刻）；门禁：桌面 tsc 0 + vitest 150 全绿。

### 提醒完成态治理——已完成任务不再提醒 + 到期处置下沉引擎

用户报告两处行为异常，排查确认三层链路（完成命令 / 双端轮询 SQL / 前端监听器）全部漏掉完成态检查：已完成任务照常弹提醒，且前端兜底清理在详情抽屉打开时删行，表现为「提醒时间莫名消失」（关闭右上角弹窗本身不碰数据）。本批在引擎层根治并统一双端口径。

- **完成即清理（P1#10 根治）**：`complete_todo_task` 在同一事务内软删完成实例的存活提醒行（Delete 事件提交后补发）——完成实例不再提醒；软删保留可审计（区别于物理删除）。
- **重复系列提醒延续（废除「不复制提醒」旧口径）**：完成重复任务时，提醒行按 due/start 同款 `delta_ms` 平移后克隆到下一实例（Insert 事件）——「每周任务带周五 9 点提醒」完成后，下一实例自动继承下周五 9 点提醒，不再断档。
- **到期扫描口径下沉 orbit-core（双端同源）**：新增 `list_due_reminders`——`is_deleted=0 + 24h 补扫窗口 + t.done=0 + t.is_deleted=0` 过滤；桌面 `notification_scheduler.rs` 与移动端 `events.rs` 轮询改为调用同一函数（此前两端各自内联 SQL 且都漏 done 过滤，已完成/回收站任务照弹）。变异测试锁定：摘掉 done 过滤测试即红。
- **到期处置下沉引擎（原前端续排逻辑）**：新增 `advance_fired_reminder`——重复任务到期删旧建新排下一次（锚点=原 remind_at 快进，不漂移）+ 防雪球守卫（存在其他未来提醒时只清理不克隆）；非重复/已完成/已删任务只清理。桌面轮询在 emit 后 spawn 调用——**窗口隐藏/托盘驻留时续排不再停滞**（旧实现在前端 JS，`visibilityState=hidden` 直接 return）；前端 `use-todo-reminder-listener` 删掉续排块只负责呈现。移动端 `boot_gate.dart` 的已完成清理块保留为防御位。
- **顺手排雷**：`repeat_tests` 三个集成用例锚定固定历史日期 `2026-08-27`，真实时间越过序列点后逾期快进翻倍步进、期望值随日历漂移（已到引爆日边缘）——改 `local_midnight_days_ago` 相对锚点。
- 门禁：orbit-core 390（+9 新用例：完成清理/克隆 3 + 到期查询 2 + 续排 4）+ 桌面 tsc 0 / vitest 144 + 移动 analyze 0 / 180 全绿（m4 WebDAV e2e 环境依赖失败非回归，既有口径；clippy 警告全为既有，零新增）。

### 0001 迁移全字段中文备注——随 sqlite_master 落库

本地库字段此前在 GUI 工具（DB Browser/DBeaver 等）打开就是裸列名看不懂；SQLite 无 MySQL 式列 COMMENT 元数据，但建表 DDL 原文（含 `--` 注释）会随库文件存进 `sqlite_master`——把备注写进建表语句，任何工具打开库即见。

- **覆盖**：0001_init.sql 14 张表（sync 2 + todo 10 + cfg 4 + sys 1 + 表内 17 个 CREATE）全部业务字段行尾中文备注（192 处）：枚举取值（priority 六档 / status 三态 / relation_type 六种 / sync_type / 调度谱系）、同步语义（updated_at=LWW 主依据、version=同毫秒平局裁决、deleted_at=墓碑口径）、外键去向（→ 哪张表 + ON DELETE 行为）、单位（ms/分钟/小时/天）。口径全部取自现有权威材料（03 文档 §一/§八、repo 文档注释、桌面端标签映射），不发明语义；语义复杂处保留原块注释（repeat_* 四件套、my_day_date）不重复加注。
- **验证**：python sqlite3 内存库跑全量 DDL+种子+治理段一次通过 + 17/17 表注释落 `sqlite_master` 断言；Rust 390 单测 + end_date_migration_check（sqlx::migrate! 真实跑注释后迁移）全绿（m4 WebDAV e2e 环境依赖失败非回归，既有口径）。
- **代价（既有约定内）**：sqlx 迁移 checksum 变更，存量库启动报 checksum mismatch，须删库重初始化（与 end_date 移除同一路径，数据经云同步/备份恢复）；文件头维护约定补「新增/变更字段须同步补写行尾备注」。
- 门禁：Rust 390 全绿。

### 小而美批次四连（并发会话 WIP 收编 + ④ 补完）

竞品矩阵收尾的四件轻量改进，①②③ 为并发会话半成品收编（收编前全量门禁核验），④ 本批补完 Dart 侧后落地。

- **① 列表行子任务进度百分比**（`e127118`）：`percent_done` 由后端按子任务勾选自动回算，0=无子任务不显示、100=已整卡完成不显示；仅中间态显示（MS To Do Steps 同款），ListChecks 图标与标签/项目/日期同元信息行。
- **② 一键复制任务三端落地**（`2e510e3`）：orbit-core `duplicate_todo_task`——克隆标题/描述/项目/优先级/状态/截止/开始/收藏/重复规则全部扩展字段，子任务复制标题+顺序完成态重置；不复制提醒/标签/评论/关联/My Day（社交性字段独立）；position 紧邻原任务之后，标题「（副本）」后缀；桌面右键菜单+详情抽屉复制钮（成功后跳转新副本），移动长按菜单「复制任务」。Rust 用例并入 381。
- **③ 描述只读态轻量 Markdown 渲染**（`680a10c`）：零依赖纯函数子集——# 标题/粗体/斜体/行内代码/链接/无序列表/任务列表字符原样保留/换行；刻意不做完整 CommonMark（描述是短文本场，react-markdown 全家 ~100KB 不划算）；点击编辑交互不变。本批补 10 用例测试（块级 5 + 行内 5，`markdown-lite.test.ts`）。
- **④ Android 分享接收**（本批）：其他 App「分享到」纯文本直接建任务。原生层 MainActivity 经 MethodChannel("orbit/share") 暴露 `takeSharedText`（冷启动 intent + 热运行 onNewIntent 两路都存原生 pendingText，取走即清幂等）；Dart 侧 `ShareReceiver` 在 `AppLifecycleState.resumed` + 冷启动 postFrame 两路轮询消费，过 NLP 短语法解析（与快加栏同源）——命中日期/优先级/项目/标签自动应用并剥离，项目/标签 ctx 用库内既有数据，标签挂载失败不阻断；Manifest 加 `ACTION_SEND text/plain` intent-filter。移动 3 用例（NLP 全命中/纯文本原样/极端剥离回退）。
- **移动端 device_id 接线修复**（随④收编的半成品）：`DeviceIdStore`（应用支持目录 `device_id.txt` 持久化，清库不清除）+ BootGate 两路 init 后 `dbSetDeviceId` 写入 Rust OnceCell——此前移动端完全缺失该接线，generic_repo 的 device_id 自动填充与同步引擎 `validate_config` 依赖此值，云同步在移动端必然报「device_id 不能为空」失败。坑：path_provider 的 platform channel 在 fake_async 测试 zone 永不 resolve（探针实证 3s 假时钟无完成也无 error）——await 会挂死 bootstrap 致 pumpAndSettle 超时，改 fire-and-forget（真机毫秒级 IO 无实用竞态）。
- **编号勘误**：原生层/组件注释曾把分享接收与 Markdown 误标 #37（#37 为拖拽重排），统一改「小而美批次」。
- **e2e 日期敏感假红修复（随手收口）**：日历用例右键今天格用 `getByRole(name: 日期数字)` 定位——getByRole 的 name 是子串匹配，「9」先命中工具栏「9月」标题按钮（日期数字与月份标题撞车的当天才触发，9/7 全绿 9/9 红的根源）；月历日格统一补 `aria-label=YYYY-MM-DD`（屏幕阅读器可访问性顺带受益），用例改 `[aria-label]` 精确定位 + 右键前先「回到今天」（年视图点 1 月后视图在 1 月，今天格不存在）。在 f812b76 复验确认为既有缺陷非本批回归。
- 门禁：Rust 381 / 桌面 tsc 0 + vitest 144 + e2e 10 / 移动 analyze 0 + 180 全绿（m4 WebDAV e2e 环境依赖失败非回归，既有口径）。

### 移动端任务列表长按拖拽重排（#37）

桌面端列表 04 文档起就有 hover 拖拽把手排序，移动端「拖拽顺序」档（manual，默认档）却只能看不能拖——本批补齐触屏重排。

- **列表形态切换**：manual 档用 `ReorderableListView.builder`（`buildDefaultDragHandles:false` + 行尾 `ReorderableDragStartListener` 把手，侧栏项目行同款形制）；其余排序档保持普通 `ListView`（顺序由排序键决定，拖了也会被覆盖——与桌面 `sortable={sortKey==="manual"}` 同口径），把手不渲染。
- **落库口径**：拖拽落位取相邻两条 `position` 的中值写库（新纯函数 `midpointPosition`：prev 缺省 0 / next 缺省 100000，与桌面 `shared/position.ts` midpoint 逐字同源），`todoTaskUpdatePosition` 落库后 invalidate 以服务端权威顺序刷新；失败 toast + 回原序。f64 中值精度在落库时取整。
- **长按语义无冲突**：长按弹操作菜单（编辑/星标/删除）保留不变；拖拽由行尾把手专用手势触发，与 Slidable 左右滑按轴向正交。
- **坑**：ReorderableListView ↔ ListView 切换排序档时新旧树同帧交替，共用单 ScrollController 触发 "attached to multiple scroll views" 断言——双控制器分体（`_reorderScrollController` / `_listScrollController`），标题栏 listenable 按档取用。
- **测试**：纯函数 8 用例（reorderItems 语义插入位/越界防御 + midpointPosition 五口径含连拖精度）；widget 3 用例（manual 档把手渲染/切档无把手/拖拽落位中值 >50000 断言端到端）；全量移动 177 绿。

### 项目颜色：侧栏圆点 + 全展示位项目名着色（#36）

`todo_projects.hex_color` 建库即有但全程无消费方、项目全是一个蓝色。本批把颜色落到所有展示位，并补齐编辑入口。侧边栏保持圆点/色块形制不变，其余位置项目名直接按项目色渲染。

- **桌面展示位换色**：列表行元信息、日历右栏/弹层任务行、表单「所属项目」下拉（`FieldOption` 增 `textColor`，选中值随 Radix SelectValue 回显同色）、快速添加 NLP 预览 chip、详情抽屉项目值 + 选择 Popover、右键「更换项目」菜单、批量「移动到项目」、看板项目列头（原统一 TODO_ACCENT，现用项目自身色）、统计项目分布 label、全局搜索项目行——项目名一律按 `hex_color` 着字，空串回退 `TODO_ACCENT`。
- **桌面编辑入口**：项目右键菜单增「编辑项目」（重命名 + 10 色预设板，与标签管理器同序列）；新建项目默认色按项目数轮换 10 色板。
- **移动端**：列表行副标题项目名着色（`TodoTaskTile` 增 `projectColorHex`）、详情项目值着色（`_InfoTile` 增 `valueColor`）、表单下拉项目名着字（去色块）；长按「编辑」对话框加同款 10 色板；侧栏补「新建项目」入口（此前移动端无创建项目的地方）。
- **测试**：移动 widget 3 用例（项目名着色/空色回退/未分组不渲染）；桌面 vitest 134、Rust 380 回归全绿（本批无 schema/后端变更）。

### 保存的筛选器三端落地（竞品矩阵批次 #35）

对标 Apple Smart List / Tasks.org 可保存过滤器 / Obsidian Presets（四款参考产品全有）：把常用组合条件存为命名视图，侧栏直达。

- **数据模型**：`todo_saved_filters` 表——条件为 JSON 文本，键白名单（status/priority_min/project_ids/label_ids/due_within_days/due_overdue/favorite_only），创建/更新时校验防任意 JSON 进库；入 `SYNCABLE_TABLES` 第 10 表随 todos 模块同步（用户内容，跨设备随库走）。
- **orbit-core `saved_filter_api`**：list/create/update/delete（软删走同步墓碑）；4 个内存库用例（roundtrip/坏键拒绝/坏 JSON 拒绝/空名拒绝）。
- **桌面**：壳层第四选中态 `savedFilterId`（与快捷视图/项目/未分组四态互斥）；侧栏「筛选器」分组（hover 删除）；新建弹层（名称 + 条件 JSON）；`applySavedFilter` 纯函数条件应用（缺键不过滤 AND 组合、损坏 JSON 防御性放行），面板标题随筛选器名切换；7 个单测锁语义。
- **移动端**：FRB 镜像 + 桥面三方法（list/create/delete）；`/todo/saved-filters` 页（列表 + 行展开即时预览命中任务 + 新建 Dialog + 长按删除）；侧栏「筛选器」入口行；mock 桥同构语义，2 个契约用例。
- **e2e**：筛选器链路（创建 → 侧栏渲染 → 点击切换过滤 → 删除消失）。
- 门禁：Rust 380 / 桌面 typecheck + vitest 134 + e2e 10 / 移动 analyze + 162 全绿。

### 重复任务规则升级：星期几 / 结束条件 / when done（竞品矩阵批次 #34）

四款参考产品（Tasks.org/MS To Do/Obsidian Tasks/Super Productivity）全有的最大规则缺口补齐。向后兼容：新字段默认值 = 旧语义不变（现有重复任务行为零变化）。

- **数据模型**：`todo_tasks` 增四列——`repeat_weekdays`（星期几位掩码 bit0=周一…bit6=周日，仅周档生效）、`repeat_end_type`（0=永不 1=按日期 2=按次数）+ `repeat_end_param`（日期型=结束日 ms/次数型=剩余次数，随克隆递减）、`repeat_from_done`（when done 语义）。存量库升级=删库重初始化（既有口径）。
- **引擎（orbit-core）**：`next_repeat_at_ex` 掩码序列——候选日须 ①weekday ∈ 掩码 ②周序号 ≡ 锚点周 (mod N)（对齐 Tasks.org/MS Graph weekly+daysOfWeek；每 N 周的中周跳过）；`plan_next_recurring_instance` 增结束条件判定（次数 param≤1 终结/日期越过即终结）+ when done 锚点切换（`next_full_step_from`：完成日 + 完整步长不吃快进——理发式迟到三周完成，下次仍一个完整周期后）+ 扩展字段随克隆。6 个引擎用例（掩码单周/双周对齐/when done/掩码+when done/日期终结/次数递减终结），370→376 全绿。
- **桌面**：表单与详情抽屉 RepeatField/RepeatEditor 升级——自定义面板展开扩展区（周档星期几 7 chips、结束条件 永不/次数/日期、when done 开关）；`repeatLabel` 支持扩展（「每周一三五（按完成日，剩 2 次）」式徽标）；提醒徽标/属性行完整显示。
- **移动端**：dto/桥/mock 全链路镜像（FRB codegen）；表单自定义面板加星期几 FilterChips + 结束次数输入 + when done chip；详情徽标 `repeatLabelExt`；mock complete 补 when-done 分支（完成日锚定不吃快进）+ 次数终结守卫，桥契约 3 用例随迁（when done 周期断言/次数递减终结/掩码克隆）。
- 门禁：Rust 376 / 桌面 typecheck + vitest 127 / 移动 analyze 0 + 160 全绿。

### 右键「添加评论」弹窗打开即聚焦输入框

- **根因**：Dialog 常驻渲染、靠 `open` 切换显隐，React `autoFocus` 只在组件挂载时生效一次，错过弹窗打开时机；Radix Dialog 默认把焦点交给弹层内首个可聚焦元素（右上角关闭钮）——所以每次开弹窗都要先点一下输入框。
- **修复**：接管 Radix 的 `onOpenAutoFocus` 事件——`preventDefault` 默认焦点流，用 ref 手动聚焦评论 `Textarea`；打开即可直接打字。
- **测试**：e2e 新增用例（右键 → 添加评论 → 断言输入框 `toBeFocused` → 打字保存 → mock 库落库），stash 验证修复前真红（旧实现焦在关闭钮）；全量 e2e 9 用例通过。

### 详情抽屉交互修复：子任务超长标题悬浮提示 + 标题栏固定不随滚动

- **子任务 tooltip**：子任务标题超长被 truncate 截断后无任何方式看全文；给标题 span 补原生 `title` 属性，hover 即显完整内容（与日历节假日、关联任务行的原生 title 惯例同款，轻量不引 Tooltip 依赖）。
- **标题栏固定**：抽屉此前是整体 `overflow-y-auto`——标题行（完成钮/标题/我的一天/星标/删除）在滚动流内，内容一长就滚出视口，完成任务/删除等高频操作够不着。重构为**头部固定 + 内容区独立滚动**：SheetContent 改 `flex-col gap-0 p-0`，标题行 `shrink-0` 常驻顶部（border-b 分隔），属性网格到附件的区块 2–9 包进 `flex-1 overflow-y-auto` 独立滚动。
- **测试**：e2e「详情属性」用例补 sticky 断言（内容滚到底后 h2 标题仍在视口内），stash 验证修复前真红（旧结构下标题确实滚出视口）；全量 e2e 8 用例通过。

### 详情抽屉补「开始日期」与「完成时间」（字段断层修复）

- **排查结论**：全链对照（数据库 → Rust 模型 → API → TS/Dart 类型 → 表单 → 详情）后，任务字段唯一断层是 **桌面详情抽屉看不到开始日期**——新增/编辑表单可设（默认预填今天），建完就在详情里失明；移动端详情一直有「开始日期」行。其余未露出字段（position/uuid/version 等）均为内部/基础设施字段或已由别的入口覆盖，无实质缺失。
- **开始日期行**：插入属性网格「截止日期」之后（与移动端「截止→开始」相邻同款，时间语义两行成对），`StartDateEditor` 复用 QuickDateMenu（kind=date 快捷项 今天/明天/下周）⇄ 纯日历形态——**无时分输入行**（start_date 是日期级零点语义，非时刻），显示 `yyyy-MM-dd`，清除带二次确认（与截止日期同款交互）。
- **完成时间行**：`done_at` 此前任何界面都看不到（完成时刻写入后无处可查）；现在属性网格新增「完成时间」行，完成任务显示 `yyyy-MM-dd HH:mm`，未完成为空占位保持网格对齐。
- **测试**：e2e 新增「详情属性」用例（开始日期行可见 + mock 写入后值区显示本地日期 + 抽屉完成钮点击后完成时间出现），stash 验证修复前真红；全量 e2e 8 用例 + vitest 127 用例通过。

### 任务附件三端落地（内容寻址 + E2E 同步；竞品矩阵批次 #33）

11 款对标竞品 9 款标配的最大功能缺口补齐（MS To Do 25MB/Apple 照片扫描/Vikunja 内联预览）。`sys_attachments` 表与 `assets/` 内容寻址同步通道 0001 全预留，本批兑付。

- **数据模型（分层设计）**：`todo_task_attachments` 关联表（uuid/软删/版本列齐全，入 `SYNCABLE_TABLES` 白名单第 9 表，随 todos 模块同步"哪个任务挂了哪个 hash"）；`sys_attachments` 保持本地账本（不进白名单——pull 侧 `ensure_local_cached` upsert 兜底，P0-8 修复后新设备不再每轮全量重下）；附件二进制走 `assets/{hash}.waitsync` 既有内容寻址通道（AES-256-GCM 加密，4 路并发）；`SYNC_MODULES.has_attachments` 开关打开（01 文档 §3.3 预留兑现）。存量库升级=删库重初始化（既有口径）。
- **orbit-core `asset_api`**：`add_task_attachment`（sha256 内容寻址 → `fs_util::write_atomic` 原子落盘 → upsert 账本 → 关联幂等：同任务同 hash 返回同一 link 不计上限）+ 上限守卫（单任务 20 个 × 单文件 50MB）+ EVENT_BUS 事件（on-change push 自动触发）；`get_task_attachments`（join 账本带 `is_local_cached`——云端有本机未拉回时 UI 置灰）；`read_task_attachment`（未缓存 NotFound 引导等待同步）；`remove_task_attachment`（软删关联）+ `gc_local_attachments`（无引用 hash 清文件+账本行；**云端对象不删**——多设备引用计数不可靠，宁可多留不误删，由 push/pull 自然对账）。7 个内存库集成用例（幂等/跨任务去重/GC 保活/上限/超限/未缓存）。
- **桌面**：详情抽屉区块 9「附件」——dialog 选文件 → fs 读 bytes → 命令上传；行显示文件名/大小（待同步徽标）/hover 删除（ConfirmPopover 同评论形制）；打开走 mime 分流（图片 blob 新窗口预览，其余落缓存目录系统程序打开）；react-query db-change 通道自动刷新。tauri 五命令注册。
- **移动端**：FRB 镜像 `asset.rs` 五函数（附件目录=base_dir/attachments 与 sync.rs 同源）+ dto 镜像；详情页区块 9（file_picker 添加 + SectionCard 列表 + 图片全屏预览 Dialog + 删除确认 AlertDialog，未缓存置灰 +「待同步」徽标）；桥契约测试 5 用例。
- **e2e**：桌面 Playwright 附件链路（区块渲染/列表刷新/移除弹层确认/mock 终态）；ipc-mock 同构语义（djb2 内容指纹幂等 + isWriteCommand 正则扩 `add|remove`）。
- 门禁：Rust 370（+7 附件）/ 桌面 vitest 122 + e2e 6 / 移动 analyze 0 + 157 全绿。

### 侧边栏导航失灵修复（回收站/统计面板下点其他菜单无反应）

- **根因**：侧边栏快捷视图/项目/未分组的点击只改壳层 React state 不跳路由，而回收站/统计是嵌套路由面板（`/todo/trash`、`/todo/stats`）——路由停在这两处时中间区渲染的是 TrashPanel/StatsPanel，TaskPanel 未挂载，此时点侧边栏其他菜单 state 静默变化、URL 与界面毫无反应；必须点右上角「待办」（真 `navigate("/todo")`）重新挂载 TaskPanel 才能恢复。
- **修复**：壳层三个选中回调（`onSelectQuickView/onSelectProject/onSelectUngrouped`）补 `selectInPanel` 兜底——当前路由非 `/todo` 时先 `navigate("/todo")` 再应用选中态；判定逻辑抽纯函数 `sidebar-nav.ts`（`needsTodoIndexNav`）。移动端无此问题（侧栏每项都是真实 `context.push` 路由跳转）。
- **测试**：`sidebar-nav.test.ts` 5 用例锁口径；e2e 新增「导航回归」用例（回收站下点「我的一天」、统计下点「全部任务」应直接回任务面板且视图真正应用），stash 验证修复前真红、修复后绿；全量 e2e 7 用例通过。

### 优先级「无」档全程着色（P0 浅灰转正，六档全显）

- **口径反转**：此前优先级「无」（P0）在多数展示位被隐藏或跳过渲染（列表左缘竖条不画、看板顶条透明占位、日历月格圆点被过滤、表单/右键菜单/批量工具条无色点），只有详情/快加选择器给了临时灰点。现 **P0 转正浅灰 `#D1D5DB`** 进正式色表，与「低」的 `#6B7280` 明度可区分；所有展示位与选择位六档全显，选择什么颜色、列表就见什么颜色。
- **桌面**：`PRIORITY_COLOR[0]` 空串→`#D1D5DB`（列表竖条/看板顶条/日历月格圆点+右栏竖条 P0 也渲染，去掉 `> 0` 门与 transparent 兜底）；详情/快加选择器灰点从硬编码改取色表；快加 Flag 图标 P0 也着色；右键菜单/批量工具条「无」补色点；表单选择器经 `opt.color` 门自动生效；统计页 P0 条形从 P1 灰回退改取 P0 正色。
- **移动端**：`priorityColorHex(0)` 空串→`#D1D5DB`（详情选择抽屉/统计分布条去掉灰兜底双写）；表单 32px 色点 P0 从「透明底+禁止图标占位」改浅灰实心点；日历月格与按日任务卡的灰兜底点统一取正色；列表行副标题色点六档全显（副标题恒渲染）；统计页优先级图例补 P5「立即处理」档。
- **测试**：桌面新增 `priority-color.test.ts`（六档全有色 + P0/P1 不撞色 + 色表文案档位对齐）；移动端 `task_logic_test` P0 断言从 `isEmpty` 改 `#D1D5DB`。

### 任务栏小尺寸图标锐化（v5.1）

- **Windows 任务栏图标模糊修复**：全构图缩到 16-32px 时环带仅 ~2px 宽且半透明灰雾占 21-28%（LANCZOS 抗锯齿+glow 光晕），在任务栏上显示为发灰的模糊环。两路修复：**≤32px 走特调档**（16/20px 主体放大 PAD 0.05 + alpha [160,235]→[0,255] 陡化去灰雾；24/32 递减力度），实蓝像素 +28%、32px 灰雾 21%→13.8%；**ICO 补全 DPI 缩放槽**——原 7 槽缺 20/40/96，Windows 125%/150%/200% 缩放取不到整槽会拉伸放大导致模糊，现为 16/20/24/32/40/48/64/96/128/256 十槽手写容器（Pillow `sizes` 参数不支持 20px 且为二次缩放，弃用），每槽独立从母版渲染。逐槽量化验收（旧→新）：16px 43→55 实蓝px、24px 114→132、32px 211→229；20px 槽构图三要素（环/卫星球/彗星）可辨。

### 同步数据安全 P0 批修（排查报告 10 项全清）

同步功能系统性排查（docs/同步功能系统性排查报告-2026-09-07.md）发现的 10 项数据丢失/污染/不可用级 P0 全部修复落地，orbit-core 363 单测全绿（新增 12 个回归用例）。P1 中危项待后续批次。

- **WebDAV 链路（P0-1/P0-2）**：PROPFIND 解析器此前只认微软私有 `<iscollection>1</iscollection>`，RFC 4918 标准的 `<D:resourcetype><D:collection/></D:resourcetype>` 空元素对不产生文本、`is_collection` 在坚果云/Nextcloud/群晖等所有主流服务器上恒 false——目录条目混入文件列表且 basename 退化为整条 URL。修复：解析器在 Start/Empty 事件识别 `collection` 子元素（含自闭合与裸元素形态）；两处 PROPFIND body 请求 `resourcetype`；basename 提取先剥尾斜杠。KeyMismatch 防污染守卫不再依赖 `list_files` 的路径形态契约（WebDAV 下恒失效），改为对每个模块 `data.waitsync` 直接 GET 探测，两适配器行为一致——云端已有 Key A 数据时本地错 Key B 的 crypto/config 不再被自动补传覆盖（此前会污染全部设备且不可恢复）。
- **S3 链路（P0-3/P0-4/P0-10）**：ListObjectsV2 循环携带 `continuation-token` 直到结束（此前 >1000 对象静默截断——pull 拉不到、push 误判云端缺文件全量重传），解析器提取 `NextContinuationToken`，防御上限 1000 页；签名 service 名接入既有 `infer_service`（此前硬编码 "s3" 导致阿里云 OSS V4 scope 不匹配、全部请求 403）；`validate_config` 补 region 空值拦截（漏填同样全 403 且错误是裸 XML 难以定位）；列举 prefix 统一带尾斜杠，消除 `wait` 前缀命中 `wait2/`、`waitfoo/` 的跨目录污染。
- **引擎数据流（P0-5/P0-6/P0-7）**：①删库重装守卫——本地空库但残留 `sync_state.json` 记录 count>0 时阻断 Push 并引导走恢复流程（此前会上传空 items+空墓碑覆盖云端），复核全 8 表合计防误触；②Pull 失败模块集随 `PullResult.failed_modules` 返回，`push_all` 对其跳过（此前单模块 pull 网络失败后继续 push，陈旧数据覆盖其他设备刚推的新数据）；③模块上传顺序改为先 meta（含墓碑）后 data——中断窗口从「漏删不可感知」变为「多删一次」，reconcile 下轮兜底（两段完全原子性属容器格式演进）。
- **附件同步（P0-8）**：落盘改 tmp+rename 原子写（Windows 目标存在先删再改名）；解密后校验内容 sha256 与文件名一致才落盘（内容寻址约定防损坏被哈希背书）；DB 记录改 `ensure_local_cached` upsert——`sys_attachments` 不在同步白名单，新设备/删库后旧 `mark_local_cached` 仅 UPDATE 永远 affected=0，差集永不为空导致每轮全量重下。
- **merge 白名单（P0-9）**：远端 data.waitsync 的 `_table` 路由此前可指向任意本地表（sync_configs/凭据等），越过同步白名单写非同步表；现校验 ∈ `module_def.tables` 否则整体拒绝合并（与读取侧 db_loader 白名单对齐）。
- 测试：propfind 5 用例（标准/自闭合/微软私有/跨条目泄漏/无前缀形态）、S3 分页游标/`infer_service`/canonical query、merge 白名单 3 用例、region 校验 2 用例。

### 重复任务推进引擎下沉 orbit-core（三端统一完成入口单事务化）

- **修复移动端核心断层**：重复任务此前仅桌面有推进引擎（完成时克隆下一实例），移动端勾选完成直接丢排程。引擎（`plan_next_recurring_instance` / `next_repeat_at` / `subtasks_to_clone`）自桌面 TS 下沉 Rust，语义逐字对齐：锚定原 due 推进（提前完成不改节奏、长期逾期快进越过 now）、月/年日历截断（1/31→2/28→3/28 链式不回弹、闰日 2024-02-29→2025-02-28）、5000 步快进上限、子任务只克隆标题完成态重置、不复制提醒。
- **`complete_todo_task` 单事务**：创建下一实例（含子任务克隆）+ 标记本实例完成在同一 SQLite 事务内原子完成，取代桌面旧两步 IPC 编排（中间崩溃丢推进窗口归零）；已完成任务幂等跳过（不重复推进）；回收站任务拒绝完成；事件提交后补发（todo_tasks Insert×2 + todo_subtasks）。
- **桌面**：`todo_tasks_complete` 命令 + `completeTask` 改单命令调用 + 批量完成对齐统一入口（补齐「批量完成不展开下一实例」缺口——重复任务批量勾选现在也会推进下一实例）。
- **移动端**：FRB 镜像 `todoTaskComplete` + 子列表/详情双屏完成入口接线（引擎下沉后与桌面同口径）；`repeat_logic` 过时注释清理。
- 测试：桌面 9 用例语义随迁 Rust（含 4 个内存库事务集成用例）+ vitest 批量口径 4 用例 + Mock bridge 契约 4 用例 + e2e 重复推进用例。

### CSV 导入迁移路径（orbit / Todoist / TickTick 三档预设）

- **补齐导入方向空白**（此前仅导出）：新用户可从主流工具迁入任务。orbit-core `csv_import_api`——RFC 4180 解析（BOM/引号转义/逗号内换行/跳空行）+ 三档映射：orbit 自有导出格式（往返一致吃狗粮）、Todoist 模板（Type=Task 行、List Name→项目自动创建、p1→4/p2→3/p3→2/p4→1 优先级、Completed Date→完成态）、TickTick 模板（高→3/中→2/低→1/无→0）。
- **务实边界**：日期支持 yyyy-MM-dd / yyyy/M/d / M/d/yyyy / yyyy-MM-dd HH:mm，解析失败置 null 不阻断（任务可后补）；两段式 preview（不写库）/execute（逐行独立成败互不阻断）；项目按标题自动创建（大小写不敏感复用）；每行生成新 uuid 规避同步冲突；写入走 repository 事件面（同步 push 自动触发）。
- **三端 UI**：桌面设置页「导入 CSV」卡（选文件→预设档→预览表→确认执行→逐行说明详情）；移动端设置页同流程（file_picker 选文件 + ChoiceChip 预设 + 预览行 + 执行统计）；导出卡旁对称。
- 测试：Rust 15 用例（解析边缘/三档映射/项目复用/预览不写库）+ 移动端桥契约 4 用例。

### 移动端 NLP 快速输入（对齐桌面 #7）

- `parse_quick_input.dart` 逐字移植桌面解析器：中文日期全词形（今天/明天/后天/大后天/周X·星期X·礼拜X/下周X/M月d日·d号）、!1–!5 优先级（负向先行排除 !12 误命中）、#项目/@标签（精确匹配优先，其次前缀命中；标签可多个去重）；命中区间互斥、长词保护内部短词（下周三 不被 周三 二次命中）、无效日期不静默滚动保留原文、未匹配 token 原样保留。
- **表单接入**：新建态标题输入实时解析 → 命中字段预览 chips（截止日期/P 级/项目/标签数）→ 保存时自动应用（due_date/优先级/项目 + 标题剥离 + 标签自动挂载，挂载失败不阻断保存）；编辑态不启用（避免覆盖回填字段）。
- 测试：桌面 17 用例同源随迁全绿 + 表单 NLP 集成 widget 用例（「明天开会 !3」→chips 出现→保存落库三字段验证）。

### 品牌图标换版 v5（AI 生图「圆环轨道」加强版透明资产直用，三端全族）

- **新构图**：用户提供第二张 AI 生图（`scripts/icon-source-2026-09-08b.png`，1254² 自带透明通道）——加粗正圆环（#246CF6，环带 ~165px）+ 缺口嵌带拖尾卫星球 + 左上月牙形行星 + 彗星自中心越环 + 环内柔光 glow。质量实测后**直接栅格使用**：主环外缘段内圆度 ±1px（整体为 rx 364/ry 347 近圆椭圆）、主体蓝 std<3 纯色、glow 99.7% 集中环内、al≥15 单连通主域（散噪 ~250px 剔除）。
- **资产管线**（沿 v4.1）：最大连通域去散噪 → 紧框裁剪 920×816 固化 `scripts/icon-asset-2026-09-08b.png`；`generate_icons.py` 仅改资产引用与 SOLID_BBOX（915×812 实测），渲染管线（solid bbox 对齐画布 80% 居中、透明底、通知剪影 alpha>128 二值化）不变。
- **覆盖**：桌面 Tauri 全族 + app-icon、Android 五密度 + 通知剪影 + 启动屏。自检四项 + 目检全绿：四角 alpha=0、透明占 58.5%、居中 0.500/0.500、环带采样 12/12（r=0.34w 峰区实测）、48px 两部件、通知 24px 构图可辨。
- 历史脉络：v1 渐变椭圆轨道 → v2 手绘描摹 → v3 高斯平滑重阈值 → v4/v4.1 AI 生图+透明底 → v5 现行；各版资产/脚本仍入库备用。

### 品牌图标换版 v4（AI 生图「圆环轨道」透明资产直用，三端全族）

- **新构图**：用户提供 AI 生图（`scripts/icon-source-2026-09-08.png`，1254² 自带透明通道）——蓝色正圆环轨道（#2B6EF7，缺口嵌带拖尾卫星球）+ 彗星自中心越环 + 双层淡蓝白 glow。质量实测后**直接栅格使用**：主环外缘圆度 ±2px（0.6%）、主体蓝 std<3、glow 四象限对称无散噪（al≥40 单一连通域）——上一版「手绘描摹带波纹」的教训不适用于此高质量源，无需重描。
- **v4.1 全族透明底**（用户口径「扣成透明背景」）：图标即资产本身、无任何底板/底色，深色底由宿主环境（桌面任务栏/Android 桌面/关于页）提供；Android 启动屏深色由 `launch_background.xml` 的 `launch_bg` 承载，图标层透明直贴；启动屏/主图/ICO 全部透明验证（四角 alpha=0、透明占 28%）。
- **资产管线**：最大连通域剔除散噪（3px）→ 主体紧框裁剪 941×961 固化 `scripts/icon-asset-2026-09-08.png`；`generate_icons.py` 重写为栅格 alpha 合成——solid bbox 对齐画布 80%（PAD=0.10）居中缩放贴入，glow 越出边距自然淡出；通知剪影按 solid 紧框铺放 alpha>128 二值化。
- **覆盖**（同 v3 全族口径）：桌面 Tauri 全族（PNG/ico/icns/Store Square）+ 关于页 `app-icon.png`；Android 五密度 `ic_launcher.png` + 通知剪影 `ic_stat_orbit.png` + 启动屏 `launch_image.png`。自检四项（四角透明/底色/环带蓝 12 向采样/通知纯白）+ 目检全绿：主体居中 0.499、48px 三部件（环+球+彗核）、16px 单部件、通知 24px 环+球+彗星可辨。
- 历史脉络：v1 渐变椭圆轨道 → v2 手绘描摹（波纹否）→ v3 高斯平滑重阈值 → v4 现行（AI 生图直用）；v2/v3 的提取脚本与形状数据仍入库备用。

### 品牌图标换版（用户提供源图重构，三端全族；两轮迭代至 v3 平滑版）

- **新构图**：用户提供手绘源图（`scripts/PixPin_2026-09-07_20-16-46.png`，白底蓝主体 364×325）——左上月牙形行星 + 左下扫至右上的变宽轨道弧（末端卫星球）+ 中部小彗星，「卫星绕行星」直扣 Orbit/循迹语义。
- **v2→v3 提取工艺迭代**：v2 轮廓描摹（RDP+Chaikin，IoU 0.89）残留手绘波纹——轨道弧底部「不够圆、太乱」；骨架中轴/单圆拟合等理想化路线均被数据否定（宽带区细化产生环状骨架、弧率处处变化非单一圆）。v3 改为**尺度分离**：`scripts/extract_icon_shapes.py`（新增入库）以「2x 超采样 + 高斯模糊 σ=5 + 127 重阈值」滤除周期 <10px 笔触波纹、完整保留宏观形状（三部件 IoU 0.994/0.998/0.994），卫星球理想化为正 64 边形；下缘直线度检验全程 <2px（尖端区 6px 为收笔上翘固有曲线非波纹）。
- **渲染**：保留品牌深空色 squircle 底（#1A1A21，与启动屏 launch_bg 同源），主体蓝 #3974F7；1024 母版 LANCZOS 出全族。`generate_icons.py` 数据驱动（JSON `bbox`+宽高比铺放，消除硬编码）+ 自检（四角透明/底色/卫星球中心色/通知纯白）。
- **覆盖**：桌面 Tauri 全族（PNG/ico/icns/Store Square）+ 关于页 `app-icon.png`；Android 五密度 `ic_launcher.png` + 通知剪影 `ic_stat_orbit.png` + 启动屏 `launch_image.png`（全出血无圆角版）。v1 渐变椭圆轨道设计由本构图替换。
- 小尺寸结构保留经连通域验证：48px 四部件完整、32px 彗星并入弧线成两部件、16px 单色块仍含月牙+弧轮廓；主体居中 0.499/0.499。

### 年视图今天方块与农历杠间距(桌面+移动)

- **今天标记从胶囊改圆角方块**:年视图今天的 `rounded-full px-1.5` 胶囊(桌面)/24px 圆形(移动)与月视图的内缩圆角方块形制不一致;桌面改为 `aspect-square h-[85%] rounded-md` 居中方块(年视图日格行高等分后很扁,纯 inset 会随格形变长条,故以格高为基准方形),移动端 24px 容器改 `BorderRadius.circular(7)` 方块(与月视图日格同形制)。浏览器几何断言 12×12 正方。
- **春节/初一农历杠与数字留距**:杠下沉从 -bottom-0.5(桌面,bottom:1 移动)加大到 -bottom-1.5(下沉 6px)/移动端补 4px padding,像素断言数字底边距杠顶 5px(原 0px 紧贴粘连)。typecheck + vitest 116 + e2e 4 + 移动 analyze/test 126 全绿。

### 添加关联图标居中修复(桌面)

- 详情「添加关联」的虚线圈 + 号从文本字符换为 lucide Plus SVG 图标:文本字符墨迹中心天然高于字符框中心(字体基线上留白),20px 虚线圈内视觉偏上;SVG 盒即墨迹盒,place-items-center 即几何居中(e2e 断言偏差 dx/dy=0),与详情其余图标同源同口径。随 dba6959 落地。

### 日历右栏任务行统一行高(桌面)

- **有无标签/项目名的行此前高度不一**:右栏/议程/弹层任务行的元信息行(标签 chips+项目名)无条件渲染——空 div 也占 mt-0.5+text-xs 一行,无元信息的行矮一截、日分组内参差。改为行高固定 `h-12`(48px):元信息有内容才渲染,内容垂直居中;浏览器几何断言带标签行/无标签行均 48px 等高。typecheck + vitest 116 + e2e 4 全绿。

### 详情四处删除确认统一行内 Popover(桌面)

- 新增共享 `ConfirmPopover`(受控 w-56 小弹框:标题+说明+取消/删除,锚定目标行下方,点外部/Esc 取消)——qraft 编辑器 tab 关闭确认同形制。接入:**删除关联任务**(注明双方解除)/ **删除评论**(内容截断 20 字)/ **删除提醒**(带提醒时间);子任务删除从上轮手写 Popover 改用共享组件统一形制。
- **清除截止日期改两步确认**:编辑弹层内「清除」首点变红显示「确认清除?」(3 秒超时复位)——弹层内不嵌套 Popover(qraft 同款嵌套测量异常),确认后清除并 toast。
- **修复启动白屏**:并发会话的 useTodoReminderListener 曾在 ReadyShell(RouterProvider 外)调 useNavigate 抛错整树崩溃;改用 router 单例实例 navigate(等效语义)。e2e 四链路(评论/提醒/关联/截止清除)+ smoke 4 + vitest 116 全绿。

### 看板/日历视图排序生效修复(桌面)

- **工具栏排序档位此前只对列表视图生效**:看板列内(`grouped`)与日历按日分组(`byDay`)拿到父层 sortTasks 已排序数组后,又各自按 position+created_at 重排覆盖——截止/优先级/标题/创建时间四档在看板和日历完全无效。两处改为保留父层传入序(排序档语义三视图归一)。
- **看板拖拽按档位收敛(#26 口径)**:仅「拖拽顺序」档允许列内拖拽重排(卡片拖拽源禁用+cursor 还原,同列 position 写入短路——写了也会被排序档覆盖);跨列移动(改归属)任何档位都保留,落位仍走 position 中值。KanbanView 新增 sortKey prop,task-panel 接线。
- typecheck + vitest 116 + Playwright e2e 4 全绿(e2e 曾因并发 reminder-listener 中间态 useNavigate 在 Router 外调用启动崩溃而全红,系并发会话半成品,其修复恢复后即绿,与本改动无关)。

### 详情截止日期弹层修复(桌面)

- **「选择日期和时间」完整视图此前撑满全屏宽+白底块**:详情抽屉 DueDateEditor 的完整视图内嵌了自带 Popover 的 DateTimePicker——Popover 套 Popover 的 portal 布局测量异常把外层弹层撑到接近视口宽(浏览器实测 1159px),且其 `w-full` 触发按钮在深色主题下渲染为一整条白底描边块。改为内联「日历 + 时/分数字输入行」(与右键菜单设置截止的 Dialog 内同款行),弹层宽度收敛 `w-72`(288px,实测验证),深色主题正常透明底。
- 提醒区两处内嵌 DateTimePicker 编辑行加 `max-w-xs` 收敛(原触发钮 w-full 在抽屉里拉满整行宽)。docs/04 §3.4 属性网格规格同步。typecheck + vitest 116 + 浏览器几何断言全绿;e2e 因并发工作区 ipc-mock 半成品状态暂无法干净复跑,待其落库后回归。

### 数据库迁移合并为单文件 0001_init.sql

- **内容**:0002_my_day(my_day_date 列+索引)、0003_holidays(cfg_holidays/cfg_kv 两表)、0004_remove_end_date(删 end_date 列)全部并回 `0001_init.sql`——todo_tasks 表体直接含 my_day_date、不含 end_date,节假日缓存表并入 cfg 段;0002–0004 文件删除,恢复「单文件迁移」维护约定(结构变更直接改 0001,改后删本地库重新初始化)。
- **⚠️ 升级后果**:0001 内容变化导致 checksum 与存量库不一致,sqlx migrate 校验会拒绝打开**所有已有数据库**(含 v0.1.1 安装设备)。升级方式 = 删除本地库文件重新初始化,数据经云同步/WebDAV 或 .orsync 全量备份恢复;未配置同步的本地数据会丢。迁移回归测试改为单文件 schema 断言(end_date 不存在/my_day_date 在表体/节假日两表在),321 单测全绿。
- end_date 的移除不再以增量迁移承载,由单文件 schema 直接体现(下条目动机不变)。

### 子任务删除确认改为行内 Popover(桌面)

- 桌面详情抽屉的子任务删除确认从居中 AlertDialog 改为**锚定目标行下方的 Popover**(w-56 小框:标题+带子任务名的说明+取消/删除按钮),与 qraft 编辑器 tab 关闭确认同形制——确认框出现在操作对象旁而非屏幕中央,视觉关联更直接;每行独立受控,点外部/Esc 视为取消。随 7937d7c 落地。
- ipc-mock 补子任务全命令面(create/toggle_done 按 Rust 口径回算父任务 percent_done/delete 软删+detail 返回真实 subtasks;原 mock 恒空数组),为子任务相关 e2e 铺路。

### 待办提醒加入任务详情入口(桌面+移动)

- **桌面**:到期提醒自定义 toast(ReminderToast)在推迟三档旁新增「查看任务」按钮(accent 主按钮+ExternalLink 图标)——点击经 §7-③ 规范写 selectedTaskId 打开右侧详情抽屉并导航 /todo,与全局搜索/命令面板同范式;动作收口在 reminder-nav.ts 纯函数(node 单测 3 条)。
- **移动**:三路点击均可进详情——①前台通知正文点击(onDidReceiveNotificationResponse,actionId 空分支)②应用被杀期间点通知冷启动拉起(BootGate ready 后 consumeLaunchNotification 解析 launch payload,postFrameCallback 兜路由装配时序)③无权限/异常兜底 WaitToast 整卡可点(WaitToast 新增 onTap 回调,带入口的 toast 不自动收起,原无回调行为不变)。服务层经静态 onNotificationTap 回调拿路由(BootGate 注入 rootRouter.push('/todo/:id')),不持有 context;payload 解析复用推迟通道的 taskId|remindAt|title 口径。
- **测试**:桌面 vitest 116 绿(+3);移动 126 绿(+6,reminder_nav_test:payload 解析口径/WaitToast onTap 行为/路由契约)。docs/04 Toast 行、docs/05 WaitToast 行规格同步。

### 子任务删除加确认弹窗(桌面/移动)

- 详情里子任务的 X/close 原为直删(仅成功 toast),误触即丢。两端改为确认弹窗:桌面详情抽屉 AlertDialog(destructive 主按钮,与任务/项目删除同形制);移动端 AlertDialog(destructive FilledButton,与评论删除同形制),文案带子任务标题。子任务软删无恢复入口(回收站只收任务行),删除即隐藏——弹窗是唯一防线。随 3ff2427 落地。

### 移除任务「结束日期」字段(end_date,全栈)

- **动机**:end_date 是 0001 建库时从 Vikunja API 模型平移的「任务执行区间终点」,与 start_date 成对,但在排序/筛选/逾期/日历/提醒/统计中零消费;中文语境下与真正驱动全部业务的「截止日期」(due_date)极易混淆,用户填错位后任务不进日历、不触发逾期。产品决策:任务日期口径统一为 截止/开始 两个。
- **全栈收窄**:新增 `0004_remove_end_date.sql` 增量迁移删列(sqlx migrate,存量库 checksum 不受影响);Rust 模型/仓储/CSV 明文导出列、orbit-flutter DTO、FRB 生成物(codegen 重跑)、桌面 TS 类型/表单字段/重复平移、移动端 DTO/桥接/mock/表单/详情页全部移除;三端测试按新口径更新(移动端断言「结束日期」不渲染)。已设值用户的 end_date 数据随迁移丢弃。
- **保留同名**:统计热力图 `StatsHeatmap.end_date`(区间端点,字符串日期)与任务字段无关,不动。

### 详情描述编辑修复与优化(桌面+移动)

- **桌面详情抽屉描述区块此前不可编辑**:原实现是条件渲染的只读文本(空描述时区块整体消失),想改描述只能关闭抽屉绕道编辑表单。改为行内编辑:展示态点击进入 Textarea(自适应高度,Ctrl/Cmd+Enter 保存、Esc 取消、失焦兜底保存,trim 空写 null 清空,角标 N/5000);空描述恒显示"+ 添加描述"占位入口,与标题行的点击编辑心智一致。
- **移动端描述编辑弹层从 AlertDialog 改底部抽屉**:原 maxLines:5 固定 5 行长描述看不全,点遮罩即关丢草稿;改 70% 屏高上限的多行自适应输入(键盘避让、内容未变只关闭不写库)。保存语义(trim 空写 null)与原一致。docs/04 §3.4、docs/05 §4.3 规格同步。

### 新增任务开始日期默认当天(桌面/移动)

- 新增表单的开始日期预填今天:桌面 `TaskFormSheet` 新增态 `initialRecord` 预填 `start_date`(本地日期,每次打开重算);移动端 `showTodoFormSheet` 新增态 `initState` 预填今天零点——FAB/侧栏/日历长按等全部新增入口生效。编辑态保持原值不动;两处测试断言按新行为更新(表单「无」占位 ×3→×2、日历长按今天格 ymd 出现两次)。随 51fc9fc 落地。

### 任务标签条目「色点+标签名」扩展到表单/详情(桌面+移动)

- 上轮只改了展示位(列表/看板/日历行),本轮补齐编辑场景:桌面新增表单 TagsField 已选条目、详情抽屉已挂条目从「彩底白字+X」实心 chip 改为「色点(hex_color)+标签名(muted)+X」描边条目;移动端详情标签区从「彩字+30% 彩边框」chip 改为「10px 色点+bodyText 标签名+divider@30% 边框」条目。
- 双端六处标签显示形制归一(点=颜色信号,文字安静层级);X 移除、勾选弹层、新建入色板等交互不变;移动端表单无标签选择、编辑弹层本就圆点+名,无需改。docs/04 §3.4、docs/05 §4.3 规格同步。

### 任务标签条目改「色点+标签名」(桌面)

- 列表行/看板卡/日历任务行的标签从彩字+描边+淡底胶囊改为**左色点(hex_color)+右标签名(常规 muted 文字)**:原胶囊与元信息行其余 muted 元素抢视觉,多标签并排时彩底块连成一片;改为点色即可分辨、文字回归安静层级,与优先级圆点「点=颜色信号」口径统一。超 3 折叠 +N(看板卡 max=2)、hex_color 空串灰兜底、hover title 均不变;详情抽屉标签区(彩底白字实心 chip)保持原样——编辑场景强调可点删。docs/04 §3.2 同步,随 8f4e7b6 落地。

### 日历视图左右分栏留白优化(桌面)

- **月/年视图不再贴左缘**:左半区加 `px-4/xl:px-5` 内缩,与右栏卡片、顶部工具栏 `px-4` 对齐同一节奏;月历与年视图内容包一层 `max-w-3xl mx-auto` 水平居中(1600px 窗口下 7 列月历约 648px,最佳可读宽度),大窗口下不贴左、不无限拉宽;Playwright 几何断言月/年视图左右内缩各 20px 对称。

### 列表优先级标记优化(桌面)

- **列表行色条改左缘竖条**:`TaskRow` 行底部 2px 通栏横条改为行左缘 4px 圆角竖条(`absolute inset-y-1.5 left-0 w-1`,与日历右栏/议程任务行同形制)——原横条与行分隔线叠成双重横线,连续紧急红/橙条尤其吵;竖条贴左侧扫读热区,行高 57px 虚拟化不受影响。
- **未设优先级(P0)不再灰条兜底**:列表行竖条/看板卡顶条(透明占位保持卡片高度)/日历行竖条/月格圆点全部 P0 不渲染,与移动端列表、详情抽屉口径统一——灰色等于默认态不携带信息,只会制造视觉噪音;统计页优先级分布条保留 P0 灰(图表语义)。
- 月格圆点改为仅统计 P1–P5 任务(全 P0 日不显点,溢出计数同步按过滤后口径);docs/04 §3.2 行规格同步(元信息行不再含优先级圆点,竖条单列)。

### 性能治理收口:规模化渲染全量虚拟化(桌面/移动)

- **看板列内虚拟化**:`KanbanColumn` 卡片区改 `useVirtualizer`(动态 measureElement)——原裸 map 全量渲染千条任务即万级 DOM;`KanbanColumn`/`KanbanCard` memo 化,打开详情回调稳定引用。
- **日历三档统一虚拟化**:新增 `VirtualGroupedList` 统一月右栏/年右栏/议程档三处裸 map + ScrollArea——打平为月头/日头/任务行线性序列交给 useVirtualizer,只渲染可视窗 ± overscan;选中日/今天定位改 `scrollToIndex`(虚拟化下目标组节点常不在渲染窗,原 scrollIntoView 失效);`CalendarTaskRow` memo,行内项目名 Map 查找替代逐行线性 find。日期头 sticky 吸附随虚拟化绝对定位改为随内容滚动(唯一体验取舍)。
- **vendor 分包**:vite manualChunks——react 全家 + react-router + @tanstack/react-query 独立 `vendor-react`(273KB),其余依赖归 `vendor`(479KB);首屏入口 chunk 495KB→63KB,懒页 10–80KB,总量零膨胀(1037KB vs 1036KB)。
- **移动端日历聚合下沉**:`calendarByDayProvider` 从 todoTasksProvider 派生——due_date→ymd 聚合+排序原在日历屏 build 每次重算(选中日等局部 setState 也触发全量重聚合),派生后仅任务数据变化时重算;当月圆点颜色表一次构建,月历 42 格 eventDotsBuilder 直接查表。
- 至此 07 报告 §4.3 四项性能风险(全量渲染/memo 缺失/单 bundle/字体)全部清零;桌面 typecheck + vitest 113 + Playwright e2e 4、移动 analyze 0 issue + 120 测试、cargo 321 全绿。

### 统计分布条着色升级(桌面/移动)

- **项目分布条用项目自选色**:统计接口 `stats_aggregate` 的 `by_project` 行新增 `project_hex_color`(SQL join `todo_projects.hex_color` 一次带出,未分组行 null);桌面 `/todo/stats` 与移动端统计页的项目分布条形完成段按各项目 `hex_color` 着色,空串/缺失回落待办强调色(与侧栏色块口径一致),未分组行回落强调色。
- **优先级分布条用优先级语义色**:完成段按 P1–P5 语义色(低灰/中蓝/高橙/紧急红/立即深红)着色,P0「无」用灰点色,与详情抽屉/表单优先级色板口径一致。
- 星期分布保持待办强调色不变。三端口径统一:Rust core join 取色 + FRB `stats.rs` 镜像 + 桌面 `tauri.ts`/`ipc-mock` + 移动端 DTO/mock 同步补字段;新增 Rust 单测 `by_project_carries_project_hex_color`(自建带色项目 + 未分组行不带色),桌面 vitest 113 / 移动 flutter test 120 / cargo test 321 全绿。

### 日历视图(wait-home 风格重构,桌面/Web)

- **左右分栏布局**:左侧月历/年视图 + 右侧当前范围任务列表(月模式按日分组、选中日高亮并滚动定位;年模式按月分节;窄窗口自动退化为上下堆叠)。
- **年视图**:点击月历标题或工具栏「年」切换,12 个迷你月历(3×4)铺满左半区,干支生肖标签(如「丙午马年」),春节(正月初一)红下划线/每月初一蓝下划线图例;点击任意日期回到月视图并定位该日。
- **农历副标签**:日格下方显示公历节日 > 农历节日(除夕) > 节气 > 农历日(初一显示月名);1900–2100 数据表与 wait-home 同源。
- **休/班徽标新样式**:圆形角标(放假「休」蓝 #4C7DF0 / 调休补班「班」橙红 #FF7043),hover 提示假日名;休息日整格浅蓝底、补班日灰底;今天内缩主色实心块、选中日描边。
- **右键日格快捷新增**:右键任意日期直接打开新增表单并预填该日为截止日期。
- **格内任务圆点**:格内仅渲染优先级色圆点(≤4 个 + "+N"),标题与详情移入右侧列表,防止撑高日格。
- 议程档保留,与月/年档互斥切换;节假日数据层(timor.tech + 每日自动更新 + 2026 兜底)不变。

### 日历视图(wait-home 风格,移动端)

- **整页滚动布局**:`/todo/calendar` 重构为月历 + 当月任务列表同页滚动(月历下方按日分组,点击日格滚动定位到对应分组,选中日高亮)。
- **月历完整版**:`AppMonthCalendar` 升级——农历/节气/节日副标签(1900–2100 与桌面同源)、休/班圆形徽标(蓝 #4C7DF0/橙红 #FF7043)、任务优先级色圆点(≤4)、今天强调块/选中描边。
- **年视图**:点击月份标题进入,12 个迷你月历(3 列)+ 干支生肖 + 春节红杠/初一蓝杠下划线,PageView 左右滑动切年,点击任意日期回月历并定位。
- **长按日格快捷新增**:长按任意日期直接打开新增表单并预填该日为截止日期(对应桌面右键)。

P1 体验能力包补记（#8/#9/#10/#11/#12/#13，8/26 落地未记账）+ P2#19 冒烟接入 CI + **我的一天（My Day）三端落地**（07 报告新增 #23）+ 标题栏窗口控制键重制 + **提醒功能三端升级**（推迟操作 / 后台闹钟 / 灵动岛类别）+ **日历视图三端升级：格内待办长条 + 联网节假日**（07 报告新增 #24）+ **回收站三端落地**（删除的任务可恢复，保留时间可配）+ **统计仪表盘三端落地**（07 报告新增 #25）+ **移动端全局搜索 + 双端排序选项**（07 报告新增 #26）+ **移动端侧滑手势**（#18 清账）+ **桌面详情抽屉关联任务区完整交互**（07 报告新增 #28）。

### Added

- **桌面详情抽屉「关联任务」区完整交互（#28）**：
  - 原状：关联任务仅只读胶囊（显示 `#id` 不显示标题，无添加/删除/跳转）
  - 升级：行显示对方任务标题（useQueries 逐行解析 + 已完成态标注）+
    类型徽标 + hover 删除关联；点击行切换抽屉到对方任务；
    「添加关联」Popover 搜索选择器（复用 `globalSearch`，300ms 防抖，
    排除自身与已关联，空态/无结果文案，回车即关联）
  - ipc-mock 补 relations 全命令面（create/delete + detail 返回真实
    relations + MockRelation 模型），为 e2e 关联用例铺路
  - 门禁：桌面 typecheck/vitest 101 + Playwright e2e 3 全绿
- **移动端侧滑手势（#18，对标 iOS Reminders / TickTick 的滑动操作）**：
  - 任务行 `flutter_slidable` 面板式动作：右滑露「完成」（已完成态变
    「恢复」，行保留不删）、左滑露「删除」（走既有确认弹窗 + 回收站
    语义）；BehindMotion + 26% 宽动作面板，与长按菜单并存不冲突；
    `onDelete` 可空参数让只读场景（搜索页等）可复用 Tile 不露删除
  - 07 原评估「WebView 手势冲突需验证」难点已随 Flutter 拆分
    （ADR 0003）失效，降为纯组件接线
  - 侧滑组件测试 3 用例；全量 Flutter 108 绿。测试基建教训：
    testWidgets 假时钟下顶层 await MockOrbitBridge 的延迟 Future 会
    死锁（须手造 DTO 或 pumpWidget 后取数）；Slidable 展开动画对
    `pumpAndSettle` 不收敛，改固定时长 pump
- **移动端全局搜索 + 双端排序选项（#26）**：
  - **搜索（移动端补齐，桌面 Ctrl+K 已有）**：FRB `search.rs` 镜像
    `search_all`（任务/项目/评论三路 LIKE 聚合）；`/todo/search` 页——
    自动聚焦输入框 + 300ms 防抖，任务行点击进详情（已完成态划线）、
    项目行点击进项目子列表、评论行显示所属任务与摘要点击直达；
    侧栏新增「搜索」入口行；MockOrbitBridge 同口径实现（软删过滤 +
    空关键词空结果）
  - **排序（双端，原硬编码 position→created_at）**：五档可选——
    拖拽顺序（默认）/截止时间（无截止沉底）/优先级（大者在前，同值落回
    拖拽顺序）/标题（中文拼音序）/创建时间（最新在前）；`sortTasks`
    共享逻辑扩档位（桌面 task-filters.ts / 移动 task_logic.dart），
    缺省档语义不变。桌面：列表工具栏排序 Select + localStorage 持久化，
    非「拖拽顺序」档隐藏行拖拽把手并禁用拖拽（顺序由排序档决定）；
    移动端：子列表标题栏排序 PopupMenu（会话内存态）
  - 门禁：桌面 vitest 101 绿（排序档位新 5 用例）、Flutter 105 绿
    （搜索冒烟 2）
- **统计仪表盘三端落地（#25，对标 TickTick 成就页 / GitHub contributions）**：
  - **数据层 `stats_api`（orbit-core，只读聚合）**：以 `done_at` 为唯一事实
    来源（本地时区日界分桶，仅统计存活任务），一次性返回总览（总数/已完成/
    未完成/近 7·30 天完成数）、热力图（窗口 35–371 天钳制，含零完成日）、
    连续完成天数（streak：今天有→今天起算，无→昨天必须有完成，best 取历史
    最长；断档规则纯函数独立单测）、项目/优先级/星期分布；零 schema 变更、
    不进同步白名单
  - **桌面端**：`/todo/stats` 嵌套面板——总览五卡 + streak 行（火焰图标）+
    CSS grid 自绘热力图（周一为行首、月标签、5 档色阶、悬停 tooltip，
    **不引图表库**）+ 项目/优先级/星期三分布卡（双段条形图）；窗口档位
    近 5 周/近半年/近一年；入口 = 侧栏「统计」行（激活高亮 + 折叠态图标）+
    命令面板「统计」
  - **移动端**：`/todo/stats` 页（PopupMenu 窗口档位 + SectionCard 风格
    总览卡/streak/横滚热力图/三分布卡）+ 侧栏「统计」入口行（日历行之下）；
    FRB `stats.rs` DTO 镜像 + MockOrbitBridge 同口径实现（含软删过滤与
    streak 断档规则对齐）+ 冒烟测试；侧栏冒烟随新行滚动断言顺序微调
  - Rust 单测 7（含纯函数 streak 断档规则）、桌面 typecheck/vitest 96 绿、
    Flutter 103 绿

- **回收站三端落地（用户需求：删除的待办进回收站，保留时间可参考优秀开源项目）**：
  - **范围与档位（对标 Todoist / 微软 To Do / Vikunja）**：仅任务进回收站
    （项目/标签维持既有保护式删除）；保留档位 **7 天 / 30 天（默认）/
    90 天 / 永久**，存 `cfg_kv`（本机偏好不随云同步）；支持一键清空回收站
  - **数据层 `trash_api`（orbit-core）**：在既有软删墓碑行之上新增
    列表（`deleted_at` 降序）/ 恢复（`is_deleted=0` + `updated_at` 提升，
    云同步复活裁决自动跨设备传播，同步引擎零改动；原项目已删则落未分组）/
    彻底删除（物理 DELETE 连带子任务/标签关联/评论/关系/提醒）/
    TTL 过期清理（`should_purge_now` 每日记账 + **同步守卫**：启用云同步时
    仅清 `deleted_at < last_synced_at` 的已上传墓碑，防止云端旧数据复活任务；
    边界决策见 **adr/0005**）
  - **桌面端**：**/todo 嵌套壳层路由**（TodoShell：侧栏 + 选中态 + 抽屉/表单
    常驻，Outlet 切任务/回收站面板——回收站也带侧边栏，切回任务面板筛选
    原样保留）；回收站面板（行含保留期倒计时徽标，右键恢复/彻底删除，
    顶部清空确认）+ 侧栏快捷区「回收站」固定行（激活高亮态；折叠态图标
    同款）+ 标题栏/命令面板入口 + 设置新增「待办」分类（保留档位 pill
    选择）+ `trash_scheduler` 60s tick 守护（启动首轮补清）+ 三处删除
    确认文案更新（「之后将移入回收站」）
  - **移动端**：`/todo/trash` 页（行长按恢复/彻底删除菜单 + 保留期倒计时
    副标题 + 标题栏清空）+ 侧栏「回收站」入口行（计数 badge）+ 设置页回收站卡
    （`select_bottom_sheet` 档位选择）+ BootGate 接 `start_trash_scheduler`
    （FRB Rust 守护 60s tick，多日未开启动首轮补清；进程被杀期间惰性等待，
    同 holiday scheduler 模式）+ 删除确认文案改「移入回收站，可在回收站恢复」
  - **Mock 桥语义对齐**：桌面 ipc-mock 与移动 MockOrbitBridge 的
    `todoTaskDelete` 从物理删除改为软删（墓碑进回收站），补齐 trash 全命令面；
    移动端侧栏冒烟测试随新行视口布局微调断言顺序
- **日历视图三端升级（#24，用户需求）**：
  - **移动端日历页 `/todo/calendar`**：月历 7×6 周格（周一起始），每个日期
    格内是当日的**待办小长条列表**（优先级色点 + 截止 HH:mm 逾期红 + 截断
    标题），**点击长条进入任务详情**；当日待办超出格子高度时**格内纵向滑动**
    查看全部；月导航（前后翻页 / 点月份标题回今天）；侧栏「日历」入口行
  - **桌面月格任务条改为可滚动列表**：原「超 3 条折叠为 +N 弹层」改为格内
    overflow-y-auto 滚动查看全部（悬停长条尾部「⋯」保留弹层精确定位路径）
  - **联网更新中国法定节假日（三端共享数据层）**：orbit-core `holiday_api`
    拉取 timor.tech 年接口（浏览器 UA 过 Cloudflare 拦截），事务「先删后插」
    整年替换 `cfg_holidays` 本地缓存表（不进云同步白名单）；内置 2026 年
    40 行预置表（放假 + 调休补班），首装冷启动 / 离线时日历仍可正确标注
  - **更新时机三触发**：①每天固定时刻一次（默认 08:00 本地时区，
    `holiday_set_fixed_hour` 可调 0-23）；②**错过更新时间（未打开应用）
    时下次开启自动补更**（`should_update_now` 以「上次成功更新的自然日」
    记账，跨天且已过固定时刻即拉）；③日历工具栏**手动更新**按钮（tooltip
    显示上次更新时间）。调度实现：桌面 `holiday_scheduler` 60s tick 守护
    （lib.rs setup 启动）+ 移动端 FRB `start_holiday_scheduler`（BootGate
    在 DB 就绪后启动，60s tick 同 reminder_poller 模式）
  - **节假日徽标**：月格日期行 + 议程分组头显示「休」（放假，绿）/
    「班」（调休补班，橙）小徽标，hover/tap 显名称
  - **PRIVACY.md §四披露**：节假日接口只携带年份、不传任何身份信息或
    本地任务数据；失败回退预置表，功能不依赖该接口
  - **附带修复 wait_toast 真实崩溃**：`Row(crossAxisAlignment.stretch)`
    在 Overlay Positioned 无界高度下把无限约束传给子级触发布局断言——
    包 `IntrinsicHeight`（此前任何 toast 链路一触发即崩，测试暴露）


- **桌面系统通知推迟按钮（三平台）**：右下角系统弹窗（Windows Toast /
  macOS 通知中心 / Linux XDG 通知）带「推迟10分钟/30分钟/1小时」三键。
  tauri-plugin-notification desktop 路径不透传 actions，绕开插件直用
  notify-rust 4.18（三平台 action + wait_for_action 回调全支持）；点击后
  Rust 侧删旧建新写 DB（锚点=原 remind_at+N，与前端 toast 同语义）+
  emit snoozed 事件前端失效缓存；timeout Never 带按钮通知不自动消失；
  Windows AUMID 用 cn.wait.orbit。新增 toast_actions_manual 手动验收
  测试——Windows 本机实测点击「推迟30分钟」回调精准收到 snooze_30。
- **系统通知推迟后联动关闭应用内提醒 toast**：双通道并发下（系统通知 +
  in-app sonner toast 同时弹出，后者 duration Infinity 常驻），在系统通知
  上点推迟后 in-app toast 会一直挂着——且其引用的提醒行已被删旧建新，
  再点它会建出第二条平行提醒。修复：snoozed 事件补 reminder_id + title
  （Rust 侧 title 克隆为 owned 过 thread::spawn 的 'static 约束）；前端
  维护 reminder.id → toast id 登记表，snoozed 到达时 dismiss 对应 toast
  并弹与站内推迟同款「已推迟到 HH:mm」确认提示；手动关闭 toast 时同步
  清登记。cargo check/clippy + tsc + 87 单测全绿。
- **提醒功能三端升级**（用户需求：到期可推迟 10 分钟/30 分钟/1 小时；
  移动端后台可提醒 + 小米灵动岛形态）+ **可用性补强轮**（commit 92b5ef5）：
  - **桌面端推迟**：到期 toast 重制为自定义卡片（sonner toast.custom，
    不再自动消失），带三档推迟按钮。删旧建新语义：新 remind_at =
    **原 remind_at + N 分钟**（锚点不漂移）；续排引擎防雪球守卫——
    到期行触发重复续排前若任务已存在其他未来提醒（推迟产物），
    只清理不克隆，避免「原系列 + 推迟系列」平行滚动。续排删旧失败
    （行已被并发清理）不再中断建新。新增 `reminder-snooze.ts`
    纯逻辑模块 + 6 项单测
  - **移动端后台闹钟通道**（ADR 0002 α→β 演进落地）：`ReminderScheduler`
    启动/dbChanges 防抖 2s 把 DB 未来提醒（join 任务标题，过滤已完成/
    已删任务）全量重排进系统闹钟（zonedSchedule alarmClock，权限缺省
    逐级回落 exact→inexactAllowWhileIdle）。闹钟由系统 AlarmManager
    持有：**退后台/被杀/Doze 均准时触发**，重启由插件 BootReceiver
    恢复；到点通知原生构建，不依赖 Dart 进程——修复「后台不提醒」。
    dbChanges 单播流修复：调度器事件由 BootGate 唯一订阅转发
    （FRB 二次 listen 静默丢事件，模拟器实测复现修复）
  - **移动端通知推迟**：到期通知带三档推迟 action，后台 isolate 回调
    （@pragma 防 AOT 裁剪，被杀可达）不写 Rust DB：重排系统闹钟 +
    静默确认通知；DB 收敛 = 旧行到期检测系统闹钟面更晚排程（推迟
    产物）→ 静默删行；前台与闹钟同 id show() 覆盖去重，识别失败
    保守放行（宁可重弹不可吞提醒）
  - **精确闹钟授权引导**：Android 12+ canScheduleExactNotifications
    为 false 时弹系统「闹钟和提醒」授权页（模拟器实测弹出）；拒绝则
    非精确闹钟兜底（Doze 下允许系统级延迟，通知仍达）
  - **小米灵动岛（焦点通知）**：category=alarm + Importance.high
    ——闹钟类高优通知在支持机型以灵动岛胶囊呈现
  - **模拟器实测**：APK 构建（6 权限 + 3 receiver 合并✓）、启动链路✓、
    授权弹窗✓、alarmClock 排程 pending✓；force-stop 清闹钟为 Android
    系统语义边界（非缺陷，重开 App 全量重排自愈）；integration_test
    基建入库；真机复验清单见 ADR 0002 §七
  - Manifest：RECEIVE_BOOT_COMPLETED / WAKE_LOCK / SCHEDULE_EXACT_ALARM /
    VIBRATE + 插件三 Receiver（官方 README 原样）；移动端 88 测试全绿
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

### Changed

- **Windows 计划通知：托盘退出后提醒仍可达（离线提醒）**：此前从托盘
  菜单「退出」= 进程结束 = 轮询守护死亡，未来提醒全部静默。现在退出
  前把 DB 未来 24h 内未删提醒注册进 Windows 系统 Toast 调度器
  （`ScheduledToastNotification` + `AddToSchedule`，新模块
  `scheduled_toast.rs`），到点由**操作系统直接弹出，零进程依赖**；
  下次启动时 `clear_schedule_on_startup` 清除全部计划，防止与运行中
  轮询通道双弹。离线 toast 为纯提醒文本（标题 + 时刻，scenario=reminder
  + Reminder 音效），不带推迟按钮——进程不在 action 回调无人接，按钮
  只会给假交互。AUMID 与直发通道一致（cn.wait.orbit）。任务标题经
  XML 转义防注入；epoch 换算（Unix ms → WinRT 1601 元年 100ns）与
  转义共 3 项单测。DB 未解锁即退出时静默跳过（无可排提醒）。
  mac/Linux 无对应离线通道，保持既有「驻留托盘」模型。
- **过期提醒不再重播（启动防轰炸）**：此前启动首轮扫描会重播 24h 窗口
  内全部已到期提醒——上午 8 点的提醒，中午 12 点启动应用还会再弹一次。
  修复两层：① Rust 启动首轮跳过过期超过 5 分钟的历史遗留提醒
  （`STALE_SKIP_MS`），静默记入去重集合，后续轮次也不再弹；启动前后
  5 分钟内到期与应用运行期间到期的提醒走正常路径（轮询间隔 20s ≪
  5 分钟阈值，无误伤）。② 前端窗口隐藏（驻留托盘）期间到达的 due
  事件不再弹应用内 Infinity toast——系统通知才是后台提醒通道，隐藏期
  弹的 toast 会在恢复窗口时堆积成一片过期卡片。「不开应用也提醒」
  由既有托盘常驻保证：关窗=隐藏驻留（非退出），轮询守护/系统通知
  在后台持续工作；从托盘菜单「退出」才是真正结束进程。
- **修复批量删除撤销失效**：batchDelete 原循环 N 次 undoableDelete——
  撤销队列是单槽位（pendingRef），第 i 笔调用会 `flush()` 第 i-1 笔
  **立即真删落库**，结果勾 N 条时除最后一笔外全部提前提交；每条
  toast 都带撤销按钮但点了毫无反应（cancel 对已执行返回 false，
  原实现此时连 dismiss 都不做）——「撤销没有作用」的直接根因。
  修复：批量删除单笔化——新增 `hideManyFromQueries` 一次隐藏全部
  N 行 + 一次 commit 删全部 + 单条 toast「已删除 N 个任务」，撤销
  一键整批恢复。撤销按钮交互顺带补强：cancel 失败（超时已提交）也
  dismiss toast 并提示「已过撤销窗口，删除已提交」，不再无声。
  浏览器实测：勾 3 条 → 确认删除 → 单 toast → 点撤销 → 3 行全部
  恢复、DB 未动（撤销窗口内未提交）、toast 消失，全链路通过。
- **删除类操作补确认/反馈**（全库盘点后分级处理）：
  - **批量删除加确认弹窗**：多选工具条删除原为一键直删（虽有 5s 整批
    撤销，图标按钮重构后误触概率上升，多条误删→撤销的心智成本高于
    一次确认）。确认弹窗带条数文案「删除 N 条任务 / 确定要删除已选的
    N 条任务吗？删除后 5 秒内可整批撤销」，红色确认键。
  - **标签删除加确认弹窗**：标签管理器删除原为悬停一键直删——删除会
    连带解除该标签与所有任务的关联（撤销虽恢复标签本体，关联不会
    重建），弹窗文案明确说明这一点。
  - **子任务/提醒/评论删除补 toast 反馈**：详情抽屉三处 hover 删除
    原为无声直删，现删后弹「已删除子任务/提醒/评论」确认；保持不加
    弹窗（局部低风险微操作，对齐 MS To Do 惯例——弹窗打断高频操作）。
  - 已有确认保持不变：任务右键/详情删除弹窗、项目删除双弹窗
    （未完成拦截 + 确认）。
  浏览器实测：勾选 3 条 → 工具条删除 → 弹窗 → 确认（10→7 乐观隐藏 +
  整批撤销 toast）/ 取消（数据不动、多选态保留）双向链路通过。
- **超长文本溢出修复（看板卡片标题为主诉 + 全库同类排查）**：看板卡片
  标题允许多行但缺 `break-words`——长英文串/URL 等无空格断点的连续文本
  不断行，直接撑出卡片右缘。修复 + 全库排查同类「渲染用户自由输入、
  允许多行但缺断行保护」的点，共 7 处：①看板卡片标题 `break-words`
  ②详情抽屉描述 ③详情抽屉评论（顺带补 `min-w-0 flex-1`，防长评论
  挤压时间/删除按钮）④提醒 toast 标题 ⑤撤销删除 toast 的 recordName
  超 30 字截断（sonner 容器不 break-words）⑥任务删除确认弹窗
  ⑦项目删除确认弹窗（均 `break-words`）；另项目右键菜单标题头加
  `max-w-[240px] truncate`（长项目名会撑宽菜单）。列表视图/日历
  视图/命令面板/全局搜索本就有 truncate（单行截断），未受影响。
  浏览器实测：长英文串在看板断 6 行、长中文断 4 行，标题右缘距
  卡片 -13px 余量、滚动区无横向溢出；抽屉长描述断 3 行 -24px 余量。
- **列表行高固定 57px**：行高不再随元信息有无变化——原版纯标题行
  47px、文本元信息行 63px、含标签 chip 行 65px 三种高度混杂，虚拟
  列表动态测量下增删/勾选标签会引起整列重排抖动。修复：TaskRow 固定
  `h-[57px]`（与虚拟器 estimateSize 恒一致），标题+元信息列
  `flex-col justify-center` 整体垂直居中（无元信息时标题独占也居中）；
  加载骨架行同步 57px。顺手清理空 meta 行：仅设优先级（无标签/项目/
  截止）时原会渲染一条内容为空的元信息行（`priority > 0` 条件的
  遗留，meta 行本就不显示优先级文本），条件收窄为「有标签/项目/截止」。
  浏览器实测：全行 57px 恒定，纯标题行标题居中 offset 18px、两行
  内容行 8–9px，无空 meta 行。
- **窗口控制键悬浮背景铺满标题栏**（修复视觉间隙）：关闭键悬浮红底
  上下各露 ~2px 深色条——根因是按钮固定 32px 高而标题栏 36px，且
  `align-self: stretch` 被中间层 `ml-auto` 容器（内容高 32px）截断，
  无法传导到栏高。修复：三键及 `.window-controls` 容器改 `align-self:
  stretch` + title-bar 右侧容器加 `self-stretch`（高度链 36→35→35
  全传导），按钮去掉固定 `height: 32px`。现在 hover/红底贴顶到底
  （0–35px 内容区全高），与 Win11 原生 caption 键行为一致；其余
  功能图标钮仍垂直居中不受影响。浏览器实测：DOM rect 0→35 全高 +
  截图像素扫描红底 y0–34 连续无断带。
- **批量工具条排版重构**（P2#17 视觉打磨）：原版 8 个带文字按钮 +
  两个 Select 直接嵌在 `<Button>` 内平铺（总宽 900px+，窄窗溢出，
  且 button>button 非法嵌套）。重制为紧凑形态——计数文本 + 分隔线 +
  一排 32px 图标 ghost 按钮（Tooltip 补语义），总宽收敛至 ~420px；
  优先级/移动项目改为 DropdownMenu 即点即执行（6 档色点 / 项目色点，
  与右键菜单同款式），消除「先选草稿再点执行」的两步心智。顺手修正
  语义偏差：「移回待办/移入进行中」恢复 `every`（全完成）口径。
  浏览器 mock IPC 实测：几何精确居中、图标间距均匀 ±1px、下拉菜单
  6 档齐全、批量优先级链路（勾选 3 → 菜单点「高」→ DB 落库 +
  工具条自动收起）全通。

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
