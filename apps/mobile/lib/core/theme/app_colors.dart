import 'package:flutter/material.dart';

/// 应用颜色 Token（设计系统 v2 —— 现代分层白卡）
///
/// 旧版（wait-home 平移）的层次问题：页面底 `#F3F3F3` 与卡片 `#F9F9F9`
/// 仅差 2.4%，叠加 `elevation: 0` 无阴影 + 0.3px 脏分割线，整屏糊成一片。
///
/// v2 分层模型（浅灰底 + 纯白卡片，建立明确的空间深度）：
/// - [background]       页面底（浅灰，退后）
/// - [surface]          卡片/列表容器（纯白，前进）——与页面底拉开明确对比
/// - [surfaceSecondary] 卡片内嵌套区 / 按下态（微灰，再退一档）
/// - [surfaceElevated]  弹层 / 抽屉（与卡片同色，靠阴影与页面底分离）
/// - [outline]          组件边框（极浅，用于卡片/输入框描边）
/// - [divider]          内容分隔线（比 outline 更浅）
///
/// 文字三级：[titleText] 主 → [bodyText] 正文 → [secondaryText] 次 → [deactivatedText] 弱。
///
/// 双色板结构（参考 SaltUI `SaltDynamicColors(light, dark)`）：
/// [AppColors.light] / [AppColors.dark] 为两套常量色板，[AppColors.of] /
/// [AppColors.ofContext] 按 [Brightness] 路由；派生色 [AppColorSet.elevated]
/// 用 [Color.alphaBlend] 计算，避免重复定义。
@immutable
class AppColorSet {
  /// 页面背景色（浅灰底）
  final Color background;

  /// 卡片/表面背景色（纯白/深色卡片）
  final Color surface;

  /// 次要表面色（嵌套区、圆形按钮底、按下态）
  final Color surfaceSecondary;

  /// 弹层表面色（底部抽屉、对话框、toast 浮层）
  final Color surfaceElevated;

  /// 组件边框色（卡片/输入框描边，极浅）
  final Color outline;

  /// 强调色（数字/链接/重要文字，非 Material primary）
  final Color accent;

  /// 标题文字色
  final Color titleText;

  /// 正文文字色
  final Color bodyText;

  /// 副标题/次要文字色
  final Color secondaryText;

  /// 图标/次要图标色
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
    required this.surfaceElevated,
    required this.outline,
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

  /// 派生：弹层背景色（v2 直接采用 elevated 表面，靠阴影与背景分离）
  Color get popup => surfaceElevated;

  /// 派生：升起表面色（卡片悬浮/强调态）= 微量强调色叠在表面上
  Color get elevated =>
      Color.alphaBlend(accent.withValues(alpha: 0.04), surface);

  /// 派生：按下态表面 = 微量黑色叠在表面上（比 surfaceSecondary 更直接）
  Color get pressed =>
      Color.alphaBlend(Colors.black.withValues(alpha: 0.045), surface);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppColorSet &&
          background == other.background &&
          surface == other.surface &&
          surfaceSecondary == other.surfaceSecondary &&
          surfaceElevated == other.surfaceElevated &&
          outline == other.outline &&
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
  int get hashCode => Object.hashAll([
        background,
        surface,
        surfaceSecondary,
        surfaceElevated,
        outline,
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
      ]);
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

  /// 亮色模式色板（现代分层白卡）
  ///
  /// 页面底 `#F5F6F8`（浅灰、微冷）↔ 卡片 `#FFFFFF`（纯白）——明度差约 4%，
  /// 叠加 [AppElevation.e1] 柔和阴影后层次清晰；边框走极浅 `#E4E8EF`，
  /// 避免旧版深灰 `#C5C9D3` 在浅底上产生的"脏线"观感。
  static const AppColorSet light = AppColorSet(
    background: Color(0xFFF5F6F8),
    surface: Color(0xFFFFFFFF),
    surfaceSecondary: Color(0xFFF2F4F7),
    surfaceElevated: Color(0xFFFFFFFF),
    outline: Color(0xFFE4E8EF),
    accent: Color(0xFF4E8CFF),
    titleText: Color(0xFF171A21),
    bodyText: Color(0xFF303642),
    secondaryText: Color(0xFF5F6875),
    iconText: Color(0xFF8A93A1),
    deactivatedText: Color(0xFFA8B0BC),
    divider: Color(0xFFECEEF3),
    dismissibleBackground: Color(0xFF3A4556),
    success: Color(0xFF16A34A),
    warning: Color(0xFFF59E0B),
    destructive: Color(0xFFE11D48),
  );

  /// 暗色模式色板（分层深灰：不用纯黑，避免 OLED 上"死黑"与过强对比）
  static const AppColorSet dark = AppColorSet(
    background: Color(0xFF0F1115),
    surface: Color(0xFF181B21),
    surfaceSecondary: Color(0xFF21252C),
    surfaceElevated: Color(0xFF22262E),
    outline: Color(0xFF2E343D),
    accent: Color(0xFF6E9BFF),
    titleText: Color(0xFFEDEFF3),
    bodyText: Color(0xFFC7CDD8),
    secondaryText: Color(0xFF98A1B0),
    iconText: Color(0xFF6F7889),
    deactivatedText: Color(0xFF545C6B),
    divider: Color(0xFF262B33),
    dismissibleBackground: Color(0xFF1A1D24),
    success: Color(0xFF22C55E),
    warning: Color(0xFFF59E0B),
    destructive: Color(0xFFF43F5E),
  );

  /// 按 [Brightness] 路由到对应色板
  static AppColorSet of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// 按 [BuildContext] 路由到对应色板
  static AppColorSet ofContext(BuildContext context) =>
      of(Theme.of(context).brightness);
}
