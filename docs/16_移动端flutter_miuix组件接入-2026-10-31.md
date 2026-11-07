# 移动端 flutter_miuix 组件接入（2026-10-31）

> 本文是「把 `flutter_miuix` 全部可用组件映射到本项目移动端」的落地记录：
> 组件清单 → 本项目现有实现的映射 → 替换范围 → 保留的兼容处理 → 验证证据。
> 组件库版本：**flutter_miuix 1.3.0**（pub.dev，精确锁版；OS4 玻璃自 1.2.0 起随包发布）。
> 代码入口：`apps/mobile/lib/core/theme/miuix_theme.dart`（主题桥）+ `apps/mobile/lib/shared/widgets/shadcn/orbit_*.dart`（原语层）。

## 一、为什么是「原语层换承载」而不是「页面重写」

本仓移动端有 72 个页面文件 / 3.5 万行 UI 代码，页面结构统一为
`OrbitPageHeader（Stack 顶部）+ 整页滚动列表`（AGENTS.md「必须整页滚动」）。
若按 flutter_miuix 的 `MiuixScaffold + MiuixTopAppBar` 范式整页重写：

- 28 个页面的 `状态栏 + rowHeight` 让位计算全部失效（内容被栏体压住或留白翻倍）；
- 页头的 `titleWidget` 槽（计数徽标 / 视图切换器 / 日期副标）在 `MiuixTopAppBar`
  里没有对应参数（它只吃 `String title`）；
- 弹层/抽屉承载（`showModalBottomSheet` 49 处）与 `OrbitSheetScaffold` 骨架耦合，
  换 `MiuixOverlayBottomSheet` 的声明式 API 等于重写全部抽屉。

故采取**最小侵入**方案：**只把「组件实现」换掉，公共 API 与布局几何逐字保留**。
调用点绝大多数零改动（`OrbitCard` / `OrbitCheckbox` / `OrbitSpinner` /
`OrbitPageHeader` / `OrbitBottomNav` / `EmptyState` / `SectionCard` 等签名不变），
页面逻辑（Riverpod provider、路由、手势、测试 finder）不受影响。

## 二、组件清单与映射

### 2.1 已替换（承载换成 Miuix）

