import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_elevation.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';

/// 面板宽度上限（px）
///
/// 锚定面板不是弹层主体，**不该铺满**：条目文案最长也就「排序方式 / 隐藏已完成」
/// 这一档，再宽只会把右侧留出一片空白（2026-09-23 反馈「太宽了」后由 300 收到本值，
/// 430 宽的机型上也一样收——定宽上限比按比例算更能保证观感一致）。
const double orbitPanelMaxWidth = 240;

/// 窄屏下的面板宽度占屏比（配合 [orbitPanelMaxWidth] 取小）
///
/// 参考竞品面板约占屏宽六成；再窄「已启用 N 项」这类行尾文案会被挤到省略号。
const double orbitPanelWidthFactor = 0.62;

/// 面板条目（[showOrbitDropdownPanel] 的数据项）
class OrbitPanelItem {
  const OrbitPanelItem({
    required this.icon,
    required this.label,
    this.onTap,
    this.children = const <OrbitPanelItem>[],
    this.checked = false,
    this.color,
    this.trailingLabel,
  });

  /// 行首图标（子项不画图标——图标列改承载选中打勾）
  final IconData icon;
  final String label;

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
/// 浮层卡片壳（下拉面板与快加快捷卡片共用同一视觉：`popup` 底 + 1px `outline` +
/// 弹出层阴影 `e4` + large 圆角；内容区限高 0.7 屏，滚动与尾栏由内容自理）。
class OrbitFloatCard extends StatelessWidget {
  const OrbitFloatCard({super.key, required this.child, this.width});

  /// 卡片内容（面板则传可滚条目列，多选卡传列表 + 尾栏）
  final Widget child;

  /// 卡片宽度；null = 与下拉面板同宽（[orbitPanelMaxWidth] 上限）；
  /// 显式宽度同样受屏宽 - 32 钳制，保证不贴边
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final screen = MediaQuery.of(context).size;
    // 宽度走统入口（含小屏钳制），与锚点定位用同一数值
    final w = orbitFloatCardWidth(context, width);
    return Padding(
      // 外留白既作面板与屏幕边的间距，也给投影留出空间（否则被裁剪）
      padding: const EdgeInsets.all(AppDimens.space8),
      child: Container(
        width: w,
        decoration: BoxDecoration(
          borderRadius: AppShapes.large,
          boxShadow: AppElevation.ofContext(context, level: 4),
        ),
        // 表面与「按下水波纹」都由这层 Material 承担（圆角裁切）
        child: Material(
          color: colors.popup,
          borderRadius: AppShapes.large,
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: AppShapes.large,
              border: Border.all(color: colors.outline),
            ),
            // 条目多时卡片可滚：整屏高度上限内不出屏
            constraints: BoxConstraints(maxHeight: screen.height * 0.7),
            child: child,
          ),
        ),
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
}) {
  final screen = MediaQuery.of(context).size;
  final Alignment alignment;
  final EdgeInsets padding;
  final Alignment scaleAlignment;
  if (anchor != null && above) {
    // 右沿对齐锚右沿，但钳在屏内：左置按钮的卡片不能滑出左屏
    // （240 宽卡片锚在左首图标时右对齐会出屏，曾致“窄条”假象）
    final w = orbitFloatCardWidth(context, width);
    final right = (screen.width - anchor.right)
        .clamp(0.0, math.max(0.0, screen.width - w - AppDimens.space8))
        .toDouble();
    alignment = Alignment.bottomRight;
    padding = EdgeInsets.only(
      bottom: math.max(0, screen.height - anchor.top) + AppDimens.space8,
      right: right,
    );
    scaleAlignment = Alignment.bottomRight;
  } else {
    alignment = Alignment.topRight;
    padding = EdgeInsets.only(
      top: topInset ??
          MediaQuery.of(context).padding.top + AppDimens.titleBarHeight,
      right: 0,
    );
    scaleAlignment = Alignment.topRight;
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    // 有意不铺遮罩色：面板打开时下层照旧可读（竞品同款）；点别处即关闭
    barrierColor: Colors.transparent,
    barrierLabel: '关闭菜单',
    transitionDuration: AppMotion.fast,
    pageBuilder: (dialogContext, _, _) => Align(
      alignment: alignment,
      child: Padding(
        padding: padding,
        child: OrbitFloatCard(width: width, child: child),
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
          alignment: scaleAlignment,
          child: child,
        ),
      );
    },
  );
}
/// 顶部下拉面板（页头 ⋮ 的载体；快加面板「更多」与快捷档复用其「锚点上方」
/// 形态；设计系统 v3 原语层，2026-09-23）
///
/// **形态**：锚在触发钮附近的浮层卡片（见 [OrbitFloatCard]），条目成组、组间
/// 1px `divider`；点面板外任意处关闭（不铺遮罩色——下层保持可见）。
///
/// **就地展开子项**：带 [OrbitPanelItem.children] 的条目点一下在**面板内**展开
/// （子项缩进到文案列、选中项打勾），展开期间其余顶层条目置灰、点击只收起子菜单
/// **不执行该条目**——「此刻只在挑子项」这一状态靠颜色一眼可辨，也不会误触到
/// 别的动作（点空白/再点该项本身同样是收起）。
///
/// **与底部抽屉的分工**（2026-09-23 修订，见 AGENTS.md）：从一组值里挑一个的
/// 纯选择类交互仍走底部抽屉（`showSelectBottomSheet` 等）；**页头的「当前列表
/// 操作」类入口**收敛到本面板——它锚在触发钮附近、不遮住列表，且「就地展开」
/// 的层级感是抽屉给不了的（竞品同款版式）。快加面板的档位快捷项（优先级 /
/// 项目单选、标签多选卡）同样锚在触发钮上方弹出，与页头面板同源同形。
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
}) {
  return showOrbitFloatCard<void>(
    context,
    anchor: anchor,
    above: above,
    topInset: topInset,
    child: _OrbitDropdownPanel(
      groups: groups,
      title: title,
      actionLabel: actionLabel,
      onAction: onAction,
    ),
  );
}

