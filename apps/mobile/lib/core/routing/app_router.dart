import 'package:go_router/go_router.dart';

import '../../modules/shell/placeholder_page.dart';

/// 应用路由（go_router）
///
/// 栈式导航语义（对齐 React 版 router.mobile.tsx，无底部 Tab）：
/// ```
/// /todo            侧栏首屏（快捷视图 + 项目 + 未分组）
/// /todo/tasks      任务子列表
/// /todo/:id        任务详情全屏
/// /settings        设置
/// /about           关于
/// ```
/// 各屏面在 Phase 6 实现；当前为占位页。
final appRouter = GoRouter(
  initialLocation: '/todo',
  routes: [
    GoRoute(
      path: '/todo',
      builder: (context, state) => const PlaceholderPage(label: '侧栏首屏'),
      routes: [
        GoRoute(
          path: 'tasks',
          builder: (context, state) => const PlaceholderPage(label: '任务子列表'),
        ),
        GoRoute(
          path: ':id',
          builder: (context, state) =>
              PlaceholderPage(label: '详情 ${state.pathParameters['id']}'),
        ),
      ],
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const PlaceholderPage(label: '设置'),
    ),
    GoRoute(
      path: '/about',
      builder: (context, state) => const PlaceholderPage(label: '关于'),
    ),
  ],
);