| flutter_miuix 组件 | 本项目原语 | 页面调用点 | 换承载后得到什么 |
|---|---|---|---|
| `MiuixCard`（squircle） | `OrbitCard` / `SectionCard` | 18 处 | 超椭圆圆角（`MiuixSquircleBorder`），描边用同一条超椭圆路径自绘（`_CardOutlinePainter`），填充/无阴影口径不变 |
| `MiuixCheckbox` | `OrbitCheckbox` | 13 处 | 圆形勾选框 + 描画式对勾（`trim` 逐帧生长）+ 按压下沉 0.85；**完成态填充仍为弱化灰**（已完成行整行置灰口径）、优先级色环由本组件自绘（库内无描边参数） |
| `MiuixInfiniteProgressIndicator` | `OrbitSpinner` | 21 处 | HyperOS 系统加载态（细环 + 绕行点，800ms 周期固定） |
| `MiuixLinearProgressIndicator` | `OrbitProgressBar`（新增） | 5 处 | 圆头胶囊进度（不再需要外层 `ClipRRect`），确定/不定态同一组件 |
| `MiuixButton`（squircle） | `OrbitButton`（新增） | 80 处 | 超椭圆按钮 + 弹簧按压遮罩；`primary/secondary/outline/text` 四档对应 Material 三件套 + destructive 语义 |
| `MiuixIconButton` | `OrbitIconButton`（新增） | 44 处 | 圆形按压底 + 弹簧反馈；保留 `tooltip` / `visualDensity` / `constraints` / `padding` / `iconSize` 兼容参数 |
| `MiuixSwitch` | `OrbitSwitch` / `OrbitSwitchRow`（新增） | 8 处 | 49×28 胶囊轨道 + thumb 放大 1.127 + 弹簧切换 |
| `MiuixSurface`（squircle） | `OrbitFilterChip`（新增） | 4 处（2 处 `ChoiceChip` + 2 处手搓容器） | 筛选标签统一为 squircle 表面 + 强调色 16% 选中底 |
| `MiuixHorizontalDivider` / `MiuixVerticalDivider` | `OrbitDivider` / `OrbitVerticalDivider`（新增） | 6 处 | 0.75 细线 + `dividerLine` 语义角色（保留 `height`/`thickness` 语义） |
| `MiuixGlassNavigationBar`（**OS4 玻璃**） | `OrbitBottomNav` | 1 处（壳） | 液态玻璃底栏 + 滑动胶囊指示器 + 弹簧回弹 + 支持拖动换页 |
| `MiuixGlassPanel` + `miuixGlassSurface`（**OS4 玻璃**） | `OrbitPageHeader` 玻璃层 / `OrbitFloatCard` 浮层 / `OrbitGlassSurface` + `OrbitGlassSheet`（更多操作抽屉，2026-11-03） | 28 页页头 + 全部锚点浮层 + 快速添加面板 + 动作抽屉 | 页头：OS4 材质（模糊 + 混色 + 描边），无采样器时回落实时 `BackdropFilter`；os4 形态（首页）leading/actions 只占 44dp 槽位、不垫玻璃底（2026-11-06 收掉浮块）；浮层：`puredThinGlass` + blur 32；弹层：`puredThinGlass` 栏体材质 + `shading: false` |
| `MiuixTheme` / `MiuixColors` / `MiuixTextStyles` | `OrbitMiuixTheme`（`core/theme/miuix_theme.dart`） | 根装配 + 测试壳 | 54 个语义色角色全部由 `AppColors` / `OrbitAccents` 派生，三套体系（Material / shadcn / Miuix）数值同源 |
| `MiuixGlassRendering` | `HomeShell.initState` 预热 | 1 处 | 首帧前加载 OS4 shader，避免"先实色后玻璃"的跳变 |

### 2.2 OS4 玻璃的采样接线（关键约束）

`MiuixGlass*` 组件通过 `MiuixLayerBackdrop` 拿「自己背后的像素」。
库内硬约束：**捕获树（`MiuixLayerBackdropCapture`）与玻璃消费方必须是兄弟节点**，
否则形成自采样反馈循环（栏体把自己也拍进背景，越糊越实）。

本项目的接线（`modules/shell/home_shell.dart`）：

```
OrbitGlassScope（向下暴露同一个 backdrop）
└─ Scaffold
   ├─ body: MiuixLayerBackdropCapture(child: navigationShell)   ← 只包页面内容
   ├─ bottomNavigationBar: OrbitBottomNav(backdrop: …)          ← 捕获树之外
   └─ floatingActionButton: OrbitFab
```

页头（`OrbitPageHeader`）在自己的页面 Stack 里，不在壳的捕获树内：
- 传了 `backdrop` → 走 OS4 材质；**首帧快照尚未录制时自动回落实时模糊**（避免闪实色）；
- 没传（测试裸页、详情页等）→ 走 `OrbitProgressiveBlur` 实时路径，观感同档。

### 2.3 有意保留（不替换，附理由）