class _OrbitDropdownPanel extends StatefulWidget {
  const _OrbitDropdownPanel({
    required this.groups,
    this.title,
    this.actionLabel,
    this.onAction,
  });

  final List<List<OrbitPanelItem>> groups;

  final String? title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<_OrbitDropdownPanel> createState() => _OrbitDropdownPanelState();
}

class _OrbitDropdownPanelState extends State<_OrbitDropdownPanel> {
  /// 当前就地展开的顶层条目（组下标, 条目下标）；null = 无展开
  (int, int)? _expanded;

  bool _isExpanded(int groupIndex, int itemIndex) =>
      _expanded == (groupIndex, itemIndex);

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
    Navigator.of(context).pop();
    item.onTap?.call();
  }

  /// 子项：选中即执行并关面板（与底部抽屉「点选即回调并关闭」同语义）
  void _tapChild(OrbitPanelItem child) {
    Navigator.of(context).pop();
    child.onTap?.call();
  }

  /// 标题行动作：先收面板再执行（导航类回调在面板关闭后落到下层页面）
  void _tapAction() {
    Navigator.of(context).pop();
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

    // 壳由入口统一包（[showOrbitFloatCard]），此处只出条目列，避免双层边框
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
                if (widget.title != null || widget.actionLabel != null)
                  _headerRow(),
                for (var g = 0; g < widget.groups.length; g++) ...[
                  if (g > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppDimens.space4),
                      child: Divider(
                        height: 1,
                        thickness: 1,
                        indent: AppDimens.space12,
                        endIndent: AppDimens.space12,
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
            ),
    );
  }

  /// 顶层条目行：有子项展开时**其余**条目置灰（图标与文案同时降级）
  Widget _topRow(int groupIndex, int itemIndex, OrbitPanelItem item) {
    final colors = AppColors.ofContext(context);
    final isExpanded = _isExpanded(groupIndex, itemIndex);
    final dimmed = _expanded != null && !isExpanded;
    final tint = dimmed
        ? colors.deactivatedText
        : (item.color ?? colors.bodyText);

    return InkWell(
      onTap: () => _tapTop(groupIndex, itemIndex, item),
      child: SizedBox(
        height: AppDimens.touchTarget,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
          child: Row(
            children: [
              Icon(
                item.icon,
                size: AppDimens.iconSizeMd,
                color: item.color ?? (dimmed ? colors.deactivatedText : colors.iconText),
              ),
              const SizedBox(width: AppDimens.space12),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: tint),
                ),
              ),
              // 开关类条目：行尾对勾表达「已开」
              if (item.checked && item.children.isEmpty) ...[
                const SizedBox(width: AppDimens.space8),
                Icon(
                  OrbitIcons.check,
                  size: AppDimens.iconSizeSm,
                  color: dimmed ? colors.deactivatedText : colors.accent,
                ),
              ],
              if (item.trailingLabel != null) ...[
                const SizedBox(width: AppDimens.space8),
                Text(
                  item.trailingLabel!,
                  style: TextStyle(fontSize: 13, color: colors.secondaryText),
                ),
              ],
              if (item.children.isNotEmpty) ...[
                const SizedBox(width: AppDimens.space4),
                Icon(
                  isExpanded ? OrbitIcons.expandMore : OrbitIcons.chevronRight,
                  size: AppDimens.iconSizeSm,
                  color: dimmed ? colors.deactivatedText : colors.iconText,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 子项行：缩进到文案列（12 + 图标列 22 + 12），选中项在图标列打勾
  Widget _childRow(OrbitPanelItem child) {
    final colors = AppColors.ofContext(context);
    return InkWell(
      onTap: () => _tapChild(child),
      child: SizedBox(
        height: AppDimens.touchTarget,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
          child: Row(
            children: [
              SizedBox(
                width: AppDimens.iconSizeMd,
                child: child.checked
                    ? Icon(
                        OrbitIcons.check,
                        size: AppDimens.iconSizeSm,
                        color: colors.accent,
                      )
                    : null,
              ),
              const SizedBox(width: AppDimens.space12),
              Expanded(
                child: Text(
                  child.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    color: child.color ?? colors.bodyText,
                    fontWeight:
                        child.checked ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
