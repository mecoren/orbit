import 'package:flutter/material.dart';

/// 应用圆角 Token（设计系统 v2）
///
/// 参考 SaltUI `SaltShapes`，v2 将圆角调柔和一档（8/12/20 → 6/10/14/20/28），
/// 更贴近现代效率工具的观感（Things / Todoist 类的中等偏大圆角）。
/// 全部成员为 `static const`，可用于 const 上下文。
class AppShapes {
  AppShapes._();

  // ── 半径真值（design system v3：shadcn 主题映射与本文件的 BorderRadius 常量
  //    共用同一组数字，改一处全量生效）──

  /// 特小圆角半径 — 6
  static const double radiusXs = 6;

  /// 小圆角半径 — 10
  static const double radiusSmall = 10;

  /// 中圆角半径 — 14
  static const double radiusMedium = 14;

  /// 大圆角半径 — 20
  static const double radiusLarge = 20;

  /// 超大圆角半径 — 28
  static const double radiusXl = 28;

  /// 特小圆角（微型 chip、徽标、色点底板）— 6
  static const BorderRadius xs = BorderRadius.all(Radius.circular(radiusXs));

  /// 小圆角（标签、小按钮、内嵌 chip）— 10
  static const BorderRadius small =
      BorderRadius.all(Radius.circular(radiusSmall));

  /// 中圆角（卡片、按钮、输入框、列表行）— 14
  static const BorderRadius medium =
      BorderRadius.all(Radius.circular(radiusMedium));

  /// 大圆角（大卡片、区块容器）— 20
  static const BorderRadius large =
      BorderRadius.all(Radius.circular(radiusLarge));

  /// 超大圆角（底部抽屉顶角、Modal 面板）— 28
  static const BorderRadius xl = BorderRadius.all(Radius.circular(radiusXl));

  /// 详情区块容器圆角（与卡片同档）
  static const BorderRadius sectionCard = medium;

  /// 全圆（头像、胶囊）
  static const BorderRadius full = BorderRadius.all(Radius.circular(9999));

  /// 通用方法：按半径构造，保留给少数无法归类的特殊值
  ///
  /// 优先使用 [xs] / [small] / [medium] / [large] / [xl]；
  /// 仅在确实需要特殊圆角时调用此方法。
  static BorderRadius of(double radius) => BorderRadius.circular(radius);
}
