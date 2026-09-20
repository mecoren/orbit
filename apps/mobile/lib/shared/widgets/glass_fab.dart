import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_elevation.dart';
import '../../core/theme/app_shapes.dart';
import 'alpha_indication.dart';

/// 悬浮按钮（白玻璃配方 v2）
///
/// v2 相对旧版（wait-home 玻璃 FAB）的变化：
/// - tint 从 alpha 0.15 提到 0.82 —— 白色磨砂块，而非几乎全透的"水膜"；
/// - 模糊 sigma 18 → 14（高不透明度下无需重度模糊，省 GPU）；
/// - 新增 [AppElevation] 柔和阴影 —— FAB 从页面"浮起来"，不再贴平；
/// - 圆角统一到设计系统 [AppShapes.large]，与卡片族同形。
///
/// 交互反馈仍使用 [AlphaIndication]（无 ripple 的 alpha 指示），保持
/// "轻点即走"的移动端手感。
class GlassFab extends StatelessWidget {
  const GlassFab({
    super.key,
    required this.onPressed,
    required this.accentColor,
    this.onLongPress,
    this.icon = Icons.add_rounded,
  });

  /// 点击回调
  final VoidCallback onPressed;

  /// 长按回调（可空；无长按语义的调用点不传即无长按）
  final VoidCallback? onLongPress;

  /// 强调色（图标颜色）
  final Color accentColor;

  /// 图标，默认 add_rounded
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final colors = AppColors.of(brightness);

    return Container(
      width: _GlassFabDefaults.size,
      height: _GlassFabDefaults.size,
      // 阴影必须放在裁剪层之外，否则会被 ClipRRect 裁掉
      decoration: BoxDecoration(
        borderRadius: _GlassFabDefaults.shape,
        boxShadow: AppElevation.e2(brightness),
      ),
      child: ClipRRect(
        borderRadius: _GlassFabDefaults.shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _GlassFabDefaults.blurSigma,
            sigmaY: _GlassFabDefaults.blurSigma,
          ),
          child: AlphaIndication(
            onTap: onPressed,
            onLongPress: onLongPress,
            borderRadius: _GlassFabDefaults.shape,
            child: Container(
              decoration: BoxDecoration(
                color: colors.surface.withValues(
                  alpha: isDark ? 0.86 : 0.82,
                ),
                borderRadius: _GlassFabDefaults.shape,
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.10)
                      : colors.outline,
                  width: _GlassFabDefaults.borderWidth,
                ),
              ),
              child: Center(
                child: Icon(
                  icon,
                  color: accentColor,
                  size: _GlassFabDefaults.iconSize,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [GlassFab] 默认值集中管理
class _GlassFabDefaults {
  _GlassFabDefaults._();

  /// FAB 尺寸
  static const double size = AppDimens.fabSize;

  /// 玻璃模糊 sigma（高不透明度白玻璃，无需重度模糊）
  static const double blurSigma = AppDimens.blurFab;

  /// 圆角（与卡片族同形制）
  static const BorderRadius shape = AppShapes.large;

  /// 图标尺寸
  static const double iconSize = 26;

  /// 边框宽度
  static const double borderWidth = 0.8;
}
