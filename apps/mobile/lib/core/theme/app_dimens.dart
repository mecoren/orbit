/// 应用间距 / 尺寸 / 模糊 Token（设计系统 v2）
///
/// 参考 SaltUI `SaltDimens`：私有构造 + `static const` 集中管理。
/// 刻度基于 4pt 子网格（8pt 主网格），并提供一批**语义命名**供页面统一节奏，
/// 避免各页各自挑选 `spaceN` 导致留白不均。
///
/// 动效参数（时长 / 曲线）不在本文件，见 [AppMotion]；阴影海拔见 [AppElevation]。
class AppDimens {
  AppDimens._();

  // ── 间距刻度（spacing scale，4pt 子网格）──
  /// 极小间隙（徽标与文字间）
  static const double space2 = 2;

  /// 极小间隙（图标与文字间）
  static const double space4 = 4;

  /// 小间隙内部细间距
  static const double space6 = 6;

  /// 小间隙（图标与文字、行内元素）
  static const double space8 = 8;

  /// 紧凑内边距（行内卡片、chip）
  static const double space12 = 12;

  /// 标准内边距（页面/卡片水平内边距）
  static const double space16 = 16;

  /// 大内边距
  static const double space20 = 20;

  /// 分区间距
  static const double space24 = 24;

  /// 大分区间距
  static const double space32 = 32;

  // ── 语义间距（页面节奏基准，新代码优先用这一组）──
  /// 页面水平内边距（所有页面左右留白的统一基准）
  static const double pageInline = space16;

  /// 卡片 / 区块内边距
  static const double cardPadding = space16;

  /// 卡片之间的竖直间距
  static const double cardGap = space12;

  /// 分区（Section）之间的竖直间距
  static const double sectionGap = space24;

  /// 列表行水平内边距
  static const double rowInline = 14;

  /// 列表行竖直内边距
  static const double rowVertical = space12;

  /// 手势条兜底高度
  static const double gestureInsetFallback = 48;

  // ── 组件尺寸（component size）──
  /// 触控目标最小高度（按钮、ListTile 等）
  static const double touchTarget = 48;

  /// 列表项高度
  static const double listItemHeight = 56;

  /// 页头高度（56px 单行页头，设计系统 v3：实色表面 + 底边 1px 描边）
  static const double titleBarHeight = 56;

  /// FAB 尺寸（56px 圆形悬浮按钮）
  static const double fabSize = 56;

  /// 启动等待画面品牌图边长（booting 阶段白底居中，与桌面端同源图标）
  static const double splashLogoSize = 96;

  /// 任务行 checkbox 边长（20px 方角，与桌面端任务行 h-5 w-5 同源；
  /// 2026-09-26 由 24 下调——24 相对 15px 标题偏重）
  static const double taskCheckboxSize = 20;

  /// 详情子任务 checkbox 直径
  static const double subtaskCheckboxSize = 22;

  /// 标签色点直径
  static const double colorDotSize = 12;

  /// 小图标尺寸
  static const double iconSizeSm = 18;

  /// 中图标尺寸（功能键等）
  static const double iconSizeMd = 22;

  /// 大图标尺寸（导航键、菜单键等）
  static const double iconSizeLg = 24;

  /// 超大图标尺寸（FAB 图标等）
  static const double iconSizeXl = 28;
}
