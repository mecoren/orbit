import 'package:go_router/go_router.dart';

import 'router_keys.dart';
import '../../modules/settings/about_page.dart';
import '../../modules/settings/settings_screen.dart';
import '../../modules/todo/detail_screen.dart';
import '../../modules/todo/sidebar_screen.dart';
import '../../modules/todo/sub_list_screen.dart';

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
      path: '/todo/tasks',
      builder: (context, state) =>
          SubListScreen(query: SubListScreen.parseQuery(state)),
    ),
    GoRoute(
      path: '/todo/:id',
      // 注意：go_router 静态段优先于动态段，/todo/tasks 不会被本路由吞掉
      builder: (context, state) => DetailScreen(
        taskId: int.tryParse(state.pathParameters['id'] ?? ''),
      ),
    ),
    GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
    GoRoute(path: '/about', builder: (context, state) => const AboutPage()),
  ],
);
