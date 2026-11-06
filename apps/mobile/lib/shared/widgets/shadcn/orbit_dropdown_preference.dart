/// 下拉偏好行（原语层：设置项「行内当前值 + 就地展开玻璃菜单」，2026-11-05）
///
/// **弹层承载 = 与「今天」页头 ⋮ 菜单完全同款的 OS4 形变**
/// （`MiuixGlassTransformPopup`，2026-11-05 收口）：
/// - 承载：[showOrbitMenuPopup] 的 `transformAnchor` + `anchorContent` 路径，
///   与底栏「更多」、快速添加五处同源——卡片从**尾随值 + 箭头**那一小块连续
///   形变长出，关闭同样播逆形变，但**卡面贴合本行就交还**、不等库内弹簧尾巴
///   （锚点的逆形变尾巴是一块已收好的玻璃壳，空挂约 370ms 读起来就是
///   「回收到最后一步卡一下」，见 `orbit_menu_popup.dart` 的
///   `_transformExitCutoff`）；
/// - 锚点**只覆盖行尾的值与箭头**（2026-11-06 详情页「优先级」反馈：整行
///   锚点会让左侧标题跟着一起被"弹出去"——副本按整行矩形缩放并模糊淡出，
///   标题文字带着行宽一起飞向菜单卡）。标题/摘要/行首动作留在原位不参与
///   形变，读起来就是「值长成菜单」；点击区域仍是整行（`MiuixBasicComponent`
///   的 `onClick`），`MiuixGlassAnchor` 只负责采样与隐藏值块；
/// - 玻璃：形变承载 `inherited = true`，材质继承锚点表面（`MiuixGlassAnchor`
///   发布的 surface），不再走 `widget.backdrop` 的「无快照退实色」分支——
///   这正是 2026-11-05 云同步「引擎」弹层看着是实色白卡、退场又「模糊着
///   闪没」的根因（旧 dropdown 承载退场叠 `(1-fade)*30` 高斯模糊且材质
///   只认 backdrop）；
/// - 卡面/行：24 圆角玻璃卡 + `MiuixGlassPopupItem` 行（44 最小行高、24
///   图标位、选中打勾），与页头菜单同档；
/// - 返回键：本行根部 `PopScope` 在展开时先关菜单，不退出当前页面。
///
/// **为什么不用 `MiuixGlassDropdownPopup`**：dropdown 是「贴行下沿揭开」的
/// 另一套开场（`arcStartWidth .69 / .2` 小块揭幕 + 退场整卡高斯模糊），与
/// 页头菜单的形变节奏不同；设置项与页头菜单要求同款观感，故统一到
/// transform 承载。**注意**：形变期只有锚点值块由 [anchorContent] 副本
/// 承担，值块自身被隐藏（`contentHidden`），标题始终留在原位。
///
/// **行本身仍是 [MiuixBasicComponent]**：标题（+可选摘要）在左、可选行首动作
/// （如总开关）、尾随当前值 + 上下双箭头，点行就地展开弹层——当前档必须在
/// 行内常驻可见；仅**尾随值 + 箭头**包进 `MiuixGlassAnchor` 供形变采样，
/// 形变期只隐藏这一小块、由 [anchorContentBuilder] 副本承担（副本随父级
/// 换档更新）。
///
/// 与 [showOrbitSelectPopup] 的分工：后者是「任意触发控件 + 浮层」的通用
/// 选择器（保留 `showGeneralDialog` 路由外壳），本行是设置项里的下拉偏好。
/// 选中判据取 [SelectItem.value] 原始值
/// 而非文案；当前值不在 [items] 里时由调用方补一项（外观页强调色的「当前色」
/// 同款），否则库内无选中项 → 尾随值与弹层对勾双双落空。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import 'orbit_dropdown_panel.dart'
    show OrbitPanelItem, orbitPanelMaxWidth, orbitPanelMinWidth;
