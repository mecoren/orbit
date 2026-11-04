/// 单选浮层（miuix 下拉偏好 Overlay 口径，2026-11-03）
///
/// **视觉与交互对齐**：flutter_miuix 的 `DropdownPreference (Overlay)`——
/// - 位置：贴着**触发行的下方**弹出，右沿对齐触发行右沿；下方放不下翻到
///   上方，左右/上下钳在安全区内（不遮住当前值）；
/// - 行：`MiuixDropdownImpl`（与库内下拉同款：未选中**正文色**、选中
///   **强调色文字 + 右端对勾**、首末行内边距由库给）；
/// - 卡面：OS4 玻璃（[OrbitGlassSurface]：有采样器走 shader 玻璃、
///   无采样器退实时模糊），圆角 16（库内列表浮层口径），选项多时可滚
///   （限高 0.6 屏）；
/// - 形变：库内 dropdown motion 同口径——卡面矩形从**触发行矩形**插值到落位
///   矩形（内容等比缩放并贴左上角裁切，锚点比卡面宽时只「揭开」不缩小），
///   260ms easeOutCubic，前 35% 顺带淡入；不压暗下层（OS4 菜单同款）。
///
/// **锚点三级回退**：显式 [anchor] / 调用方 context 是行尺度取自身矩形 /
/// 最近一次指针按下位置（[OrbitPointerAnchor]，`main()` 首帧前安装）。
///
/// 49 处存量调用点仍走兼容名 `showSelectBottomSheet`，零改动。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_elevation.dart';
import 'orbit_glass_surface.dart';

/// 弹层卡片圆角 —— 对齐 miuix 下拉弹层（Overlay）口径
///
/// 取库内 `MiuixListPopupDefaults.cornerRadius`（16）：下拉浮层比对话框/抽屉
/// 更「薄」，24 会显得像抽屉。
const double orbitSelectPopupRadius = 16;

/// 弹层根节点 key（测试定位用；旧 `BottomSheet` 定位已失效）
const Key orbitSelectPopupKey = ValueKey('orbit-select-popup');

/// 弹层与锚点/屏幕边缘的最小间距
const double _gap = 8;

/// 弹层距屏幕左右/底部的最小留白
const double _edge = 12;

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
  // 玻璃采样器在**调用方** context 上取：弹层挂在 Navigator 路由上，位于
  // 壳层 OrbitGlassScope 之外（与 showMoreActionsSheet 同一套路）。push 出来
  // 的页面（设置子页等）连调用方也取不到 → null，卡面自动走实时模糊路径
  final backdrop = OrbitGlassScope.maybeOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭选择',
    // OS4 菜单不压暗下层（参考图里页面照常可见），只留一条透明拦截层
    // 接「点外部关闭」；压暗会把玻璃采样到的背景再蒙一层灰
    barrierColor: Colors.transparent,
    // 形变靠下面 body 自己的「锚点矩形 → 卡面矩形」插值驱动：
    // 路由只提供同一条 animation（进出场同 260ms），不再叠淡入缩放
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (dialogContext, _, _) => _OrbitSelectPopupBody<T>(
      title: title,
      items: items,
      current: current,
      anchor: resolvedAnchor,
      backdrop: backdrop,
      onPick: (value) {
        Navigator.of(dialogContext).pop();
        onSelect(value);
      },
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
/// 回退到底部居中，免得用过时坐标定位。
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

  /// OS4 玻璃背景采样器（调用方从壳层 scope 取；null = 实时模糊路径）
  final MiuixLayerBackdrop? backdrop;
  final ValueChanged<T> onPick;

  @override
  State<_OrbitSelectPopupBody<T>> createState() =>
      _OrbitSelectPopupBodyState<T>();
}

class _OrbitSelectPopupBodyState<T> extends State<_OrbitSelectPopupBody<T>> {
  /// 卡面实测尺寸：首帧在离屏位布局一次取尺寸，拿到后才跑形变
  /// （形变终点就是「卡面矩形」，不知道尺寸无从插值）
  Size? _cardSize;

