import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'router_keys.dart';
import '../../modules/settings/about_page.dart';
import '../../modules/settings/settings_screen.dart';
import '../../modules/settings/sync_settings_page.dart';
import '../../modules/todo/calendar_screen.dart';
import '../../modules/todo/detail_screen.dart';
import '../../modules/todo/sidebar_screen.dart';
import '../../modules/todo/stats_screen.dart';
import '../../modules/todo/sub_list_screen.dart';
import '../../modules/todo/trash_screen.dart';

/// 应用路由（go_router，栈式导航语义，对齐原 React 版 router.mobile.tsx）
///
/// ```
/// /todo            侧栏首屏（快捷视图 + 项目 + 未分组）
/// /todo/tasks      任务子列表（query 三参数互斥 view/projectId/ungrouped）
/// /todo/:id        任务详情全屏
/// /settings        设置
/// /about           关于
/// ```
///
/// query 参数解析收口在 [SubListScreen.parseQuery]；
/// 详情 id 非正整数时传 null 走屏内失败态。

/// 入栈自右滑入（07 报告 §五-P1#12：方向随入栈/出栈，pop 时反向播放）。
/// 三屏 todo 栈与设置页共用；时长/曲线集中在此，后续调手感只改一处。
CustomTransitionPage<void> pageSlideFromRight(Widget child, {LocalKey? key}) =>
    CustomTransitionPage<void>(
      key: key,
      child: child,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(curved),
          child: child,
        );
      },
    );

final appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/todo',
  routes: [
    GoRoute(
      path: '/',
      redirect: (_, _) => '/todo',
    ),
    GoRoute(path: '/todo', builder: (context, state) => const SidebarScreen()),
    GoRoute(
      path: '/todo/calendar',
      pageBuilder: (context, state) => pageSlideFromRight(
        const CalendarScreen(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/todo/tasks',
      pageBuilder: (context, state) => pageSlideFromRight(
        SubListScreen(query: SubListScreen.parseQuery(state)),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/todo/trash',
      pageBuilder: (context, state) => pageSlideFromRight(
        const TrashScreen(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/todo/stats',
      pageBuilder: (context, state) => pageSlideFromRight(
        const StatsScreen(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/todo/:id',
      // 注意：go_router 静态段优先于动态段，/todo/tasks 不会被本路由吞掉
      pageBuilder: (context, state) => pageSlideFromRight(
        DetailScreen(
          taskId: int.tryParse(state.pathParameters['id'] ?? ''),
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings',
      pageBuilder: (context, state) => pageSlideFromRight(
        const SettingsScreen(),
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
    GoRoute(path: '/about', builder: (context, state) => const AboutPage()),
  ],
);
