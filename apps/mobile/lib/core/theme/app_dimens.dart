/// 应用间距 / 尺寸 / 模糊 / 时长 Token
///
/// 参考 SaltUI `SaltDimens`：私有构造 + `static const` 集中管理。
/// 数值与 wait-home/mobile 及 orbit docs/05 §七 常量速查卡一致。
class AppDimens {
  AppDimens._();

  // ── 间距（spacing）──
  /// 极小间隙（图标与文字间）
  static const double space4 = 4;

  /// 小间隙
  static const double space8 = 8;

  /// 紧凑内边距
  static const double space12 = 12;

  /// 标准内边距（页面/卡片水平内边距）
  static const double space16 = 16;

  /// 大内边距
  static const double space20 = 20;

  /// 分区间距
  static const double space24 = 24;

  /// 大分区间距
  static const double space32 = 32;

  /// 手势条兜底高度（docs/05：env(safe-area-inset-bottom) 为 0 时兜底）
  static const double gestureInsetFallback = 48;

  // ── 组件尺寸（component size）──
  /// 触控目标最小高度（按钮、ListTile 等）
  static const double touchTarget = 48;

  /// 列表项高度
  static const double listItemHeight = 56;

  /// 标题栏高度（docs/05 §三：56px 单行液态玻璃标题栏）
  static const double titleBarHeight = 56;

  /// FAB 尺寸（docs/05：GlassFab 56px 圆形）
  static const double fabSize = 56;

  /// 任务行 checkbox 直径（docs/05 §七）
  static const double taskCheckboxSize = 24;

  /// 详情子任务 checkbox 直径（docs/05 §四：22px 圆）
  static const double subtaskCheckboxSize = 22;

  /// 标签色点直径（docs/05 §七：12×12 色点）
  static const double colorDotSize = 12;

  /// 小图标尺寸
  static const double iconSizeSm = 18;

  /// 中图标尺寸（功能键等）
  static const double iconSizeMd = 22;

  /// 大图标尺寸（导航键、菜单键等）
  static const double iconSizeLg = 24;

  /// 超大图标尺寸（FAB 图标等）
  static const double iconSizeXl = 28;

  // ── 模糊（blur sigma）──
  /// 静态玻璃模糊（卡片/弹层，性能成本 ∝ σ²）
  static const double blurStatic = 45;

  /// 标题栏最大模糊（docs/05 §三：blur σ20）
  static const double blurTitleBarMax = 20;

  /// FAB / 底栏模糊（docs/05：GlassFab blur18）
  static const double blurFab = 18;

  /// 滚动渐显区间（模糊层从透明到完全显示的滚动偏移）
  static const double blurScrollFadeDistance = 32;

  // ── 动画时长（duration ms）──
  /// 快速动画（按压反馈、状态切换）
  static const int durationFast = 150;

  /// 常规动画（图标切换、淡入淡出）
  static const int durationNormal = 250;

  /// 慢速动画（容器形变、展开收起）
  static const int durationSlow = 300;
}
