import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/icon_map.dart';

/// 悬浮主操作按钮（flutter_miuix `MiuixFloatingActionButton` 承载）
///
/// **2026-11-01 换承载**：shadcn `Button.primary`（圆形变体 + 组件级主题
/// 覆盖填色）换成 miuix FAB——squircle 引擎同源的 `StadiumBorder`（正方形
/// bounds 下为正圆）、`MiuixPressable` 弹簧按压遮罩与库内阴影公式（HyperOS
/// 规格：elevation 4、黑 15% 投影），按实例填色走 [MiuixFloatingActionButton.containerColor]
/// 直接传强调色，不再需要绕组件主题。
///
/// **2026-11-05 玻璃档**（[glass]）：与悬浮底栏同源的 OS4 液态玻璃——底栏是
/// `MiuixGlassMaterials.puredThinGlass` + 999 圆角胶囊，本钮同材质、同圆角
/// （圆形钮取 999 即正圆）。玻璃版**不填强调色**，图标转主题色（玻璃卡面上
/// 白字会糊掉），按压/长按语义不变。没有采样器时回落实色主题色底白字（与
/// 旧实心档一致，不会黑屏）。
///
/// 长按语义（模板新建）miuix FAB 无此参数，经外层 `GestureDetector` 补上：
/// FAB 内部的 `MiuixPressable` 不注册长按手势（onLongPress 传 null 不进
/// 手势竞技场），外层识别器无竞争、正常触发。
class OrbitFab extends StatelessWidget {
  const OrbitFab({
    super.key,
    required this.onPressed,
    required this.accentColor,
    this.onLongPress,
    this.icon = OrbitIcons.add,
    this.dimension = AppDimens.fabSize,
    this.glass = false,
    this.backdrop,
  });

  /// 点击回调
  final VoidCallback onPressed;

  /// 长按回调（可空；无长按语义的调用点不传即无长按）
  final VoidCallback? onLongPress;

  /// 强调色（实心档作填充底色；玻璃档作图标色）
  final Color accentColor;

  /// 图标，默认 plus
  final IconData icon;

  /// 圆钮边长（默认悬浮钮规格 56；底部导航中央凸起钮用 48 小档）
  final double dimension;

  /// 是否走 OS4 玻璃材质（与悬浮底栏同档；见文件头）
  final bool glass;

  /// 玻璃档的背景采样器（null = 回落实色档）
  final MiuixLayerBackdrop? backdrop;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 玻璃档：材质取底栏同款（puredThinGlass + 999 圆角 = 正圆）
    final hasGlass = glass && backdrop != null;
    final iconColor = hasGlass ? accentColor : const Color(0xFFFFFFFF);
    final content = Icon(icon, size: AppDimens.iconSizeLg, color: iconColor);
    final button = hasGlass
        // 玻璃档：`MiuixPressable` 承载点击与弹簧按压（与实心档 miuix FAB
        // 同源的 pressDown/pressUp 弹簧），玻璃面板本身不吃手势
        ? MiuixPressable(
            onPressed: onPressed,
            borderRadius: BorderRadius.circular(dimension / 2),
            child: SizedBox(
              width: dimension,
              height: dimension,
              child: MiuixGlassPanel(
                backdrop: backdrop,
                material: MiuixGlassMaterials.puredThinGlass(isDark),
                shape: const MiuixGlassShape(cornerRadius: 999),
                // 与底栏同档：栏体类表面，材质即本体不叠折射着色
                shading: false,
                child: Center(child: content),
              ),
            ),
          )
        : MiuixFloatingActionButton(
            onPressed: onPressed,
            // 圆钮直径 = dimension（minWidth/minHeight 同时钉住）
            minWidth: dimension,
            minHeight: dimension,
            // 内容色不跟随库内 onSurface（miuix FAB 内容色继承 Surface 默认值），
            // 按既有口径恒白
            containerColor: accentColor,
            child: content,
          );
    return GestureDetector(onLongPress: onLongPress, child: button);
  }
}
