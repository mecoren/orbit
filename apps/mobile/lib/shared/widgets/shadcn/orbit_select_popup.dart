/// 单选浮层（锚定选择菜单，2026-11-05 统一到「今天」页头菜单口径）
///
/// **承载与动效全部交给 flutter_miuix 的 OS4 dropdown 弹层**
/// （`MiuixGlassDropdownPopup`：`OverlayPortal` 挂根 Overlay + dropdown motion）：
/// - 位置：贴着**触发行的下沿**弹出，右沿对齐触发行右沿；下方放不下翻到
///   上方，左右/上下钳在安全区与 viewPadding 内（库内 `miuixGlassPopupFrame`）；
/// - 行：`MiuixGlassPopupItem`（玻璃菜单条目同款：最小行高 44、24 图标位、
///   未选中**正文色**、选中**强调色文字 + 右端对勾**、可带副说明）；
/// - 卡面：`MiuixGlassPanel`（无采样器时库内退实色白卡），圆角 24、
///   `puredThinGlass` + blur 32（与 ⋮ 菜单同档），选项多时限高 0.6 屏可滚；
/// - 进场：库内 dropdown motion（卡面从触发行右上角 0.69×0.2 的小块揭到整张，
///   圆角 4→24，内容等比缩放裁切）。
///
/// 本文件只保留：数据项（[SelectItem]）、入口函数、锚点三级回退
/// （显式 [anchor] / 调用方 context 是行尺度取自身矩形 / 最近一次指针按下位置）
/// 与行首构件（[orbitSelectItemLeading]，下拉偏好行共用）。测量、落位、
/// 翻转与形变不再手写——那套逻辑与库内逐项同构，手写版已于 2026-11-05 删除。
///
/// **路由版同样播回收动画**：点选/取消先把面板 `show=false`，逆形变结束再
/// pop 路由；`onSelect` 仍同步执行（调用方写库/导航不等待动画）。若回调里
/// push 了新页，收尾只移除本条透明路由，不会误 pop 新页面。需要保持输入
/// 焦点、不新建路由的底部表单/弹层改走 [showOrbitSelectMenu]（宿主须用
/// `PopScope` 兜底返回键）。
///
/// 存量调用点仍走兼容名 `showSelectBottomSheet`，零改动。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import 'orbit_dropdown_panel.dart'
    show
        OrbitPanelItem,
        orbitPanelMaxWidth,
        orbitPanelMinWidth,
        orbitSelectPopupKey;
import 'orbit_glass_surface.dart';
import 'orbit_menu_popup.dart'
    show
        OrbitMenuPopupBody,
        OrbitMenuPopupBodyState,
        OrbitMenuSession,
        showOrbitMenuPopup;

/// 弹层根节点 key（测试定位用；定义与两个入口共用见 `orbit_dropdown_panel.dart`）
export 'orbit_dropdown_panel.dart' show orbitSelectPopupKey;

/// 单选弹层数据项（行首图标 / 12×12 色点 + 文案，二选一）
/// - [icon] + [iconColor]：行首语义图标（快捷视图切换等与清单页图标同源的场景）；
/// - [colorDot]：12px 语义色点（项目 / 优先级等颜色即语义的场景）；
/// - [hint]：次要说明（渲染为 miuix 行的副标题，如「周四, 09:00」）。
class SelectItem<T> {
  const SelectItem({
    required this.value,
    required this.label,
    this.hint,
    this.colorDot,
    this.icon,
    this.iconColor,
  });

  final T value;
  final String label;
  final String? hint;
  final Color? colorDot;
  final IconData? icon;
  final Color? iconColor;
}

/// 行首构件：语义图标优先，其次 12px 色点（两处选择弹层共用）
///
/// 库内行首是 24×24 图标位，直接传 12px 色点会被拉伸成整格，故色点用
/// 居中盒承载；图标尺寸取设计 token，与清单页快捷行同档。
Widget? orbitSelectItemLeading<T>(SelectItem<T> item) {
  if (item.icon != null) {
    return Icon(item.icon, size: AppDimens.iconSizeMd, color: item.iconColor);
  }
  if (item.colorDot != null) {
    return Center(
      child: Container(
        width: AppDimens.colorDotSize,
        height: AppDimens.colorDotSize,
        decoration: BoxDecoration(color: item.colorDot, shape: BoxShape.circle),
      ),
    );
  }
  return null;
}

