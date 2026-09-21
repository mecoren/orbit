import 'package:flutter/material.dart' hide Typography;

import 'app_colors.dart';
import 'app_dimens.dart';
import 'app_shapes.dart';
import 'color_schemes.dart';
import 'orbit_accents.dart';
import 'typography.dart';

/// 应用主题工厂 —— Material 侧（设计系统 v2 目标：现代分层白卡）
///
/// **设计系统 v3 起本文件只服务 Material 设施**（`Scaffold` /
/// `showModalBottomSheet` / 文本选择 / 滚动条等未迁移或无需迁移的部分）；
/// 面向 shadcn 组件族的那一套主题由 `shadcn_theme.dart` 的 `buildShadcnTheme`
/// 提供，二者从同一份 `core/theme` token 派生，数值同源。
/// 新增视觉规则请优先落到 shadcn 侧。
///
/// v2 相对旧版（wait-home 平移）的关键变化：
/// 1. **色彩分层**：手写 ColorScheme（见 [ColorSchemes]），页面底浅灰 +
///    卡片纯白，取代旧版 `#F3F3F3`/`#F9F9F9` 几乎同色的"糊"；
/// 2. **组件形态**：卡片给圆角 + 极浅描边 + 柔和阴影，输入框/按钮/抽屉/
///    对话框全部重定，摆脱 M3 默认观感；
/// 3. **排版**：`TextTheme` 补齐行高（见 [Typography]），
///    字号缩放改用 `TextTheme.apply(fontSizeFactor:)` 统一处理；
/// 4. **分割线**：0.3px 脏线 → 1px 极浅实线。
///
/// 亮暗由外观页三态控制（theme_mode：system/light/dark，默认跟随系统；
/// 见 services/appearance.dart），此处仅按传入 brightness 生成对应档。
/// 字体使用 Android 系统默认（Roboto），不引入 google_fonts。
ThemeData buildAppTheme({
  required Brightness brightness,
  double fontScale = 1.0,
  FontWeight baseWeight = FontWeight.w400,
}) {
  final isDark = brightness == Brightness.dark;
  final accent = OrbitAccents.themeAccent;
  final colorScheme =
      isDark ? ColorSchemes.dark(accent) : ColorSchemes.light(accent);
  final colors = AppColors.of(brightness);

  // 字号缩放：apply 统一乘 fontScale，行高（height 为倍数）随之等比变化
  final scaled = Typography.textTheme.apply(fontSizeFactor: fontScale);
  final textTheme = Typography.withWeight(scaled, baseWeight);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    textTheme: textTheme,
    // 页面底 = 浅灰（surfaceContainerHighest 已映射到 AppColors.background）
    scaffoldBackgroundColor: colorScheme.surfaceContainerHighest,
    canvasColor: colors.surface,
    dividerColor: colors.divider,
    // 文本选择/光标走强调色（表单质感）
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: 0.22),
      selectionHandleColor: accent,
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: colors.titleText,
      titleTextStyle: textTheme.titleLarge?.copyWith(color: colors.titleText),
    ),
    // 卡片：白底 + 中圆角 + 极浅描边（暗色必需）+ 极弱阴影
    cardTheme: CardThemeData(
      elevation: isDark ? 0 : 1,
      color: colors.surface,
      shadowColor: const Color(0xFF101828),
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.medium,
        side: isDark
            ? BorderSide(color: colors.outline)
            : BorderSide.none,
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: const RoundedRectangleBorder(borderRadius: AppShapes.medium),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppDimens.pageInline,
        vertical: AppDimens.space4,
      ),
      titleTextStyle: textTheme.titleMedium?.copyWith(color: colors.titleText),
      subtitleTextStyle: textTheme.bodySmall?.copyWith(
        color: colors.secondaryText,
      ),
      iconColor: colors.iconText,
    ),
    // 输入框：浅灰填充 + 极浅描边；聚焦时强调色描边 + 表面提亮
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceSecondary,
      hintStyle: textTheme.bodyMedium?.copyWith(color: colors.deactivatedText),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: 14,
      ),
      border: const OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: colors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: accent, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: colors.destructive),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: colors.destructive, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, AppDimens.touchTarget),
        backgroundColor: accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: colors.divider,
        disabledForegroundColor: colors.deactivatedText,
        elevation: 0,
        shadowColor: Colors.transparent,
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
        side: BorderSide(color: accent.withValues(alpha: 0.45)),
        shape: const RoundedRectangleBorder(
          borderRadius: AppShapes.medium,
        ),
        textStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
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
        textStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: isDark ? 0 : 3,
      highlightElevation: isDark ? 0 : 4,
      backgroundColor: accent,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: AppShapes.of(18)),
    ),
    // 分割线：1px 极浅实线，替代旧版 0.3px 脏线
    dividerTheme: DividerThemeData(
      thickness: 1,
      space: 1,
      color: colors.divider,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark ? colors.surfaceElevated : const Color(0xFF272C36),
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
      actionTextColor: isDark ? accent : const Color(0xFF9DBBFF),
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: AppShapes.medium),
    ),
    // 悬浮提示统一主题色底白字（对齐桌面 ui/tooltip.tsx 原语 bg-primary 口径）
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
      shape: const RoundedRectangleBorder(borderRadius: AppShapes.full),
      backgroundColor: accent.withValues(alpha: 0.10),
      labelStyle: textTheme.labelMedium?.copyWith(color: accent),
      side: BorderSide.none,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space8,
        vertical: AppDimens.space2,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return OrbitAccents.todoAccent;
        }
        return Colors.transparent;
      }),
      checkColor: WidgetStateProperty.all(Colors.white),
      side: BorderSide(color: colors.outline),
      shape: RoundedRectangleBorder(borderRadius: AppShapes.of(5)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return accent;
        }
        return colors.iconText;
      }),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          // 纯色强调色，避免低对比度导致看不清选中状态
          return accent;
        }
        return colors.iconText.withValues(alpha: isDark ? 0.35 : 0.30);
      }),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      trackOutlineWidth: WidgetStateProperty.all(0),
      materialTapTargetSize: MaterialTapTargetSize.padded,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStateProperty.all(colors.surfaceElevated),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shape: WidgetStateProperty.all(
          const RoundedRectangleBorder(borderRadius: AppShapes.medium),
        ),
      ),
    ),
    // 底部抽屉默认皮肤（调用点显式传参时以显式为准）
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surfaceElevated,
      modalBackgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    // 对话框：大圆角 + 白底 + 无 M3 色调叠加
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space24,
        vertical: AppDimens.space24,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppShapes.xl),
      titleTextStyle: textTheme.titleLarge?.copyWith(color: colors.titleText),
      contentTextStyle:
          textTheme.bodyMedium?.copyWith(color: colors.bodyText),
    ),
    // ── 全局滚动条（悬浮细滑块：轨道透明、圆角胶囊、hover/按下加深）──
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
          return colors.iconText.withValues(alpha: 0.55);
        }
        if (states.contains(WidgetState.hovered)) {
          return colors.iconText.withValues(alpha: 0.45);
        }
        return colors.iconText.withValues(alpha: 0.30);
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
