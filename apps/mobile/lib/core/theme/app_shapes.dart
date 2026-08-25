import 'package:flutter/material.dart';

/// 应用圆角 Token
///
/// 参考 SaltUI `SaltShapes`：8 / 12 / 20 三档核心圆角集中化。
/// 全部成员为 `static const`，可用于 const 上下文。
class AppShapes {
  AppShapes._();

  /// 小圆角（图标占位、tag、输入框内 chip）— 8
  static const BorderRadius small = BorderRadius.all(Radius.circular(8));

  /// 中圆角（卡片、按钮、输入框、ListTile）— 12
  static const BorderRadius medium = BorderRadius.all(Radius.circular(12));

  /// 大圆角（底部抽屉顶部、大卡片）— 20
  static const BorderRadius large = BorderRadius.all(Radius.circular(20));

  /// 详情区块容器圆角 — 12（docs/05 §四：SectionCard）
  static const BorderRadius sectionCard = medium;

  /// 全圆（头像）
  static const BorderRadius full = BorderRadius.all(Radius.circular(9999));

  /// 通用方法：按半径构造，保留给少数无法归类的特殊值
  ///
  /// 优先使用 [small] / [medium] / [large]；仅在确实需要特殊圆角时调用此方法。
  static BorderRadius of(double radius) => BorderRadius.circular(radius);
}
