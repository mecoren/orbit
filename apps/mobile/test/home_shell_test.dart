// 底部导航壳测试：页签切换、今天页签页头（日期副标）、中央添加钮、
// 「今天」页签角标（MockOrbitBridge 注入 + 生产路由表全链路）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/routing/app_router.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/calendar_screen.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/modules/todo/stats_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_bottom_nav.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_fab.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestAppRouter(routerConfig: appRouter),
    );

Future<void> _pump(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(_wrap(bridge));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  // 生产路由是全局单例：上一个用例可能停在别的页签，统一切回「今天」
  appRouter.go('/today');
  await tester.pumpAndSettle();
}

MockOrbitBridge _seededBridge() {
  final bridge = MockOrbitBridge();
  bridge.store.seed();
  return bridge;
}

void main() {
  testWidgets('初始落「今天」页签：页头今天 + 日期副标，页签栏四枚 + 中央添加钮',
      (tester) async {
    await _pump(tester, _seededBridge());

    expect(find.text('今天'), findsWidgets); // 页头 + 页签
    // 日期副标（M月D日 周X）随页签根出现
    expect(find.text(todayHeaderLabel(DateTime.now())), findsOneWidget);
    // 四枚页签
    expect(find.byType(OrbitBottomNav), findsOneWidget);
    expect(find.text('清单'), findsOneWidget);
    expect(find.text('日历'), findsOneWidget);
    expect(find.text('统计'), findsOneWidget);
    // 中央添加钮 = 壳里唯一的 OrbitFab 实例（页面内 FAB 已上收）
    expect(find.byType(OrbitFab), findsOneWidget);
  });

  testWidgets('切页签：清单 → 日历 → 统计 → 回今天，各自页面渲染', (tester) async {
    await _pump(tester, _seededBridge());

    await tester.tap(find.text('清单'));
    await tester.pumpAndSettle();
    expect(find.byType(SidebarScreen), findsOneWidget);
    expect(find.text('循迹'), findsOneWidget);

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarScreen), findsOneWidget);

    await tester.tap(find.text('统计'));
    await tester.pumpAndSettle();
    expect(find.byType(StatsScreen), findsOneWidget);

    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    expect(find.text(todayHeaderLabel(DateTime.now())), findsOneWidget);
  });

  testWidgets('中央添加钮：点击弹出快速添加面板', (tester) async {
    await _pump(tester, _seededBridge());

    // 中央添加钮是壳内唯一的 OrbitFab（页面内 FAB 已上收）
    await tester.tap(find.byType(OrbitFab));
    await tester.pumpAndSettle();

    expect(find.text('准备做什么？'), findsOneWidget);
  });

  testWidgets('「今天」页签角标：有今天截止未完成任务时显示计数', (tester) async {
    final bridge = _seededBridge();
    // 造一条今天截止的未完成任务（截止 = 当前时刻，落在今天日界内）
    final now = bridge.store.now();
    bridge.store.tasks[9001] = {
      'id': 9001,
      'uuid': 'uuid-badge-1',
      'title': '角标压测任务',
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
    await _pump(tester, bridge);

    // 角标挂在「今天」页签图标右上：底部导航内的计数文本与页面页头计数并存。
    // today 视图含逾期（截止 < 明日零点即计入，与 computeSidebarCounts 同口径）
    final endOfToday =
        DateTime.fromMillisecondsSinceEpoch(now).add(const Duration(days: 1));
    final endOfTodayMs = DateTime(
      endOfToday.year,
      endOfToday.month,
      endOfToday.day,
    ).millisecondsSinceEpoch;
    final undone = (bridge.store.tasks.values).where((t) {
      if (t['is_deleted'] == 1 || t['done'] == 1) return false;
      final due = t['due_date'] as int?;
      return due != null && due < endOfTodayMs;
    }).length;
    expect(undone, greaterThan(0));
    expect(
      find.descendant(
        of: find.byType(OrbitBottomNav),
        matching: find.text('$undone'),
      ),
      findsOneWidget,
    );
  });
}
