import 'package:flutter/material.dart' hide Typography;

import 'app_colors.dart';
import 'app_dimens.dart';
import 'app_shapes.dart';
import 'color_schemes.dart';
import 'orbit_accents.dart';
import 'typography.dart';

/// 应用主题工厂
///
/// 自 wait-home/mobile 移植并裁剪：
/// - 强调色固定为 OrbitAccents.themeAccent（#4E8CFF，docs/05 §2.2），
///   暗色由 ColorScheme.fromSeed 自动调整；
/// - 亮暗由外观页三态控制（theme_mode：system/light/dark，默认跟随系统；
///   见 services/appearance.dart），此处仅按传入 brightness 生成对应档；
/// - 字号经 fontScale 等比缩放全文阶，字重经 baseWeight 统一正文/标题基重
///   （Typography.withWeight 口径）；
/// - 字体使用 Android 系统默认（Roboto），不引入 google_fonts.
///
/// 参考 shrimpsend 的 buildAppTheme 模式。
ThemeData buildAppTheme({
  required Brightness brightness,
  double fontScale = 1.0,
  FontWeight baseWeight = FontWeight.w400,
}) {
  final isDark = brightness == Brightness.dark;
  final accent = OrbitAccents.themeAccent;
  final colorScheme =
      isDark ? ColorSchemes.dark(accent) : ColorSchemes.light(accent);

  // 使用 AppColors Token 值作为增强默认色
  final colorSet = AppColors.of(brightness);
  final effectiveOnSurface = colorSet.bodyText;
  final effectiveOnSurfaceVariant = colorSet.secondaryText;
  final effectiveDividerColor = colorSet.divider;
  final effectiveColorScheme = colorScheme.copyWith(
    onSurface: effectiveOnSurface,
    onSurfaceVariant: effectiveOnSurfaceVariant,
  );

  // 外观页字号/字重：先等比缩放字阶，再统一基重（标题/标签行保留 w500/w600
  // 层级，见 Typography.withWeight）
  final scaled = Typography.textTheme.copyWith(
    displayLarge: Typography.textTheme.displayLarge
        ?.copyWith(fontSize: 32 * fontScale),
    displayMedium: Typography.textTheme.displayMedium
        ?.copyWith(fontSize: 28 * fontScale),
    displaySmall: Typography.textTheme.displaySmall
        ?.copyWith(fontSize: 24 * fontScale),
    headlineLarge: Typography.textTheme.headlineLarge
        ?.copyWith(fontSize: 22 * fontScale),
    headlineMedium: Typography.textTheme.headlineMedium
        ?.copyWith(fontSize: 20 * fontScale),
    headlineSmall: Typography.textTheme.headlineSmall
        ?.copyWith(fontSize: 18 * fontScale),
    titleLarge: Typography.textTheme.titleLarge
        ?.copyWith(fontSize: 16 * fontScale),
    titleMedium: Typography.textTheme.titleMedium
        ?.copyWith(fontSize: 14 * fontScale),
    titleSmall: Typography.textTheme.titleSmall
        ?.copyWith(fontSize: 12 * fontScale),
    bodyLarge: Typography.textTheme.bodyLarge
        ?.copyWith(fontSize: 16 * fontScale),
    bodyMedium: Typography.textTheme.bodyMedium
        ?.copyWith(fontSize: 14 * fontScale),
    bodySmall: Typography.textTheme.bodySmall
        ?.copyWith(fontSize: 12 * fontScale),
    labelLarge: Typography.textTheme.labelLarge
        ?.copyWith(fontSize: 14 * fontScale),
    labelMedium: Typography.textTheme.labelMedium
        ?.copyWith(fontSize: 12 * fontScale),
    labelSmall: Typography.textTheme.labelSmall
        ?.copyWith(fontSize: 10 * fontScale),
  );
  final textTheme = Typography.withWeight(scaled, baseWeight);

  // 页面背景 = surfaceContainerHighest（亮色 #F3F3F3，暗色 #000000）
  // 卡片/AppBar/弹层 = surface（亮色 #F9F9F9，暗色 #181818）
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: effectiveColorScheme,
    textTheme: textTheme,
    scaffoldBackgroundColor: colorScheme.surfaceContainerHighest,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      backgroundColor: colorScheme.surface,
      foregroundColor: effectiveOnSurface,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: effectiveOnSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.of(16),
      ),
      color: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    listTileTheme: const ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.medium,
      ),
      contentPadding: EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space4,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark
          ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
          : colorScheme.surfaceContainerHighest,
      border: const OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(
          color: effectiveOnSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: 14,
      ),
      hintStyle: TextStyle(
        color: effectiveOnSurfaceVariant.withValues(alpha: 0.6),
        fontSize: 14,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, AppDimens.touchTarget),
        backgroundColor: accent,
        foregroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: AppShapes.medium,
        ),
        textStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, AppDimens.touchTarget),
        foregroundColor: accent,
        side: BorderSide(color: accent.withValues(alpha: 0.5)),
        shape: const RoundedRectangleBorder(
          borderRadius: AppShapes.medium,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, AppDimens.touchTarget),
        foregroundColor: accent,
        shape: const RoundedRectangleBorder(
          borderRadius: AppShapes.medium,
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: isDark ? 0 : 2,
      backgroundColor: accent,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.of(16),
      ),
    ),
    dividerTheme: DividerThemeData(
      thickness: 0.3,
      space: 0.3,
      color: effectiveDividerColor.withValues(alpha: 0.8),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.of(10),
      ),
    ),
    // 悬浮提示统一主题色底白字（对齐桌面 ui/tooltip.tsx 原语 bg-primary 口径；
    // 热力图/表单优先级等原生 Tooltip 不再走默认灰底）
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: accent,
        borderRadius: AppShapes.of(8),
      ),
      textStyle: textTheme.bodySmall?.copyWith(
        color: Colors.white,
        fontSize: 12,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    chipTheme: ChipThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: AppShapes.large,
      ),
      backgroundColor: accent.withValues(alpha: 0.1),
      labelStyle: textTheme.labelMedium?.copyWith(
        color: accent,
      ),
      side: BorderSide.none,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return OrbitAccents.todoAccent;
        }
        return Colors.transparent;
      }),
      checkColor: WidgetStateProperty.all(Colors.white),
      side: BorderSide(
        color: effectiveOnSurfaceVariant.withValues(alpha: 0.5),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.of(4),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return accent;
        }
        return effectiveOnSurfaceVariant.withValues(alpha: 0.5);
      }),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          // 纯色强调色，避免低对比度导致看不清选中状态
          return accent;
        }
        return isDark
            ? effectiveOnSurfaceVariant.withValues(alpha: 0.35)
            : effectiveOnSurfaceVariant.withValues(alpha: 0.3);
      }),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      trackOutlineWidth: WidgetStateProperty.all(0),
      materialTapTargetSize: MaterialTapTargetSize.padded,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStateProperty.all(colorScheme.surface),
      ),
    ),
    // ── 全局滚动条（qraft 同款悬浮细滑块风格）──
    // 轨道透明、圆角胶囊滑块、hover/按下加深；悬浮于内容之上
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.dragged)) return 6;
        if (states.contains(WidgetState.hovered)) return 6;
        return 4;
      }),
      thumbVisibility: const WidgetStatePropertyAll(false),
      radius: const Radius.circular(999),
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.dragged)) {
          return effectiveOnSurfaceVariant.withValues(alpha: 0.45);
        }
        if (states.contains(WidgetState.hovered)) {
          return effectiveOnSurfaceVariant.withValues(alpha: 0.4);
        }
        return effectiveOnSurfaceVariant.withValues(alpha: 0.28);
      }),
      trackVisibility: const WidgetStatePropertyAll(false),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
    ),
    extensions: [
      const AppTypographyConfig(baseFontWeight: FontWeight.w400),
    ],
  );
}