| 组件 | 保留原因 |
|---|---|
| `showModalBottomSheet`（49 处） | 抽屉承载与 `OrbitSheetScaffold`（标题/可滚内容/固定尾栏/键盘避让）深度耦合；`MiuixOverlayBottomSheet` 是声明式 API（`show` 布尔 + `onDismissRequest`），且库内**没有** `MiuixGlassBottomSheet`（上游未实现）。换承载会同时改 49 处调用写法与全部抽屉测试。 |
| `showDialog`（3 处，均为附件图片预览透明 Dialog） | 非选择/确认/输入类，AGENTS.md 明确豁免 |
| ~~`TextField` / `TextFormField`（27 + 12 处）~~ | **2026-11-02 已替换**为 `OrbitTextField`（`MiuixTextField` 承载，见 5.4.1）：壳层补齐 `maxLength` / `validator` / `onTapOutside` 与 `inline` 变体。业务层不再有裸 Material 输入框。 |
| `ListTile`（20 处） | `MiuixBasicComponent` 的 2:5:3 测量约束与 `ListTile` 的 `leading/title/subtitle/trailing` 语义不一一对应；侧栏/搜索/回收站的 `ListTile` 已由 `orbit_list_card` 的分段卡面承载外观，换组件只换布局实现、不改观感。 |
| ~~`RefreshIndicator`（列表页 4 处）~~ | **2026-11-01 已替换**：先由 `MiuixPullToRefresh` 承载，2026-11-03 指示器改自绘 `OrbitPullToRefresh`（手势/弹簧口径不变），见第五节。 |
| `Tooltip`（9 处） | 全局 `tooltipTheme` 已是「主题色底白字」口径（AGENTS.md 强制），64 条测试用 `find.byTooltip`；`MiuixTooltip` 是独立组件（`MiuixTooltipBox`），换掉会同时改调用写法与断言。`OrbitIconButton` 内部仍用 Material `Tooltip`，保证 `byTooltip` 全部有效。 |
| `InkWell` / `Material`（74 / 13 处） | 属点击/裁剪基建而非"组件"，且大量用于水波/圆角裁切。 |
| `MiuixScaffold` / `MiuixTopAppBar` / `MiuixNavigationRail` / `MiuixTabRow` / `MiuixBreadcrumbBar` / `MiuixSearchBar` / `MiuixSlider` 系 / 偏好项（`Miuix*Preference`） | 本项目**没有对应功能**：无 Tab 栏（用底部导航）、无面包屑、无搜索框（清单过滤用 chip 行）、无 Slider（容量是文本输入）、偏好项语义由 `SectionCard` + 行组件表达。**不为了"用上组件"而新造功能**（AGENTS.md 裁剪口径）。~~`MiuixColorPicker` 系~~ / ~~`MiuixNumberPicker`~~ / ~~`MiuixFloatingToolbar`~~ 已于 2026-11-01 替换（取色抽屉 / 时分滚轮 / 批量工具条），见第五节。 |
| ~~`MiuixSnackbar` / `MiuixSnackbarHost`~~ | **2026-11-01 已替换**：`WaitToast` 公共 API 不变、引擎换 `MiuixSnackbarHostState` 队列（根部 `OrbitToastHost` 挂载，不依赖页面 Scaffold），见第五节。 |

## 三、验证

- `flutter analyze`：0 issue；
- `flutter test`：**1112 项全绿**（与接入前同数量，含 `done_gray` / `home_shell` /
  `subtask_section` / `quick_add_sheet` / `sync_settings_page` 等交互回归）；
- 新增/改写的原语单测：`orbit_card_test` / `orbit_checkbox_test` / `orbit_spinner_test` /
  `orbit_empty_state_test`（断言从「内部 painter 字段」收敛到「组件契约」）；
- 依赖解析：`pubspec.lock` 记录 `flutter_miuix 1.3.0`（hosted，sha256 与 pub.dev 一致）。

### 3.1 构建与资源验证（Android）

- `flutter build apk --debug` 通过；
- **7 个 OS4 shader 确认打进 APK**：
  `assets/flutter_assets/packages/flutter_miuix/shaders/` 下
  `miuix_os4_glass/mask/stroke/shadow/rim/blend.frag` + `miuix_bloom_stroke.frag` 全部存在
  ——玻璃路径在真机上可加载，不是"只有回退实色"。

### 3.2 实机验收（Pixel 9 Pro XL 模拟器，Android 17 / API 37，1080×2400）

逐页截图核对，主路径无回归：

