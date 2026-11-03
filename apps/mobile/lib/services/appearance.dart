import 'package:flutter/material.dart';

import '../core/theme/orbit_accents.dart';
import '../shared/utils/hex_color.dart';
import 'local_prefs.dart';

/// 外观偏好（对应桌面 localStorage 主题/字号/字重键）
///
/// 三键全走 [LocalPrefs] 字符串读写（纯字符串落盘，与桌面同编码）：
/// - `theme_mode`：system | light | dark（默认 system 跟随系统）
/// - `font_size_level`：small | standard | large（默认 standard）
/// - `font_weight_level`：regular | medium | bold（默认 regular）
///
/// 值域由读取方校验（脏数据回落默认档）。写后 bump [revision] 触发
/// [OrbitApp] 重建 MaterialApp（首帧前 [LocalPrefs.load] 已载入）。
class Appearance {
  Appearance._();

  static const themeKey = 'theme_mode';
  static const fontSizeKey = 'font_size_level';
  static const fontWeightKey = 'font_weight_level';

  /// 全局强调色（#RRGGBB；缺省 = `OrbitAccents.defaultThemeAccent`，对齐桌面预设板）
  static const accentKey = 'theme_accent_hex';

  /// 外观变更计数器（appearance_page 写后 bump，app 侧监听重建）
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static ThemeMode themeMode() {
    switch (LocalPrefs.getString(themeKey)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String themeLabel() {
    switch (LocalPrefs.getString(themeKey)) {
      case 'light':
        return '浅色';
      case 'dark':
        return '深色';
      default:
        return '跟随系统';
    }
  }

  /// 主题档原始值（system/light/dark）
  ///
  /// 选择弹层的选中判据必须用本值，不能用 [themeLabel] 的中文文案——
  /// 文案与 `SelectItem.value`（英文键）永不相等，弹层里会一项都不打勾。
  static String themeValue() {
    switch (LocalPrefs.getString(themeKey)) {
      case 'light':
        return 'light';
      case 'dark':
        return 'dark';
      default:
        return 'system';
    }
  }

  /// 字号缩放比（small 0.9 / standard 1.0 / large 1.15）
  static double fontScale() {
    switch (LocalPrefs.getString(fontSizeKey)) {
      case 'small':
        return 0.9;
      case 'large':
        return 1.15;
      default:
        return 1.0;
    }
  }

  static String fontSizeLabel() {
    switch (LocalPrefs.getString(fontSizeKey)) {
      case 'small':
        return '小';
      case 'large':
        return '大';
      default:
        return '标准';
    }
  }

  /// 字号档原始值（small/standard/large；选择弹层选中判据）
  static String fontSizeValue() {
    switch (LocalPrefs.getString(fontSizeKey)) {
      case 'small':
        return 'small';
      case 'large':
        return 'large';
      default:
        return 'standard';
    }
  }

  /// 基础字重（regular w400 / medium w500 / bold w600）
  static FontWeight fontWeight() {
    switch (LocalPrefs.getString(fontWeightKey)) {
      case 'medium':
        return FontWeight.w500;
      case 'bold':
        return FontWeight.w600;
      default:
        return FontWeight.w400;
    }
  }

  static String fontWeightLabel() {
    switch (LocalPrefs.getString(fontWeightKey)) {
      case 'medium':
        return '适中';
      case 'bold':
        return '加粗';
      default:
        return '常规';
    }
  }

  /// 字重档原始值（regular/medium/bold；选择弹层选中判据）
  static String fontWeightValue() {
    switch (LocalPrefs.getString(fontWeightKey)) {
      case 'medium':
        return 'medium';
      case 'bold':
        return 'bold';
      default:
        return 'regular';
    }
  }

  static Future<void> setTheme(String value) async {
    await LocalPrefs.setString(themeKey, value);
    revision.value++;
  }

  static Future<void> setFontSize(String value) async {
    await LocalPrefs.setString(fontSizeKey, value);
    revision.value++;
  }

  static Future<void> setFontWeight(String value) async {
    await LocalPrefs.setString(fontWeightKey, value);
    revision.value++;
  }

  /// 启动恢复强调色（`main()` 在 `LocalPrefs.load()` 之后、`runApp` 之前调用）
  ///
  /// 脏值/缺省回落 #4E8CFF；不 bump revision（此时根部还没建）。
  static void restoreAccent() {
    OrbitAccents.applyThemeAccent(
      hexToColor(
        LocalPrefs.getString(accentKey),
        fallback: OrbitAccents.defaultThemeAccent,
      ),
    );
  }

  /// 覆盖全局强调色（`#RRGGBB`）：只改 themeAccent 槽，todoAccent 不动
  static Future<void> setAccent(String hex) async {
    await LocalPrefs.setString(accentKey, hex);
    OrbitAccents.applyThemeAccent(
      hexToColor(hex, fallback: OrbitAccents.defaultThemeAccent),
    );
    revision.value++;
  }
}