/// 打开锚定在触发行下方的单选浮层；点选即回调并关闭，点外部/返回键取消。
///
/// [title] 仅作无障碍语义（miuix 下拉面板没有标题行，当前值由对勾表达）。
Future<void> showOrbitSelectPopup<T>(
  BuildContext context, {
  required List<SelectItem<T>> items,
  T? current,
  required ValueChanged<T> onSelect,
  String? title,
  Rect? anchor,
  bool useContextAnchor = true,
}) {
  if (items.isEmpty) return Future<void>.value();
  OrbitPointerAnchor.install();
  final resolvedAnchor =
      anchor ??
      (useContextAnchor ? _anchorFromContext(context) : null) ??
      OrbitPointerAnchor.recentRect;
  // 玻璃采样器在**调用方** context 上取：弹层挂在根 Overlay 上，位于
  // 壳层 OrbitGlassScope 之外（与 `OrbitDropdownPreference` 同一套路）。
  // push 出来的页面（设置子页等）连调用方也取不到 → null，卡面自动走
  // 库内实色填充，观感同「今天」菜单。
  final backdrop = OrbitGlassScope.maybeOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭选择',
    // OS4 菜单不压暗下层（参考图里页面照常可见）。透明 barrier 只负责
    // 无障碍语义；真正的「点外部关闭」由库内弹层自带的拦截层处理，
    // 它挂在根 Overlay 顶部，比这条路由的 barrier 更先命中。
    barrierColor: Colors.transparent,
    // 进场全由库内 dropdown motion 承担，路由只提供一张透明页面；但**不能**
    // 设 zero——路由退场期间那几百毫秒是「点选后页面重建」唯一的帧窗口，
    // 归零会让重建落在最后一帧（调用方在 `onSelect` 里拉取的异步数据没有
    // 机会结算，测试的 mock 延迟 timer 会挂到用例结束）。与旧手搓版 260ms
    // 同档，取 slow。
    transitionDuration: AppMotion.slow,
    pageBuilder: (_, _, _) => _OrbitSelectPopupRoute<T>(
      title: title,
      items: items,
      current: current,
      anchor: resolvedAnchor,
      backdrop: backdrop,
      onPick: onSelect,
    ),
  );
}

/// 单选项的 Overlay 承载版：用于底部表单/弹层内需要全程保持输入焦点的场景。
///
/// 与 [showOrbitSelectPopup] 同一份 [SelectItem] 数据与行渲染，但改走
/// [showOrbitMenuPopup]：不新建路由、不抢焦点，关闭播逆形变。调用方必须
/// 用 `PopScope` 把返回键先归给菜单（Overlay 不消费路由返回）。
///
/// 返回值用于等待 `closed`；点选回调仍立即执行。锚点未显式给出时沿用
/// 「调用方矩形 → 最近指针位置」的回退口径。
OrbitMenuSession showOrbitSelectMenu<T>(
  BuildContext context, {
  String? title,
  required List<SelectItem<T>> items,
  T? current,
  required ValueChanged<T> onSelect,
  Rect? anchor,
  bool useContextAnchor = true,
  double? minWidth,
  double? maxWidth,
  Key? contentKey,
  FocusNode? restoreFocus,
}) {
  assert(items.isNotEmpty, '选择菜单至少需要一个条目');
  OrbitPointerAnchor.install();
  final resolvedAnchor =
      anchor ??
      (useContextAnchor ? _anchorFromContext(context) : null) ??
      OrbitPointerAnchor.recentRect;
  return showOrbitMenuPopup(
    context,
    anchor: resolvedAnchor,
    minWidth: minWidth,
    maxWidth: maxWidth,
    title: title,
    contentKey: contentKey,
    groupsBuilder: () => [
      [
        for (final item in items)
          OrbitPanelItem(
            icon: item.icon,
            iconColor: item.iconColor,
            leading: orbitSelectItemLeading(item),
            label: item.label,
            trailingLabel: item.hint,
            checked: item.value == current,
            onTap: () => onSelect(item.value),
          ),
      ],
    ],
    restoreFocus: restoreFocus ?? FocusManager.instance.primaryFocus,
    backdrop: OrbitGlassScope.maybeOf(context),
  );
}

/// 取 context 对应 RenderObject 的全局矩形作为锚点。
///
/// 只采信「行/按钮尺度」的矩形：页面级 context（Scaffold / 滚动视图）的
/// 矩形接近整屏，用它当锚点会让弹层贴到屏幕角落，不如回退到指针位置。
Rect? _anchorFromContext(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.attached) return null;
  if (!renderObject.hasSize) return null;
  final size = renderObject.size;
  final screen = MediaQuery.sizeOf(context);
  if (size.width < 32 || size.height < 16) return null;
  if (size.width > screen.width * 0.85 || size.height > 320) return null;
  return renderObject.localToGlobal(Offset.zero) & size;
}

/// 最近一次指针按下的全局位置（选择入口的兜底锚点）
///
/// 存量调用点大多只持有页面级 `BuildContext`（Scaffold / 滚动视图），从中
/// 取不到"是哪一行被点"；而选择入口必然发生在一次按下之后。这里用
/// `GestureBinding.pointerRouter` 的全局路由记下最近一次 PointerDown 坐标，
/// 让这些入口也能贴着触发位置弹出，无需逐处改签名传行矩形。
///
/// 安装必须在 `main()` 首帧前完成：懒安装会漏掉「触发本次弹层」的那次按下
/// （2026-11-03 外观页第一次打开落到屏幕底部的根因）。超过 800ms 视为过期，
/// 回退到右上角形态，免得用过时坐标定位。
class OrbitPointerAnchor {
  OrbitPointerAnchor._();