| 场景 | 结果 |
|---|---|
| 解锁页 | squircle 主按钮 + 描边按钮正常 |
| 首页（今天） | OS4 玻璃底栏（滑动指示器胶囊、选中态强调色）+ 玻璃页头 + squircle「新建任务」 |
| 清单页 | 分段卡片（首/中/末段圆角拼接）+ 玻璃页头（内容滚过时磨砂可见） |
| 任务列表（300 条示例数据） | 圆形勾选框（空心环 + 优先级红/橙/蓝/灰配色）+ 角标 90 |
| 勾选交互 | 计数 90→89、今日已完成 1→2、底栏角标同步（写路径 + 失效链正常） |
| 详情页 | squircle 卡片、圆头进度条（子任务 1/2）、已完成灰填充勾选框 |
| 优先级抽屉 | 选项行/色点/当前值对勾齐全，点选即关 |
| 日历页 | squircle 选中日块、农历/休班徽标、圆形勾选框 |
| 四象限 | 四张 squircle 卡片 + 圆形勾选框 + 分隔线 |
| 统计页 | 热力图、条形图、squircle 卡片正常 |
| 「更多」面板 | 玻璃浮层锚在「更多」页签上方，条目/编辑入口齐全 |
| 暗色主题 | 深色玻璃底栏/页头、角标与文字对比度正常 |

**验收中发现并修复的一处真机问题**：OS4 玻璃导航栏自身只画 54 高玻璃条 +
3dp 悬浮边距，**不吃 `viewPadding.bottom`**，系统手势条与页签图标叠在一起
（`cad2800` 已补 `EdgeInsets.only(bottom: viewPadding.bottom)`，等价旧实现的
`SafeArea(top: false)`）。

**对照基线确认的非回归项**：底部抽屉（快速添加 / 选择 / 确认）在 `main` HEAD
上同样是「全屏白底 + 内容贴底」的观感——这是 `showModalBottomSheet` +
`isScrollControlled: true` 的既有行为（基线 APK 同点位截图一致，widget 测试
中两者的 `BottomSheet` rect 也完全相同），不是本次换组件引入的。

## 四、已知取舍（改前必读）

1. **勾选框形态**：方角 → 圆形（HyperOS 语言）。若产品要回方角，改
   `orbit_checkbox.dart` 的 `_CheckboxRingPainter` + 库内 `MiuixCheckbox` 的
   `borderRadius`（库内写死圆形，需上游支持）。
2. **底栏文字**：仍是纯图标（`MiuixGlassNavigationItem` 只传 `contentDescription`），
   未取 HyperOS 的 iconAndText 形态（`home_shell_test` 锁定「今天」只出现在页头）。
3. **触感**：`MiuixCheckbox` 内部每次切换都发 `lightImpact`，本层不再补
   `selectionClick`（叠加会变成两下震感）；取消完成时同样震一下属上游行为。
4. **shader 降级**：无 runtime shader 的设备上，OS4 玻璃退化为「模糊 + 原生混色」，
   不是实色；`MiuixGlassRendering.loadError` 可查原因。

## 五、第二批：组件面全量收口（2026-11-01）

### 5.1 目标与结果

第一批（10-31）只换了「原语层承载」，页面里仍有 12 个文件直接使用 shadcn
组件（`sh.Button` / `sh.showToast` / `sh.ColorPicker` / `sh.Tooltip` /
`sh.Card` / `ShadcnLayer` 装配）。本批**把残余 sh.* 组件用法清零**：

- `import 'package:shadcn_flutter'` 全库仅剩 `core/theme/icon_map.dart`
  （`LucideIcons` 图标字体源，与桌面端 lucide-react 同套线性图标）；
- `ShadcnLayer` / `DrawerOverlay` / `buildShadcnTheme` / destructive 组件主题
  整层移除（`core/theme/shadcn_theme.dart` 删除），运行时不再有第三套主题层；
