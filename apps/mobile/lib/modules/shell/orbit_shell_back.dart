import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 页签壳的「上一页」记忆：分支根页返回键的回退目标
///
/// [StatefulShellRoute] 给每个功能模块一份**独立导航栈**，分支根页（回收站 /
/// 统计 / 搜索等经「更多」面板、侧栏或设置页跳进来的模块）就坐在自己栈的栈底
/// ——`Navigator.maybePop` 无处可退，页头返回键会变成死键。而这类模块的进入
/// 路径几乎都不在底栏：页签栏此时给不出「回到刚才那一页」的出口（点「更多」
/// 只开面板、点别的页签是换目的地而非回退）。
///
/// 故由 [HomeShell] 在分支切换时记下上一次停靠的模块下标，经本 InheritedWidget
/// 下发给分支根页；[StatefulNavigationShell.goBranch] 会恢复目标分支原有栈，
/// 回退后位置与筛选状态都不丢。
class OrbitShellBack extends InheritedWidget {
  const OrbitShellBack({
    super.key,
    required this.targetBranchIndex,
    required super.child,
  });

  /// 返回键目标模块分支下标；null = 无处可退（如冷启动直接落在本模块且它是
  /// 唯一启用模块、或本模块已占据底栏页签——回退由页签承担），调用方不渲染
  /// 返回键
  final int? targetBranchIndex;

  /// 取最近的壳层记忆；不在壳内（单页测试 / 根级推入页）返回 null
  static OrbitShellBack? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OrbitShellBack>();

  @override
  bool updateShouldNotify(OrbitShellBack oldWidget) =>
      targetBranchIndex != oldWidget.targetBranchIndex;
}

/// 分支根页的返回动作：切回进站前的模块页签
///
/// 无壳上下文（或壳内无处可退）时退回 `Navigator.maybePop`——根级推入页
/// （详情 / 设置子页）的返回语义照旧。
void goBackToPreviousModule(BuildContext context) {
  final target = OrbitShellBack.maybeOf(context)?.targetBranchIndex;
  final shell = target == null
      ? null
      : StatefulNavigationShell.maybeOf(context);
  if (target == null || shell == null) {
    Navigator.of(context).maybePop();
    return;
  }
  shell.goBranch(target);
}
