import 'package:flutter/widgets.dart';

/// 窗口宽度分档（#107 平板/横屏适配）
///
/// 阈值对齐 Material 3 的 compact / medium / expanded：
/// - [compact] < 600：手机竖屏，**现有版式原样**（360dp 回归锚点）；
/// - [medium] 600–839：手机横屏 / 小平板；
/// - [expanded] >= 840：平板横屏 / 桌面分屏宽窗。
///
/// 取 `MediaQuery.sizeOf` 而非 `MediaQuery.of`：只订阅尺寸字段，
/// 键盘弹起等无关变化不会让整棵树重建（与仓库既有的 sizeOf 惯例一致）。
enum OrbitWindowSize { compact, medium, expanded }

abstract final class OrbitBreakpoints {
  static const double mediumMinWidth = 600;
  static const double expandedMinWidth = 840;

  /// 常驻侧栏宽度（expanded 下嵌在主导航左侧；与桌面 220–240 的口径不同，
  /// 移动端行高更大，320 才能容纳「项目名 + 未完成数」不折行）
  static const double sidebarWidth = 320;

  /// 阅读型内容最大宽度（详情/设置/回顾）：超过后居中留白，
  /// 避免平板上文字行宽拉到 1000+ 影响可读性
  static const double contentMaxWidth = 760;

  /// 月历网格最大宽度（>520 后日格会被拉成大方块，圆点与农历副标签的空隙失衡）
  static const double calendarGridMaxWidth = 520;

  /// 列表型内容最大宽度（任务子列表/搜索结果）
  static const double listMaxWidth = 720;

  /// 底部抽屉最大宽度（平板从底部弹出时不要横贯全屏）
  static const double sheetMaxWidth = 640;

  static OrbitWindowSize ofWidth(double width) {
    if (width >= expandedMinWidth) return OrbitWindowSize.expanded;
    if (width >= mediumMinWidth) return OrbitWindowSize.medium;
    return OrbitWindowSize.compact;
  }

  static OrbitWindowSize of(BuildContext context) =>
      ofWidth(MediaQuery.sizeOf(context).width);

  static bool isExpanded(BuildContext context) =>
      of(context) == OrbitWindowSize.expanded;

  /// 宽到可以并排（横屏/平板）：日历双栏、内容居中用
  static bool isWide(BuildContext context) =>
      of(context) != OrbitWindowSize.compact;
}
