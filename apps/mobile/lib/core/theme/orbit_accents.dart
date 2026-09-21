import 'package:flutter/material.dart';

/// Orbit 移动端专属色彩常量（docs/05 §2.2 双强调色 + §七 常量速查卡）
///
/// 与 React 版 `features/todo/shared/constants.ts` 的数值一一对应，
/// Flutter 端为唯一消费方（桌面端仍由 React 维护自己的常量）。
abstract final class OrbitAccents {
  /// 全局主题强调色（OrbitFab / EqSpinner / 链接等）
  /// 对应 React 版 themeAccent = #4E8CFF
  static const Color themeAccent = Color(0xFF4E8CFF);

  /// 待办模块强调色（checkbox 选中、区块标题 accent 等）
  /// 对应 React 版 TODO_ACCENT = #3B82F6
  static const Color todoAccent = Color(0xFF3B82F6);

  /// 逾期红（对应 #F44336）
  static const Color overdueRed = Color(0xFFF44336);

  /// 收藏黄 / 星标（对应 #FACC15）
  static const Color starYellow = Color(0xFFFACC15);

  /// 我的一天琥珀（07 报告新增项，对应桌面 #F59E0B）
  static const Color myDayAmber = Color(0xFFF59E0B);

  /// 完成绿（对应桌面 STATUS_COLOR.done = #22C55E；Logbook 完成日头图标用）
  static const Color doneGreen = Color(0xFF22C55E);
}
