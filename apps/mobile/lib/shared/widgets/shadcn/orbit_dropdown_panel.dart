import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shapes.dart';
import 'package:flutter_miuix/miuix.dart';

/// 面板宽度上限（px）
///
/// 锚定面板不是弹层主体，**不该铺满**：条目文案最长也就「排序方式 / 隐藏已完成」
/// 这一档，再宽只会把右侧留出一片空白（2026-09-23 反馈「太宽了」后由 300 收到本值，
/// 430 宽的机型上也一样收——定宽上限比按比例算更能保证观感一致）。
const double orbitPanelMaxWidth = 240;

/// 弹出菜单的最小宽度（库内 `MiuixGlassPopupSizing.minWidth` 口径）
///
/// 条目只有两三个字（「跟随系统」「浅色」）时不该缩成一小片，也不该被库内
/// 默认的 200 撑宽——180 是这套菜单在本项目里的统一下限。
const double orbitPanelMinWidth = 180;

/// 窄屏下的面板宽度占屏比（配合 [orbitPanelMaxWidth] 取小）
///
/// 参考竞品面板约占屏宽六成；再窄「已启用 N 项」这类行尾文案会被挤到省略号。
const double orbitPanelWidthFactor = 0.62;

/// 面板条目（[showOrbitDropdownPanel] 的数据项）
class OrbitPanelItem {
  const OrbitPanelItem({
    this.icon,
    required this.label,
    this.leading,
    this.iconColor,
    this.onTap,
    this.children = const <OrbitPanelItem>[],
    this.checked = false,
    this.color,
    this.trailingLabel,
  });

  /// 行首图标（子项不画图标——图标列改承载选中打勾）
  ///
  /// 可空：纯文字条目（选择浮层里主题/字号这类没有语义图标的档位）。
  final IconData? icon;
  final String label;

  /// 自定义行首（12px 色点等），优先于 [icon]
  ///
  /// 项目/优先级选择用「颜色即语义」的色点，[icon] 的 IconData 表达不了；
  /// 尺寸由行内 22×22 图标列承载，内容自行居中。
  final Widget? leading;

  /// 行首图标着色（语义色图标，如快捷视图八键；null 跟随文案层级）。
  /// 与 [color] 分开：只染图标、不动文案（快捷视图选中档文案仍走主题色）
  final Color? iconColor;

  /// 叶子条目回调（带子项的条目由面板管理展开，不用它）
  final VoidCallback? onTap;

  /// 非空 = 该条目在面板内**就地展开**子项
  final List<OrbitPanelItem> children;

  /// 勾选态（开关类条目，以及展开子项里的当前档位）
  final bool checked;

  /// 文案与图标着色（破坏性动作传红；null 走默认层级）
  final Color? color;

  /// 行尾补充文案（如「已启用 2 项」）
  final String? trailingLabel;
}

/// 浮层卡片宽度：显式宽度同样受屏宽 - 32 钳制，保证不贴边
double orbitFloatCardWidth(BuildContext context, [double? width]) {
  final screen = MediaQuery.of(context).size;
  return math.min(
    width ??
        math.min(
          orbitPanelMaxWidth,
          math.min(screen.width * orbitPanelWidthFactor,
              screen.width - AppDimens.space32),
        ),
    screen.width - AppDimens.space32,
  );
}
/// 浮层卡片壳（下拉面板与快加快捷卡片共用同一视觉：OS4 玻璃面 + 浮层阴影
/// + large 圆角；内容区限高 0.7 屏，滚动与尾栏由内容自理）。
///
/// **OS4 玻璃（2026-11-03 补齐采样器）**：卡片一直是 `miuixGlassSurface` 的
/// 菜单档表面，但此前没接 [backdrop]，库内拿不到快照就退回**实色填充**——
/// 于是页头 ⋮ 是玻璃菜单（`OrbitGlassMenu`）、而所有锚定卡片是白色实色卡片，
/// 两套观感并存。现在采样器由调用方透传（卡片挂在路由/Overlay 上，取不到
/// 壳层 `OrbitGlassScope`），与形变菜单同一档材质。
class OrbitFloatCard extends StatelessWidget {
  const OrbitFloatCard({
    super.key,
    required this.child,
    this.width,
    this.backdrop,
  });

