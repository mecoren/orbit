/// shadcn 主题映射层（设计系统 v3 —�?shadcn New York 语言�?
///
/// **单一来源原则**：本文件不定义任何新色�?尺寸，全部由 `core/theme/` 既有
/// token（[AppColors] / [AppShapes] / [AppDimens] / [OrbitAccents] / [Typography]�?
/// 派生。改设计只改 token，Material 侧（`app_theme.dart`）与 shadcn 侧同步生效�?
///
/// **命名冲突**：shadcn �?`ThemeData` / `Typography` / `ColorScheme` �?Material
/// 同名，故本文件对 material �?`m.` 前缀、对 shadcn �?`sh.` 前缀导入�?
/// 全仓库沿用该约定（其它文件若同时用到两者，shadcn 一�?`as sh` 前缀导入）�?
///
/// **为什么不�?MaterialShadcnApp**：其依赖�?`shadcn_flutter_material` 全库�?
/// 0.0.54 一版，硬要�?Dart �?.13 / Flutter �?.47，本仓库�?Flutter 3.44.2 无法
/// 解析；改�?`MaterialApp.router` + `builder` 内包 `ShadcnLayer`（shadcn 官方
/// 文档对「已�?MaterialApp」场景的推荐接入方式）�?
library;

import 'dart:ui' show Color;

import 'package:flutter/material.dart' as m;
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import 'app_colors.dart';
import 'app_dimens.dart';
import 'app_shapes.dart';
import 'orbit_accents.dart';

/// shadcn 圆角基准倍数
///
/// shadcn �?`radius` �?*倍数**：`radiusMd = radius × 12`、`radiusXxl = radius × 24`�?
/// �?`AppShapes.radiusMedium / 12`�? 14/12）后�?
/// - `radiusMd  = 14` = [AppShapes.radiusMedium]（卡�?按钮/输入框）
/// - `radiusXxl = 28` = [AppShapes.radiusXl]（底部抽屉顶�?/ Modal 面板�?
/// 即两个最常用档位与既�?token 精确对齐，中间档位按比例落在 6~28 之间�?
const double kShadcnRadiusBase = AppShapes.radiusMedium / 12;

/// 构建一�?shadcn 主题（亮/暗各构建一份，�?`OrbitApp` 同时喂给 [ShadcnLayer]�?
///
/// - [brightness] 决定取哪�?token 色板（[AppColors.of]�?
/// - [baseWeight] 外观页字重档（w400 / w500 / w600），只作用于正文类字�?
///   （标题类字阶的权重是语义的一部分，不随用户偏好漂移）
sh.ThemeData buildShadcnTheme({
  required m.Brightness brightness,
  m.FontWeight baseWeight = m.FontWeight.w400,
}) {
  return sh.ThemeData(
    colorScheme: buildShadcnColorScheme(brightness),
    radius: kShadcnRadiusBase,
    typography: buildShadcnTypography(baseWeight: baseWeight),
    iconTheme: kShadcnIconTheme,
  );
}

/// token 色板 �?shadcn 语义色角�?
///
/// 角色映射口径（与 shadcn/ui 的语义保持一致，避免"看起来像但语义不�?）：
/// - `background`/`card`/`popover`：三层表面，直接�?[AppColorSet] �?
///   `background` / `surface` / `surfaceElevated`
/// - `primary`�?*全局唯一主色** = [AppColorSet.accent]（亮 #4E8CFF / �?#6E9BFF�?
///   �?[OrbitAccents.themeAccent] 的亮度自适应档）
/// - `accent`：shadcn 语义是「悬�?选中底色」而非"强调�?，故�?`surfaceSecondary`�?
///   业务侧需要的强调色（链接、数字）仍从 [OrbitAccents] 取，两者不要混�?
/// - `muted`/`secondary`：同�?`surfaceSecondary`（shadcn �?muted �?secondary
///   在浅色下本就同值，分开只是给暗色留调整空间�?
/// - `destructive` / `ring` / `border` / `input`：状态色与描边色直取 token
/// - `chart1..5`：统计页色阶，主色打头，后接状态色（成�?警告/我的一�?完成绿）
sh.ColorScheme buildShadcnColorScheme(m.Brightness brightness) {
  final c = AppColors.of(brightness);
  return sh.ColorScheme(
    brightness: brightness,
    background: c.background,
    foreground: c.titleText,
    card: c.surface,
    cardForeground: c.titleText,
    popover: c.surfaceElevated,
    popoverForeground: c.titleText,
    primary: c.accent,
    primaryForeground: _onPrimary,
    secondary: c.surfaceSecondary,
    secondaryForeground: c.bodyText,
    muted: c.surfaceSecondary,
    mutedForeground: c.secondaryText,
    accent: c.surfaceSecondary,
    accentForeground: c.titleText,
    destructive: c.destructive,
    destructiveForeground: _onPrimary,
    border: c.outline,
    input: c.outline,
    ring: c.accent,
    chart1: OrbitAccents.todoAccent,
    chart2: c.success,
    chart3: c.warning,
    chart4: OrbitAccents.myDayAmber,
    chart5: OrbitAccents.doneGreen,
  );
}

