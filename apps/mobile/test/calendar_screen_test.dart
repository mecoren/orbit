// 日历视图组件测试：月格待办长条渲染 + 点击长条进详情 + 节假日徽标 +
// 侧栏入口 + 手动更新链路（MockOrbitBridge 注入）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/calendar_screen.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp.router(routerConfig: _router),
    );

/// 极简路由：侧栏 + 日历 + 详情占位页
/// （点击长条后以「detail:」前缀文本页落地，验证导航目标）
late GoRouter _router;

MockOrbitBridge _seededBridge() {
  final bridge = MockOrbitBridge();
  bridge.store.seed();
  return bridge;
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
          builder: (_, s) =>
              Scaffold(body: Center(child: Text('detail:${s.pathParameters['id']}'))),
        ),
      ],
    );
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets('月格渲染：今日格有任务长条，点击长条进入详情页', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 种子里「完成移动端重构方案评审」截止在明天（now+1d）——含具体时刻，
    // 会落在当前月。直接断言该标题长条出现在日历上（可能需滚动到所在格）
    // 月格含前后月补位：跨越月界时同一日期会在补位格与本月格各出现一次
    final bar = find.text('完成移动端重构方案评审');
    expect(bar, findsWidgets);

    // 点击该长条 → 详情页出现（长条 onTap = context.push('/todo/:id')）
    await tester.tap(bar.first);
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) =>
          w is Text && (w.data ?? '').startsWith('detail:')),
      findsOneWidget,
    );
  });

  testWidgets('节假日徽标：休/班 出现在月格日期行', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // mock 节假日：2026-01-01「休」/2026-01-04「班」/2026-02-17「休」
    // （当前 2026-09 不含节假日 → 翻月验证数据链路）
    expect(find.text('日历'), findsOneWidget);

    // 从 2026-09 向前翻 8 次到 2026-01（9→8→…→1，跨年取道 2025）
    for (var i = 0; i < 10; i++) {
      if (find.text('2026年1月').evaluate().isNotEmpty) break;
      await tester.tap(find.byTooltip('上个月'));
      await tester.pumpAndSettle();
    }
    expect(find.text('2026年1月'), findsOneWidget);

    // 元旦（01-01 放假）与补班日（01-04）徽标同屏可见
    expect(find.text('休'), findsWidgets);
    expect(find.text('班'), findsWidgets);
  });

  testWidgets('手动更新：点击刷新按钮 → toast「节假日数据已更新」', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    final refresh = find.byIcon(Icons.refresh_rounded);
    expect(refresh, findsOneWidget);
    await tester.tap(refresh);
    await tester.pump(); // 触发 _updateHolidays async 开始
    await tester.pump(const Duration(milliseconds: 300)); // mock 延迟
    await tester.pump(); // WaitToast Overlay 插入帧

    expect(find.text('节假日数据已更新'), findsOneWidget);
    // provider 已失效重拉（mock 返回相同常量，断言不抛错即通过）
    expect(find.text('日历'), findsOneWidget);
    // 快进过 toast 的 2.6s 自动收起 Timer（防测试结束时 pending timer 断言）
    await tester.pump(const Duration(milliseconds: 2700));
  });

  testWidgets('月导航：上/下月翻页与「今天」回位', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    final currentTitle = tester
        .widget<Text>(find.textContaining('年').first)
        .data;

    // 下一个月 → 标题变化
    await tester.tap(find.byIcon(Icons.chevron_right_rounded).first);
    await tester.pumpAndSettle();
    final nextTitle = tester
        .widget<Text>(find.textContaining('年').first)
        .data;
    expect(nextTitle, isNot(currentTitle));

    // 点月份标题回今天 → 标题还原
    await tester.tap(find.text(nextTitle!));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.textContaining('年').first).data,
      currentTitle,
    );
  });

  testWidgets('侧栏入口：「日历」行渲染于快捷视图与项目之间', (tester) async {
    final bridge = _seededBridge();
    _router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/todo',
      routes: [
        GoRoute(path: '/todo', builder: (_, _) => const SidebarScreen()),
        GoRoute(
          path: '/todo/calendar',
          builder: (_, _) => const CalendarScreen(),
        ),
      ],
    );
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 默认视口可能截断：滚到「日历」行
    await tester.scrollUntilVisible(
      find.text('日历'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('日历'), findsOneWidget);

    // 点击进入日历页
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarScreen), findsOneWidget);
  });

  testWidgets('超量待办：同日多条任务在格内可纵向滑动查看', (tester) async {
    final bridge = _seededBridge();
    // 直接在 store 造 15 条今天的任务（构造长条列表溢出格高）。
    // 注意 position 必须为 int：mock todoTaskList 排序按 `as int` 强转。
    final now = bridge.store.now();
    for (var i = 0; i < 15; i++) {
      final id = 100 + i;
      bridge.store.tasks[id] = {
        'id': id,
        'uuid': 'uuid-stress-$i',
        'title': '压测任务$i',
        'description': null,
        'project_id': null,
        'priority': 0,
        'status': 'pending',
        'done': 0,
        'done_at': null,
        'due_date': now + i * 60000, // 今天，分钟级递增
        'start_date': null,
        'end_date': null,
        'repeat_after': 1,
        'repeat_mode': 0,
        'percent_done': 0,
        'position': i,
        'is_favorite': 0,
        'my_day_date': null,
        'is_deleted': 0,
        'created_at': now,
        'updated_at': now,
        'deleted_at': null,
        'version': 1,
      };
    }
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 断言至少一条压测任务长条可见（渲染成功；月格含补位可能两处出现）
    expect(find.textContaining('压测任务'), findsWidgets);

    // 在今日格的滚动区域上竖向拖动（格内 ListView 手势），验证滑动查看
    // 超出可视高度的内容不崩溃且长条仍渲染（有界泵防 pending timer 卡死）
    final anyBar = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_TaskBar',
    );
    expect(anyBar, findsWidgets);
    await tester.drag(anyBar.first, const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 200));
    expect(anyBar, findsWidgets);
  });
}
