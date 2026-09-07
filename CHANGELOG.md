# Changelog

本文件记录 Orbit 的所有显著变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

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
