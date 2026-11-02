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
  });

  /// 点击回调
  final VoidCallback onPressed;

  /// 长按回调（可空；无长按语义的调用点不传即无长按）
  final VoidCallback? onLongPress;

  /// 强调色（填充底色；图标恒为白色）
  final Color accentColor;

  /// 图标，默认 plus
  final IconData icon;

  /// 圆钮边长（默认悬浮钮规格 56；底部导航中央凸起钮用 48 小档）
  final double dimension;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onLongPress,
      child: MiuixFloatingActionButton(
        onPressed: onPressed,
        // 圆钮直径 = dimension（minWidth/minHeight 同时钉住）
        minWidth: dimension,
        minHeight: dimension,
        // 内容色不跟随库内 onSurface（miuix FAB 内容色继承 Surface 默认值），
        // 按既有口径恒白
        containerColor: accentColor,
        child: Icon(
          icon,
          size: AppDimens.iconSizeLg,
          color: const Color(0xFFFFFFFF),
        ),
      ),
    );
  }
}