  final GlobalKey _probeKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureCard());
  }

  void _measureCard() {
    if (!mounted || _cardSize != null) return;
    final box = _probeKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    setState(() => _cardSize = box.size);
  }

  BoxConstraints _cardConstraints(Size screen) => BoxConstraints.loose(
        Size(screen.width - _edge * 2, screen.height * 0.6),
      );

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final screen = MediaQuery.sizeOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final radius = BorderRadius.circular(orbitSelectPopupRadius);

    // 行配色直接吃库内下拉默认值（未选中正文色、选中强调色 + 强调色对勾），
    // 只把行底改透明——卡面由下面的玻璃面承担
    final dropdownColors = MiuixDropdownDefaults.dropdownColors(
      context,
      containerColor: Colors.transparent,
      selectedContainerColor: Colors.transparent,
    );

    final rows = <Widget>[
      for (var i = 0; i < widget.items.length; i++)
        MiuixDropdownImpl(
          item: MiuixDropdownItem(
            text: widget.items[i].label,
            selected: widget.items[i].value == widget.current,
            icon: _leading(widget.items[i], colors),
            summary: widget.items[i].hint,
          ),
          optionSize: widget.items.length,
          isSelected: widget.items[i].value == widget.current,
          index: i,
          isFirst: i == 0,
          isLast: i == widget.items.length - 1,
          dropdownColors: dropdownColors,
          onSelectedIndexChange: (_) => widget.onPick(widget.items[i].value),
        ),
    ];

    // 卡片内容（材质之外的纯内容）：形变期它按等比缩放贴面板左上角裁切，
    // 玻璃面板本身由外层按动画矩形逐帧铺满（见下）
    final content = Material(
      // showGeneralDialog 不像 showDialog / 底部抽屉那样自带 Material：
      // 缺了这层，DefaultTextStyle 落到 MaterialApp 的警告样式，
      // 选项文字下面会画出一条黄线（2026-11-04 外观页截图暴露）。
      // 透明底不上色，卡面由玻璃面承担；这层同时负责圆角裁切
      // （选项滚动时不出卡），key 挂这供测试取卡片矩形。
      key: orbitSelectPopupKey,
      color: Colors.transparent,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        // 选项多时可滚（不把弹层顶出屏幕）
        constraints: BoxConstraints(maxHeight: screen.height * 0.6),
        child: MiuixListPopupColumn(children: rows),
      ),
    );

    final size = _cardSize;
    if (size == null) {
      // 首帧：离屏布局一次取尺寸（Offstage 只排版不上屏），下一帧开始形变
      return Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Offstage(
              child: ConstrainedBox(
                constraints: _cardConstraints(screen),
                child: KeyedSubtree(key: _probeKey, child: content),
              ),
            ),
          ),
        ],
      );
    }

    final placement = _placePopup(
      screen: screen,
      child: size,
      anchor: widget.anchor,
      viewPadding: viewPadding,
    );
    final settled = placement.position & size;
    // 库内 dropdown motion（`miuixGlassPopupFrame`）：面板从落位右上角
    // 一小块（0.69 宽 × 0.2 高，圆角 4）弹到整块（圆角 16），中心同步归位；
    // 内容按 `rect.width / 卡面宽` 等比缩放、贴左上角裁切，所以早期只「揭开」
    // 正在长出来的那块，不会把整张卡缩成一点
    final ratio = size.height / size.width;
    final startWidth = size.width * 0.69;
    final startHeight = startWidth * 0.2;
    final startCenter = placement.alignTop
        ? Offset(settled.right - startWidth / 2, settled.top + startHeight / 2)
        : Offset(settled.right - startWidth / 2, settled.bottom - startHeight / 2);
    final animation = ModalRoute.of(context)?.animation;
    return Semantics(
      label: widget.title,
      child: AnimatedBuilder(
        animation: animation ?? const AlwaysStoppedAnimation<double>(1),
        builder: (context, _) {
          final raw = (animation?.value ?? 1.0).clamp(0.0, 1.0);
          final t = Curves.easeOutCubic.transform(raw);
          final width =
              ui.lerpDouble(startWidth, size.width, t)!.clamp(1.0, 1e5);
          final height = math.max(
            1.0,
            width * ui.lerpDouble(0.2, ratio, t)!,
          );
          final center =
              Offset.lerp(startCenter, settled.center, t)!;
          final rect =
              Rect.fromCenter(center: center, width: width, height: height);
          final animatedRadius =
              ui.lerpDouble(4, orbitSelectPopupRadius, t)!;
          // 内容等比缩放：早期矩形没卡面宽时只揭开一部分，绝不把文字拉小
          final scale = math.min(1.0, rect.width / math.max(size.width, 1));
          // 淡入只占前 35%，形变本身承担「从行尾弹开」的观感
          final opacity = (t / 0.35).clamp(0.0, 1.0);
          final shape = BorderRadius.circular(animatedRadius);
          return Stack(
            children: [
              Positioned.fromRect(
                rect: rect,
                child: DecoratedBox(
                  // 实时模糊路径没有玻璃面板自带的投影，这里补一层
                  // （OS4 采样路径由面板自带，不叠）。投影画在玻璃**之下**：
                  // `BackdropFilter` 只糊自身边界内的背景，卡外那圈投影不受
                  // 影响；卡内那点内溢正好被玻璃盖住。
                  decoration: BoxDecoration(
                    borderRadius: shape,
                    boxShadow: widget.backdrop == null
                        ? AppElevation.e4(Theme.of(context).brightness)
                        : null,
                  ),
                  child: DecoratedBox(
                    // 描边必须画在玻璃**之上**（foreground）。画在下面会被
                    // `BackdropFilter` 连同背景一起高斯糊掉，再被半透明表面色
                    // 洗一遍——2026-11-04 截图里弹层「没有边、糊成一块脏斑」
                    // 的根因。色值吃 `outline` 而非 `popup`（surfaceElevated）：
                    // 浅色下两者都是白，白描边落在白卡上等于没画。
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(
                      borderRadius: shape,
                      border: widget.backdrop == null
                          ? Border.all(color: colors.outline, width: 0.8)
                          : null,
                    ),
                    // 卡面走 [OrbitGlassSurface]，**不要**直接用
                    // `miuixGlassSurface`：后者拿不到采样快照时不回退，库内
                    // 直接填成实色白卡——设置页这类 push 出来的路由挂在 Overlay
                    // 上、与 HomeShell 平级，取不到 `OrbitGlassScope`
                    // （2026-11-04「怎么没变玻璃」的根因）。
                    // 实时路径按 ⋮ 菜单的 puredThinGlass 档调参（sigma 14
                    // 同档、表面白度压低、描边由外层补），别用库默认 0.72 白
                    // ——那档在浅色页面上会糊成一块实色卡。
                    child: OrbitGlassSurface(
                      backdrop: widget.backdrop,
                      borderRadius: shape,
                      realtimeSigma: 16,
                      realtimeSurfaceOpacity: 0.5,
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: size.width,
                        maxWidth: size.width,
                        minHeight: size.height,
                        maxHeight: size.height,
                        child: Opacity(
                          opacity: opacity,
                          child: Transform.scale(
                            scale: scale,
                            alignment: Alignment.topLeft,
                            child: SizedBox(
                              width: size.width,
                              height: size.height,
                              child: content,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 行首图标位：语义图标优先，其次 12px 色点（与抽屉版信息位一致）
  ///
  /// 库内图标位是 26×26 约束盒，直接传 12px 色点会被拉伸成 26px，
  /// 故统一用居中盒承载，保住色点/图标的原始尺寸。
  Widget? _leading(SelectItem<T> item, AppColorSet colors) {
    if (item.icon != null) {
      return SizedBox.square(
        dimension: 26,
        child: Center(
          child: Icon(
            item.icon,
            size: AppDimens.iconSizeMd,
            color: item.iconColor ?? colors.iconText,
          ),
        ),
      );
    }
    if (item.colorDot != null) {
      return SizedBox.square(
        dimension: 26,
        child: Center(
          child: Container(
            width: AppDimens.colorDotSize,
            height: AppDimens.colorDotSize,
            decoration:
                BoxDecoration(color: item.colorDot, shape: BoxShape.circle),
          ),
        ),
      );
    }
    return null;
  }
}

/// 卡面最终落位：锚点下方优先、放不下翻上方；无锚点则底部居中。
///
/// 纯函数：形变动效要拿「落位矩形」当插值终点，不能再藏在 layout delegate 里
/// （delegate 只在排版期存在，动画取不到）。
({Offset position, bool alignTop}) _placePopup({
  required Size screen,
  required Size child,
  required Rect? anchor,
  required EdgeInsets viewPadding,
}) {
  final minX = _edge;
  final maxX = math.max(minX, screen.width - child.width - _edge);
  final minY = _edge + viewPadding.top;
  final maxY =
      math.max(minY, screen.height - child.height - _edge - viewPadding.bottom);
  final anchorRect = anchor;
  if (anchorRect == null) {
    return (
      position: Offset(
        ((screen.width - child.width) / 2).clamp(minX, maxX),
        maxY,
      ),
      alignTop: true,
    );
  }
  final bottomLimit = screen.height - _edge - viewPadding.bottom;
  var y = anchorRect.bottom + _gap;
  var alignTop = true;
  if (y + child.height > bottomLimit) {
    // 下方空间不足 → 翻到锚点上方（形变起点也换到底边）
    y = anchorRect.top - _gap - child.height;
    alignTop = false;
  }
  // 右沿对齐触发行（miuix end 口径）；1px 指针锚点用点击 x，向左下展开
  final x = (anchorRect.width < 32 ? anchorRect.center.dx : anchorRect.right) -
      child.width;
  return (
    position: Offset(x.clamp(minX, maxX), y.clamp(minY, maxY)),
    alignTop: alignTop,
  );
}
