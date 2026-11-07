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
/// **性能口径（2026-11-07）**：卡面材质、背景采样与弹簧尾巴统一由
/// [OrbitPopupGlassMotion] 管——形变窗口内走实色卡面（不采样背景、不跑离屏
/// 模糊），窗口结束同帧切真玻璃并冻结库内弹簧尾巴。细则与实测见
/// `orbit_popup_glass.dart` 文件头。
///
/// **承载是 Overlay 直挂，不是路由**：菜单打开期间不重建页面、不新建路由。
/// 调用方传了 [showOrbitMenuPopup] 的 `restoreFocus`（弹层背后有输入框、要求
/// 键盘全程不落）时，整棵弹层子树被包进不可获焦的 `Focus`——库内 presenter
/// 自带 `FocusScope(autofocus: true)`，只要它可获焦就会在挂载首帧抢走输入框
/// 焦点，`EditableText` 因此关闭输入连接、输入法收起（等两帧再归还就是肉眼
/// 可见的「键盘收回再弹出」，2026-11-07 真机反馈）；关闭先切
/// `show=false` 播逆形变，退场收尾后才移除 entry（形变承载在卡面贴合触发件
/// 那一刻就收尾，不等库内弹簧尾巴，见 [_transformExitCutoff]）；行回调仍
/// 立即执行（调用方可以马上写库），不等待退场动画。
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
import 'orbit_popup_glass.dart';

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

