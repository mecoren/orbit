/// 下拉偏好行（原语层：设置项「行内当前值 + 就地展开玻璃菜单」，2026-11-05）
///
/// **弹层与任务列表页头「⋮」菜单（[OrbitGlassMenu]）同一套视觉语言**：
/// - 承载：库内 [MiuixGlassDropdownPopup]，`OverlayPortal` 挂根 Overlay，
///   dropdown motion（圆角 4 → 24、从锚点右上角揭开到整块），点外部/返回键收起；
/// - 卡面：玻璃档 `puredThinGlass` + `blurRadius 32`（与 ⋮ 菜单同档；库默认
///   `popupViewGlass` 的 60 档在动画期逐帧重算离屏模糊，真机掉帧）；无壳层
///   采样器（push 出来的设置子页）时库内退实色填充，观感同「今天」菜单；
/// - 行：[MiuixGlassPopupItem]——最小行高 44、24 图标位、选中转强调色且右端
///   打勾、副说明走 `summary`，与菜单条目逐像素同构。
///
/// **行本身仍是 [MiuixBasicComponent]**：标题（+可选摘要）在左、可选行首动作
/// （如总开关）、尾随当前值 + 上下双箭头，点行就地展开弹层——当前档必须在
/// 行内常驻可见，故锚点走「本行下沿零高度矩形」而不是 `MiuixGlassAnchor`
/// （库内 dropdown motion 会隐藏锚点控件内容）。
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
import 'orbit_glass_surface.dart';
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

  /// 弹层展开中（驱动按压底 + 库内进出场）
  bool _open = false;

  /// 弹层锚点（**零高度**矩形 = 本行下沿；库内落位是「y = 锚点 top + gap、
  /// 右沿对齐锚点右沿」，故 8px 呼吸位并进锚点矩形）。首帧为 null → 弹层
  /// 不挂载（库内断言要求 show/bounds 同时就绪）；收起后**不清**——退出动画
  /// 仍要按它定位。
  Rect? _anchorBounds;

  /// 弹层材质（按亮暗各缓存一份：库内纹理缓存以值相等为命中判据）
  static final _materialLight = MiuixGlassMaterials.puredThinGlassLight
      .copyWith(blurRadius: 32);
  static final _materialDark = MiuixGlassMaterials.puredThinGlassDark.copyWith(
    blurRadius: 32,
  );

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
      setState(() => _open = false);
      return;
    }
    final rect = _rowRect;
    if (rect == null) return;
    setState(() {
      _anchorBounds = Rect.fromLTWH(
        rect.left,
        rect.bottom + AppDimens.space8,
        rect.width,
        0,
      );
      _open = true;
    });
  }

  /// 点选：先收弹层再回调（回调里可能重建整棵树，如主题切换）
  void _pick(T value) {
    setState(() => _open = false);
    widget.onSelect(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final actionColor = _effectiveEnabled
        ? theme.colors.onSurfaceVariantActions
        : theme.colors.disabledOnSurface;
    final value = _valueLabel;
    final bounds = _anchorBounds;
    // 玻璃采样器在**调用方** context 上取：弹层挂在根 Overlay（本页
    // OrbitGlassPage 捕获树的兄弟层），不会把弹层自己拍进背景
    final backdrop = OrbitGlassScope.maybeOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MiuixBasicComponent(
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
          onClick: _effectiveEnabled ? _toggle : null,
          enabled: _effectiveEnabled,
        ),
        if (bounds != null)
          MiuixGlassDropdownPopup(
            show: _open,
            anchorBounds: bounds,
            backdrop: backdrop,
            // 宽度与全站弹出菜单同档（180–240）：库内默认 200–288 在窄屏
            // 上会盖掉大半行文字
            sizing: const MiuixGlassPopupSizing(
              minWidth: orbitPanelMinWidth,
              maxWidth: orbitPanelMaxWidth,
            ),
            visuals: MiuixGlassPopupVisuals(
              material: isDark ? _materialDark : _materialLight,
            ),
            onDismissRequest: () => setState(() => _open = false),
            child: Column(
              key: orbitDropdownPopupKey,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in widget.items)
                  MiuixGlassPopupItem(
                    text: item.label,
                    summary: item.hint,
                    icon: orbitSelectItemLeading(item),
                    selected: item.value == widget.current,
                    onPressed: () => _pick(item.value),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
