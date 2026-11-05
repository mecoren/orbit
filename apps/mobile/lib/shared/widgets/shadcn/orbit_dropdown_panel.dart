import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
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

/// 锚定菜单内容节点 key（两个入口共用：Overlay 直挂的 `showOrbitMenuPopup`
/// 与保留路由外壳的 `showOrbitSelectPopup`；测试据此定位弹层卡片）
const Key orbitSelectPopupKey = ValueKey('orbit-select-popup');

/// 菜单条目（锚定面板 / 页头玻璃菜单 / 底部动作菜单共用的数据项）
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

/// 下拉面板内容视图（公开件：只出行，不含卡壳——卡面/动效由
/// `orbit_menu_popup.dart` 的 `OrbitMenuPopupBody` 统一承担）。
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
    // 壳由调用方统一包（OrbitMenuPopupBody / OrbitGlassMenu），此处只出条目列，
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