- 公共 API 全部保持（`WaitToast` / `OrbitButton` / `OrbitSheetActions` /
  `showOrbitColorPickerSheet` / `OrbitFab` 签名逐字不变），页面调用点改动
  仅限「同一个按钮换构造名」。

### 5.2 本批映射

| 现有实现 | 换成的 flutter_miuix 组件 | 落点 | 口径 |
|---|---|---|---|
| `sh.showToast` 队列（`WaitToast` 内部） | `MiuixSnackbarHostState` + `MiuixSnackbarHost` | `orbit_toast.dart`（引擎）+ 根部 `OrbitToastHost` | 单条策略/停留档位/四变体语义不变；卡面换 HyperOS squircle + `BackdropFilter` 毛玻璃（口径同 `MiuixSnackbar.blurSigma`）；新增横滑关闭；变体色/副文案按 `MiuixSnackbarData` 身份挂 payload 表（退场期不串色） |
| `sh.Button.primary`（圆形 FAB） | `MiuixFloatingActionButton` | `orbit_fab.dart` | 填色走 `containerColor`（不再绕组件主题）；长按（模板新建）由外层 `GestureDetector` 保留（内部 `MiuixPressable` 不注册长按） |
| `sh.ColorPicker`（色域/滑杆/HEX 三档） | `MiuixColorPicker`（HSV 三滑杆 + 预览）+ `MiuixTextField`（HEX 输入） | `orbit_color_picker.dart` | 门面 `showOrbitColorPickerSheet` 不变；HEX 双向同步（聚焦中不回写）；3/6 位十六进制均接受 |
| `sh.Button.outline/destructive/primary`（抽屉尾栏） | `OrbitButton`（`MiuixButton`） | `orbit_sheet_scaffold.dart` 的 `OrbitSheetActions` | 三形态一一对应；`Expanded` 拉满宽语义保留 |
| `sh.Button.ghost`（日期面板清除/确认） | `OrbitButton.text` | `orbit_date_picker.dart` | 紧凑档 40 高 |
| `sh.Button.*`（分诊 / 周回顾 / 排程三页） | `OrbitButton.*` | `triage_page` / `weekly_review_sheet` / `plan_day_sheet` | primary→`primary(expand)`、outline→`outline(compact)`、ghost→`text(compact)` |
| `sh.Tooltip`（月历翻月钮） | `OrbitIconButton.tooltip`（Material `Tooltip`） | `orbit_month_calendar.dart` | 日期面板 2026-09-21 已回退 Material 根层弹层，「找不到 Overlay」约束消失；外观由 `tooltipTheme` 统一（AGENTS.md 口径） |
| `RefreshIndicator`（主列表/清单/统计/回收站） | 自绘 `OrbitPullToRefresh`（2026-11-03；此前为 `MiuixPullToRefresh`） | 新增 `orbit_pull_to_refresh.dart` + 4 页 | 手势/弹簧/阻尼仍按 `MiuixPullToRefresh` 口径；指示器改自绘「弧 → 阈值拉长圆 → 松手收圆 + 环内绕行点」（`OrbitSpinner` 同源几何），阈值态保留拉长圆手感、松手后才出点；`isRefreshing` 由包装内持（页面零改动）；`edgeOffset`/`displacement` 仍作绘制下移避让玻璃页头 |
| `CupertinoPicker`（时分滚轮） | `MiuixNumberPicker` | `orbit_date_picker.dart` 的 `_TimeWheelSheet` | 每项 44 高、5 项视窗、逐项触感、弹簧吸附；边界不环绕（同 Cupertino）；选中/非选中取 `titleText`/`secondaryText` 渐变插值 |
| 手搓批量工具条容器（`Container` + e3） | `MiuixFloatingToolbar` | `sub_list_screen.dart` 的 `_batchToolbar` | squircle 胶囊 + 固定几何阴影 + 0.75dp 描边；外层留白 12/8 由组件贡献，占位常量 `touchTarget + space8*4` 不变；动作内容与横滑逻辑原样 |

