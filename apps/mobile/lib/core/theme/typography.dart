import 'package:flutter/material.dart';

/// 字体排版规范（设计系统 v2）
///
/// v2 核心变化：**为每一档补齐 `height`（行高倍数）**。
/// 旧版只有 `fontSize`，行高吃系统默认，导致多行文字与标题行距拥挤、
/// 段落贴在一起——这是"内容拥挤"观感的直接来源。v2 按内容类型给出行高：
/// - 展示/标题类 1.2 ~ 1.4（紧致，成块）
/// - 正文类 1.45 ~ 1.5（舒展，可读）
/// - 标签类 1.35 ~ 1.4（紧凑）
///
/// 字体族使用 Android 系统默认（Roboto），不引入 google_fonts。
class Typography {
  Typography._();

  /// 基础 TextTheme（含行高）
  static const TextTheme textTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: 32,
      height: 1.2,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.5,
    ),
    displayMedium: TextStyle(
      fontSize: 28,
      height: 1.2,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.3,
    ),
    displaySmall: TextStyle(
      fontSize: 24,
      height: 1.25,
      fontWeight: FontWeight.w500,
    ),
    headlineLarge: TextStyle(
      fontSize: 22,
      height: 1.3,
      fontWeight: FontWeight.w600,
    ),
    headlineMedium: TextStyle(
      fontSize: 20,
      height: 1.3,
      fontWeight: FontWeight.w600,
    ),
    headlineSmall: TextStyle(
      fontSize: 18,
      height: 1.35,
      fontWeight: FontWeight.w600,
    ),
    titleLarge: TextStyle(
      fontSize: 17,
      height: 1.4,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: TextStyle(
      fontSize: 15,
      height: 1.4,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: TextStyle(
      fontSize: 13,
      height: 1.4,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: TextStyle(
      fontSize: 15,
      height: 1.5,
      fontWeight: FontWeight.w400,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      height: 1.5,
      fontWeight: FontWeight.w400,
    ),
    bodySmall: TextStyle(
      fontSize: 13,
      height: 1.45,
      fontWeight: FontWeight.w400,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      height: 1.4,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      height: 1.35,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      height: 1.35,
      fontWeight: FontWeight.w500,
    ),
  );

  /// 应用自定义字重到 TextTheme
  ///
  /// 正文/标签跟随用户选择的 [baseWeight]；标题层保留固定字重（w500/w600），
  /// 避免整屏字重被拉平时层级塌陷。
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
