/// 锚定选择菜单（2026-11-05）
///
/// 全项目「贴着触发控件弹出的选择菜单」的唯一入口：承载与动效交给
/// flutter_miuix 的 OS4 dropdown 弹层（`MiuixGlassDropdownPopup`）——
/// 卡面从触发行一角 0.69×0.2 的小块揭幕、连续形变为整张（圆角 4→24、
/// 内容等比缩放裁切）。这套几何与弹簧已在 `miuix_glass_popup_style.dart`
/// 内，**不要**手写测量/翻转/形变；本文件只负责挑锚点：向下时锚在触发行
/// 下沿 + 8，上方时锚在触发行上沿 - 8（卡底停在按钮上方，**不遮住触发钮**，
/// 见 `_placeAbove` / `_anchorBounds`）。
///
/// 行样式复用 [OrbitDropdownPanelView]（`MiuixGlassPopupItem`：44 最小行高、
/// 24 图标位、语义色文案、选中强调色 + 右端对勾、组间 0.5 分隔线），与
/// 「今天」页头 ⋮ 菜单、下拉偏好行同源。
///
/// **承载是 Overlay 直挂，不是路由**：菜单打开期间不重建页面、不新建路由，
/// 输入框焦点与键盘保持升起（库内 `FocusScope(autofocus)` 会先接管一次，
/// 组件在测量落定后再等两帧归还，见 `_scheduleFocusRestore`）；关闭先切
/// `show=false` 播逆形变，`onDismissFinished` 后才移除 entry；行回调仍立即
/// 执行（调用方可以马上写库），不等待退场动画。
///
/// **返回键**：Overlay 下 `ModalRoute.of` 为 null，库内 `LocalHistoryEntry`
/// 不生效；调用方有底部面板时用既有 `PopScope` 兜底（会话 `close()` 幂等）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import 'orbit_dropdown_panel.dart';

/// 弹层与触发行之间的呼吸位（并进锚点矩形，与 `showOrbitSelectPopup` 同口径）
const double _gap = AppDimens.space8;

/// 无锚点时距屏幕右沿的最小留白（右上角兜底形态）
const double _edgeInset = AppDimens.space12;

/// 无锚点时距状态栏的下移量（页头高度档，与页头 ⋮ 菜单落位同惯例）
const double _noAnchorTopInset = AppDimens.titleBarHeight;

/// 弹层高度上限占屏比（选项多时库内内容可滚）
const double _maxHeightFactor = 0.6;

/// 方向判定用的保守行高（库内最小行高 44 + 余量：估算宁大勿小，
/// 偏大只会让菜单更早上翻，不会出现「先向下盖住按钮」）
const double _estimateRowHeight = 48;

/// 方向判定用的面板上下留白（行面板自带 8+8，再留 8 余量）
const double _estimatePanelPadding = 24;

/// 标题行高度（`OrbitDropdownPanelView` 的标题行 + 上下留白）
const double _estimateHeaderHeight = 40;

/// 锚定菜单会话：`close` 幂等，`closed` 在弹层移除后完成。
///
/// 调用方需要「关闭后回到某个状态」时（如底部面板的 `PopScope.canPop`）
/// 监听 [closed]；不需要则忽略即可。
class OrbitMenuSession {
  OrbitMenuSession._(this._close, this._dispose, this._closed);

  final VoidCallback _close;
  final VoidCallback _dispose;
  final Future<void> _closed;
  bool _open = true;

  /// 菜单是否尚未收到关闭请求（回收动画期间也为 false）
  bool get isOpen => _open;

  /// 播放回收动画并关闭菜单（幂等；已请求关闭时为空操作）
  void close() {
    if (!_open) return;
    _open = false;
    _close();
  }

  /// 宿主销毁时立即清理，不在已卸载的锚点上继续播回收动画。
  void dispose() {
    _open = false;
    _dispose();
  }