### 5.3 OS4 玻璃增量

第一批已接：玻璃底栏 / 玻璃页头 / 玻璃浮层。本批新增：

- **Toast 毛玻璃**：`ClipPath`（squircle）+ `BackdropFilter(σ=28)` + 82% 表面 +
  1px 描边 + e2 阴影（阴影画在裁剪外），与 `MiuixSnackbar.blurSigma` 同构；
- **FAB 换 miuix 引擎**：`MiuixFloatingActionButton`（HyperOS 阴影公式 + 弹簧按压），
  仍为实心强调色（沿用 v3「FAB 不玻璃化」的既定决策，避免与底栏玻璃双重磨砂）。
- **弹出层表面统一 OS4 玻璃（2026-11-03）**：
  - 锚定卡片 `OrbitFloatCard` 接 `MiuixLayerBackdrop`（此前缺采样器退实色白卡）；
  - 底部菜单型抽屉 `showMoreActionsSheet` 改 `OrbitGlassSheet`（承载透明 +
    `elevation 0` + 32% 黑遮罩，键盘避让提到玻璃层外）；**单选**同日再改为
    页头菜单同源的面板（`OrbitDropdownPanelView` 行 + `OrbitGlassSurface`
    卡面，右上角、页头下沿，见 `orbit_select_popup.dart`），不再走底部抽屉
    （`showSelectBottomSheet` 降为兼容名，直接转发新原语）；
    `showConfirmBottomSheet` 保持实色（确认框不是菜单，读秒/危险动作需要实体感）；
  - 形变菜单扩容（`MiuixGlassTransformPopup`）：项目编辑页头 ⋮、上级文件夹行
    （**整行**作触发件，`anchorContent` 为同构副本）、底栏「更多」——
    `OrbitBottomNav` 新增 `moreAnchor` 把图标包进 `MiuixGlassAnchor`，
    `onMoreTap` 退回无参回调，宿主用 `gap: -(barHeight + bottomGap)` 让菜单浮在
    底栏之上；`OrbitDropdownPanelView` 新增 `scrollable: false`（形变弹层外层
    已滚动，内层再套会拿到无界高度报错）；
  - **快加面板 4 张锚定卡片（优先级/标签/项目/更多）保留 `OrbitOverlayCard`
    直挂**：`MiuixGlassTransformPopup` 内部 `FocusScope(autofocus: true)` 会抢走
    标题输入框焦点、键盘下沉，违背「边打字边选」的既有交互（`quick_add_sheet_test`
    三个用例锁死）；它们已是玻璃表面，只差形变动画。**2026-11-07 已解**：
    `showOrbitMenuPopup` 在传入 `restoreFocus`（打开前确实持有焦点的输入框）时，
    把整棵弹层子树包进 `Focus(canRequestFocus: false, descendantsAreFocusable: false)`
    ——库内 autofocus 在 `_Autofocus.applyIfValid` 里因 `canRequestFocus == false`
    直接丢弃，焦点全程留在输入框；四张卡片已全部改走形变承载（见 AGENTS.md
    「所有弹出选择/菜单统一…」条）。
- **锚定浮层卡片接玻璃采样器（2026-11-03）**：`OrbitFloatCard` 早先已挂
  `miuixGlassSurface`，但**没接 `MiuixLayerBackdrop`**——库内无快照即退实色，
  于是「页头 ⋮ 是玻璃菜单、所有锚定卡片是白色实色卡片」两套观感并存。现由
  调用方透传采样器（卡片在 `showGeneralDialog` / `OverlayEntry` 上，位于
  `OrbitGlassScope` 之外，内部自取永远为 null）：底栏「更多」传壳层实例、
  项目编辑页两处传 `OrbitGlassScope.maybeOf`、快加面板用打开时取到的实例。
  材质与 `OrbitGlassMenu` 同档（`puredThinGlass` + blur 32，`shading: false`，
  进场缩放期 origin 逐帧变、纹理缓存失效，60 档会掉帧），并去掉手绘 1px
  `outline`——改由玻璃 shader 的高光描边承担。
