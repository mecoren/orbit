import 'package:flutter/material.dart';

/// Orbit 移动端专属色彩常量（docs/05 §2.2 双强调色 + §七 常量速查卡）
///
/// 与 React 版 `features/todo/shared/constants.ts` 的数值一一对应，
/// Flutter 端为唯一消费方（桌面端仍由 React 维护自己的常量）。
abstract final class OrbitAccents {
  /// 主题强调色默认值（OrbitFab / OrbitSpinner / 链接等）
  /// 对应 React 版 themeAccent = #4E8CFF
  static const Color defaultThemeAccent = Color(0xFF4E8CFF);

  /// 全局主题强调色。
  ///
  /// 运行期可被外观页「强调色」覆盖（#107）：改成非 final 静态字段后，
  /// `Appearance.revision` 一 bump 根部即重建，全库 70+ 处引用无需逐个改签名。
  /// **只动这一个槽**——[todoAccent]、六档优先级色、状态色一律不跟随。
  static Color themeAccent = defaultThemeAccent;

  /// 应用强调色（外观页与启动恢复调用；调用方负责 bump `Appearance.revision`）
  static void applyThemeAccent(Color color) {
    themeAccent = color;
  }

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