  static Offset? _lastDown;
  static DateTime? _lastAt;
  static bool _installed = false;

  /// 安装全局指针监听（幂等；hot reload 不会重复挂路由）
  static void install() {
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  static void _onPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    _lastDown = event.position;
    _lastAt = DateTime.now();
  }

  /// 最近一次按下的点矩形（1×1）；超出时效或无记录返回 null
  static Rect? get recentRect {
    final point = _lastDown;
    final at = _lastAt;
    if (point == null || at == null) return null;
    if (DateTime.now().difference(at) > const Duration(milliseconds: 800)) {
      return null;
    }
    return point & const Size(1, 1);
  }
}

class _OrbitSelectPopupRoute<T> extends StatefulWidget {
  const _OrbitSelectPopupRoute({
    required this.title,
    required this.items,
    required this.current,
    required this.anchor,
    required this.backdrop,
    required this.onPick,
  });

  /// 无障碍语义（可视区不画标题行）
  final String? title;
  final List<SelectItem<T>> items;
  final T? current;
  final Rect? anchor;

  /// OS4 玻璃背景采样器（调用方从壳层 scope 取；null = 库内实色填充）
  final MiuixLayerBackdrop? backdrop;

  /// 点选：关路由并交回选中值（取消只关路由，不回调）
  final ValueChanged<T> onPick;

  @override
  State<_OrbitSelectPopupRoute<T>> createState() =>
      _OrbitSelectPopupRouteState<T>();
}

class _OrbitSelectPopupRouteState<T> extends State<_OrbitSelectPopupRoute<T>> {
  final _bodyKey = GlobalKey<OrbitMenuPopupBodyState>();

  /// 已关路由（库内拦截层可能重复回调，防二次 pop 误伤下层页面）
  bool _closed = false;

  /// 关掉承载路由
  ///
  /// 库内 presenter 弹出时给本路由挂了一条 `LocalHistoryEntry`（返回键用），
  /// 而 `LocalHistoryRoute.didPop` 会先消费它并返回 **false**——直接 pop 一次
  /// 只会吃掉那条 entry，路由留在栈上（弹层关不掉，调用方的 `await` 也永不
  /// 完成）。故先按 [willHandlePopInternally] 判断：有内部 history 就多 pop
  /// 一次。正常路径也不走 `removeRoute` 抄近路：退场那几百毫秒是「点选后
  /// 页面重建」唯一的帧窗口（调用方在回调里拉取的异步数据要靠它结算）。
  void _closeRoute() {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route == null) return;
    // 点选回调里若已 push 新页，当前栈顶不是弹层：直接摘掉这条透明路由，
    // 绝不能 navigator.pop()（会误关刚打开的页面）。
    if (!route.isCurrent) {
      navigator.removeRoute(route);
      return;
    }
    if (route.willHandlePopInternally) {
      // 第一次只消费库内挂的 LocalHistoryEntry（弹层本身的 onDismissRequest
      // 会因 _closed 已置位而空转）
      navigator.pop();
    }
    if (!mounted) return;
    navigator.pop();
  }

  /// 请求回收：先关面板播逆形变，结束回调里再 pop 路由
  void _requestDismiss() {
    if (_closed) return;
    _closed = true;
    final body = _bodyKey.currentState;
    if (body == null) {
      _closeRoute();
      return;
    }
    body.dismiss();
  }

  void _dismiss() => _requestDismiss();

  void _pick(T value) {
    if (_closed) return;
    _closed = true;
    final body = _bodyKey.currentState;
    if (body == null) {
      _closeRoute();
      widget.onPick(value);
      return;
    }
    body.dismiss();
    widget.onPick(value);
  }

  @override
  Widget build(BuildContext context) {
    // 卡面/行/方向判定/回收动效与 `showOrbitMenuPopup` 共用同一内容件；
    // 本路由只负责「返回键 + 退场完成后 pop」的路由语义。
    return Semantics(
      label: widget.title,
      child: OrbitMenuPopupBody(
        key: _bodyKey,
        anchor: widget.anchor,
        contentKey: orbitSelectPopupKey,
        // 存量路由版 21 处保持既有 180–240 宽度档（新增待办才用底栏「更多」
        // 的库内默认 200–288）
        minWidth: orbitPanelMinWidth,
        maxWidth: orbitPanelMaxWidth,
        backdrop: widget.backdrop,
        onDismiss: _dismiss,
        onDismissFinished: _closeRoute,
        // 单选项的关闭由 `_pick` 自己请求回收；这里不能让面板再关一次，
        // 否则 `_closed` 提前置位会吞掉选中回调。
        itemDismiss: () {},
        groupsBuilder: () => [
          [
            for (final item in widget.items)
              OrbitPanelItem(
                icon: item.icon,
                iconColor: item.iconColor,
                leading: orbitSelectItemLeading(item),
                label: item.label,
                trailingLabel: item.hint,
                checked: item.value == widget.current,
                onTap: () => _pick(item.value),
              ),
          ],
        ],
      ),
    );
  }
}