- **快速添加面板玻璃化（2026-11-03）**：`showQuickAddSheet` 承载层改透明
  （`backgroundColor: transparent` + `elevation: 0`，否则 Material 在透明底上补
  一圈直角阴影）、遮罩降到 32% 黑；面板表面走新原语 `OrbitGlassSurface`
  （`puredThinGlass` 栏体材质 + `shading: false`，与页头/底栏同档），采样壳层
  同一份 `MiuixLayerBackdrop`（面板挂在根 Overlay，不在捕获树内，无自采样）。
  首帧/无壳退实时 `BackdropFilter`；键盘避让提到玻璃层**之外**，玻璃只覆盖
  面板本体（键盘高度不进模糊纹理）。**FAB 的 `onPressed` 必须用
  `Builder` 下的 context**——`HomeShell.build` 的 context 在 `OrbitGlassScope`
  之上，直接取采样器永远为 null（`home_shell_test` 已锁）。

#### 5.3.1 锚定弹层性能闸门（2026-11-07）

真机反馈「弹窗菜单太卡」（今天页头标题切换、清单/详情 ⋮、快速添加五处（现为
六处，2026-11-07 增「提醒」）、底栏「更多」）。两处开销都在库内形变承载上，收口到 `orbit_popup_glass.dart`
的 `OrbitPopupGlass` + `OrbitPopupGlassMotion`（所有锚定弹层共用，调用点只传
「是否打开」）：

- **形变期不采样背景**：库内纹理缓存键含面板 `origin/size`，形变期间逐帧变 →
  每帧 3 次 `toImageSync`（模糊 + 两趟混色）全量重跑。窗口内（320ms）改走
  库内「无快照」分支的实色圆角（`containerColor`）+ 关描边，卡面观感不变
  （97% 白底 / 深色 `#2C2C2C`）；
- **同帧切玻璃 + 冻结弹簧尾巴**：库内弹簧按 `Tolerance(.0015)` 要跑到 ~690ms，
  卡面 320ms 就已到位（与 `_transformExitCutoff` 同一测量口径）。窗口结束用
  `TickerMode` 静音承载的 ticker：卡面静止后纹理由此只准备一次并全程命中缓存，
  剩余 ~370ms 不再逐帧重绘。代价是几何停在弹簧 ~98% 处（≤1.5%，肉眼不可辨）、
  行按压弹簧被一起静音——故**按下即解冻**（`pointerRouter` 全局路由，卡面在
  `OverlayPortal` 子树里祖先 `Listener` 收不到事件）。**只冻结开场**：二级面板
  退场要靠库内 ticker 才移除 `OverlayPortal`，冻结会把它停在屏幕上；
- **背景快照降采样**：`MiuixLayerBackdropCapture` 每重绘一次就整页
  `toImageSync`（列表滚动是逐帧），按 DPR 录制 1080×2400 屏一次 2.6MP，而取样端
  只要 `dpr/4`。壳层与 `OrbitGlassPage` 改按半个 DPR 录制
  （`orbitBackdropPixelRatio`），快照面积降到 1/4，玻璃观感无差。

### 5.4 保留的兼容处理（本批仍未替换）