  /// 卡片内容（面板则传可滚条目列，多选卡传列表 + 尾栏）
  final Widget child;

  /// 卡片宽度；null = 与下拉面板同宽（[orbitPanelMaxWidth] 上限）；
  /// 显式宽度同样受屏宽 - 32 钳制，保证不贴边
  final double? width;

  /// OS4 玻璃背景采样器（调用方传壳层的 `MiuixLayerBackdrop`）
  ///
  /// 卡片经 `showGeneralDialog` / `OverlayEntry` 挂在 Navigator / Overlay 上，
  /// 位于 `OrbitGlassScope` 之外，**不能在卡片内部自取**；null 时库内退实色
  /// （无壳或测试裸页）。
  final MiuixLayerBackdrop? backdrop;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final screen = MediaQuery.of(context).size;
    // 宽度走统入口（含小屏钳制），与锚点定位用同一数值
    final w = orbitFloatCardWidth(context, width);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // OS4 玻璃浮层：材质档与 `OrbitGlassMenu` 同源（`puredThinGlass` +
    // blurRadius 32，`shading: false` 不做仿生折射）——库默认 `popupViewGlass`
    // 的 60 档在进场动画期（origin/size 逐帧变、纹理缓存逐帧失效）会每帧
    // 重算 sigma≈27 的离屏模糊，真机掉帧明显。
    final surface = miuixGlassSurface(
      backdrop: backdrop,
      material: MiuixGlassMaterials.puredThinGlass(isDark).copyWith(
        blurRadius: 32,
      ),
      shadow: MiuixGlassShadows.floating,
      alpha: 1,
    );
    return Padding(
      // 外留白既作面板与屏幕边的间距，也给投影留出空间（否则被裁剪）
      padding: const EdgeInsets.all(AppDimens.space8),
      child: SizedBox(
        width: w,
        // 条目多时卡片可滚：整屏高度上限内不出屏
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: screen.height * 0.7),
          child: surface(
            context,
            RoundedRectangleBorder(borderRadius: AppShapes.large),
            // 表面与「按下水波纹」都由这层 Material 承担（圆角裁切）；
            // 描边不再手绘 1px `outline`——玻璃 shader 自带高光描边，
            // 再叠一圈灰线会让玻璃面看起来像实色卡片
            Material(
              color: colors.popup.withValues(alpha: 0.0),
              borderRadius: AppShapes.large,
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 锚点浮层卡片定位（三件套：对齐 + 内边距 + 缩放锚点）
typedef OrbitFloatCardLayout = ({
  Alignment align,
  EdgeInsets padding,
  Alignment scale,
});

/// 锚点上方形态的定位计算（[showOrbitFloatCard] 与 Overlay 直挂版共用同一数值，
/// 卡片与锚点不错位）
OrbitFloatCardLayout orbitFloatCardLayout(
  BuildContext context, {
  Rect? anchor,
  bool above = true,
  double? topInset,
  double? width,
}) {
  final screen = MediaQuery.of(context).size;
  if (anchor != null && above) {
    // 右沿对齐锚右沿，但钳在屏内：左置按钮的卡片不能滑出左屏
    // （240 宽卡片锚在左首图标时右对齐会出屏，曾致“窄条”假象）
    final w = orbitFloatCardWidth(context, width);
    final right = (screen.width - anchor.right)
        .clamp(0.0, math.max(0.0, screen.width - w - AppDimens.space8))
        .toDouble();
    return (
      align: Alignment.bottomRight,
      padding: EdgeInsets.only(
        bottom: math.max(0, screen.height - anchor.top) + AppDimens.space8,
        right: right,
      ),
      scale: Alignment.bottomRight,
    );
  }
  return (
    align: Alignment.topRight,
    padding: EdgeInsets.only(
      top: topInset ??
          MediaQuery.of(context).padding.top + AppDimens.titleBarHeight,
      right: 0,
    ),
    scale: Alignment.topRight,
  );
}

/// Overlay 直挂的锚点卡片进场动效件（与路由版 [showOrbitFloatCard] 同源：
/// 淡入 + 自锚点同侧轻微放大；Overlay 没有转场器，自带一次控制器）。
class OrbitOverlayCard extends StatefulWidget {
  const OrbitOverlayCard({
    super.key,
    required this.child,
    required this.scaleAlignment,
  });

  /// 卡片内容（通常是 [OrbitFloatCard]）
  final Widget child;

  /// 缩放锚点（[orbitFloatCardLayout] 的 scale，与路由版同值）
  final Alignment scaleAlignment;

  @override
  State<OrbitOverlayCard> createState() => _OrbitOverlayCardState();
}

class _OrbitOverlayCardState extends State<OrbitOverlayCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.fast,
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: _controller,
      curve: AppMotion.decelerate,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
        alignment: widget.scaleAlignment,
        child: widget.child,
      ),
    );
  }
}

