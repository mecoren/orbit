/// 下拉偏好行（原语层：设置项「行内当前值 + 就地展开玻璃菜单」，2026-11-05）
///
/// **弹层走全站统一锚定原语 [showOrbitSelectMenu]**：
/// - 承载：[OrbitMenuPopupBody]（与快速添加、页头 ⋮ 菜单同源），Overlay
///   直挂；点开从本行下方揭开，关闭播逆形变、结束后才移除条目；
/// - 卡面/行：`puredThinGlass` + blur 32、24 圆角 `MiuixGlassPanel`，
///   `MiuixGlassPopupItem` 行（44 最小行高、24 图标位、选中打勾）；
/// - 返回键：本行根部 `PopScope` 在展开时先关菜单，不退出当前页面。
///
/// **行本身仍是 [MiuixBasicComponent]**：标题（+可选摘要）在左、可选行首动作
/// （如总开关）、尾随当前值 + 上下双箭头，点行就地展开弹层——当前档必须在
/// 行内常驻可见，故用本行矩形作锚点而不是 `MiuixGlassAnchor`（形变会隐藏
/// 锚点控件内容）。
///
/// 与 [showOrbitSelectPopup] 的分工：后者是「任意触发控件 + 浮层」的通用
/// 选择器，本行是设置项里的下拉偏好。选中判据取 [SelectItem.value] 原始值
/// 而非文案；当前值不在 [items] 里时由调用方补一项（外观页强调色的「当前色」
/// 同款），否则库内无选中项 → 尾随值与弹层对勾双双落空。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import 'orbit_dropdown_panel.dart' show orbitPanelMaxWidth, orbitPanelMinWidth;
import 'orbit_menu_popup.dart' show OrbitMenuSession;
import 'orbit_select_popup.dart';

export 'orbit_select_popup.dart' show SelectItem;

/// 下拉弹层内容节点 key（测试定位用：`find.byKey(orbitDropdownPopupKey)`）
const Key orbitDropdownPopupKey = ValueKey('orbit-dropdown-popup');

/// 下拉偏好行（见文件头）
class OrbitDropdownPreference<T> extends StatefulWidget {
  const OrbitDropdownPreference({
    super.key,
    required this.title,
    required this.items,
    required this.current,
    required this.onSelect,
    this.summary,
    this.startAction,
    this.insideMargin = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 14,
    ),
    this.enabled = true,
  });

  /// 行标题
  final String title;

  /// 可选摘要（标题下方次要文字）
  final String? summary;

  /// 下拉选项（[SelectItem.value] 是选中判据，[SelectItem.label] 是行内尾随值
  /// 与弹层条目文案；[SelectItem.hint] 落弹层条目副说明）
  final List<SelectItem<T>> items;

  /// 当前值（必须能在 [items] 里找到，否则不显示尾随值）
  final T? current;

  /// 选中回调（弹层点选后触发）
  final ValueChanged<T> onSelect;

  /// 行首动作（如总开关）：并入同一个 `MiuixBasicComponent`，展开时按压灰底
  /// 才会覆盖整行；放在行外另起 `Row` 时灰底只会盖住下拉行那一段。
  /// 行禁用时本控件仍可点（库内禁用只置空行自身的回调），总开关可回开。
  final Widget? startAction;

  /// 行内边距（外观页口径 16×14；行自带水平内边距，外层卡片归零水平内边距，
  /// 按压灰底才能横贯整卡）
  final EdgeInsetsGeometry insideMargin;

  /// 是否启用（false 时整行转禁用色、不可展开）
  final bool enabled;

  @override
  State<OrbitDropdownPreference<T>> createState() =>
      _OrbitDropdownPreferenceState<T>();
}

class _OrbitDropdownPreferenceState<T>
    extends State<OrbitDropdownPreference<T>> {
  /// 本行矩形采样点（点开瞬间的全局描点）
  final GlobalKey _rowKey = GlobalKey();

  /// 共享锚定菜单会话（Overlay 直挂，与快速添加/单选浮层同一内容件）
  OrbitMenuSession? _menuSession;

  bool get _open => _menuSession?.isOpen ?? false;

  @override
  void dispose() {
    _menuSession?.dispose();
    super.dispose();
  }

  bool get _effectiveEnabled => widget.enabled && widget.items.isNotEmpty;

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

  void _toggle() {
    if (_open) {
      _menuSession?.close();
      return;
    }
    final rect = _rowRect;
    if (rect == null) return;
    _menuSession?.dispose();
    final session = showOrbitSelectMenu<T>(
      context,
      anchor: rect,
      items: widget.items,
      current: widget.current,
      onSelect: widget.onSelect,
      minWidth: orbitPanelMinWidth,
      maxWidth: orbitPanelMaxWidth,
      contentKey: orbitDropdownPopupKey,
    );
    _menuSession = session;
    session.closed.whenComplete(() {
      if (!mounted || _menuSession != session) return;
      setState(() => _menuSession = null);
    });
    setState(() {});
  }

  Widget _buildRow() {
    final theme = MiuixTheme.of(context);
    final actionColor = _effectiveEnabled
        ? theme.colors.onSurfaceVariantActions
        : theme.colors.disabledOnSurface;
    final value = _valueLabel;
    return MiuixBasicComponent(
      key: _rowKey,
      title: widget.title,
      summary: widget.summary,
      startAction: widget.startAction,
      insideMargin: widget.insideMargin,
      endActions: [
        if (value != null)
          Flexible(
            flex: 1,
            fit: FlexFit.loose,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: AppDimens.space8),
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
      onClick: _effectiveEnabled ? _toggle : null,
      enabled: _effectiveEnabled,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _menuSession?.dispose();
        } else {
          _menuSession?.close();
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_buildRow()],
      ),
    );
  }
}