  /// 弹层移除后完成；`dispose()` 立即清理时同步完成（锚点恢复由库在下一帧）
  Future<void> get closed => _closed;
}

/// 弹出锚定选择菜单（贴触发行弹出，点外部/返回键关闭）。
///
/// - [transformAnchor]：触发控件锚点（`MiuixGlassAnchor` 包裹过的按钮）。
///   传入时走**与底栏「更多」同款**的 OS4 形变：卡片从按钮轮廓连续长出来
///   （按钮内容由 [anchorContent] 副本按按钮矩形承担），并自动隐藏按钮本体；
///   不传则回退 [anchor] 的 dropdown 形变。
/// - [anchor]：触发行/按钮的全局矩形（dropdown 承载）；null 时回退右上角
///   形态。**不要**传页面级 context 的矩形（接近整屏，弹层会贴到屏幕角落）。
/// - [gap]：形变模式下的落位微调（负值把卡片底边抬到按钮上方，避免压住
///   触发钮；底栏「更多」用 `-(栏高 + 间距)`，工具栏按钮用 `-(按钮高 + 8)`）。
/// - [groupsBuilder]：条目在每次重建时重新取（多选连选靠它翻勾），闭包里
///   读调用方当下的选中集合；**不要**在闭包里做副作用。
/// - [closeOnTap]：单选/动作菜单为 true（点行即关）；多选常驻传 false。
/// - [minWidth]/[maxWidth]：null = 库内菜单档（200–288，与底栏「更多」同档）；
///   标签这类长文案菜单可传 `maxWidth: 300`。
/// - [restoreFocus]：菜单落定后把焦点归还给它（输入框仍在的快速添加面板
///   必传，否则键盘会落下、面板位移导致锚点错位）。
/// - [backdrop]：OS4 玻璃采样器（调用方从壳层 `OrbitGlassScope` 取；弹层
///   挂在根 Overlay 上，位于 scope 之外，组件内部取不到）。
OrbitMenuSession showOrbitMenuPopup(
  BuildContext context, {
  Rect? anchor,
  MiuixGlassPopupAnchor? transformAnchor,
  Widget? anchorContent,
  double gap = 0,
  required List<List<OrbitPanelItem>> Function() groupsBuilder,
  double? minWidth,
  double? maxWidth,
  bool closeOnTap = true,
  String? title,
  String? actionLabel,
  VoidCallback? onAction,
  Key? contentKey,
  MiuixLayerBackdrop? backdrop,
  FocusNode? restoreFocus,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final done = Completer<void>();
  final bodyKey = GlobalKey<OrbitMenuPopupBodyState>();
  late final OverlayEntry entry;
  late final OrbitMenuSession session;
  var removed = false;

  void remove() {
    if (removed) return;
    removed = true;
    entry.remove();
    entry.dispose();
    if (!done.isCompleted) done.complete();
  }

  void close() {
    if (removed) return;
    final body = bodyKey.currentState;
    if (body == null) {
      remove();
      return;
    }
    body.dismiss();
  }

  entry = OverlayEntry(
    builder: (_) => OrbitMenuPopupBody(
      key: bodyKey,
      anchor: anchor,
      transformAnchor: transformAnchor,
      anchorContent: anchorContent,
      gap: gap,
      groupsBuilder: groupsBuilder,
      minWidth: minWidth,
      maxWidth: maxWidth,
      closeOnTap: closeOnTap,
      title: title,
      actionLabel: actionLabel,
      onAction: onAction,
      contentKey: contentKey,
      backdrop: backdrop,
      restoreFocus: restoreFocus,
      onDismiss: () => session.close(),
      onDismissFinished: remove,
    ),
  );
  overlay.insert(entry);
  session = OrbitMenuSession._(close, remove, done.future);
  return session;
}

/// 锚定菜单内容件（受控）：卡面、行、方向判定与形变动效的唯一实现。
///
/// 两种承载共用本件，只在「关闭」与「返回键」上各负其责：
/// - [showOrbitMenuPopup]：`OverlayEntry` 直挂，关闭 = 先播回收、完成后移除
///   entry，返回键由调用方 `PopScope` 兜底；
/// - `showOrbitSelectPopup`：保留 `showGeneralDialog` 路由外壳（21 处存量
///   调用点零改动），同样先播回收，结束后消费 `LocalHistoryEntry` 并 pop。
///
/// 行点击的关闭语义：`closeOnTap` 为 true 时点行先 [onDismiss] 再执行
/// `OrbitPanelItem.onTap`（与旧行为一致：调用方在回调里立即写库/导航）；
/// 为 false 时只回调并就地重取 [groupsBuilder] 翻勾。
class OrbitMenuPopupBody extends StatefulWidget {
  const OrbitMenuPopupBody({
    super.key,
    this.anchor,
    this.transformAnchor,
    this.anchorContent,
    this.gap = 0,
    required this.groupsBuilder,
    required this.onDismiss,
    this.onDismissFinished,
    this.minWidth,
    this.maxWidth,
    this.closeOnTap = true,
    this.title,
    this.actionLabel,
    this.onAction,
    this.contentKey,
    this.backdrop,
    this.restoreFocus,
    this.itemDismiss,
  });

  /// dropdown 承载的触发矩形（[transformAnchor] 为空时使用）
  final Rect? anchor;

  /// 形变承载的触发件锚点（`MiuixGlassAnchor` 包裹过的按钮）；
  /// 非空时走与底栏「更多」同款的 `MiuixGlassTransformPopup`
  final MiuixGlassPopupAnchor? transformAnchor;

  /// 形变期触发件副本（按钮内容被隐藏后由它按按钮矩形缩放显示）
  final Widget? anchorContent;

  /// 形变落位微调（负值把卡片底边抬到按钮上方）
  final double gap;

  /// 每次重建重取条目（多选连选翻勾）
  final List<List<OrbitPanelItem>> Function() groupsBuilder;

  /// null = 库内菜单档（200–288，与底栏「更多」同档）
  final double? minWidth;
  final double? maxWidth;
  final bool closeOnTap;
  final String? title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? contentKey;
  final MiuixLayerBackdrop? backdrop;
  final FocusNode? restoreFocus;

  /// 点外部/返回键请求关闭（由承载入口处理）
  final VoidCallback onDismiss;

  /// 逆形变结束（Overlay 承载此时才移除 entry）
  final VoidCallback? onDismissFinished;

  /// 行点击时的「先关面板」动作（默认同 [onDismiss]）
  ///
  /// 路由承载下单选行由 `item.onTap` 自己负责关路由（`_pick`），这里传空
  /// 函数避免重复 pop 吞掉选中回调；Overlay 承载先请求回收再立即执行行回调。
  final VoidCallback? itemDismiss;

  @override
  State<OrbitMenuPopupBody> createState() => OrbitMenuPopupBodyState();
}

class OrbitMenuPopupBodyState extends State<OrbitMenuPopupBody> {
  bool _show = true;
  bool _closing = false;

  /// 请求回收；库内退场完成后由 [OrbitMenuPopupBody.onDismissFinished] 收尾。
  void dismiss() {
    if (_closing || !mounted) return;
    _closing = true;
    // 首帧尚未挂上库内 portal 时没有退场可播，直接让承载方清理，避免
    // 「show=false 但从未 present」时收不到完成回调而泄漏 entry。
    if (_measured == null) {
      widget.onDismissFinished?.call();
      return;
    }
    setState(() => _show = false);
  }

  /// 卡面材质（与页头 ⋮ 菜单 / 下拉偏好同档：puredThinGlass + blur 32；
  /// 按亮暗各缓存一份——值相等是库内纹理缓存的性能要件，动画期逐帧新建
  /// 材质会让缓存逐帧失效、每帧重跑离屏模糊）
  static final _materialLight = MiuixGlassMaterials.puredThinGlassLight
      .copyWith(blurRadius: 32);
  static final _materialDark = MiuixGlassMaterials.puredThinGlassDark.copyWith(
    blurRadius: 32,
  );

  /// 焦点归还是否已排期（只排一次；后续行点击重建不再抢焦点）
  bool _focusScheduled = false;

  /// 排期把焦点还给输入框
  ///
  /// 库内弹层用 `FocusScope(autofocus)` 接管焦点，会把输入框的键盘顶下去；
  /// 它的 autofocus 在 overlay 挂载后的 postFrame 才真正生效（早于/晚于
  /// [onMeasured] 取决于帧序），故在测量回调后**再等两帧**归还——此时它已
  /// 完成一次抢占，不会再重复。
  void _scheduleFocusRestore() {
    if (_focusScheduled || widget.restoreFocus == null) return;
    _focusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final node = widget.restoreFocus;
        if (node == null || node.context == null || !node.canRequestFocus) {
          return;
        }
        node.requestFocus();
      });
    });
  }

  /// 首次测量到的卡面尺寸（方向判定优先用它，未测到前用行数估算）
  Size? _measured;

  /// 估算卡面高度（行数 × 保守行高 + 面板/标题/分隔留白）
  double _estimatedHeight(List<List<OrbitPanelItem>> groups) {
    var rows = 0;
    for (final group in groups) {
      rows += group.length;
    }
    var height = rows * _estimateRowHeight + _estimatePanelPadding;
    if (widget.title != null || widget.actionLabel != null) {
      height += _estimateHeaderHeight;
    }
    if (groups.length > 1) height += (groups.length - 1) * AppDimens.space8;
    return height;
  }

  /// 是否向上展开（卡底贴触发钮上沿，不遮住按钮）
  ///
  /// 库内 `alignTop` 的判据是 `below = 安全底 - anchor.top` 与卡高比较：
  /// - 向下锚点取「按钮下沿 + gap」，卡顶贴按钮下方；
  /// - 向上锚点取「按钮上沿 - gap」的零高矩形，库内落位
  ///   `y = anchor.bottom - 卡高`，即卡底停在按钮上方。
  /// 只有向上锚点的 `below` 也小于卡高时库内才真的翻上（否则仍按向下弹），
  /// 故两个条件同时成立才上翻；上方空间不足时保持向下、交给库内钳制。
  bool _placeAbove(Size screen, double height) {
    final rect = widget.anchor;
    if (rect == null) return false;
    final view = MediaQuery.viewPaddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom =
        screen.height - math.max(view.bottom, keyboard) - _edgeInset;
    final safeTop = view.top + _edgeInset;
    final belowDown = safeBottom - (rect.bottom + _gap);
    final belowUp = safeBottom - (rect.top - _gap);
    final above = (rect.top - _gap) - safeTop;
    return belowDown < height && belowUp < height && above > belowDown;
  }

  /// 锚点矩形（库内 dropdown 口径：`y = 锚点 top`、右沿对齐锚点右沿）
  ///
  /// 向下时锚点取「按钮下沿 + gap」零高矩形；向上时取「按钮上沿 - gap」，
  /// 这样库内 `anchor.bottom - 卡高` 落位后卡底停在按钮上方，不遮住触发钮。
  Rect _anchorBounds(Size screen, List<List<OrbitPanelItem>> groups) {
    final rect = widget.anchor;
    if (rect != null) {
      final height = _measured?.height ?? _estimatedHeight(groups);
      final top = _placeAbove(screen, height)
          ? rect.top - _gap
          : rect.bottom + _gap;
      return Rect.fromLTWH(rect.left, top, rect.width, 0);
    }
    final top = MediaQuery.viewPaddingOf(context).top;
    return Rect.fromLTWH(
      screen.width - _edgeInset,
      top + _noAnchorTopInset,
      0,
      0,
    );
  }

  /// 多选常驻时点行要就地翻勾：`OrbitDropdownPanelView` 只吃一份条目快照，
  /// 故在组件内部 setState 重取 [widget.groupsBuilder]（单选菜单点行即关，
  /// 不需包装）。
  List<List<OrbitPanelItem>> _liveGroups(List<List<OrbitPanelItem>> groups) {
    if (widget.closeOnTap) return groups;
    return [
      for (final group in groups)
        [
          for (final item in group)
            if (item.children.isEmpty)
              OrbitPanelItem(
                icon: item.icon,
                leading: item.leading,
                iconColor: item.iconColor,
                label: item.label,
                color: item.color,
                trailingLabel: item.trailingLabel,
                checked: item.checked,
                onTap: () {
                  item.onTap?.call();
                  if (mounted) setState(() {});
                },
              )
            else
              item,
        ],
    ];
  }

  /// 尺寸档：null 用库内菜单档（200–288，与底栏「更多」逐像素同档）
  MiuixGlassPopupSizing _sizing(double maxHeight) {
    final minWidth = widget.minWidth;
    final maxWidth = widget.maxWidth;
    if (minWidth == null && maxWidth == null) {
      return MiuixGlassPopupSizing(maxHeight: maxHeight);
    }
    return MiuixGlassPopupSizing(
      minWidth: minWidth ?? MiuixGlassPopupDefaults.minWidth,
      maxWidth: maxWidth ?? MiuixGlassPopupDefaults.maxWidth,
      maxHeight: maxHeight,
    );
  }

  /// 测量落定（弹层已完成首帧布局）：归还焦点 + 用真实卡高修正方向
  void _handleMeasured(Size size) {
    _scheduleFocusRestore();
    // 估算偏小时首帧会先向下、被安全区钳到底部（可能压住按钮），这里按实际
    // 高度切回向上；跳变发生在进场首帧，用户不可见。尺寸不变不 setState。
    if (_measured == size) return;
    _measured = size;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final groups = _liveGroups(widget.groupsBuilder());
    final panel = OrbitDropdownPanelView(
      key: widget.contentKey ?? orbitSelectPopupKey,
      // 库内形变弹层外层已带纵向滚动，内部再套一层会拿到无界高度
      scrollable: false,
      closeOnTap: widget.closeOnTap,
      title: widget.title,
      actionLabel: widget.actionLabel,
      onAction: widget.onAction,
      onClose: widget.itemDismiss ?? widget.onDismiss,
      groups: groups,
    );
    final visuals = MiuixGlassPopupVisuals(
      material: isDark ? _materialDark : _materialLight,
    );
    final transformAnchor = widget.transformAnchor;
    if (transformAnchor != null) {
      // 与底栏「更多」完全同款：卡片从触发件轮廓连续形变长出（按钮内容由
      // anchorContent 副本承担），sizing/留白取库内菜单档，不另设宽度档。
      return MiuixGlassTransformPopup(
        show: _show,
        anchor: transformAnchor,
        anchorContent: widget.anchorContent ?? const SizedBox.shrink(),
        backdrop: widget.backdrop,
        gap: widget.gap,
        sizing: _sizing(screen.height * _maxHeightFactor),
        visuals: visuals,
        onMeasured: _handleMeasured,
        onDismissRequest: widget.onDismiss,
        onDismissFinished: widget.onDismissFinished,
        child: panel,
      );
    }
    return MiuixGlassDropdownPopup(
      show: _show,
      anchorBounds: _anchorBounds(screen, groups),
      backdrop: widget.backdrop,
      sizing: _sizing(screen.height * _maxHeightFactor),
      visuals: visuals,
      // 库内已包 SingleChildScrollView + Padding；行面板自带上下 8 留白，
      // 这里归零，避免双份内边距把首尾行压窄。
      contentPadding: EdgeInsets.zero,
      onMeasured: _handleMeasured,
      onDismissRequest: widget.onDismiss,
      onDismissFinished: widget.onDismissFinished,
      child: panel,
    );
  }
}
