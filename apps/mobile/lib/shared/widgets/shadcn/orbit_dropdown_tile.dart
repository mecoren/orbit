/// 下拉偏好行（原语层：flutter_miuix OS4 玻璃下拉弹层，2026-11-04）
///
/// **与 [OrbitArrowTile] 的区别只在交互语义**：箭头行是「跳到下一页」，
/// 本行是「就地展开下拉」——尾随位换成库内 [MiuixDropdownArrowEndAction]
/// 的上下双箭头（10×16），点击贴着本行下沿弹出 OS4 玻璃下拉面板，当前档在
/// 面板里转强调色并打勾。
///
/// **弹层直接取库内 [MiuixGlassDropdownPopup]**（对齐 flutter_miuix
/// `example/lib/showcase/os4.dart` 的「弹层」示例），不再自建路由 + 卡面 +
/// 形变插值：
/// - 面板由库内 `OverlayPortal` 挂到根 Overlay，进出场走库内 dropdown motion
///   （圆角 4 → 24、从锚点右上角一片揭到整块），点外部 / 返回键收起；
/// - 行是 [MiuixGlassPopupItem]：未选中正文色，选中主题色 + 右端对勾；
/// - 材质档取 `puredThinGlass` + `blurRadius 32`（与 [OrbitGlassMenu] 同档：
///   库默认 `popupViewGlass` 的 60 档在动画期每帧重算离屏模糊，真机掉帧）。
///
/// **锚点走 `anchorBounds` 而非 `MiuixGlassAnchor`**：库内 dropdown motion
/// 会隐藏锚点控件内容（当它是「长出来的触发钮」），而本行的当前值必须留在
/// 原处可见。改传一条**零高度矩形**（本行下沿）：库内落位是「y = 锚点 top +
/// gap、右沿对齐锚点右沿」，于是面板正好落在行下方 8px，且不吞掉行本身。
///
/// 几何全部走 `MiuixBasicComponent`：标题 `headline1`（w500）+ 摘要
/// `body2`，最小行高 56；**水平内边距 16 由本行自带**（竖直 8），外层
/// 卡片（[SectionCard]）传仅含 bottom 的零水平内边距——与 flutter_miuix
/// `GroupCard`（`insideMargin: zero`，行自带内边距）同构，行展开期间
/// [MiuixBasicComponent.holdDownState] 的按压灰底（onBackground 10%）才
/// 能横贯整卡、直角贴分组卡边、由卡片 squircle 圆角裁切，与库内
/// 「菜单选择 Menus」示例的下拉偏好行按压态逐像素同观感。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import 'orbit_glass_surface.dart';
import 'orbit_select_popup.dart';

/// 下拉弹层内容节点 key（测试定位用：`find.byKey(orbitDropdownPopupKey)`）
const Key orbitDropdownPopupKey = ValueKey('orbit-dropdown-popup');

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

  /// 选中回调（面板点选后触发）
  final ValueChanged<T> onSelect;

  /// 是否启用（false 时整行转禁用色、不可展开）
  final bool enabled;

  @override
  State<OrbitDropdownTile<T>> createState() => _OrbitDropdownTileState<T>();
}

class _OrbitDropdownTileState<T> extends State<OrbitDropdownTile<T>> {
  /// 本行矩形采样点（点开瞬间的全局描点）
  final GlobalKey _rowKey = GlobalKey();

  /// 面板展开中（驱动按压底 + 库内进出场）
  bool _open = false;

  /// 面板锚点（**零高度**矩形 = 本行下沿；见文件头锚点口径）。
  /// 首帧为 null → 弹层不挂载（库内断言要求 show/bounds 同时就绪）；
  /// 收起后**不清**——退出动画仍要按它定位。
  Rect? _anchorBounds;

  /// 弹层材质（按亮暗各缓存一份：库内纹理缓存以值相等为命中判据）
  static final _materialLight = MiuixGlassMaterials.puredThinGlassLight
      .copyWith(blurRadius: 32);
  static final _materialDark = MiuixGlassMaterials.puredThinGlassDark.copyWith(
    blurRadius: 32,
  );

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
      // 库内 `MiuixGlassDropdownPopup` 没有 gap 参数（落位 = 锚点 top），
      // 8px 呼吸位并进锚点矩形：本行下沿再往下 8
      _anchorBounds = Rect.fromLTWH(
        rect.left,
        rect.bottom + AppDimens.space8,
        rect.width,
        0,
      );
      _open = true;
    });
  }

  /// 点选：先收面板再回调（回调里可能重建整棵树，如主题切换）
  void _pick(T value) {
    setState(() => _open = false);
    widget.onSelect(value);
  }

  /// 行首信息位：语义图标优先，其次 12px 色点（库内图标位固定 24×24 盒）
  Widget? _leading(SelectItem<T> item) {
    if (item.icon != null) {
      return Icon(item.icon, size: 20, color: item.iconColor);
    }
    if (item.colorDot != null) {
      return Center(
        child: Container(
          width: AppDimens.colorDotSize,
          height: AppDimens.colorDotSize,
          decoration: BoxDecoration(
            color: item.colorDot,
            shape: BoxShape.circle,
          ),
        ),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final effectiveEnabled = widget.enabled && widget.items.isNotEmpty;
    final actionColor = effectiveEnabled
        ? theme.colors.onSurfaceVariantActions
        : theme.colors.disabledOnSurface;
    final value = _valueLabel;
    final bounds = _anchorBounds;
    // 玻璃采样器在**调用方** context 上取：面板挂在根 Overlay（本页
    // OrbitGlassPage 捕获树的兄弟层），不会把面板自己拍进背景
    final backdrop = OrbitGlassScope.maybeOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MiuixBasicComponent(
          key: _rowKey,
          title: widget.title,
          summary: widget.summary,
          insideMargin: const EdgeInsets.symmetric(
            vertical: AppDimens.space8,
            horizontal: AppDimens.space16,
          ),
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
          onClick: effectiveEnabled ? _toggle : null,
          enabled: effectiveEnabled,
        ),
        if (bounds != null)
          MiuixGlassDropdownPopup(
            show: _open,
            anchorBounds: bounds,
            backdrop: backdrop,
            visuals: MiuixGlassPopupVisuals(
              material: Theme.of(context).brightness == Brightness.dark
                  ? _materialDark
                  : _materialLight,
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
                    icon: _leading(item),
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
