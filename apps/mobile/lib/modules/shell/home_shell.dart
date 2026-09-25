import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_bottom_nav.dart';
import '../../shared/widgets/shadcn/orbit_dropdown_panel.dart';
import '../../shared/widgets/shadcn/orbit_fab.dart';
import '../todo/form_bottom_sheet.dart';
import '../todo/logic/quick_add_context.dart';
import '../todo/logic/task_logic.dart';
import '../todo/providers/todo_providers.dart';
import '../todo/quick_add_sheet.dart' show showQuickAddSheet;
import 'nav_modules.dart';

/// 主导航壳（底部页签 + 右下悬浮新建钮 + 「更多」面板）
///
/// 对齐竞品主导航形态：模块页签经 StatefulShellRoute 各自持有导航栈，切页签
/// 互不丢栈，页签内入栈（任务列表、项目编辑等）时底栏常驻；任务详情等根级
/// 路由覆盖全屏，底栏随之隐藏。**底栏页签可配置**（对齐竞品「功能模块」）：
/// 启用序前 [NavModulesState.bottomTabLimit] 个模块进底栏，其余启用模块收进
/// 「更多」面板；末位「更多」动作页签不切页——就地弹出锚在页签上方的次级
/// 目的地面板（标题行带「编辑」入口进功能模块配置页），点面板外关闭，面板
/// 条目点击 = 切到对应模块分支。「新建」上收右下悬浮钮（[OrbitFab]）：落点
/// 跟随当前列表页（[QuickAddContext] 登记的筛选入参），长按直达模板新建；
/// 「今天」页签挂今日未完成计数角标（不在底栏时不挂）。
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});

  /// go_router 的页签容器（IndexedStack 语义，切换保留各页签状态）
  final StatefulNavigationShell navigationShell;

  /// 「更多」面板：当前配置下未进底栏的启用模块（[NavModulesState.morePanelItems]）
  ///
  /// 面板条目点击 = 切分支（与页签同语义，底栏常驻）；标题行「编辑」进
  /// 功能模块配置页。
  void _showMorePanel(
    BuildContext context,
    Rect anchor,
    List<OrbitNavModule> items,
  ) {
    showOrbitDropdownPanel(
      context,
      anchor: anchor,
      above: true,
      title: '更多',
      actionLabel: '编辑',
      onAction: () => context.push('/settings/nav-modules'),
      groups: [
        [
          for (final m in items)
            OrbitPanelItem(
              icon: m.icon,
              label: m.label,
              onTap: () =>
                  navigationShell.goBranch(m.branchIndex),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(todoTasksProvider).value ?? const <TodoTask>[];
    final nav = ref.watch(navModulesProvider);
    final tabs = nav.bottomTabs;
    // 「今天」角标 = 今天截止视图的未完成数（0 不显示，见 [OrbitBottomNav]）；
    // 今天模块不在底栏时无角标位
    final counts = computeSidebarCounts(tasks);
    final todayPos = tabs.indexOf(OrbitNavModule.today);
    // 当前分支对应模块不在底栏（经「更多」面板/侧栏内跳进入）时，选中态落
    // 「更多」动作位（竞品同款：面板进入的模块页高亮「更多」）
    final currentModule = OrbitNavModule.values[navigationShell.currentIndex];
    final currentTabPos = tabs.indexOf(currentModule);

    // 配置变化后当前模块被停用：回落到启用序第一个模块（配置页在全屏路由
    // 之上操作，返回壳前兜底，避免停在「无页签指向」的分支上）
    ref.listen(navModulesProvider, (prev, next) {
      if (!next.enabled.contains(currentModule)) {
        navigationShell.goBranch(next.enabled.first.branchIndex);
      }
    });

    return Scaffold(
      body: navigationShell,
      floatingActionButton: OrbitFab(
        accentColor: OrbitAccents.themeAccent,
        // 新建落点跟随当前列表（无页面语境时面板内自选）
        onPressed: () {
          final target = QuickAddContext.current;
          showQuickAddSheet(
            context,
            defaultProjectId: target?.projectId,
            quickView: target?.quickView,
          );
        },
        // 长按 = 从模板新建（与列表页长按加号同源；无模板静默返回）
        onLongPress: () => showTemplateCreateFlow(
          context,
          ref.read(orbitBridgeProvider),
        ),
      ),
      bottomNavigationBar: OrbitBottomNav(
        currentIndex: currentTabPos >= 0 ? currentTabPos : tabs.length,
        moreTabIndex: tabs.length,
        onMoreTap: (anchor) => _showMorePanel(context, anchor, nav.morePanelItems),
        // 重复点击当前页签回退到该页签根（go_router 惯例：保留栈内其余状态）
        onTap: (index) {
          final module = tabs[index];
          navigationShell.goBranch(
            module.branchIndex,
            initialLocation: module.branchIndex == navigationShell.currentIndex,
          );
        },
        badges: todayPos >= 0
            ? {todayPos: counts.quickView[QuickViewKey.today] ?? 0}
            : const <int, int>{},
        items: [
          for (final m in tabs)
            OrbitBottomNavItem(icon: m.icon, label: m.label),
          const OrbitBottomNavItem(icon: OrbitIcons.more, label: '更多'),
        ],
      ),
    );
  }
}