/// 锚点浮层卡片通用入口（快加快捷卡片用；出场动效与下拉面板同源）
/// [anchor] 为空回落右上（与面板默认同）。
Future<T?> showOrbitFloatCard<T>(
  BuildContext context, {
  required Widget child,
  Rect? anchor,
  bool above = true,
  double? topInset,
  double? width,
  MiuixLayerBackdrop? backdrop,
}) {
  final layout = orbitFloatCardLayout(
    context,
    anchor: anchor,
    above: above,
    topInset: topInset,
    width: width,
  );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    // 有意不铺遮罩色：面板打开时下层照旧可读（竞品同款）；点别处即关闭
    barrierColor: Colors.transparent,
    barrierLabel: '关闭菜单',
    transitionDuration: AppMotion.fast,
    pageBuilder: (dialogContext, _, _) => Align(
      alignment: layout.align,
      child: Padding(
        padding: layout.padding,
        child: OrbitFloatCard(width: width, backdrop: backdrop, child: child),
      ),
    ),
    // 出场：淡入 + 自锚点同侧轻微放大（空间上「从按钮里长出来」）
    transitionBuilder: (context, animation, _, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: AppMotion.decelerate);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          alignment: layout.scale,
          child: child,
        ),
      );
    },
  );
}
/// 顶部下拉面板（页头 ⋮ 的载体；设计系统 v3 原语层，2026-09-23）
/// 快加面板的档位快捷项（优先级 / 项目单选、标签多选卡、「更多」）形态同源，
/// 但走 Overlay 直挂（[OrbitOverlayCard]，不经过路由、不抢输入框焦点——
/// 路由版弹出即失焦，输入法下沉；见快加面板键盘保持）。
///
/// **形态**：锚在触发钮附近的浮层卡片（见 [OrbitFloatCard]），条目成组、组间
/// 1px `divider`；点面板外任意处关闭（不铺遮罩色——下层保持可见）。
///
/// **就地展开子项**：带 [OrbitPanelItem.children] 的条目点一下在**面板内**展开
/// （子项缩进到文案列、选中项打勾），展开期间其余顶层条目置灰、点击只收起子菜单
/// **不执行该条目**——「此刻只在挑子项」这一状态靠颜色一眼可辨，也不会误触到
/// 别的动作（点空白/再点该项本身同样是收起）。
///
/// **与选择浮层的分工**（2026-11-03 修订，见 AGENTS.md）：从一组值里挑一个的
/// 纯选择交互（`showOrbitSelectPopup`）**直接复用本面板**——同一
/// `OrbitDropdownPanelView` 行渲染、同一右上角坐标，只是由 `showSelectBottomSheet`
/// 兼容名转发；**页头的「当前列表操作」类入口**（含开关、就地展开子项）仍收敛
/// 到本面板——「就地展开」的层级感是单项选择给不了的（竞品同款版式）。快加
/// 面板的档位快捷项（优先级 / 项目单选、标签多选卡）同样锚在触发钮上方弹出，
/// 与页头面板同源同形。
Future<void> showOrbitDropdownPanel(
  BuildContext context, {
  required List<List<OrbitPanelItem>> groups,

  /// 面板顶端避让（通常 = 状态栏 + 页头高，使面板贴在页头下沿）
  double? topInset,

  /// 锚矩形（全局坐标）：与 [above] 联用，面板长在锚点上方、右沿对齐锚右沿；
  /// 为空时走默认的右上形态（此时 [above] 被忽略）。
  Rect? anchor,

  /// 锚点上方形态（快加面板「更多」与快捷档用）
  bool above = false,

  /// 标题行文案（如「更多」）；与 [actionLabel] 至少给一个才渲染标题行
  String? title,

  /// 标题行尾随动作文案（如「编辑」，主题强调色）；点击先收面板再回调
  String? actionLabel,
  VoidCallback? onAction,

  /// OS4 玻璃背景采样器（壳层 `OrbitGlassScope` 的实例；null = 退实色）
  MiuixLayerBackdrop? backdrop,
}) {
  return showOrbitFloatCard<void>(
    context,
    anchor: anchor,
    above: above,
    topInset: topInset,
    backdrop: backdrop,
    child: OrbitDropdownPanelView(
      groups: groups,
      title: title,
      actionLabel: actionLabel,
      onAction: onAction,
    ),
  );
}

