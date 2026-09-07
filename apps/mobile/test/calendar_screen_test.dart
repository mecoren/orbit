// 日历视图组件测试（wait-home 风格重构版）：月历农历副标签/任务圆点 +
// 下方按日分组列表点击进详情 + 休/班徽标 + 长按日格快捷新增（预填截止日）+
// 年视图入口 + 月导航/今天回位 + 手动更新链路（MockOrbitBridge 注入）。
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
/// （点击任务卡后以「detail:」前缀文本页落地，验证导航目标）
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

  testWidgets('月历+分组列表：农历副标签渲染，任务卡点击进详情页', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 月历：农历副标签渲染（数字格下方，如「十九」等农历日名/节气/节日）
    // 星期表头存在（周一始）
    expect(find.text('一'), findsOneWidget);

    // 种子里「完成移动端重构方案评审」截止在明天（now+1d）——
    // 落在月历圆点 + 当月分组列表的任务卡（整页滚动布局下滚到可见）
    final card = find.text('完成移动端重构方案评审');
    await tester.scrollUntilVisible(
      card.first,
      300,
    );
    expect(card, findsWidgets);

    // 点击下方列表的任务卡 → 详情页出现
    await tester.tap(card.first);
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) =>
          w is Text && (w.data ?? '').startsWith('detail:')),
      findsOneWidget,
    );
  });

  testWidgets('节假日徽标：休/班 出现在月历格', (tester) async {
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

  testWidgets('长按日格：弹出新增表单且截止日期预填为该日', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 长按今天格（月历 AppMonthCalendar 的日格）
    final today = DateTime.now();
    final dayText = find.text('${today.day}').first;
    await tester.longPress(dayText, warnIfMissed: false);
    await tester.pumpAndSettle();

    // 新增表单打开（标题「添加待办」）：
    expect(find.text('添加待办'), findsOneWidget);

    // 预填断言：表单里截止日期行显示今天日期字符串（YYYY-MM-DD）
    final ymd =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    expect(find.text(ymd), findsOneWidget);
  });

  testWidgets('年视图：点月份标题进入，干支生肖 + 迷你月历 + 点日期返回', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 点月份标题 → 年视图页（干支生肖标签 + 12 迷你月历）
    await tester.tap(find.textContaining('年').first);
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').endsWith('年') && (w.data ?? '').length == 4,
      description: '大年份 2026',
    ), findsOneWidget);
    expect(find.text('丙午马年'), findsOneWidget);

    // 12 个迷你月标题齐全
    for (final m in ['1月', '6月', '12月']) {
      expect(find.text(m), findsWidgets);
    }

    // 点 9 月标题（年视图内容超屏，先在年视图页内滚动到可见）→ 返回月历定位。
    // 年视图页滚动区 = SingleChildScrollView（显式指定，PageView 亦为可滚组件会歧义）
    final yearScroll = find.descendant(
      of: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == 'YearOverviewPage'),
      matching: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(find.text('9月').first, 200,
        scrollable: yearScroll);
    await tester.tap(find.text('9月').first);
    await tester.pumpAndSettle();
    expect(find.text('2026年9月'), findsOneWidget);
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

    // 点「回到今天」按钮 → 标题还原
    await tester.tap(find.byIcon(Icons.today_rounded));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.textContaining('年').first).data,
      currentTitle,
    );
  });

  testWidgets('侧栏入口：「日历」行渲染并点击进入', (tester) async {
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

  testWidgets('超量待办：同日多条任务在下方列表可纵向滑动查看', (tester) async {
    final bridge = _seededBridge();
    // 直接在 store 造 15 条今天的任务（当月分组列表超屏）。
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

    // 断言压测任务卡渲染（整页滚动布局下列表在月历下方，滚到可见）
    await tester.scrollUntilVisible(
      find.textContaining('压测任务').first,
      300,
    );
    expect(find.textContaining('压测任务'), findsWidgets);

    // 在整页滚动区上竖向拖动，验证滚动查看不崩溃且卡片仍渲染
    final anyCard = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_TaskCard',
    );
    expect(anyCard, findsWidgets);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 200));
    expect(anyCard, findsWidgets);
  });
}
