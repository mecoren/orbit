/// flutter_miuix（HyperOS / OS4）主题桥接层
///
/// **单一来源原则**：本文件不定义任何新色值/尺寸，`MiuixColors` 的 54 个语义
/// 角色全部由 `core/theme` 既有 token（[AppColors] / [OrbitAccents]）派生，
/// 与 Material 侧（`app_theme.dart`）同源；2026-11-01 起移动端组件面全量
/// Miuix 化（shadcn_flutter 退为图标字体源），两套主题并存不再有色板漂移。
///
/// **为什么不用 `MiuixSystemTheme`**：它会读 `MediaQuery.platformBrightness`，
/// 而本项目的亮暗由外观页三态（`theme_mode`：system/light/dark）控制，
/// 强制亮/暗档与系统亮度无关。故这里显式收 [brightness] 参数，
/// 由 `app.dart` 用 `Appearance.themeMode()` 解析后传入。
///
/// **角色映射口径**（与 HyperOS 语义对齐，避免"看起来像但语义不对"）：
/// - `primary`/`onPrimary`：全局强调色 [OrbitAccents.themeAccent]（运行期可被
///   外观页覆盖）+ 白字；Switch / Button / Slider / 选中态都取这一槽。
/// - `surface*` 四档：直接落 [AppColorSet] 的 `surface` / `surfaceSecondary` /
///   `surfaceElevated` 分层，卡片与弹层沿用既有表面层级。
/// - `onSurface*` 三档：标题 → 正文 → 次要文字，与 AppColorSet 三级文字同源。
/// - `outline` / `dividerLine`：分别取组件描边与内容分隔线（两档本就不同色）。
/// - `error*`：破坏性色 [AppColorSet.destructive]（删除/清空类语义）。
/// - `disabled*`：禁用文字 [AppColorSet.deactivatedText] 与分隔线混合，
///   不额外引入灰色。
/// - `windowDimming`：遮罩按亮暗分别 0x73000000 / 0x99000000（Miuix 的
///   对话框/下拉/底部弹层遮罩统一取这一槽）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'app_colors.dart';
import 'orbit_accents.dart';

