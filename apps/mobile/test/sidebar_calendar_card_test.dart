// 侧栏 + 日历卡片化回归（今天任务列表同款整卡口径）：
// - 侧栏全部导航行（快捷 / 功能 / 项目 / 未分组）都在 OrbitCardSegment 内；
// - 日历月历整张是单段卡；选中日空态与议程档空态是单段卡。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/calendar_screen.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_list_card.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_month_calendar.dart';
import 'support/orbit_test_app.dart';

late GoRouter _router;

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestAppRouter(routerConfig: _router),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 指定文本的祖先链里必须有卡片段（edge 可选断言）
void _expectInSegment(
  WidgetTester tester,
  Finder text, [
  OrbitCardEdge? edge,
]) {
  expect(text, findsWidgets);
  final segments = find.ancestor(
    of: text.first,
    matching: find.byType(OrbitCardSegment),
  );
  expect(segments, findsWidgets, reason: '${text.toString()} 应在卡片段内');
  if (edge != null) {
    expect(
      tester
          .widgetList<OrbitCardSegment>(segments)
          .any((s) => s.edge == edge),
      isTrue,
      reason: '${text.toString()} 段位应为 $edge',
    );
  }
}

void main() {
  setUp(() {
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
  });

  testWidgets('侧栏：全部导航行都在卡片段内（快捷/功能/项目/未分组）',
      (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    // 快捷视图卡：7 行（首段 / 中段 / 末段齐全）
    _expectInSegment(tester, find.text('我的一天'), OrbitCardEdge.first);
    _expectInSegment(tester, find.text('今天'));
    _expectInSegment(tester, find.text('无日期'), OrbitCardEdge.last);
    // 功能入口卡：搜索 / 筛选器 / 回收站同卡三段
    _expectInSegment(tester, find.text('搜索'), OrbitCardEdge.first);
    _expectInSegment(tester, find.text('筛选器'));
    _expectInSegment(tester, find.text('回收站'), OrbitCardEdge.last);
    // 项目行在懒加载列表折叠处：先滚到底把整列建成，再断言段内
    await tester.scrollUntilVisible(find.text('未分组'), 200,
        scrollable: find.byType(Scrollable).first);
    // 项目卡：种子项目行在段内；未分组是独立单段卡
    _expectInSegment(tester, find.text('工作'));
    _expectInSegment(tester, find.text('未分组'), OrbitCardEdge.single);

    // 兜底：侧栏内每个 ListTile 都有卡片段祖先（无裸行漏网）
    final tiles = find.byType(ListTile);
    expect(tiles, findsWidgets);
    for (final tile in tester.widgetList<ListTile>(tiles)) {
      expect(
        find.ancestor(
          of: find.byWidget(tile),
          matching: find.byType(OrbitCardSegment),
        ),
        findsWidgets,
        reason: 'ListTile「${(tile.title as Text?)?.data}」应在卡片段内',
      );
    }
  });

  testWidgets('日历：月历整卡 + 选中日空态卡 + 议程组卡', (tester) async {
    // 种子任务皆不在今天（相对日期 now()±N 天）：选中日空态确定出现；
    // 议程档当月有任务：分组卡确定出现。
    final bridge = MockOrbitBridge();
    _router.go('/todo/calendar');
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    // 月历整张是单段卡
    final month = find.byType(OrbitMonthCalendar);
    expect(month, findsOneWidget);
    final monthSeg = find.ancestor(
      of: month,
      matching: find.byType(OrbitCardSegment),
    );
    expect(monthSeg, findsOneWidget);
    expect(tester.widget<OrbitCardSegment>(monthSeg).edge,
        OrbitCardEdge.single);

    // 选中日空态是单段卡（整页滚动布局下滚到可见）
    await tester.dragFrom(
      Offset(120, tester.getBottomRight(month).dy + 40),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    _expectInSegment(tester, find.text('当天没有任务'), OrbitCardEdge.single);

    // 议程档组卡：日期头是首段，任务行在段内
    await tester.tap(find.byTooltip('切换到议程'));
    await tester.pumpAndSettle();
    expect(find.byType(OrbitMonthCalendar), findsNothing);
    _expectInSegment(tester, find.text('完成移动端重构方案评审'));
    expect(
      find.byWidgetPredicate(
        (w) => w is OrbitCardSegment && w.edge == OrbitCardEdge.first,
        description: '组卡首段（日期头）',
      ),
      findsWidgets,
    );
  });
}
