/// 下拉偏好行（原语层：flutter_miuix `DropdownPreference` 口径，2026-11-03）
///
/// **与 [OrbitArrowTile] 的区别只在交互语义**：箭头行是「跳到下一页」，
/// 本行是「就地展开下拉」——尾随位换成库内 [MiuixDropdownArrowEndAction]
/// 的上下双箭头（10×16），点击后贴着本行弹出 [showOrbitSelectPopup]
/// 单选浮层，当前档在浮层里打勾并转强调色。
///
/// 几何全部走 `MiuixBasicComponent`：标题 `headline1`（w500）+ 摘要
/// `body2`，最小行高 56；水平内边距交给外层卡片（`SectionCard` 的 16），
/// 故 `insideMargin` 只留竖直 8（同 `nav_modules_page` 的模块行口径，
/// 避免「卡内 16 + 行内 16」叠成 32 挤断摘要）。
///
/// 展开期间 [MiuixBasicComponent.holdDownState] 常亮，与库里下拉偏好的
/// 按压态一致（参考图第一行展开时带灰底）。灰底被 [ClipRRect] 裁成圆角
/// 高亮条：行宽横贯卡片内容区（不像 miuix demo 那样贴分组卡边），直角
/// 灰块会顶出「选中一整块」的生硬观感，圆角 10（small 档）才是 HyperOS
/// 卡内行的按压形态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import 'orbit_select_popup.dart';

class OrbitDropdownTile<T> extends StatefulWidget {
  const OrbitDropdownTile({
    super.key,
    required this.title,
    required this.items,
    required this.current,
    required this.onSelect,
    this.summary,
    this.enabled = true,
  });

  /// 行标题
  final String title;

  /// 可选摘要（标题下方次要文字，如「亮暗随系统或手动指定」）
  final String? summary;

  /// 下拉选项（[SelectItem.value] 是选中判据，[SelectItem.label] 是尾随值文案）
  final List<SelectItem<T>> items;

  /// 当前值（与 [SelectItem.value] 同域比较，不用文案匹配）
  final T? current;

  /// 选中回调（浮层点选后触发）
  final ValueChanged<T> onSelect;

  /// 是否启用（false 时整行转禁用色、不可展开）
  final bool enabled;

  @override
  State<OrbitDropdownTile<T>> createState() => _OrbitDropdownTileState<T>();
}

class _OrbitDropdownTileState<T> extends State<OrbitDropdownTile<T>> {
  /// 行矩形锚点：浮层贴着本行下沿、右沿对齐弹出
  final GlobalKey _rowKey = GlobalKey();

  /// 浮层展开中（驱动按压底）
  bool _open = false;

  Rect? get _rowRect {
    final box = _rowKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 尾随当前值文案；当前值不在选项里（脏数据）时留空
  String? get _valueLabel {
    for (final item in widget.items) {
      if (item.value == widget.current) return item.label;
    }
    return null;
  }

  Future<void> _expand() async {
    final rect = _rowRect;
    setState(() => _open = true);
    try {
      await showOrbitSelectPopup<T>(
        context,
        title: widget.title,
        items: widget.items,
        current: widget.current,
        anchor: rect,
        onSelect: widget.onSelect,
      );
    } finally {
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final effectiveEnabled = widget.enabled && widget.items.isNotEmpty;
    final actionColor = effectiveEnabled
        ? theme.colors.onSurfaceVariantActions
        : theme.colors.disabledOnSurface;
    final value = _valueLabel;
    return ClipRRect(
      borderRadius: AppShapes.small,
      child: MiuixBasicComponent(
        key: _rowKey,
        title: widget.title,
        summary: widget.summary,
        insideMargin: const EdgeInsets.symmetric(vertical: AppDimens.space8),
        endActions: [
          if (value != null)
            Flexible(
              flex: 1,
              fit: FlexFit.loose,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  end: AppDimens.space8,
                ),
                child: MiuixText(
                  value,
                  fontSize: theme.textStyles.body2.fontSize,
                  color: actionColor,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          MiuixDropdownArrowEndAction(actionColor: actionColor),
        ],
        role: MiuixBasicComponentRole.dropdownList,
        holdDownState: _open,
        onClick: effectiveEnabled ? _expand : null,
        enabled: effectiveEnabled,
      ),
    );
  }
}
