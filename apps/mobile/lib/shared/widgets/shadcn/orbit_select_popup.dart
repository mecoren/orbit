/// 单选浮层（**直接复用页头 ⋮ 菜单的同一套面板**，2026-11-03）
///
/// **为什么不再自绘**：前两版用 `showGeneralDialog` + 自研玻璃卡 + 自算锚点，
/// 虽然能跑，但行高、图标列、勾选位、宽度、右上角留白与「今天」页头菜单始终
/// 差一点点，维护两套视觉等于长期漂移。现在改为**照抄页头菜单**：
/// - 内容：`OrbitDropdownPanelView`（同一行渲染：22px 图标列 / 15px 文案 /
///   行尾强调色对勾 / 44 行高 / 组间 1px divider）；
/// - 表面：`OrbitGlassSurface`（OS4 液态玻璃，无快照时实时模糊，不是白卡）；
/// - 位置：右上角、页头下沿——与「今天」页 ⋮ 弹出菜单同一坐标口径；
/// - 交互：点面板外任意处关闭（不铺遮罩），点选项即回调并关闭。
///
/// 49 处存量调用点仍走兼容名 `showSelectBottomSheet`，零改动。
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import 'orbit_dropdown_panel.dart';
import 'orbit_glass_surface.dart';

/// 弹层根节点 key（测试定位用；旧 `BottomSheet` 定位已失效）
const Key orbitSelectPopupKey = ValueKey('orbit-select-popup');

/// 单选弹层数据项（行首图标 / 12×12 色点 + 文案，二选一）
/// - [icon] + [iconColor]：行首语义图标（快捷视图切换等与清单页图标同源的场景）；
/// - [colorDot]：12px 语义色点（项目 / 优先级等颜色即语义的场景）；
/// - [hint]：行尾次要文案（渲染为面板的 trailingLabel，如「周四, 09:00」）。
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

/// 打开右上角玻璃单选菜单；点选即回调并关闭，点外部/返回键取消。
///
/// [title] 仅作无障碍语义（页头菜单不画标题行，当前值由对勾表达）。
///
/// [anchor] / [useContextAnchor] 是**贴行弹出**的扩展点（行式入口可传触发行
/// 矩形），当前统一走「右上角、页头下沿」菜单形态，暂未参与定位。
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
  // 玻璃表面采样壳层内容（与页头菜单同一实例）；设置页这类独立路由取不到
  // 快照时由 OrbitGlassSurface 退实时模糊，仍是透明玻璃而非实色白卡
  final backdrop = OrbitGlassScope.maybeOf(context);
  final topInset =
      MediaQuery.paddingOf(context).top + AppDimens.titleBarHeight;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭选择',
    // 与页头菜单一致：不铺遮罩，下层保持可读
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 170),
    pageBuilder: (dialogContext, _, _) => Semantics(
      label: title,
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: EdgeInsets.only(
            top: topInset + AppDimens.space8,
            right: AppDimens.space8,
          ),
          child: SizedBox(
            key: orbitSelectPopupKey,
            width: orbitFloatCardWidth(context),
            child: OrbitGlassSurface(
              backdrop: backdrop,
              borderRadius: AppShapes.large,
              // 无快照路由的实时路径：默认档在白卡上像实心白壳，压低表面
              // 不透明度 + 提高模糊量才透得出底层内容
              realtimeSigma: 22,
              realtimeSurfaceOpacity: 0.55,
              // 行内的 InkWell 需要 Material 祖先（`OrbitFloatCard` 同款）：
              // 玻璃表面本身不是 Material，缺这层会直接抛
              // "No Material widget found"，行布局塌成异常高度
              child: Material(
                color: Colors.transparent,
                borderRadius: AppShapes.large,
                clipBehavior: Clip.antiAlias,
                child: OrbitDropdownPanelView(
                  groups: [
                    [
                      for (final item in items)
                        OrbitPanelItem(
                          label: item.label,
                          icon: item.icon,
                          iconColor: item.iconColor,
                          leading: item.colorDot == null
                              ? null
                              : _colorDot(item.colorDot!),
                          checked: item.value == current,
                          trailingLabel: item.hint,
                          onTap: () => onSelect(item.value),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
          // 与页头菜单同一生长锚点：从右上角展开
          alignment: Alignment.topRight,
          child: child,
        ),
      );
    },
  );
}

/// 12px 语义色点（行首 22×22 图标列内居中，不会被约束拉伸）
Widget _colorDot(Color color) => Container(
      width: AppDimens.colorDotSize,
      height: AppDimens.colorDotSize,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
