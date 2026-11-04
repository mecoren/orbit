/// 单选浮层（miuix 下拉偏好 Overlay 口径，2026-11-03）
///
/// **视觉与交互对齐**：flutter_miuix 的 `DropdownPreference (Overlay)`——
/// - 位置：贴着**触发行的下方**弹出，右沿对齐触发行右沿；下方放不下翻到
///   上方，左右/上下钳在安全区内（不遮住当前值）；
/// - 行：`MiuixDropdownImpl`（与库内下拉同款：未选中**正文色**、选中
///   **强调色文字 + 右端对勾**、首末行内边距由库给）；
/// - 卡面：OS4 玻璃（`miuixGlassSurface` 菜单档，与页头 ⋮ 面板/
///   [OrbitFloatCard] 同源同档），圆角 16（库内列表浮层口径），选项多时
///   可滚（限高 0.6 屏）。
///
/// **锚点三级回退**：显式 [anchor] / 调用方 context 是行尺度取自身矩形 /
/// 最近一次指针按下位置（[OrbitPointerAnchor]，`main()` 首帧前安装）。
///
/// 49 处存量调用点仍走兼容名 `showSelectBottomSheet`，零改动。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
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
  // 玻璃采样器必须在**调用方** context 上取：弹层挂在 Navigator 路由上，
  // 位于壳层 OrbitGlassScope 之外（与 showMoreActionsSheet 同一套路）；
  // 无壳（测试裸页）取不到 → 库内退实色，几何与交互不受影响
  final backdrop = OrbitGlassScope.maybeOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭选择',
    // miuix 下拉 Overlay 带一档轻遮罩（截图里下层明显压暗）
    barrierColor: Colors.black.withValues(alpha: 0.12),
    transitionDuration: const Duration(milliseconds: 170),
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
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          // 自右上角生长（下拉行右沿对齐，弹层向左下展开）
          alignment: Alignment.topRight,
          child: child,
        ),
      );
    },
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

class _OrbitSelectPopupBody<T> extends StatelessWidget {
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

  /// OS4 玻璃背景采样器（调用方从壳层 scope 取；null = 库内退实色）
  final MiuixLayerBackdrop? backdrop;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final brightness = Theme.of(context).brightness;
    final screen = MediaQuery.sizeOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);

    // 行配色直接吃库内下拉默认值（未选中正文色、选中强调色 + 强调色对勾），
    // 只把行底改透明——卡面由本浮层自己的 DecoratedBox 承担
    final dropdownColors = MiuixDropdownDefaults.dropdownColors(
      context,
      containerColor: Colors.transparent,
      selectedContainerColor: Colors.transparent,
    );

    final rows = <Widget>[
      for (var i = 0; i < items.length; i++)
        MiuixDropdownImpl(
          item: MiuixDropdownItem(
            text: items[i].label,
            selected: items[i].value == current,
            icon: _leading(items[i], colors),
            summary: items[i].hint,
          ),
          optionSize: items.length,
          isSelected: items[i].value == current,
          index: i,
          isFirst: i == 0,
          isLast: i == items.length - 1,
          dropdownColors: dropdownColors,
          onSelectedIndexChange: (_) => onPick(items[i].value),
        ),
    ];

    // OS4 玻璃卡面（与 OrbitFloatCard 同源同档）：puredThinGlass 提到
    // blurRadius 32 的菜单档——不用库默认 popupViewGlass(60)，进场动画期
    // 纹理缓存逐帧失效、每帧重算 sigma≈27 的离屏模糊，真机掉帧明显；
    // 描边/浮层阴影交给 miuixGlassSurface 默认值（shader 自带高光描边，
    // 再手绘 1px 边线会像实色卡片）。
    final surface = miuixGlassSurface(
      backdrop: backdrop,
      material:
          MiuixGlassMaterials.puredThinGlass(brightness == Brightness.dark)
              .copyWith(blurRadius: 32),
      shadow: MiuixGlassShadows.floating,
    );
    return Semantics(
      label: title,
      child: CustomSingleChildLayout(
        delegate: _OrbitSelectPopupLayout(
          anchor: anchor,
          viewPadding: viewPadding,
        ),
        child: surface(
          context,
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(orbitSelectPopupRadius),
          ),
          Material(
            // showGeneralDialog 不像 showDialog / 底部抽屉那样自带 Material：
            // 缺了这层，DefaultTextStyle 落到 MaterialApp 的警告样式，
            // 选项文字下面会画出一条黄线（2026-11-04 外观页截图暴露）。
            // 透明底不上色，卡面由玻璃面承担；这层同时负责圆角裁切
            // （选项滚动时不出卡），key 挂这供测试取卡片矩形。
            key: orbitSelectPopupKey,
            color: colors.popup.withValues(alpha: 0.0),
            borderRadius: BorderRadius.circular(orbitSelectPopupRadius),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              // 选项多时可滚（不把弹层顶出屏幕）
              constraints: BoxConstraints(maxHeight: screen.height * 0.6),
              child: MiuixListPopupColumn(children: rows),
            ),
          ),
        ),
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

/// 弹层定位：锚点下方优先、放不下翻上方；无锚点则底部居中。
class _OrbitSelectPopupLayout extends SingleChildLayoutDelegate {
  _OrbitSelectPopupLayout({required this.anchor, required this.viewPadding});

  final Rect? anchor;
  final EdgeInsets viewPadding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.max(0, constraints.maxWidth - _edge * 2),
          constraints.maxHeight * 0.6,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minX = _edge;
    final maxX = math.max(minX, size.width - childSize.width - _edge);
    final minY = _edge + viewPadding.top;
    final maxY =
        math.max(minY, size.height - childSize.height - _edge - viewPadding.bottom);
    final anchorRect = anchor;
    if (anchorRect == null) {
      return Offset(
        ((size.width - childSize.width) / 2).clamp(minX, maxX),
        maxY,
      );
    }
    final bottomLimit = size.height - _edge - viewPadding.bottom;
    var y = anchorRect.bottom + _gap;
    if (y + childSize.height > bottomLimit) {
      // 下方空间不足 → 翻到锚点上方
      y = anchorRect.top - _gap - childSize.height;
    }
    // 右沿对齐触发行（miuix end 口径）；1px 指针锚点用点击 x，向左下展开
    final x =
        (anchorRect.width < 32 ? anchorRect.center.dx : anchorRect.right) -
            childSize.width;
    return Offset(x.clamp(minX, maxX), y.clamp(minY, maxY));
  }

  @override
  bool shouldRelayout(_OrbitSelectPopupLayout oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.viewPadding != viewPadding;
}