/// 下拉面板内容视图（公开件：路由版包在 [OrbitFloatCard] 里，Overlay 直挂版
/// 由调用方包卡并传 [onClose] 接管关闭动作）。
class OrbitDropdownPanelView extends StatefulWidget {
  const OrbitDropdownPanelView({
    super.key,
    required this.groups,
    this.title,
    this.actionLabel,
    this.onAction,
    this.onClose,
    this.scrollable = true,
    this.closeOnTap = true,
  });

  final List<List<OrbitPanelItem>> groups;

  /// 点叶子条目后是否关面板
  ///
  /// 单选/动作菜单为 true（默认）；多选卡片（如快速添加的标签连选）传
  /// false——点行只翻转勾选、面板常驻，由点卡外收起。
  final bool closeOnTap;

  final String? title;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 关闭动作覆写（Overlay 直挂时传调用方的 remove；null = 路由 pop，
  /// 既有调用方行为不变）
  final VoidCallback? onClose;

  /// 是否自带滚动容器
  ///
  /// OS4 形变弹层（`MiuixGlassTransformPopup`）外层已经包了纵向滚动，
  /// 内部再套一层滚动会拿到无界高度直接报错，那里传 false。
  final bool scrollable;

  @override
  State<OrbitDropdownPanelView> createState() => OrbitDropdownPanelViewState();
}

class OrbitDropdownPanelViewState extends State<OrbitDropdownPanelView> {
  /// 当前就地展开的顶层条目（组下标, 条目下标）；null = 无展开
  (int, int)? _expanded;

  bool _isExpanded(int groupIndex, int itemIndex) =>
      _expanded == (groupIndex, itemIndex);

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _tapTop(int groupIndex, int itemIndex, OrbitPanelItem item) {
    final expanded = _expanded;
    if (expanded != null && expanded != (groupIndex, itemIndex)) {
      // 子菜单展开中：其余条目是置灰的「此刻不可选」，点它们只退出子菜单
      setState(() => _expanded = null);
      return;
    }
    if (item.children.isNotEmpty) {
      setState(() =>
          _expanded = expanded == null ? (groupIndex, itemIndex) : null);
      return;
    }
    if (widget.closeOnTap) _close();
    item.onTap?.call();
  }

