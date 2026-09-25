// 月档选中日任务卡行内元信息图标：重复 / 提醒 / 描述 三图标条件渲染
// （对齐竞品日视图行：右列时刻下方图标排）。全量元信息任务三图标齐出，
// 无元信息任务不出图标列。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/calendar_screen.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'support/orbit_test_app.dart';

late GoRouter _router;

MockOrbitBridge _seededBridge() {
  final bridge = MockOrbitBridge();
  bridge.store.seed();
  return bridge;
}

/// 造一条今天截止且带 重复+提醒+描述 的任务（对齐竞品参考行「116」）
void _seedFullMetaTask(MockOrbitBridge bridge) {
  final now = bridge.store.now();
  final todayMs = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
    17,
  ).millisecondsSinceEpoch;
  bridge.store.tasks[9101] = {
    'id': 9101,
    'uuid': 'uuid-meta-1',
    'title': '全元信息任务',
    'description': '有一段描述',
    'project_id': null,
    'priority': 3,
    'status': 'pending',
    'done': 0,
    'done_at': null,
    'due_date': todayMs,
    'start_date': null,
    'repeat_after': 1,
    'repeat_mode': 1,
    'percent_done': 0,
    'position': 999,
    'is_favorite': 0,
    'my_day_date': null,
    'is_deleted': 0,
    'created_at': now,
    'updated_at': now,
    'deleted_at': null,
    'version': 1,
  };
  bridge.store.reminders[9101] = {
    'id': 9101,
    'uuid': 'uuid-rem-1',
    'task_id': 9101,
    'remind_at': todayMs - 3600000,
    'is_deleted': 0,
    'created_at': now,
    'updated_at': now,
    'deleted_at': null,
    'version': 1,
  };
}

void main() {
  setUp(() {
    _router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/todo/calendar',
      routes: [
        GoRoute(path: '/todo', builder: (_, _) => const SidebarScreen()),
        GoRoute(
          path: '/todo/calendar',
          builder: (_, _) => const CalendarScreen(),
        ),
        GoRoute(
          path: '/todo/:id',
          builder: (_, s) => Scaffold(
              body: Center(child: Text('detail:${s.pathParameters['id']}'))),
        ),
      ],
    );
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  Widget wrap(MockOrbitBridge bridge) => ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
        child: orbitTestAppRouter(routerConfig: _router),
      );

  testWidgets('全元信息任务：重复/提醒/描述三图标齐出 + 时刻在上方', (tester) async {
    final bridge = _seededBridge();
    _seedFullMetaTask(bridge);
    await tester.pumpWidget(wrap(bridge));
    await settle(tester);

    expect(find.text('全元信息任务'), findsOneWidget);
    // 三枚元信息图标（Repeat / Notification 铃 / FileText 描述）
    expect(find.byIcon(OrbitIcons.repeat), findsOneWidget);
    expect(find.byIcon(OrbitIcons.notification), findsOneWidget);
    expect(find.byIcon(OrbitIcons.fileText), findsOneWidget);
    // 时刻 17:00 渲染在图标上方（同一右列）
    expect(find.text('17:00'), findsOneWidget);
  });

  testWidgets('无元信息任务：不出图标列（条件渲染口径）', (tester) async {
    final bridge = _seededBridge();
    final now = bridge.store.now();
    bridge.store.tasks[9102] = {
      'id': 9102,
      'uuid': 'uuid-meta-2',
      'title': '素任务',
      'description': null,
      'project_id': null,
      'priority': 0,
      'status': 'pending',
      'done': 0,
      'done_at': null,
      'due_date': now,
      'start_date': null,
      'repeat_after': 1,
      'repeat_mode': 0,
      'percent_done': 0,
      'position': 999,
      'is_favorite': 0,
      'my_day_date': null,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
      'version': 1,
    };
    await tester.pumpWidget(wrap(bridge));
    await settle(tester);

    expect(find.text('素任务'), findsOneWidget);
    expect(find.byIcon(OrbitIcons.repeat), findsNothing);
    expect(find.byIcon(OrbitIcons.notification), findsNothing);
    expect(find.byIcon(OrbitIcons.fileText), findsNothing);
  });
}
