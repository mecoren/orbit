import 'package:flutter/widgets.dart';

/// 分支根页标记：由 [app_router.dart] 的 `tabRoot` 统一套在八个模块分支根页上。
///
/// [OrbitPageHeader] 借此区分「分支根页」与「栈内推入页」——只有前者在
/// [OrbitShellBack.hasPrevious] 为真时长出返回箭头，后者继续走 Navigator
/// 原生 `maybePop`（推入页的上一页就是 go_router 栈里那一页）。
class OrbitBranchRoot extends InheritedWidget {
  const OrbitBranchRoot({super.key, required super.child});

  /// 当前 context 是否落在一个模块分支根页内
  static bool isRoot(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OrbitBranchRoot>() != null;

  @override
  bool updateShouldNotify(covariant OrbitBranchRoot oldWidget) => false;
}

/// 壳层的「上一页」上下文：下发可回退状态与统一返回动作
///
/// [StatefulShellRoute] 给每个模块一份独立导航栈，分支根页坐在自己栈的栈底，
/// `Navigator.maybePop` 无处可退。系统返回键由 [HomeShell] 的单一 `PopScope`
/// 兜底；页头返回箭头则由本 InheritedWidget 下发的 [onBack] 驱动，两者共用
/// `orbit_back_dispatch.dart` 的 [goBack] —— 不会出现两套回退真值。
class OrbitShellBack extends InheritedWidget {
  const OrbitShellBack({
    super.key,
    required this.hasPrevious,
    required this.onBack,
    required super.child,
  });

  /// 是否存在上一个操作页面（无则交框架退系统桌面）
  final bool hasPrevious;

  /// 回到上一个操作页面（壳层 State 上的稳定方法引用）
  final VoidCallback onBack;

  /// 取最近的壳层记忆；不在壳内（单页测试 / 根级推入页）返回 null
  static OrbitShellBack? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OrbitShellBack>();

  @override
  bool updateShouldNotify(OrbitShellBack oldWidget) =>
      hasPrevious != oldWidget.hasPrevious || onBack != oldWidget.onBack;
}
