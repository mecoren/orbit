import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_bottom_nav.dart';
import '../todo/form_bottom_sheet.dart';
import '../todo/logic/quick_add_context.dart';
import '../todo/logic/task_logic.dart';
import '../todo/providers/todo_providers.dart';
import '../todo/quick_add_sheet.dart' show showQuickAddSheet;

/// 主导航壳（底部页签 + 中央添加钮）
///
/// 四个一级页签（今天 / 清单 / 日历 / 统计）经 StatefulShellRoute 各自持有
/// 导航栈：切页签互不丢栈，页签内入栈（任务列表、项目编辑、搜索等）时底栏
/// 常驻；任务详情 / 设置等根级路由覆盖全屏，底栏随之隐藏。
/// 中央添加钮的落点跟随当前列表页（[QuickAddContext] 登记的筛选入参），
/// 长按直达模板新建；「今天」页签挂今日未完成计数角标。
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});

  /// go_router 的页签容器（IndexedStack 语义，切换保留各页签状态）
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(todoTasksProvider).value ?? const <TodoTask>[];
    // 「今天」角标 = 今天截止视图的未完成数（0 不显示，见 [OrbitBottomNav]）
    final counts = computeSidebarCounts(tasks);
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: OrbitBottomNav(
        currentIndex: navigationShell.currentIndex,
        // 重复点击当前页签回退到该页签根（go_router 惯例：保留栈内其余状态）
        onTap: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        badges: {0: counts.quickView[QuickViewKey.today] ?? 0},
        items: const [
          OrbitBottomNavItem(icon: OrbitIcons.sun, label: '今天'),
          OrbitBottomNavItem(icon: OrbitIcons.list, label: '清单'),
          OrbitBottomNavItem(icon: OrbitIcons.calendarDays, label: '日历'),
          OrbitBottomNavItem(icon: OrbitIcons.trending, label: '统计'),
        ],
        // 新建落点跟随当前列表（无页面语境时面板内自选）
        onAddTap: () {
          final target = QuickAddContext.current;
          showQuickAddSheet(
            context,
            defaultProjectId: target?.projectId,
            quickView: target?.quickView,
          );
        },
        // 长按 = 从模板新建（与列表页长按加号同源；无模板静默返回）
        onAddLongPress: () => showTemplateCreateFlow(
          context,
          ref.read(orbitBridgeProvider),
        ),
      ),
    );
  }
}