/// token 色板 → Miuix 语义色（54 个角色全覆盖）
///
/// 所有带透明度的合成色一律经 [Color.alphaBlend] 预合成到对应底色上，
/// 与 Miuix 官方 `mapMd3RolesToMiuixColors` 的"结果全不透明"口径一致。
MiuixColors buildMiuixColors(Brightness brightness) {
  final c = AppColors.of(brightness);
  final accent = OrbitAccents.themeAccent;
  final isDark = brightness == Brightness.dark;
  const onAccent = Color(0xFFFFFFFF);
  const onDestructive = Color(0xFFFFFFFF);

  // 强调色的低透明度容器（chip / 选中底 / 主色变体）
  Color tint(Color base, double alpha, [Color? over]) =>
      Color.alphaBlend(base.withValues(alpha: alpha), over ?? c.surface);

  final primaryContainer = tint(accent, isDark ? 0.20 : 0.12);
  final errorContainer = tint(c.destructive, isDark ? 0.22 : 0.12);
  final secondaryContainer = c.surfaceSecondary;

  return MiuixColors(
    primary: accent,
    onPrimary: onAccent,
    primaryVariant: primaryContainer,
    onPrimaryVariant: isDark ? c.titleText : tint(accent, 0.85),
    error: c.destructive,
    onError: onDestructive,
    errorContainer: errorContainer,
    onErrorContainer: c.destructive,
    // 禁用态：文字统一弱化灰，按钮底回落分隔线色（与 Material 侧同口径）
    disabledPrimary: c.deactivatedText,
    disabledOnPrimary: c.surface,
    disabledPrimaryButton: c.divider,
    disabledOnPrimaryButton: c.deactivatedText,
    disabledPrimarySlider: c.deactivatedText,
    primaryContainer: primaryContainer,
    onPrimaryContainer: isDark ? c.titleText : tint(accent, 0.85),
    secondary: c.surfaceSecondary,
    onSecondary: c.bodyText,
    secondaryVariant: c.surfaceSecondary,
    onSecondaryVariant: c.secondaryText,
    disabledSecondary: c.surfaceSecondary,
    disabledOnSecondary: c.deactivatedText,
    disabledSecondaryVariant: c.surfaceSecondary,
    disabledOnSecondaryVariant: c.deactivatedText,
    secondaryContainer: secondaryContainer,
    onSecondaryContainer: c.bodyText,
    secondaryContainerVariant: c.surfaceSecondary,
    onSecondaryContainerVariant: c.secondaryText,
    tertiaryContainer: c.surfaceSecondary,
    onTertiaryContainer: c.bodyText,
    tertiaryContainerVariant: c.surfaceSecondary,
    // 应用底 / 表面四档：直接落分层表面 token
    background: c.background,
    onBackground: c.titleText,
    onBackgroundVariant: c.secondaryText,
    surface: c.surface,
    onSurface: c.titleText,
    surfaceVariant: c.surfaceSecondary,
    onSurfaceSecondary: c.secondaryText,
    onSurfaceVariantSummary: c.secondaryText,
    onSurfaceVariantActions: c.accent,
    disabledOnSurface: c.deactivatedText,
    surfaceContainer: c.surface,
    onSurfaceContainer: c.titleText,
    onSurfaceContainerVariant: c.secondaryText,
    surfaceContainerHigh: c.surfaceElevated,
    onSurfaceContainerHigh: c.titleText,
    surfaceContainerHighest: c.surfaceSecondary,
    onSurfaceContainerHighest: c.bodyText,
    outline: c.outline,
    dividerLine: c.divider,
    // 遮罩：亮色 45% / 暗色 60% 黑（暗色下表面本身已深，遮罩再重会糊）
    windowDimming:
        isDark ? const Color(0x99000000) : const Color(0x73000000),
    sliderKeyPoint: c.outline,
    sliderKeyPointForeground: c.secondaryText,
    sliderBackground: c.surfaceSecondary,
  );
}

/// 构建 Miuix 主题数据（亮/暗各一份）
///
/// [fontWeightAdjustment] 是 Miuix 的全局字重偏移（100 = 一档）：外观页字重档
/// （w400/w500/w600）换算成 0/100/200 传入，Miuix 组件内的标题/正文随之整体
/// 变粗，与 Material 侧 `Typography.withWeight` 的观感一致。
MiuixThemeData buildMiuixThemeData({
  required Brightness brightness,
  FontWeight baseWeight = FontWeight.w400,
}) =>
    MiuixThemeData(
      colors: buildMiuixColors(brightness),
      textStyles: defaultTextStyles(),
      brightness: brightness,
      fontWeightAdjustment: baseWeight.value - FontWeight.w400.value,
    );

/// 把 Miuix 主题挂到子树（`lib/app.dart` 与测试壳同构装配）
///
/// **位置**：必须挂在 `MaterialApp.builder` 之内、页面之上——Miuix 组件靠
/// `MiuixTheme.of(context)` 取色，且部分组件（TextField 系）需要 MediaQuery。
/// 与 [ShadcnLayer] 是兄弟层而非替代关系：三套体系（Material / shadcn /
/// Miuix）各自读自己的 InheritedWidget，互不覆盖。
///
/// [brightness] 由调用方按 `Appearance.themeMode()` 解析后传入（不读
/// `platformBrightness`，理由见文件头）。
class OrbitMiuixTheme extends StatelessWidget {
  const OrbitMiuixTheme({
    super.key,
    required this.brightness,
    required this.child,
    this.baseWeight = FontWeight.w400,
  });

  final Brightness brightness;
  final FontWeight baseWeight;
  final Widget child;

  @override
  Widget build(BuildContext context) => MiuixTheme(
        data: buildMiuixThemeData(
          brightness: brightness,
          baseWeight: baseWeight,
        ),
        child: child,
      );
}