import 'orbit_glass_surface.dart' show OrbitGlassScope;
import 'orbit_menu_popup.dart' show OrbitMenuSession, showOrbitMenuPopup;
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
  /// 形变承载的触发件锚点（卡片从本行轮廓长出的起点）
  ///
  /// 与 `OrbitGlassMenu` 同口径：调用方创建并 `dispose`，不能把同一 anchor
  /// 绑到两个控件。本行只有一个弹层，故整行共用一个。
  final MiuixGlassPopupAnchor _anchor = MiuixGlassPopupAnchor();

  /// 共享锚定菜单会话（Overlay 直挂，与快速添加/页头菜单同一内容件）
  OrbitMenuSession? _menuSession;

  /// 点选后的乐观显示值（父级尚未回写前先顶上）
  ///
  /// 调用方的 `onSelect` 通常是 `await 写库 → invalidate` 的异步路径，回弹
  /// 动画（约 200ms）往往在父级换档前就播完了——期间副本读 `widget.current`
  /// 只能是旧值（2026-11-05「保留时间」真机实测：toast 已是 30 天，回弹仍写
  /// 「永久」）。点选瞬间先记下目标值，`widget.current` 跟上后清除。
  /// 用 [T?] + 标志位而非哨兵值，避免与合法档位值（如 0 = 永久）混淆。
  T? _pendingValue;
  bool _hasPending = false;

  bool get _open => _menuSession?.isOpen ?? false;

  @override
  void didUpdateWidget(OrbitDropdownPreference<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父级已换档（异步写库完成）：乐观值功成身退
    if (_hasPending && widget.current != oldWidget.current) {
      _hasPending = false;
      _pendingValue = null;
    }
  }

  @override
  void dispose() {
    _menuSession?.dispose();
    _anchor.dispose();
    super.dispose();
  }

  bool get _effectiveEnabled => widget.enabled && widget.items.isNotEmpty;

  /// 行内应显示的当前值：乐观值优先（回弹期即已显示新档）
  T? get _displayCurrent => _hasPending ? _pendingValue : widget.current;

  /// 尾随当前值文案；当前值不在选项里（脏数据）时留空
  String? get _valueLabel {
    for (final item in widget.items) {
      if (item.value == _displayCurrent) return item.label;
    }
    return null;
  }

  /// 点选一档：先乐观换值（回弹期就显示新档），再交给调用方写库
  void _pick(T value) {
    if (value != _displayCurrent) {
      setState(() {
        _pendingValue = value;
        _hasPending = true;
      });
    }
    widget.onSelect(value);
  }

  void _toggle() {
    if (_open) {
      _menuSession?.close();
      return;
    }
    _menuSession?.dispose();
    final session = showOrbitMenuPopup(
      context,
      // 形变承载：卡片从行尾「值 + 箭头」轮廓连续长出，退场播逆形变（与
      // 「今天」页头 ⋮ 菜单同款——锚的都是小触发件，不是整行）。不传矩形
      // anchor——那条路径会退 dropdown 承载，正是要替换掉的旧观感。
      transformAnchor: _anchor,
      // 副本走 builder（而非一次性 Widget）：父级换档后 setState 会让弹层
      // 重建并按新值重取副本——一次性 Widget 会停在打开瞬间的旧值
      // （2026-11-05「保留时间」实测：toast 已显示 30 天，回弹仍写「永久」）
      anchorContentBuilder: _anchorContent,
      groupsBuilder: () => [
        [
          for (final item in widget.items)
            OrbitPanelItem(
              icon: item.icon,
              iconColor: item.iconColor,
              leading: orbitSelectItemLeading(item),
              label: item.label,
              trailingLabel: item.hint,
              checked: item.value == _displayCurrent,
              onTap: () => _pick(item.value),
            ),
        ],
      ],
      minWidth: orbitPanelMinWidth,
      maxWidth: orbitPanelMaxWidth,
      contentKey: orbitDropdownPopupKey,
      // **不传 simplified**：锚点虽是「值 + 箭头」小块，但副本要在锚点矩形里
      // 按原样顶出来再模糊淡出，才有「值长成菜单」的连续感；传 true 会省掉
      // 副本、值块直接消失，读起来是「值闪没 + 卡凭空出现」。
      // 玻璃采样器：形变承载会继承锚点表面，这里仍传一份兜底（无锚点表面
      // 发布时用；壳层/根级页都能取到）
      backdrop: OrbitGlassScope.maybeOf(context),
    );
    _menuSession = session;
    session.closed.whenComplete(() {
      if (!mounted || _menuSession != session) return;
      setState(() => _menuSession = null);
    });
    setState(() {});
  }

  /// 形变期触发件副本：**只含尾随值 + 箭头**（不含标题）
  ///
  /// 形变承载会把锚点值块隐藏（`contentHidden`），由这份副本承接
  /// 「值 → 卡片」的连续形变。锚点矩形就是这块值的尺寸，副本必须同宽同构，
  /// 否则 tight 约束下会被拉伸/裁切。
  ///
  /// 标题不放进副本（2026-11-06 详情页「优先级」反馈）：副本按锚点矩形缩放
  /// 并模糊淡出，把整行塞进来等于"标题也一起弹出去"。
  Widget _anchorContent() => _buildValueBlock();

  /// 触发行；锚点只包行尾 [endActions] 的值块（标题/摘要/行首动作留在原位）
  Widget _buildRow({bool interactive = true}) {
    return MiuixBasicComponent(
      title: widget.title,
      summary: widget.summary,
      startAction: widget.startAction,
      insideMargin: widget.insideMargin,
      endActions: [_buildValueBlock(withAnchor: interactive)],
      role: MiuixBasicComponentRole.dropdownList,
      // 副本不参与交互：形变期由 IgnorePointer 包裹，这里也不给点击/按压态
      holdDownState: interactive && _open,
      onClick: interactive && _effectiveEnabled ? _toggle : null,
      enabled: _effectiveEnabled,
    );
  }

  /// 尾随当前值 + 上下双箭头（形变锚点 / 副本的唯一内容）
  ///
  /// [withAnchor] 为 false 时用于副本——同一个 [MiuixGlassPopupAnchor] 不能
  /// 在两处采样。布局上仍按行尾同款：值按松散约束收在尾部（可省略号截断），
  /// 箭头紧跟其后。
  Widget _buildValueBlock({bool withAnchor = false}) {
    final theme = MiuixTheme.of(context);
    final actionColor = _effectiveEnabled
        ? theme.colors.onSurfaceVariantActions
        : theme.colors.disabledOnSurface;
    final value = _valueLabel;
    final block = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
    );
    if (!withAnchor) return block;
    // 形变锚点只覆盖这一小块：弹层从值处长出，标题不参与形变
    return MiuixGlassAnchor(anchor: _anchor, child: block);
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
        children: [
          // 形变锚点只包行尾值块（见 `_buildValueBlock`）：标题不参与形变，
          // 副本由 `_anchorContent` 承担
          _buildRow(),
        ],
      ),
    );
  }
}
