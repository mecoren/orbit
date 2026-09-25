// 底部导航壳测试：页签切换、今天页签页头（日期副标）、右下悬浮新建钮、
// 「更多」面板（编辑入口 + 条目切分支）、「今天」页签角标、功能模块配置联动
// （MockOrbitBridge 注入 + 生产路由表全链路）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/routing/app_router.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/calendar_screen.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/matrix_screen.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/services/local_prefs.dart';
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

/// 底栏页签按图标定位（栏体纯图标无文字，见 OrbitBottomNav）
Finder _navIcon(IconData icon) => find.descendant(
      of: find.byType(OrbitBottomNav),
      matching: find.byIcon(icon),
    );

void main() {
  setUp(() => LocalPrefs.resetForTest());
  testWidgets('初始落「今天」页签：页头今天 + 日期副标，五枚页签无中央添加钮',
      (tester) async {
    await _pump(tester, _seededBridge());

    expect(find.text('今天'), findsOneWidget); // 仅页头（底栏纯图标无文字）
    // 日期副标（M月D日 周X）随页签根出现
    expect(find.text(todayHeaderLabel(DateTime.now())), findsOneWidget);
    // 五枚页签（图标定位）
    expect(find.byType(OrbitBottomNav), findsOneWidget);
    expect(_navIcon(OrbitIcons.list), findsOneWidget);
    expect(_navIcon(OrbitIcons.calendarDays), findsOneWidget);
    expect(_navIcon(OrbitIcons.grid), findsOneWidget);
    expect(_navIcon(OrbitIcons.more), findsOneWidget);
    // 悬浮新建钮 = 壳里唯一的 OrbitFab 实例
    expect(find.byType(OrbitFab), findsOneWidget);
  });

  testWidgets('切页签：清单 → 日历 → 四象限 → 回今天，各自页面渲染', (tester) async {
    await _pump(tester, _seededBridge());

    await tester.tap(_navIcon(OrbitIcons.list));
    await tester.pumpAndSettle();
    expect(find.byType(SidebarScreen), findsOneWidget);
    expect(find.text('循迹'), findsOneWidget);

    await tester.tap(_navIcon(OrbitIcons.calendarDays));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarScreen), findsOneWidget);

    await tester.tap(_navIcon(OrbitIcons.grid));
    await tester.pumpAndSettle();
    expect(find.byType(MatrixScreen), findsOneWidget);

    await tester.tap(_navIcon(OrbitIcons.sun));
    await tester.pumpAndSettle();
    expect(find.text(todayHeaderLabel(DateTime.now())), findsOneWidget);
  });

  testWidgets('悬浮新建钮：点击弹出快速添加面板', (tester) async {
    await _pump(tester, _seededBridge());

    // 悬浮钮是壳内唯一的 OrbitFab
    await tester.tap(find.byType(OrbitFab));
    await tester.pumpAndSettle();

    expect(find.text('准备做什么？'), findsOneWidget);
  });

  testWidgets('「更多」动作位：弹出面板（标题行带编辑），点条目切分支底栏常驻',
      (tester) async {
    await _pump(tester, _seededBridge());

    await tester.tap(_navIcon(OrbitIcons.more));
    await tester.pumpAndSettle();

    // 面板标题行 + 次级目的地条目齐出（默认配置：统计/搜索/回收站/设置）
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('统计'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    // 点条目 = 切分支（与页签同语义）：底栏保持可见，页面切到统计
    await tester.tap(find.text('统计'));
    await tester.pumpAndSettle();
    expect(find.text('总任务'), findsOneWidget);
    expect(find.byType(OrbitBottomNav), findsOneWidget);
  });

  testWidgets('「更多」面板「编辑」：进功能模块配置页，两段列表齐出',
      (tester) async {
    await _pump(tester, _seededBridge());

    await tester.tap(_navIcon(OrbitIcons.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('功能模块'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    // 顶部预览把下方内容顶出首屏：两段 ReorderableListView 懒构建，
    // 滚到可见再断言（外层 ListView 显式指定，内层段列表不可滚会歧义）
    final pageScroll = find.byType(Scrollable).first;
    // 首屏：已启用段 4 行齐出
    for (final label in ['今天', '清单', '日历', '四象限']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.scrollUntilVisible(find.text('未启用'), 200,
        scrollable: pageScroll);
    expect(find.text('未启用'), findsOneWidget);
    // 滚到底：未启用段 4 行齐出（池内 8 模块全员可见可配）
    await tester.scrollUntilVisible(find.text('设置'), 200,
        scrollable: pageScroll);
    for (final label in ['统计', '搜索', '回收站', '设置']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('功能模块配置页：顶部底栏预览跟随启用序', (tester) async {
    await _pump(tester, _seededBridge());

    await tester.tap(_navIcon(OrbitIcons.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    // 预览 = 底栏落位：今天/清单/日历/四象限 + 更多（纯图标）
    final preview = find.byKey(const ValueKey('nav-preview'));
    expect(preview, findsOneWidget);
    for (final icon in [
      OrbitIcons.sun,
      OrbitIcons.list,
      OrbitIcons.calendarDays,
      OrbitIcons.grid,
      OrbitIcons.more,
    ]) {
      expect(
        find.descendant(of: preview, matching: find.byIcon(icon)),
        findsOneWidget,
      );
    }

    // 默认启用序第 4 枚减号停用四象限 → 预览由统计顺延顶替
    await tester.tap(find.byIcon(OrbitIcons.remove).at(3));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
          of: preview, matching: find.byIcon(OrbitIcons.grid)),
      findsNothing,
    );
    expect(
      find.descendant(
          of: preview, matching: find.byIcon(OrbitIcons.trending)),
      findsOneWidget,
    );
  });

  testWidgets('配置页停用「四象限」：返回壳后底栏页签由统计顺延顶替',
      (tester) async {
    await _pump(tester, _seededBridge());

    await tester.tap(_navIcon(OrbitIcons.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    // 默认启用序 [今天, 清单, 日历, 四象限]：第 4 枚减号停用四象限
    await tester.tap(find.byIcon(OrbitIcons.remove).at(3));
    await tester.pumpAndSettle();
    expect(find.text('四象限'), findsOneWidget); // 移入未启用段

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    // 底栏：四象限图标消失，启用序第 5 位「统计」图标顺延进底栏
    expect(_navIcon(OrbitIcons.grid), findsNothing);
    expect(_navIcon(OrbitIcons.trending), findsOneWidget);
    expect(find.text('今天'), findsOneWidget); // 仅页头（底栏纯图标）
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
