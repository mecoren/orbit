import 'package:flutter/material.dart';

/// 应用阴影海拔 Token（设计系统 v2）
///
/// 旧版 `CardTheme.elevation: 0` + `shadowColor: transparent` 导致卡片完全没有
/// 投影，只能靠 0.3px 边框与几乎同色的底区分——这是"没立体感"的直接来源。
///
/// v2 采用 4 档柔和阴影（冷调 #101828，比纯黑更高级）：
/// - [e1] 列表卡片 / 静态卡片（贴地，极弱）
/// - [e2] 悬浮卡片 / FAB / 强调卡（离地）
/// - [e3] 底部抽屉 / 底部弹层（向上投影）
/// - [e4] 对话框 / 居中弹层（最高）
///
/// 暗色下阴影几乎不可见，故降为极弱黑色，**层次主要靠 [AppColorSet] 的
/// 表面分级 + outline 描边承载**（深色设计系统的通行做法）。
class AppElevation {
  AppElevation._();

  /// 阴影基调色（冷灰蓝，比纯黑柔和）
  static const Color shadowColor = Color(0xFF101828);

  /// 档位 1：列表卡片 / 静态卡片
  static List<BoxShadow> e1(Brightness brightness) =>
      brightness == Brightness.dark
          ? const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 2,
                offset: Offset(0, 1),
              ),
            ]
          : const [
              BoxShadow(
                color: Color(0x0D101828),
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
              BoxShadow(
                color: Color(0x08101828),
                blurRadius: 2,
                offset: Offset(0, 1),
                spreadRadius: -1,
              ),
            ];

  /// 档位 2：悬浮卡片 / FAB / 强调卡
  static List<BoxShadow> e2(Brightness brightness) =>
      brightness == Brightness.dark
          ? const [
              BoxShadow(
                color: Color(0x52000000),
                blurRadius: 8,
                offset: Offset(0, 4),
              ),
            ]
          : const [
              BoxShadow(
                color: Color(0x14101828),
                blurRadius: 6,
                offset: Offset(0, 4),
                spreadRadius: -1,
              ),
              BoxShadow(
                color: Color(0x0F101828),
                blurRadius: 4,
                offset: Offset(0, 2),
                spreadRadius: -2,
              ),
            ];

  /// 档位 3：底部抽屉 / 底部弹层（向上投影）
  static List<BoxShadow> e3(Brightness brightness) =>
      brightness == Brightness.dark
          ? const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 24,
                offset: Offset(0, -4),
              ),
            ]
          : const [
              BoxShadow(
                color: Color(0x1A101828),
                blurRadius: 24,
                offset: Offset(0, -4),
                spreadRadius: -4,
              ),
              BoxShadow(
                color: Color(0x12101828),
                blurRadius: 8,
                offset: Offset(0, -2),
                spreadRadius: -2,
              ),
            ];

  /// 档位 4：对话框 / 居中弹层
  static List<BoxShadow> e4(Brightness brightness) =>
      brightness == Brightness.dark
          ? const [
              BoxShadow(
                color: Color(0x73000000),
                blurRadius: 40,
                offset: Offset(0, 12),
              ),
            ]
          : const [
              BoxShadow(
                color: Color(0x2E101828),
                blurRadius: 48,
                offset: Offset(0, 16),
                spreadRadius: -12,
              ),
              BoxShadow(
                color: Color(0x14101828),
                blurRadius: 16,
                offset: Offset(0, 4),
                spreadRadius: -4,
              ),
            ];

  /// 按档位号（1~4）取阴影，越界回落到 [e1]
  static List<BoxShadow> level(int level, Brightness brightness) {
    switch (level) {
      case 2:
        return e2(brightness);
      case 3:
        return e3(brightness);
      case 4:
        return e4(brightness);
      default:
        return e1(brightness);
    }
  }

  /// 便捷：从 [BuildContext] 取当前亮暗下的指定档位阴影
  static List<BoxShadow> ofContext(BuildContext context, {int level = 1}) =>
      AppElevation.level(level, Theme.of(context).brightness);
}
