import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'orbit_accents.dart';

/// 亮色与暗色颜色方案工厂（设计系统 v2）
///
/// **v2 不再使用 `ColorScheme.fromSeed`**：seed 推导会让 `primary` / 各
/// `surfaceContainer*` 角色漂移出设计值（历史踩坑：日历选中色被漂成灰蓝
/// `#455E91`）。v2 改为**手写整套 ColorScheme**，每个角色都显式取自
/// [AppColors]，保证"单一真源、零漂移"。
///
/// 角色映射：
/// - `surface`                  = 卡片（纯白 / 深色卡）
/// - `surfaceContainerHighest`  = 页面底（浅灰 / 深灰）
/// - `surfaceContainer*`        = 嵌套区（微灰）
/// - `outline` / `outlineVariant` = 描边 / 分割线
/// - `primary`                  = themeAccent（不再漂移）
/// - `secondary`                = todoAccent（模块身份色）
class ColorSchemes {
  ColorSchemes._();

  /// 阴影基调色（与 [AppElevation.shadowColor] 同源，此处内联避免循环依赖）
  static const Color _shadow = Color(0xFF101828);

  /// 亮色方案
  static ColorScheme light(Color accent) =>
      _build(Brightness.light, accent, AppColors.light);

  /// 暗色方案
  static ColorScheme dark(Color accent) =>
      _build(Brightness.dark, accent, AppColors.dark);

  static ColorScheme _build(
    Brightness brightness,
    Color accent,
    AppColorSet c,
  ) {
    final isDark = brightness == Brightness.dark;
    const todoAccent = OrbitAccents.todoAccent;

    return ColorScheme(
      brightness: brightness,
      // ── 主色 = 全局主题强调色（显式给定，杜绝 seed 漂移）──
      primary: accent,
      onPrimary: Colors.white,
      primaryContainer: accent.withValues(alpha: 0.14),
      onPrimaryContainer: accent,
      // ── 次色 = 待办模块色 ──
      secondary: todoAccent,
      onSecondary: Colors.white,
      secondaryContainer: todoAccent.withValues(alpha: 0.14),
      onSecondaryContainer: todoAccent,
      tertiary: accent,
      onTertiary: Colors.white,
      // ── 错误 ──
      error: c.destructive,
      onError: Colors.white,
      errorContainer: c.destructive.withValues(alpha: 0.14),
      onErrorContainer: c.destructive,
      // ── 表面分层（v2 核心）──
      surface: c.surface,
      onSurface: c.titleText,
      onSurfaceVariant: c.secondaryText,
      surfaceContainerLowest: c.surface,
      surfaceContainerLow: c.surface,
      surfaceContainer: c.surfaceSecondary,
      surfaceContainerHigh: c.surfaceSecondary,
      surfaceContainerHighest: c.background,
      // ── 描边 ──
      outline: c.outline,
      outlineVariant: c.divider,
      // ── 其他 ──
      shadow: _shadow,
      scrim: Colors.black,
      inverseSurface: isDark ? c.surface : c.titleText,
      onInverseSurface: isDark ? c.titleText : c.surface,
      inversePrimary: accent,
    );
  }
}