/// 形变承载的退场截断时长：卡面贴合触发件即收尾
///
/// 库内 transform 退场是 `bounds(.8,.28)` 与 `center(.8,.4)` 两条弹簧取 max，
/// 按 0.0015 容差要跑到 **~690ms**；但实测卡面在 **~320ms** 就已经落到触发件
/// 矩形上，此后只剩 1–2px 的过冲回摆（肉眼不可见），而行内容副本最迟 130ms
/// （`_icon` 延迟 50 + 80）就完全顶出来了。那多出来的 ~370ms 里画面已经收好、
/// 弹层却还挂着（还压着那层玻璃卡壳），观感就是**回收到最后一步卡一下**
/// （2026-11-06 云同步「引擎」行反馈，探针实测卡壳矩形 320ms 已等于行矩形、
/// 688ms 才移除）。故形变承载不等库内收尾，到点自己交还给触发件。
const Duration _transformExitCutoff = Duration(milliseconds: 320);

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
/// - [restoreFocus]：打开前持有焦点的输入框。传了它 → 弹层整棵子树不可获焦
///   （库内 autofocus 直接失效，键盘全程不落）+ 落定后再还一次焦点兜底。
///   只有**打开时确实持有焦点**的节点才登记，避免菜单关闭后把键盘无端叫起来。
/// - [backdrop]：OS4 玻璃采样器（调用方从壳层 `OrbitGlassScope` 取；弹层
///   挂在根 Overlay 上，位于 scope 之外，组件内部取不到）。
OrbitMenuSession showOrbitMenuPopup(
  BuildContext context, {
  Rect? anchor,
  MiuixGlassPopupAnchor? transformAnchor,
  Widget? anchorContent,
  Widget Function()? anchorContentBuilder,
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
  bool simplified = false,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final done = Completer<void>();
  final bodyKey = GlobalKey<OrbitMenuPopupBodyState>();
  // 只有打开前**确实持有焦点**的节点才纳入护航：既保证盾牌只在这种场景生效
  // （无输入框的菜单照旧接管焦点），也避免关闭时把键盘无端叫起来
  final focused = (restoreFocus?.hasFocus ?? false) ? restoreFocus : null;
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
      anchorContentBuilder: anchorContentBuilder,
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
      restoreFocus: focused,
      simplified: simplified,
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
    this.anchorContentBuilder,
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
    this.simplified = false,
  });

  /// dropdown 承载的触发矩形（[transformAnchor] 为空时使用）
  final Rect? anchor;

  /// 形变承载的触发件锚点（`MiuixGlassAnchor` 包裹过的按钮）；
  /// 非空时走与底栏「更多」同款的 `MiuixGlassTransformPopup`
  final MiuixGlassPopupAnchor? transformAnchor;

  /// 形变期展开阶段是否省掉锚点副本
  ///
  /// 库内语义（`popup_presenter.dart`）：true 时展开期不叠 [anchorContent]
  /// 副本、卡片直接从轮廓长出；false（默认）会叠一份副本并模糊渐隐。
  /// 页头「今天 ▾」菜单用 true（`OrbitGlassMenu`）；底栏「更多」/快速添加/
  /// 下拉偏好行沿用默认 false——它们要让触发件内容（按钮文字、尾随值）
  /// 连续长成卡片，而不是凭空出现。
  final bool simplified;

  /// 形变期触发件副本（按钮内容被隐藏后由它按按钮矩形缩放显示）
  final Widget? anchorContent;

  /// 副本的动态构造（优先于 [anchorContent]）
  ///
  /// 一次性 Widget 会在弹层打开瞬间固化；调用方若在弹层打开期间换值
  /// （设置项选中新档），回弹期的副本就会停在旧值——2026-11-05 设置页
  /// 「保留时间」实测：toast 已显示 30 天，回弹画面仍写「永久」。
  /// 传本参数后，父级 `setState` 触发的重建会重新调用它，副本即随当下值更新。
  final Widget Function()? anchorContentBuilder;

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

  /// 退场收尾（Overlay 承载此时才移除 entry）
  ///
  /// 形变承载在卡面贴合触发件时（约 320ms）即回调，不等库内弹簧尾巴；
  /// dropdown 承载仍由库内退场结束回调。
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

  /// 承载方是否已收尾（库里完成回调与退场截断只认先到的那个）
  bool _finished = false;

  /// 形变承载的退场截断定时器（见 [_transformExitCutoff]）
  Timer? _cutoff;

  /// 请求回收；库内退场完成后（或形变承载到点截断后）由 [_finish] 收尾。
  void dismiss() {
    if (_closing || !mounted) return;
    _closing = true;
    // 首帧尚未挂上库内 portal 时没有退场可播，直接让承载方清理，避免
    // 「show=false 但从未 present」时收不到完成回调而泄漏 entry。
    if (_measured == null) {
      _finish();
      return;
    }
    setState(() => _show = false);
    // 形变承载：库内逆形变的弹簧尾巴很长（见 [_transformExitCutoff]），
    // 卡面贴上触发件就交还，不再空挂那 ~370ms
    if (widget.transformAnchor != null) {
      _cutoff = Timer(_transformExitCutoff, _finish);
    }
  }

  /// 退场收尾（幂等）：放出锚点内容 → 由承载方移除弹层
  ///
  /// 先放锚点内容再移除：库内 presenter 卸载时才在**帧末**恢复
  /// `contentHidden`，先摘承载会空出一帧「行内容消失」；这里两件事在同一个
  /// 构建帧生效，行与弹层无缝交接。
  void _finish() {
    if (_finished || !mounted) return;
    _finished = true;
    _cutoff?.cancel();
    _cutoff = null;
    widget.transformAnchor?.contentHidden = false;
    widget.onDismissFinished?.call();
  }

  @override
  void dispose() {
    _cutoff?.cancel();
    super.dispose();
  }

  /// 焦点归还是否已排期（只排一次；后续行点击重建不再抢焦点）
  bool _focusScheduled = false;

  /// 排期把焦点还给输入框（兜底）
  ///
  /// 正常路径下焦点从未离开输入框（见 [build] 的焦点护航），这里只是防御：
  /// 万一库内某个节点仍然抢到了焦点，测量落定后再等两帧还回去。
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
        if (node.hasFocus) return;
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
    final transformAnchor = widget.transformAnchor;
    // 玻璃闸门：形变窗口内实色卡面（不采样背景），窗口结束切真玻璃并冻结
    // 库内弹簧尾巴——细则与实测见 `orbit_popup_glass.dart` 文件头
    final body = OrbitPopupGlassMotion(
      open: _show,
      builder: (context, glass) {
        final visuals = OrbitPopupGlass.visuals(
          isDark: isDark,
          glass: glass,
        );
        final backdrop = glass ? widget.backdrop : null;
        if (transformAnchor != null) {
          // 与底栏「更多」完全同款：卡片从触发件轮廓连续形变长出（按钮内容由
          // anchorContent 副本承担），sizing/留白取库内菜单档，不另设宽度档。
          return MiuixGlassTransformPopup(
            show: _show,
            anchor: transformAnchor,
            // builder 优先：每次重建（含 refreshContent）都按调用方当下的值取副本
            anchorContent:
                widget.anchorContentBuilder?.call() ??
                widget.anchorContent ??
                const SizedBox.shrink(),
            simplified: widget.simplified,
            backdrop: backdrop,
            gap: widget.gap,
            sizing: _sizing(screen.height * _maxHeightFactor),
            visuals: visuals,
            onMeasured: _handleMeasured,
            onDismissRequest: widget.onDismiss,
            // 统一走 _finish：退场截断与库内完成幂等互斥，都只收尾一次
            onDismissFinished: _finish,
            child: panel,
          );
        }
        return MiuixGlassDropdownPopup(
          show: _show,
          anchorBounds: _anchorBounds(screen, groups),
          backdrop: backdrop,
          sizing: _sizing(screen.height * _maxHeightFactor),
          visuals: visuals,
          // 库内已包 SingleChildScrollView + Padding；行面板自带上下 8 留白，
          // 这里归零，避免双份内边距把首尾行压窄。
          contentPadding: EdgeInsets.zero,
          onMeasured: _handleMeasured,
          onDismissRequest: widget.onDismiss,
          onDismissFinished: _finish,
          child: panel,
        );
      },
    );
    // 焦点护航（[OrbitMenuPopupBody.restoreFocus] 非空 = 调用方要求键盘全程
    // 不落）：库内 presenter 自带 `FocusScope(autofocus: true)`，弹层一旦可
    // 获焦就在首帧抢走输入框焦点，`EditableText` 随即关闭输入连接、输入法
    // 收起——再等两帧归还就是肉眼可见的「键盘收回再弹出」。把整棵弹层子树
    // 设成不可获焦，库内 autofocus 在 `_Autofocus.applyIfValid` 里被丢弃，
    // 焦点自始至终留在输入框上。行是点按交互，语义树不受影响。
    if (widget.restoreFocus == null) return body;
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: false,
      child: body,
    );
  }
}