  /// 子项：选中即执行并关面板（与底部抽屉「点选即回调并关闭」同语义）
  void _tapChild(OrbitPanelItem child) {
    _close();
    child.onTap?.call();
  }

  /// 标题行动作：先收面板再执行（导航类回调在面板关闭后落到下层页面）
  void _tapAction() {
    _close();
    widget.onAction?.call();
  }

  /// 标题行：左侧标题 + 右侧强调色动作（竞品「更多 / 编辑」同款版式）
  Widget _headerRow() {
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space12,
        AppDimens.space8,
        AppDimens.space8,
        AppDimens.space4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.titleText,
              ),
            ),
          ),
          if (widget.actionLabel != null)
            InkWell(
              borderRadius: AppShapes.small,
              onTap: _tapAction,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.space8,
                  vertical: AppDimens.space4,
                ),
                child: Text(
                  widget.actionLabel!,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: colors.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.title != null || widget.actionLabel != null) _headerRow(),
        for (var g = 0; g < widget.groups.length; g++) ...[
          if (g > 0)
            // 组间分隔对齐玻璃菜单口径（0.5 厚、左右各 20 缩进、上下 4）
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Divider(
                height: 1,
                thickness: 0.5,
                indent: 20,
                endIndent: 20,
                color: colors.divider,
              ),
            ),
          for (var i = 0; i < widget.groups[g].length; i++) ...[
            _topRow(g, i, widget.groups[g][i]),
            if (_isExpanded(g, i))
              for (final child in widget.groups[g][i].children)
                _childRow(child),
          ],
        ],
      ],
    );
    // 壳由入口统一包（[showOrbitFloatCard] / OS4 形变弹层），此处只出条目列，
    // 避免双层边框；形变弹层外层已带纵向滚动，[scrollable] 为 false 时不再套
    // 上下 8 呼吸位对齐玻璃菜单的 contentPadding
    const padding = EdgeInsets.symmetric(vertical: 8);
    return widget.scrollable
        ? SingleChildScrollView(padding: padding, child: column)
        : Padding(padding: padding, child: column);
  }

  /// 顶层条目行：有子项展开时**其余**条目置灰（图标与文案同时降级）
  ///
  /// 行口径与「今天」页头 ⋮ 菜单同款（[MiuixGlassPopupItem]）：44 最小行高、
  /// 24 图标位、选中转强调色并右端打勾、子项箭头随展开转向。
  Widget _topRow(int groupIndex, int itemIndex, OrbitPanelItem item) {
    final colors = AppColors.ofContext(context);
    final isExpanded = _isExpanded(groupIndex, itemIndex);
    final dimmed = _expanded != null && !isExpanded;
    // 行首：自定义 leading（色点）> 语义图标 > 无（纯文字条目）
    final Widget? leading = item.leading != null
        ? Center(child: item.leading!)
        : (item.icon != null
              ? Icon(
                  item.icon,
                  size: MiuixGlassPopupDefaults.itemIconSize,
                  color: dimmed
                      ? colors.deactivatedText
                      : (item.iconColor ?? item.color ?? colors.iconText),
                )
              : null);
    return MiuixGlassPopupItem(
      text: item.label,
      icon: leading,
      summary: item.trailingLabel,
      // 开关类条目：行尾对勾表达「已开」（菜单同款：选中态染强调色）
      selected: item.checked && item.children.isEmpty,
      showArrow: item.children.isNotEmpty,
      arrowRotation: isExpanded ? -90 : 0,
      contentColor: dimmed ? colors.deactivatedText : item.color,
      onPressed: () => _tapTop(groupIndex, itemIndex, item),
    );
  }

  /// 子项行：与一级同款玻璃条目（选中打勾在行尾，与菜单二级一致）
  Widget _childRow(OrbitPanelItem child) => MiuixGlassPopupItem(
    text: child.label,
    selected: child.checked,
    contentColor: child.color,
    onPressed: () => _tapChild(child),
  );
}