| 项 | 理由 |
|---|---|
| `showModalBottomSheet` + `OrbitSheetScaffold` | 见 2.3：与 49 处抽屉的键盘避让/平板限宽/长按确认/固定尾栏深度耦合；`MiuixOverlayBottomSheet` 是声明式 API，属交互级重写 |
| ~~`TextField` / `TextFormField`（27 + 12 处）~~ | **2026-11-02 已迁移**，见 5.4.1 |
| `ListTile`（20 处） | 已在 `orbit_list_card` 分段卡面内承载外观，换 `MiuixBasicComponent` 只换布局实现 |
| Material `Tooltip` | AGENTS.md 全局口径 + 64 条 `find.byTooltip` 断言；`MiuixTooltip` 属另一套独立 API |
| `table_calendar`（月历网格） | miuix 无月历组件；农历/节气/休班语义是任务日期底座（AGENTS.md 明确不算生活记录域） |
| `MiuixBadge` | 尺寸档 16/11sp 与 docs/04 像素规格（底栏角标 14/9sp）冲突，保留自绘胶囊 |
| `MiuixIcon` 系（`MiuixIcons.os4`） | 图标体系锁 Lucide（跨端与桌面 lucide-react 一致）；OS4 图标为填充/多字重风格，全量替换属视觉改版 |
| `MiuixScaffold` / `MiuixTopAppBar` / `MiuixNavigationRail` / `MiuixTabRow` / 偏好项 / `MiuixDatePicker` / `MiuixNumberPicker` / `MiuixSlider` / `MiuixSearchBar` / `MiuixBreadcrumbBar` / `MiuixCascading*` | 无对应场景或会改变既定交互（日期面板带农历网格、时分用步进器、视图切换是图标钮）；**不为了用组件而新造功能** |

#### 5.4.1 追加：输入框全量收口（2026-11-02）

`TextField` / `TextFormField` 的 36 处调用全部迁到 `OrbitTextField`
（`shared/widgets/shadcn/orbit_text_field.dart`，底层 `MiuixTextField`）：

- **两种形态**：默认 `filled`（16 内边距 / 16 圆角 / 灰底 / 浮动标签）；`inline`
  （详情页标题原地编辑、子任务行、评论框、项目名行、周期数值格）为透明底、零
  内边距、hint 当占位，边框/布局交给宿主容器。
- **补齐库缺口**：`maxLength`（库不暴露 `inputFormatters`，按 grapheme 截断，
  不画 Material 计数器）、`validator`（包 `FormField`，错误文案画在框下并把标签/
  描边染成破坏性色）、`onTapOutside`（包 `TapRegion`）。
- **已知取舍**：miuix 输入框不暴露 `textAlign`，重复规则面板的数值格从居中改
  左对齐；占位/标签色统一取 `secondaryText`（主题桥接的 `onSecondaryContainer`
  是正文色，直接吃会偏黑）。
- **测试**：`find.byType(TextFormField)` 全部改 `OrbitTextField`；
  `decoration.hintText` 定位改读原语字段；新增 `orbit_text_field_test.dart`
  锁限长 / 校验 / 内联占位。
- **配套**：云同步页「引擎 / 定时同步」选择行从 `InputDecorator`（模拟 Material
  输入框）改为与 miuix filled 同形的灰底胶囊（16 圆角 + 小号浮动标签 + 尾箭头）。

### 5.5 验证

- `flutter analyze`：**No issues found**；
- `flutter test`：**1112 项全绿**（含 `wait_toast` 停留口径四例、`orbit_sheets`
  破坏性按钮实色断言、`calendar_screen` 时间轴手势、`wait_date_picker` 双按钮居中
  与两条时分滚轮用例——finder 已换 `MiuixNumberPicker`，44px 拖拽一格吸附方向/
  边界钳制与 Cupertino 一致）；
- 回归修复：miuix 队列是**静态跨用例存活**的，用例结束时在途条目会留在队列里、
  下一用例挂载后被重新渲染成卡片遮挡底部点击（曾致 `calendar_screen` 8 例 /
  `manager_pages` 1 例红）。修法：`OrbitToastHost` 挂载时换新队列
  （生产壳只挂载一次，等价单例），`drainToastTimers` 追加
  `WaitToast.debugFlushForTest()` 清残留；
- 新增/改写的测试辅助：`orbit_sheets_test.buttonFillOf` 改为读
  `MiuixButton.colors.color`（shadcn `OverflowDecoratedBox` 已不存在）。
