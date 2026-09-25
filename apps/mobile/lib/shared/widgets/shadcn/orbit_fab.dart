import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_elevation.dart';
import '../../../core/theme/icon_map.dart';

/// 悬浮主操作按钮（设计系统 v3：shadcn `Button` 圆形变体承载�?
///
/// �?`OrbitFab` 的「白玻璃（BackdropFilter + 渐变 tint）」随玻璃三件套整体移除；
/// v3 采用 shadcn �?*实心圆形按钮**——按模块强调色填�?+ 白色线性图�?+ e2 柔和
/// 投影（阴影留给浮层元素，FAB 属于浮层语义）�?
///
/// 按实例着色用 shadcn 的组件级主题（`ComponentTheme<PrimaryButtonTheme>`）实现：
/// `ButtonStyle` 只带 variance/size/density/shape 不带颜色，颜色只能经组件主题
/// 或 `decoration` 委托覆盖——这样既保住了 shadcn Button 的按压/悬停/焦点状态机，
/// 又能让待办模块用 [OrbitAccents.todoAccent]、其余模块用全局 primary。
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
    return sh.ComponentTheme<sh.PrimaryButtonTheme>(
      data: sh.PrimaryButtonTheme(
        // 覆盖填充色为模块强调色；圆形状由 ButtonShape.circle 提供
        decoration: (context, states, defaultValue) => ShapeDecoration(
          color: accentColor,
          shape: const CircleBorder(),
          shadows: AppElevation.ofContext(context, level: 2),
        ),
      ),
      child: SizedBox.square(
        dimension: dimension,
        child: sh.Button.primary(
          onPressed: onPressed,
          onLongPressStart: onLongPress == null ? null : (_) => onLongPress!(),
          style: sh.ButtonStyle.primary(shape: sh.ButtonShape.circle),
          child: Icon(
            icon,
            size: AppDimens.iconSizeLg,
            color: const Color(0xFFFFFFFF),
          ),
        ),
      ),
    );
  }
}
