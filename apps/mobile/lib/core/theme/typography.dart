import 'package:flutter/material.dart';

/// 字体排版规范
///
/// 自 wait-home/mobile 移植的统一 Material TextTheme（支持动态字重）。
class Typography {
  Typography._();

  /// 基础 TextTheme（Android 默认字体族为 Roboto，无需引入 google_fonts）
  static const TextTheme textTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.5,
    ),
    displayMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w400,
    ),
    displaySmall: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w400,
    ),
    headlineLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w500,
    ),
    headlineMedium: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w500,
    ),
    headlineSmall: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w500,
    ),
    titleLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
    ),
    labelSmall: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
    ),
  );

  /// 应用自定义字重到 TextTheme
  static TextTheme withWeight(TextTheme base, FontWeight baseWeight) {
    return base.copyWith(
      displayLarge: base.displayLarge?.copyWith(fontWeight: baseWeight),
      displayMedium: base.displayMedium?.copyWith(fontWeight: baseWeight),
      displaySmall: base.displaySmall?.copyWith(fontWeight: baseWeight),
      headlineLarge: base.headlineLarge?.copyWith(fontWeight: baseWeight),
      headlineMedium: base.headlineMedium?.copyWith(fontWeight: baseWeight),
      headlineSmall: base.headlineSmall?.copyWith(fontWeight: baseWeight),
      titleLarge: base.titleLarge?.copyWith(fontWeight: baseWeight),
      titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w500),
      titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w500),
      bodyLarge: base.bodyLarge?.copyWith(fontWeight: baseWeight),
      bodyMedium: base.bodyMedium?.copyWith(fontWeight: baseWeight),
      bodySmall: base.bodySmall?.copyWith(fontWeight: baseWeight),
      labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w500),
      labelMedium: base.labelMedium?.copyWith(fontWeight: FontWeight.w500),
      labelSmall: base.labelSmall?.copyWith(fontWeight: FontWeight.w500),
    );
  }
}

/// TextTheme 扩展，用于动态获取应用的字重（ThemeExtension）
class AppTypographyConfig extends ThemeExtension<AppTypographyConfig> {
  final FontWeight baseFontWeight;

  const AppTypographyConfig({required this.baseFontWeight});

  @override
  AppTypographyConfig copyWith({FontWeight? baseFontWeight}) {
    return AppTypographyConfig(
      baseFontWeight: baseFontWeight ?? this.baseFontWeight,
    );
  }

  @override
  AppTypographyConfig lerp(AppTypographyConfig? other, double t) {
    if (other == null) return this;
    return AppTypographyConfig(
      baseFontWeight: FontWeight.lerp(baseFontWeight, other.baseFontWeight, t)!,
    );
  }
}
