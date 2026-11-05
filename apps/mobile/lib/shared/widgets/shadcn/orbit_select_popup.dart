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
/// **关闭立即生效**（不播逆形变）：49 处存量调用点都是
/// `await showSelectBottomSheet(...)` 后立即写库/导航，等收起动画播完再回调会
/// 改变既有交互时序；点选与取消都直接 pop 路由，与 2026-11-03 起的旧实现
/// 逐帧一致。
///
/// 49 处存量调用点仍走兼容名 `showSelectBottomSheet`，零改动。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import 'orbit_dropdown_panel.dart' show orbitPanelMaxWidth, orbitPanelMinWidth;
import 'orbit_glass_surface.dart';

/// 弹层根节点 key（测试定位用；挂在条目列根上）
///
/// 承载是库内 dropdown 后，这里的矩形在进场落定后 = 卡面矩形
/// （`GlassPopupLayout` 以内容尺寸布局、按帧缩放绘制），`getRect` 语义不变；
/// 但 `MiuixGlassPanel` 与内容在库内是**兄弟**（同在 `GlassPopupLayout` 里），
/// 不再是内容的祖先。
const Key orbitSelectPopupKey = ValueKey('orbit-select-popup');

/// 弹层与触发行之间的呼吸位（并进锚点矩形，见 `_anchorBounds`）
const double _gap = 8;

/// 弹层距屏幕右/上边的最小留白（仅无锚点兜底形态用）
const double _edge = 12;

/// 无锚点时距状态栏的下移量（页头高度档，与 ⋮ 菜单落位同惯例）
const double _noAnchorTopInset = 56;

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
    return Icon(
      item.icon,
      size: AppDimens.iconSizeMd,
      color: item.iconColor,
    );
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
  final resolvedAnchor = anchor ??
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
    pageBuilder: (_, _, _) => _OrbitSelectPopupBody<T>(
      title: title,
      items: items,
      current: current,
      anchor: resolvedAnchor,
      backdrop: backdrop,
      onPick: onSelect,
    ),
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

class _OrbitSelectPopupBody<T> extends StatefulWidget {
  const _OrbitSelectPopupBody({
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
  State<_OrbitSelectPopupBody<T>> createState() =>
      _OrbitSelectPopupBodyState<T>();
}

class _OrbitSelectPopupBodyState<T> extends State<_OrbitSelectPopupBody<T>> {
  /// 已关路由（库内拦截层可能重复回调，防二次 pop 误伤下层页面）
  bool _closed = false;

  /// 关掉承载路由
  ///
  /// 库内 presenter 弹出时给本路由挂了一条 `LocalHistoryEntry`（返回键用），
  /// 而 `LocalHistoryRoute.didPop` 会先消费它并返回 **false**——直接 pop 一次
  /// 只会吃掉那条 entry，路由留在栈上（弹层关不掉，调用方的 `await` 也永不
  /// 完成）。故先按 [willHandlePopInternally] 判断：有内部 history 就多 pop
  /// 一次。**不能**用 `removeRoute` 抄近路：它会跳过退场动画，而退场那几百
  /// 毫秒是「点选后页面重建」唯一的帧窗口（调用方在回调里拉取的异步数据要
  /// 靠它结算）。
  void _closeRoute() {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route != null && route.willHandlePopInternally) {
      // 第一次只消费库内挂的 LocalHistoryEntry（弹层本身的 onDismissRequest
      // 会因 _closed 已置位而空转）
      navigator.pop();
    }
    if (!mounted) return;
    navigator.pop();
  }

  /// 卡面材质（与 ⋮ 菜单同档：puredThinGlass + blurRadius 32；按亮暗各
  /// 缓存一份，值相等是库内纹理缓存的性能要件）
  static final _materialLight = MiuixGlassMaterials.puredThinGlassLight
      .copyWith(blurRadius: 32);
  static final _materialDark = MiuixGlassMaterials.puredThinGlassDark.copyWith(
    blurRadius: 32,
  );

  static MiuixGlassMaterial _popupMaterial(bool isDark) =>
      isDark ? _materialDark : _materialLight;

  void _dismiss() {
    if (_closed) return;
    _closed = true;
    _closeRoute();
  }

  void _pick(T value) {
    if (_closed) return;
    _closed = true;
    _closeRoute();
    widget.onPick(value);
  }

  /// 锚点矩形（库内 dropdown 口径：`y = 锚点 top`、右沿对齐锚点右沿，
  /// 故把 [gap] 并进「行下沿零高度矩形」，与 `OrbitDropdownPreference` 同款）
  ///
  /// 无锚点（指针按下已超过 800ms 的程序化调用）走右上角形态，与页头 ⋮
  /// 菜单同一落位惯例。
  Rect _anchorBounds(Size screen) {
    final rect = widget.anchor;
    if (rect != null) {
      return Rect.fromLTWH(rect.left, rect.bottom + _gap, rect.width, 0);
    }
    final top = MediaQuery.viewPaddingOf(context).top;
    return Rect.fromLTWH(screen.width - _edge, top + _noAnchorTopInset, 0, 0);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MiuixGlassDropdownPopup(
      show: true,
      anchorBounds: _anchorBounds(screen),
      backdrop: widget.backdrop,
      // 宽度与全站弹出菜单同档（180–240）；高度限 0.6 屏，选项多时可滚
      sizing: MiuixGlassPopupSizing(
        minWidth: orbitPanelMinWidth,
        maxWidth: orbitPanelMaxWidth,
        maxHeight: screen.height * 0.6,
      ),
      visuals: MiuixGlassPopupVisuals(material: _popupMaterial(isDark)),
      onDismissRequest: _dismiss,
      child: Semantics(
        label: widget.title,
        child: Column(
          key: orbitSelectPopupKey,
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
    );
  }
}
