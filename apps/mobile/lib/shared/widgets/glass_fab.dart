import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import 'alpha_indication.dart';

/// 液态玻璃风格浮动按钮
///
/// 自 wait-home/mobile 移植，对应 orbit React 版 glass-fab.tsx：
/// - BackdropFilter sigma 18 + alpha 0.15 极低透明度
/// - 细微边框 + 底部折射高光线（亮 [0,.85,1,.85,0] / 暗 [0,.30,.45,.30,0]）
/// - 图标使用强调色
///
/// 交互反馈使用 [AlphaIndication]（无 ripple 的 alpha 指示）。
class GlassFab extends StatelessWidget {
  const GlassFab({
    super.key,
    required this.onPressed,
    required this.accentColor,
    this.icon = Icons.add_rounded,
  });

  /// 点击回调
  final VoidCallback onPressed;

  /// 强调色（图标颜色）
  final Color accentColor;

  /// 图标，默认 add_rounded
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      width: _GlassFabDefaults.size,
      height: _GlassFabDefaults.size,
      child: ClipRRect(
        borderRadius: _GlassFabDefaults.shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _GlassFabDefaults.blurSigma,
            sigmaY: _GlassFabDefaults.blurSigma,
          ),
          child: AlphaIndication(
            onTap: onPressed,
            borderRadius: _GlassFabDefaults.shape,
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? AppColors.dark.surface.withValues(alpha: 0.15)
                    : const Color(0xFFFFFFFF).withValues(alpha: 0.15),
                borderRadius: _GlassFabDefaults.shape,
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.black.withValues(alpha: 0.06),
                  width: _GlassFabDefaults.borderWidth,
                ),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Icon(
                      icon,
                      color: accentColor,
                      size: _GlassFabDefaults.iconSize,
                    ),
                  ),
                  // 底部折射高光线（docs/05 §三：1px 五段 alpha）
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      width: double.infinity,
                      height: _GlassFabDefaults.highlightHeight,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: isDark
                              ? [
                                  Colors.white.withValues(alpha: 0.0),
                                  Colors.white.withValues(alpha: 0.30),
                                  Colors.white.withValues(alpha: 0.45),
                                  Colors.white.withValues(alpha: 0.30),
                                  Colors.white.withValues(alpha: 0.0),
                                ]
                              : [
                                  Colors.white.withValues(alpha: 0.0),
                                  Colors.white.withValues(alpha: 0.85),
                                  Colors.white.withValues(alpha: 1.0),
                                  Colors.white.withValues(alpha: 0.85),
                                  Colors.white.withValues(alpha: 0.0),
                                ],
                        ),
                      ),
                    ),
                  ),
                ],
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

  /// 玻璃模糊 sigma（docs/05：blur18）
  static const double blurSigma = AppDimens.blurFab;

  /// 圆角（与设计系统 [AppShapes.medium] 统一为 12）
  static const BorderRadius shape = AppShapes.medium;

  /// 图标尺寸
  static const double iconSize = AppDimens.iconSizeXl;

  /// 边框宽度
  static const double borderWidth = 0.5;

  /// 底部折射高光线高度
  static const double highlightHeight = 1;
}