/// 主色/破坏色之上的前景色（两种模式下主色都是中深蓝/玫红，统一用白字）
const Color _onPrimary = Color(0xFFFFFFFF);

/// token 字阶 �?shadcn 排版体系
///
/// - 字体族固�?Roboto（系统字体，仓库不引 google_fonts），覆盖 shadcn 默认�?
///   Geist 三处出口：`sans` / `mono` / `inlineCode`——其余字阶（xSmall…x9Large�?
///   �?shadcn 里本就不�?fontFamily，靠继承，所以只需覆盖这三个出�?
/// - 缩放后仍保证「行高是倍数」的语义不丢（shadcn 的字阶默认不�?height�?
///   逐行高度由组件自身的 padding/lineHeight 决定�?
/// 字号缩放不在此层做：由 app.dart 注入全局 TextScaler 后，shadcn 字阶与内联
/// TextStyle 同时生效，故本函数不收 fontScale 参数（原先的 typography.scale
/// 会在 TextScaler 之上被乘两次）
sh.Typography buildShadcnTypography({
  m.FontWeight baseWeight = m.FontWeight.w400,
}) {
  const geist = sh.Typography.geist();
  var typography = geist.copyWith(
    sans: () => const m.TextStyle(fontFamily: 'Roboto'),
    mono: () => const m.TextStyle(fontFamily: 'RobotoMono'),
    inlineCode: () => const m.TextStyle(
      fontFamily: 'RobotoMono',
      fontSize: 14,
      fontWeight: m.FontWeight.w600,
    ),
  );

  // 字重档只作用于正文类字阶；h1~h4 / textLarge 等标题类字阶保持语义权重
  if (baseWeight != m.FontWeight.w400) {
    final src = typography;
    typography = src.copyWith(
      sans: () => src.sans.copyWith(fontWeight: baseWeight),
      base: () => src.base.copyWith(fontWeight: baseWeight),
      p: () => src.p.copyWith(fontWeight: baseWeight),
      small: () => src.small.copyWith(fontWeight: baseWeight),
      xSmall: () => src.xSmall.copyWith(fontWeight: baseWeight),
      large: () => src.large.copyWith(fontWeight: baseWeight),
      xLarge: () => src.xLarge.copyWith(fontWeight: baseWeight),
      textMuted: () => src.textMuted.copyWith(fontWeight: baseWeight),
    );
  }

  return typography;
}

/// 图标尺寸�?�?shadcn `IconThemeProperties`
///
/// 映射到既�?token：small 18 / medium 22 / large 24 / xLarge 28
/// （[AppDimens.iconSizeSm] / Md / Lg / Xl）。注�?shadcn �?`xLarge` 默认�?32�?
/// 此处收窄�?28 以对齐仓库既有图标阶梯，其余档位保留 shadcn 默认�?
const sh.IconThemeProperties kShadcnIconTheme = sh.IconThemeProperties(
  small: m.IconThemeData(size: AppDimens.iconSizeSm),
  medium: m.IconThemeData(size: AppDimens.iconSizeMd),
  large: m.IconThemeData(size: AppDimens.iconSizeLg),
  xLarge: m.IconThemeData(size: AppDimens.iconSizeXl),
);
