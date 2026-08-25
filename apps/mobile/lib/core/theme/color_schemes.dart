import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 亮色与暗色颜色方案工厂
///
/// 根据传入的强调色动态生成 Material 3 ColorScheme。
/// 表面三角色一律引用 [AppColors] 常量，杜绝 seed 漂移（单一真源）：
/// - 页面背景    = surfaceContainerHighest = AppColors.*.background
/// - 卡片/AppBar = surface                = AppColors.*.surface
class ColorSchemes {
  ColorSchemes._();

  /// 根据强调色生成亮色 ColorScheme
  static ColorScheme light(Color accent) {
    return ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
      surface: AppColors.light.surface,
      onSurface: AppColors.light.titleText,
      surfaceContainerHighest: AppColors.light.background,
    );
  }

  /// 根据强调色生成暗色 ColorScheme
  static ColorScheme dark(Color accent) {
    return ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      surface: AppColors.dark.surface,
      onSurface: AppColors.dark.titleText,
      surfaceContainerHighest: AppColors.dark.background,
    );
  }
}
