import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_motion.dart';
import 'router_keys.dart';
import '../../modules/settings/about_page.dart';
import '../../modules/settings/appearance_page.dart';
import '../../modules/settings/backup_page.dart';
import '../../modules/settings/label_manager_page.dart';
import '../../modules/settings/nav_modules_page.dart';
import '../../modules/settings/notification_history_page.dart';
import '../../modules/settings/quick_actions_page.dart';
import '../../modules/settings/settings_screen.dart';
import '../../modules/settings/sync_conflicts_page.dart';
import '../../modules/settings/sync_settings_page.dart';
import '../../modules/settings/template_manager_page.dart';
import '../../modules/shell/home_shell.dart';
import '../../modules/shell/nav_modules.dart';
import '../../modules/todo/calendar_screen.dart';
import '../../modules/todo/detail_screen.dart';
import '../../modules/todo/matrix_screen.dart';
import '../../modules/todo/project_edit_page.dart';
import '../../modules/todo/saved_filters_screen.dart';
import '../../modules/todo/search_screen.dart';
import '../../modules/todo/sidebar_screen.dart';
import '../../modules/todo/stats_screen.dart';
import '../../modules/todo/sub_list_screen.dart';
import '../../modules/todo/trash_screen.dart';
import '../../modules/todo/logic/task_logic.dart';

/// 应用路由（go_router，底部页签壳 + 栈式导航语义）
///
/// ```
/// /today                   「今天」模块（今日截止视图，日期副标页头）
/// /todo                    「清单」模块（快捷视图 + 项目 + 未分组）
/// /todo/tasks              任务子列表（页签栈内入栈，底栏常驻；
///                          query 三参数互斥 view/projectId/ungrouped）
/// /todo/projects/:id/edit  项目（清单）编辑整页
/// /todo/calendar           「日历」模块
/// /todo/matrix             「四象限」模块
/// /todo/stats              「统计」模块（可配置进底栏或「更多」面板）
/// /todo/search             「搜索」模块
/// /todo/trash              「回收站」模块
/// /settings                「设置」模块
/// /settings/nav-modules    功能模块配置页（「更多」面板「编辑」入口）
/// /todo/:id                任务详情全屏（根级路由，覆盖页签壳、底栏隐藏）
/// ```
///
/// 一级页签经 [StatefulShellRoute.indexedStack] 各自持有导航栈：切换互不丢
/// 栈，页签内入栈底栏常驻；二级页（详情等）挂根级路由，覆盖全屏。
/// **分支序 = [OrbitNavModule] 枚举序**（goBranch 按下标寻分支，见该枚举
/// 文档）——八个模块全部声明为分支，底栏显示哪些由用户配置决定（功能模块
/// 配置页），配置外的模块分支依旧可达（侧栏/设置内跳转 `go` 切分支）。
/// 页签根用 [NoTransitionPage]（切页签是平移切换语义，不做推入转场），
/// 页签栈内的入栈仍走 [pageSlideFromRight]。
///
/// query 参数解析收口在 [SubListScreen.parseQuery]；
/// 详情 id 非正整数时传 null 走屏内失败态。

/// 入栈自右滑入（07 报告 §五-P1#12：方向随入栈/出栈，pop 时反向播放）。
/// 页签栈与设置页共用；时长/曲线集中在此，后续调手感只改一处。
CustomTransitionPage<void> pageSlideFromRight(Widget child, {LocalKey? key}) =>
    CustomTransitionPage<void>(
      key: key,
      child: child,
      transitionDuration: AppMotion.pageEnter,
      reverseTransitionDuration: AppMotion.pageExit,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppMotion.pageInCubic,
          reverseCurve: AppMotion.pageOutCubic,
        );
        return SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(curved),
          child: child,
        );
      },
    );

/// 页签根页：无转场直切（go_router pageKey 复用，切换不重播动画）
NoTransitionPage<void> tabRoot(Widget child, {LocalKey? key}) =>
    NoTransitionPage<void>(key: key, child: child);

/// 「今天」页签：今日截止视图（无返回键，页头带日期副标）
SubListScreen _todayTab() => const SubListScreen(
      query: TaskFilterInput(quickView: QuickViewKey.today),
      showBack: false,
      titleOverride: '今天',
    );

final appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  // 冷启动落点随底部导航配置走：「今天」被停用时落启用序第一个模块
  initialLocation: startupLocation,
  routes: [
    GoRoute(path: '/', redirect: (_, _) => startupLocation),
    // 底部页签壳：八个模块分支各自持栈（分支序 = OrbitNavModule 枚举序，
    // 底栏显示哪些由功能模块配置决定；切模块互不丢栈，栈内入栈底栏常驻）
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          HomeShell(navigationShell: navigationShell),
      branches: [
        // ── 今天 ──
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/today',
            pageBuilder: (context, state) => tabRoot(_todayTab()),
          ),
        ]),
        // ── 清单（快捷视图 / 项目 / 未分组 + 页签栈内子页）──
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/todo',
            pageBuilder: (context, state) =>
                tabRoot(const SidebarScreen(), key: state.pageKey),
          ),
          GoRoute(
            path: '/todo/tasks',
            pageBuilder: (context, state) => pageSlideFromRight(
              SubListScreen(query: SubListScreen.parseQuery(state)),
              key: state.pageKey,
            ),
          ),
          // 项目（清单）编辑整页：静态段在前，且不落在 /todo/:id 动态段里
          GoRoute(
            path: '/todo/projects/:id/edit',
            pageBuilder: (context, state) => pageSlideFromRight(
              ProjectEditPage(
                projectId: int.tryParse(state.pathParameters['id'] ?? ''),
              ),
              key: state.pageKey,
            ),
          ),
          GoRoute(
            path: '/todo/saved-filters',
            pageBuilder: (context, state) => pageSlideFromRight(
              const SavedFiltersScreen(),
              key: state.pageKey,
            ),
          ),
        ]),
        // ── 日历 ──
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/todo/calendar',
            pageBuilder: (context, state) =>
                tabRoot(const CalendarScreen(), key: state.pageKey),
          ),
        ]),
        // ── 四象限 ──
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/todo/matrix',
            pageBuilder: (context, state) =>
                tabRoot(const MatrixScreen(), key: state.pageKey),
          ),
        ]),
        // ── 统计（默认在「更多」面板；配置进底栏即成页签）──
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/todo/stats',
            pageBuilder: (context, state) => tabRoot(
                const StatsScreen(showBack: false), key: state.pageKey),
          ),
        ]),
        // ── 搜索 ──
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/todo/search',
            pageBuilder: (context, state) => tabRoot(
                const SearchScreen(showBack: false), key: state.pageKey),
          ),
        ]),
        // ── 回收站 ──
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/todo/trash',
            pageBuilder: (context, state) => tabRoot(
                const TrashScreen(showBack: false), key: state.pageKey),
          ),
        ]),
        // ── 设置（子页 /settings/* 仍是根级推入：覆盖全屏、底栏隐藏）──
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => tabRoot(
                const SettingsScreen(showBack: false), key: state.pageKey),
          ),
        ]),
      ],
    ),
    // 任务详情：根级全屏页（覆盖页签壳，底栏隐藏）；go_router 静态段优先于
    // 动态段，/todo/tasks 等不会落进本路由
    GoRoute(
      path: '/todo/:id',
      pageBuilder: (context, state) => pageSlideFromRight(
        DetailScreen(
          taskId: int.tryParse(state.pathParameters['id'] ?? ''),
        ),
        key: state.pageKey,
      ),
    ),
    // 功能模块配置页：底部导航可配置（「更多」面板「编辑」入口；根级全屏推入）
    GoRoute(
      path: '/settings/nav-modules',
      pageBuilder: (context, state) => pageSlideFromRight(
        const NavModulesPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/sync',
      pageBuilder: (context, state) => pageSlideFromRight(
        const SyncSettingsPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/conflicts',
      pageBuilder: (context, state) => pageSlideFromRight(
        const SyncConflictsPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/backup',
      pageBuilder: (context, state) => pageSlideFromRight(
        const BackupPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/labels',
      pageBuilder: (context, state) => pageSlideFromRight(
        const LabelManagerPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/templates',
      pageBuilder: (context, state) => pageSlideFromRight(
        const TemplateManagerPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/appearance',
      pageBuilder: (context, state) => pageSlideFromRight(
        const AppearancePage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/notifications',
      pageBuilder: (context, state) => pageSlideFromRight(
        const NotificationHistoryPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/quick-actions',
      pageBuilder: (context, state) => pageSlideFromRight(
        const QuickActionsPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/about',
      // 与同级设置子页统一右滑入转场（原裸 builder 无转场，突兀）
      pageBuilder: (context, state) =>
          pageSlideFromRight(const AboutPage(), key: state.pageKey),
    ),
  ],
);
