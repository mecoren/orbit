import 'package:flutter/material.dart';

/// 应用颜色 Token
///
/// 自 wait-home/mobile 移植（My Diary 设计 Token 体系），
/// 数值与 orbit docs/05《UI复刻规格-移动端》§2.2 完全一致。
///
/// 双色板结构（参考 SaltUI `SaltDynamicColors(light, dark)`）：
/// - [AppColorSet] 持有一套完整色板（亮色或暗色）
/// - [AppColors.light] / [AppColors.dark] 为两套常量色板
/// - [AppColors.of] / [AppColors.ofContext] 按 [Brightness] 路由
/// - 派生色（[AppColorSet.popup] / [AppColorSet.elevated]）用 [Color.alphaBlend]
///   计算，避免重复定义
@immutable
class AppColorSet {
  /// 页面背景色
  final Color background;

  /// 卡片/表面背景色
  final Color surface;

  /// 次要表面色（圆形按钮背景、图标背景）
  final Color surfaceSecondary;

  /// 强调色（数字/链接/重要文字，非 Material primary）
  final Color accent;

  /// 标题文字色
  final Color titleText;

  /// 正文文字色
  final Color bodyText;

  /// 副标题/次要文字色
  final Color secondaryText;

  /// 图标/禁用文字色
  final Color iconText;

  /// 完全禁用文字色
  final Color deactivatedText;

  /// 分割线色
  final Color divider;

  /// 滑动删除背景色
  final Color dismissibleBackground;

  /// 成功状态色（toast/alert 变体、成功徽标）
  final Color success;

  /// 警告状态色
  final Color warning;

  /// 破坏性操作色（删除按钮、危险确认）
  final Color destructive;

  const AppColorSet({
    required this.background,
    required this.surface,
    required this.surfaceSecondary,
    required this.accent,
    required this.titleText,
    required this.bodyText,
    required this.secondaryText,
    required this.iconText,
    required this.deactivatedText,
    required this.divider,
    required this.dismissibleBackground,
    required this.success,
    required this.warning,
    required this.destructive,
  });

  /// 派生：弹层背景色 = 半透明表面色叠在背景上
  Color get popup =>
      Color.alphaBlend(surface.withValues(alpha: 0.92), background);

  /// 派生：升起表面色（卡片悬浮态）= 微量强调色叠在表面上
  Color get elevated =>
      Color.alphaBlend(accent.withValues(alpha: 0.04), surface);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppColorSet &&
          background == other.background &&
          surface == other.surface &&
          surfaceSecondary == other.surfaceSecondary &&
          accent == other.accent &&
          titleText == other.titleText &&
          bodyText == other.bodyText &&
          secondaryText == other.secondaryText &&
          iconText == other.iconText &&
          deactivatedText == other.deactivatedText &&
          divider == other.divider &&
          dismissibleBackground == other.dismissibleBackground &&
          success == other.success &&
          warning == other.warning &&
          destructive == other.destructive;

  @override
  int get hashCode => Object.hash(
        background,
        surface,
        surfaceSecondary,
        accent,
        titleText,
        bodyText,
        secondaryText,
        iconText,
        deactivatedText,
        divider,
        dismissibleBackground,
        success,
        warning,
        destructive,
      );
}

/// 应用颜色 Token 入口
///
/// 使用方式：
/// ```dart
/// final colors = AppColors.ofContext(context);
/// Text('标题', style: TextStyle(color: colors.titleText));
/// ```
class AppColors {
  AppColors._();

  // ──────── 双色板 ────────

  /// 亮色模式色板（与 orbit React 版 html[data-platform=mobile] token 一致）
  static const AppColorSet light = AppColorSet(
    background: Color(0xFFF3F3F3),
    surface: Color(0xFFF9F9F9),
    surfaceSecondary: Color(0xFFF5F6F8),
    accent: Color(0xFF4E8CFF),
    titleText: Color(0xFF1A1D26),
    bodyText: Color(0xFF2C3240),
    secondaryText: Color(0xFF6B7685),
    iconText: Color(0xFF8B95A5),
    deactivatedText: Color(0xFF8B95A5),
    divider: Color(0xFFC5C9D3),
    dismissibleBackground: Color(0xFF3A4556),
    success: Color(0xFF16A34A),
    warning: Color(0xFFF59E0B),
    destructive: Color(0xFFE11D48),
  );

  /// 暗色模式色板（OLED 风：真黑页面底 + #181818 卡面）
  static const AppColorSet dark = AppColorSet(
    background: Color(0xFF000000),
    surface: Color(0xFF181818),
    surfaceSecondary: Color(0xFF222222),
    accent: Color(0xFF5B7FFF),
    titleText: Color(0xFFEAECF0),
    bodyText: Color(0xFFCDD2DA),
    secondaryText: Color(0xFF8B92A5),
    iconText: Color(0xFF6B7394),
    deactivatedText: Color(0xFF4B5068),
    divider: Color(0xFF4D5262),
    dismissibleBackground: Color(0xFF1A1D2E),
    success: Color(0xFF16A34A),
    warning: Color(0xFFF59E0B),
    destructive: Color(0xFFE11D48),
  );

  /// 按 [Brightness] 路由到对应色板
  static AppColorSet of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// 按 [BuildContext] 路由到对应色板
  static AppColorSet ofContext(BuildContext context) =>
      of(Theme.of(context).brightness);
}
