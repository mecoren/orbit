// 日历视图组件测试（wait-home 风格重构版）：月历农历副标签/任务圆点 +
// 下方按日分组列表点击进详情 + 休/班徽标 + 长按日格快捷新增（预填截止日）+
// 年视图入口 + 月导航/今天回位 + 手动更新链路（MockOrbitBridge 注入）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/calendar_screen.dart';
import 'package:orbit/modules/todo/logic/time_block.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/core/theme/app_dimens.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/modules/todo/year_overview_page.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_list_card.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_month_calendar.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_page_header.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_timeline_day.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:table_calendar/table_calendar.dart'
    show CalendarFormat, TableCalendar;
import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestAppRouter(routerConfig: _router),
    );

/// 极简路由：侧栏 + 日历 + 详情占位页
/// （点击任务卡后以「detail:」前缀文本页落地，验证导航目标）
late GoRouter _router;

MockOrbitBridge _seededBridge() {
  final bridge = MockOrbitBridge();
  bridge.store.seed();
  return bridge;
}

/// 含 2026-10 国庆假期的桥（复现「翻到十月应看到假期」场景）
/// 用上/下月钮把月历导航到目标年月——假期徽标用例写死「一次下个月到
/// 2026-10」，跨月后（2026-10-01 起）一按就进 11 月，徽标断言整体漂移；
/// 按当前月差导航才能与真实「今天」解耦。
Future<void> _navigateToMonth(WidgetTester tester, int year, int month) async {
  var diff = (year - DateTime.now().year) * 12 + (month - DateTime.now().month);
  while (diff > 0) {
    await tester.tap(find.byTooltip('下个月'));
    await tester.pumpAndSettle();
    diff--;
  }
  while (diff < 0) {
    await tester.tap(find.byTooltip('上个月'));
    await tester.pumpAndSettle();
    diff++;
  }
}

/// 视图档切换（页头档位抽屉 → 点选一项）
///
/// [from] 是切换前的档位名（页头 tooltip 内嵌当前档位，用它定位按钮）；
/// 抽屉关闭有动画 + 确认值在关闭收尾后才回调用方（shadcn overlay 语义），
/// 故点选后再 pumpAndSettle 一轮。
/// 时间轴档的「N 个时段」徽标计数（档内工具条；-1 = 未找到徽标）
int _badgeCount(WidgetTester tester) {
  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    final d = t.data;
    if (d != null && d.contains('个时段')) {
      return int.tryParse(d.split(' ').first) ?? -1;
    }
  }
  return -1;
}

Future<void> _switchViewMode(
  WidgetTester tester,
  String to, {
  String from = '月历',
}) async {
  await tester.tap(find.byTooltip('切换视图（当前：$from）'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(to));
  await tester.pumpAndSettle();
}

/// 长按拾起 + 纵向拖动块（#75 手势口径：长按 500ms 后才接管纵向位移）
///
/// `longPress` 需要超过默认阈值才触发，必须显式给时长；随后 `moveBy` 沿
/// 长按起点移动（tester 记的是同一个 pointer）。
Future<void> _dragTimeslotBlock(
  WidgetTester tester,
  Finder block, {
  required double dy,
}) async {
  final start = tester.getCenter(block);
  final gesture = await tester.startGesture(start);
  // 超阈值的长按（默认 500ms，这里给 600 留余量）
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.moveBy(Offset(0, dy));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
  // 落库走桥的 Future.delayed（mock 延迟），须推过它才拿到新值
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  // 落库成功弹 WaitToast，其停留计时器在用例结束时须推掉
  // （库内 Timer 不随条目 dispose 取消——见 AGENTS「测试收尾推掉 toast 计时器」）
  await drainToastTimers(tester);
}

/// 时间轴块的标题文案（块内 Text，非档内工具条）
Finder timeslotBlock(String title) => find.text(title);

/// 把测试视口放大到能整屏装下 24h 网格（1152dp）——默认 800×600 下
/// 靠后的时段块落在视口外，手势命中不到（拖拽手势必须打在块上）。
void _wideSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(1600, 3400); // 800×1700 逻辑像素
  addTearDown(tester.view.reset);
}

/// 含带时刻任务的桥（时间轴档用）：显式 start / due 倒推 / 次日 /
/// 次周（第 5 天）/ 两周（第 9 天）各一——后两者供跨度档断言
class _TimedBridge extends MockOrbitBridge {
  @override
  Future<List<HolidayInfo>> holidayList() async => const [];
}

MockOrbitBridge _timedBridge() {
  final bridge = _TimedBridge();
  bridge.store.seed();
  final now = bridge.store.now();
  final today = DateTime.fromMillisecondsSinceEpoch(now);

  /// 相对今天第 dayOffset 天的 HH:mm 时间戳（锚 mock 时钟，不随真实时间漂移）
  int at(int dayOffset, int h, [int m = 0]) => DateTime(
        today.year,
        today.month,
        today.day + dayOffset,
        h,
        m,
      ).millisecondsSinceEpoch;
  final rows = <Map<String, Object?>>[
    // 显式排程：start 带时刻 → 块起点即 start
    {'id': 701, 'title': '显式排程块', 'start': at(0, 9), 'due': null, 'dur': 60},
    // 截止倒推：due 带时刻 → 块起点 = due − 时长
    {'id': 702, 'title': '倒推块', 'start': null, 'due': at(0, 18), 'dur': 90},
    // 次日块（三日跨度才可见）
    {'id': 703, 'title': '次日块', 'start': at(1, 10), 'due': null, 'dur': 30},
    // 次周块（周/两周跨度才可见）
    {'id': 704, 'title': '次周块', 'start': at(5, 10), 'due': null, 'dur': 30},
    // 两周块（两周跨度才可见）
    {'id': 705, 'title': '两周块', 'start': at(9, 14), 'due': null, 'dur': 30},
  ];
  for (final r in rows) {
    bridge.store.tasks[r['id'] as int] = {
      'id': r['id'],
      'uuid': 'uuid-timed-${r['id']}',
      'title': r['title'],
      'description': null,
      'project_id': null,
      'priority': 0,
      'status': 'pending',
      'done': 0,
      'done_at': null,
      'due_date': r['due'],
      'start_date': r['start'],
      'repeat_after': 1,
      'repeat_mode': 0,
      'repeat_weekdays': 0,
      'repeat_end_type': 0,
      'repeat_end_param': 0,
      'repeat_from_done': 0,
      'repeat_month_mode': 0,
      'repeat_nth_week': 0,
      'duration_minutes': r['dur'],
      'percent_done': 0,
      'position': r['id'],
      'is_favorite': 0,
      'my_day_date': null,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
      'version': 1,
    };
  }
  return bridge;
}

class _OctHolidayBridge extends MockOrbitBridge {
  @override
  Future<List<HolidayInfo>> holidayList() async => const [
        HolidayInfo(date: '2026-09-25', year: 2026, isHoliday: true, name: '中秋节'),
        HolidayInfo(date: '2026-10-01', year: 2026, isHoliday: true, name: '国庆节'),
        HolidayInfo(date: '2026-10-02', year: 2026, isHoliday: true, name: '国庆节'),
        HolidayInfo(date: '2026-10-08', year: 2026, isHoliday: true, name: '国庆节'),
        HolidayInfo(date: '2026-10-10', year: 2026, isHoliday: false, name: '国庆节后补班'),
      ];
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

  /// 页头标题里的月份大字（titleWidget 槽内唯一以「月」结尾的 Text；
  /// 相对天数小字「N天前/N天后」不含「月」，trailing 提示在 title 之后）
  String headerTitle(WidgetTester tester) => tester
      .widget<Text>(find
          .descendant(
            of: find.byType(OrbitPageHeader),
            matching: find.textContaining('月'),
          )
          .first)
      .data!;

  /// 页头标题槽内按字面找 Text
  Finder headerText(String text) => find.descendant(
        of: find.byType(OrbitPageHeader),
        matching: find.text(text),
      );

  /// 整页滚动一屏（起点取月历下缘之下的列表区）：网格起滑的纵向手势已被
  /// 「上滑收周条/下滑展开」接管（AvailableGestures.all），从列表区起滑
  /// 才走外层整页滚动
  Future<void> dragListUp(WidgetTester tester, [double dy = -300]) async {
    final calendarBottom =
        tester.getBottomRight(find.byType(OrbitMonthCalendar)).dy;
    await tester.dragFrom(Offset(120, calendarBottom + 40), Offset(0, dy));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  /// 树内的 table_calendar 实例（应用侧是 `TableCalendar<void>`，byType 的
  /// `TableCalendar<dynamic>` 泛型实参不等会扑空，走 `is` 子类型判定）
  Finder tableCalendarFinder() => find.byWidgetPredicate(
        (w) => w is TableCalendar,
        description: 'TableCalendar',
      );

  TableCalendar calendarOf(WidgetTester tester) =>
      tester.widget<TableCalendar>(tableCalendarFinder());

  CalendarFormat calendarFormatOf(WidgetTester tester) =>
      calendarOf(tester).calendarFormat;

  testWidgets('月历+选中日任务卡：当天任务卡渲染，点击进详情页', (tester) async {
    final bridge = _seededBridge();
    // 造一条今天截止的未完成任务：月档下方列表 = 选中日任务卡，
    // 只有选中日（默认今天）的任务出现
    final now = bridge.store.now();
    bridge.store.tasks[8001] = {
      'id': 8001,
      'uuid': 'uuid-cal-1',
      'title': '今日评审任务',
      'description': null,
      'project_id': null,
      'priority': 3,
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
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 月历：农历副标签渲染（数字格下方，如「十九」等农历日名/节气/节日）
    // 星期表头存在（周一始）
    expect(find.text('一'), findsOneWidget);

    // 选中日任务卡（整页滚动布局下滚到可见）
    final card = find.text('今日评审任务');
    // 竖滚起点在列表区（网格起滑会被周历收展手势接管，见 dragListUp）
    await dragListUp(tester, -400);
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
    // 页头：月份导航标题仅显月份（「日历」文字标题已收敛进月份标题）
    expect(headerText('${DateTime.now().month}月'), findsOneWidget);

    // 从 2026-09 向前翻到 2026-01（同年 → 标题无年份前缀）
    for (var i = 0; i < 10; i++) {
      if (headerText('1月').evaluate().isNotEmpty) break;
      await tester.tap(find.byTooltip('上个月'));
      await tester.pumpAndSettle();
    }
    expect(headerText('1月'), findsOneWidget);

    // 元旦（01-01 放假）与补班日（01-04）徽标同屏可见
    expect(find.text('休'), findsWidgets);
    expect(find.text('班'), findsWidgets);
  });

  testWidgets('长按日格：弹出快速添加面板且截止预填为该日', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 长按今天格（月历 OrbitMonthCalendar 的日格）
    final today = DateTime.now();
    final dayText = find.text('${today.day}').first;
    await tester.longPress(dayText, warnIfMissed: false);
    await tester.pumpAndSettle();

    // 统一新建入口：快速添加面板打开（不再是完整表单）
    expect(find.text('准备做什么？'), findsOneWidget);

    // 截止预填今天：选中态落底部图标（tooltip 带值），顶部不加 chips 行
    expect(find.byTooltip('截止：今天'), findsOneWidget);
    final ymd =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    expect(find.text(ymd), findsNothing);
  });

  testWidgets('年视图：点月份标题进入，干支生肖 + 迷你月历 + 点日期返回', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 点月份标题 → 年视图页（干支生肖标签 + 12 迷你月历）
    await tester.tap(headerText('${DateTime.now().month}月').first);
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
    expect(headerText('9月'), findsOneWidget);
  });

  testWidgets('手动更新：点击刷新按钮 → toast「节假日数据已更新」', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    final refresh = find.byIcon(OrbitIcons.refresh);
    expect(refresh, findsOneWidget);
    await tester.tap(refresh);
    await tester.pump(); // 触发 _updateHolidays async 开始
    await tester.pump(const Duration(milliseconds: 300)); // mock 延迟
    await tester.pump(); // WaitToast Overlay 插入帧

    expect(find.text('节假日数据已更新'), findsOneWidget);
    // provider 已失效重拉（mock 返回相同常量，断言不抛错即通过）
    expect(headerText('${DateTime.now().month}月'), findsOneWidget);
    // 快进过 toast 的 2.6s 自动收起 Timer（防测试结束时 pending timer 断言）
    await tester.pump(const Duration(milliseconds: 2700));
  });

  testWidgets('页头相对天数小字：跟随选中日（点日格即变），翻月未选中回落锚定 1 号',
      (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // 仅显月份：当前年不带年份前缀（跨年才补「YYYY年」小字，与月历表头同约定）
    expect(headerTitle(tester), '${now.month}月');
    // 旧格式「YYYY年M月」不再出现
    expect(find.textContaining('年${now.month}月'), findsNothing);

    // 默认选中今天：小字「今天」（选中日在所看月份内 → 锚定选中日）
    expect(headerText('今天'), findsOneWidget);

    // 点当月另一天（距今天恰 5 天）：小字立即跟随选中日
    final targetDay = now.day >= 6 ? now.day - 5 : now.day + 5;
    final targetLabel = now.day >= 6 ? '5天前' : '5天后';
    await tester.tap(find.text('$targetDay').first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(headerText(targetLabel), findsOneWidget);
    // 同月内选择：月份标题不变
    expect(headerTitle(tester), '${now.month}月');

    // 翻到下月（选中日留在本月）：回落为下月 1 号距今天（竞品月份口径）
    await tester.tap(find.byTooltip('下个月'));
    await tester.pumpAndSettle();
    final nextDiff = DateTime(now.year, now.month + 1, 1).difference(today).inDays;
    expect(headerTitle(tester), '${DateTime(now.year, now.month + 1).month}月');
    expect(
        headerText(nextDiff == 0
            ? '今天'
            : '${nextDiff.abs()}天${nextDiff < 0 ? '前' : '后'}'),
        findsOneWidget);
  });

  testWidgets('月历去卡片化：网格直接铺底（无卡片分段包裹），左右与上方间隔保留',
      (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    final calendar = find.byType(OrbitMonthCalendar);
    // 去卡片：月历不再包在 OrbitCardSegment 白卡里（描边/圆角/内衬一并移除）
    expect(
      find.ancestor(of: calendar, matching: find.byType(OrbitCardSegment)),
      findsNothing,
    );

    // 左右间隔保留：左缘距屏幕 space12（去卡片前是卡片 12 + 内衬 8 = 20）
    expect(tester.getTopLeft(calendar).dx, AppDimens.space12);
    // 上方间隔保留：顶缘 = 页头行高 + 页头下 space8 留白
    expect(tester.getTopLeft(calendar).dy,
        OrbitPageHeader.rowHeight + AppDimens.space8);
  });

  testWidgets('年视图间距：页边距 16 / 行组间隔 32 / 日格行高 24（参考三列竞品版式）',
      (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: const YearOverviewPage(initialYear: 2026, initialMonth: 9),
      ),
    );
    await settle(tester);

    // 滚动区内边距：左右页边距 space16、顶部 space12、底部 space32
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    final pad = scroll.padding! as EdgeInsets;
    expect(pad.left, AppDimens.space16);
    expect(pad.top, AppDimens.space12);
    expect(pad.bottom, AppDimens.space32);

    // 行组间隔（1-3 月行块 → 4-6 月行块）= space32
    // （外层月份行是全页唯一 crossAxisAlignment.start 且含月份标题的 Row，
    // 迷你月历内部行均为默认 center）
    Finder monthRow(String title) => find.ancestor(
          of: find.text(title),
          matching: find.byWidgetPredicate(
            (w) => w is Row && w.crossAxisAlignment == CrossAxisAlignment.start,
          ),
        );
    expect(monthRow('1月'), findsOneWidget);
    final gap = tester.getTopLeft(monthRow('4月')).dy -
        tester.getBottomLeft(monthRow('1月')).dy;
    expect(gap, AppDimens.space32);

    // 日格行高 = 24（相邻两行同列日期：1 → 8）
    final d1 = tester.getTopLeft(find.text('1').first).dy;
    final d8 = tester.getTopLeft(find.text('8').first).dy;
    expect(d8 - d1, 24);
  });

  testWidgets('月导航：上/下月翻页与「今天」回位', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    final currentTitle = headerTitle(tester);

    // 下一个月 → 标题变化（页头翻页钮，tooltip 精确定位）
    await tester.tap(find.byTooltip('下个月'));
    await tester.pumpAndSettle();
    final nextTitle = headerTitle(tester);
    expect(nextTitle, isNot(currentTitle));

    // 点「回到今天」按钮 → 标题还原
    await tester.tap(find.byIcon(OrbitIcons.calendarCheck));
    await tester.pumpAndSettle();
    expect(headerTitle(tester), currentTitle);
  });

  testWidgets('左右滑动翻月：左滑到下月、右滑回上月', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    String title() => headerTitle(tester);
    final currentTitle = title();

    // 月历区域左滑 → 下月（fling 兼有位移与速度，两个判据都越阈）。
    // 起点取**日期格**而非星期表头：v3 月历的横滑由 table_calendar 的 PageView
    // 承担，星期表头在 PageView 之外，从表头起滑不会翻页
    final dayCell = find.text('${DateTime.now().day}').first;
    await tester.fling(dayCell, const Offset(-320, 0), 900);
    await tester.pumpAndSettle();
    expect(title(), isNot(currentTitle));

    // 右滑 → 回到原月份
    await tester.fling(find.text('${DateTime.now().day}').first,
        const Offset(320, 0), 900);
    await tester.pumpAndSettle();
    expect(title(), currentTitle);
  });

  testWidgets('横滑翻月后网格与标题同步：目标月假期徽标不丢', (tester) async {
    final bridge = _OctHolidayBridge()..store.seed();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 先导航到 2026-09（假期月的上一个月）再横滑进 10 月：从「当前月」横滑
    // 一次的写法跨月后会漂（2026-10-01 起一滑就进 11 月，10 月徽标断言全空）。
    // 起滑点用 15 号——任何月份网格里都存在，不依赖「今天是几号」。
    await _navigateToMonth(tester, 2026, 9);
    await tester.fling(find.text('15').first, const Offset(-320, 0), 900);
    await tester.pumpAndSettle();
    expect(headerText('10月'), findsOneWidget);

    // 网格必须真的渲染 10 月：10/1、10/2、10/8 的「休」与 10/10 的「班」可见。
    // 修复前 firstDay/lastDay 随 month 漂移（`month ± 5 年`），横滑后 PageView
    // 页索引语义整体错位——标题已到 10 月而网格落在相邻月，徽标全无。
    // 断言收窄在月历网格内：选中日（今天 9-25，mock 里也是「休」）的日期头
    // 徽标会在网格之外多出一枚，不能计入网格渲染数
    final gridHoliday = find.descendant(
      of: find.byType(OrbitMonthCalendar),
      matching: find.text('休'),
    );
    expect(gridHoliday, findsNWidgets(3));
    final gridWorkday = find.descendant(
      of: find.byType(OrbitMonthCalendar),
      matching: find.text('班'),
    );
    expect(gridWorkday, findsOneWidget);
  });

  testWidgets('月历上滑收成单行周条、下滑展开复原（收起对齐选中日所在周）',
      (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    final calendar = find.byType(OrbitMonthCalendar);
    final monthHeight = tester.getSize(calendar).height;
    final today = DateTime.now().day;

    // 在日格上上滑 → 收成单行周条（table_calendar 档位切到 week）
    await tester.fling(find.text('$today').first, const Offset(0, -220), 800);
    await tester.pumpAndSettle();
    expect(calendarFormatOf(tester), CalendarFormat.week);
    expect(tester.getSize(calendar).height, lessThan(monthHeight));
    // 周条 = 选中日（今天）所在周：今天仍在条内
    expect(find.text('$today'), findsWidgets);
    // focusedDay 原样落在选中日（收起对齐选中周，未拽回月初那一周）
    final focused = calendarOf(tester).focusedDay;
    expect(focused.year, DateTime.now().year);
    expect(focused.month, DateTime.now().month);
    expect(focused.day, DateTime.now().day);

    // 周条横滑翻周：focused 逐字 ±7 天（onPageChanged 原样回传口径）
    await tester.fling(find.text('$today').first, const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    final focusedAfterWeekSwipe = calendarOf(tester).focusedDay;
    expect(
      focusedAfterWeekSwipe.difference(DateTime.now()).inDays.abs(),
      inInclusiveRange(6, 8),
    );
    expect(calendarFormatOf(tester), CalendarFormat.week);

    // 下滑 → 展开回整月档（翻周后「今天」已不在条内，锚点改取条内任意日号格）
    final anyDayCell = find.descendant(
      of: tableCalendarFinder(),
      matching: find.byWidgetPredicate(
        (w) => w is Text && int.tryParse(w.data ?? '') != null,
      ),
    ).first;
    await tester.fling(anyDayCell, const Offset(0, 220), 800);
    await tester.pumpAndSettle();
    expect(calendarFormatOf(tester), CalendarFormat.month);
    expect(tester.getSize(calendar).height, monthHeight);
  });

  testWidgets('周条跨月周：补位日期不弱化（dimOutsideMonth=false 生效）',
      (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 收成周条后，条内所有日号一律正常色（周档 dimOutsideMonth=false）：
    // 找出条内任一日期格断言非 deactivatedText（月档下补位格是弱化灰，
    // 开关若失效跨月周会露灰）
    await tester.fling(find.text('${DateTime.now().day}').first,
        const Offset(0, -220), 800);
    await tester.pumpAndSettle();
    expect(calendarFormatOf(tester), CalendarFormat.week);

    final strip = find.descendant(
      of: tableCalendarFinder(),
      matching: find.byWidgetPredicate(
        (w) => w is Text && int.tryParse(w.data ?? '') != null,
      ),
    );
    expect(strip, findsWidgets);
    for (final text in tester.widgetList<Text>(strip)) {
      expect(
        text.style!.color,
        isNot(AppColors.light.deactivatedText),
        reason: '周条内 ${text.data} 不应弱化',
      );
    }
  });

  testWidgets('页签根语义：页头无返回键（日历已是底部页签，回退由导航承担）', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.byType(CalendarScreen), findsOneWidget);
    // 日历升级为底部页签根：页头不带返回键（原「侧栏入口行」随页签化移除）
    expect(find.byTooltip('返回'), findsNothing);
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
    // 竖滚起点在列表区（网格起滑会被周历收展手势接管，见 dragListUp）
    await dragListUp(tester, -400);
    expect(find.textContaining('压测任务'), findsWidgets);

    // 在列表区竖向拖动，验证滚动查看不崩溃且卡片仍渲染
    final anyCard = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_DayTaskRow',
    );
    expect(anyCard, findsWidgets);
    await dragListUp(tester, -300);
    expect(anyCard, findsWidgets);
  });

  // ── 议程档（docs/07 #56：对齐桌面 CalendarSubMode.agenda）──

  testWidgets('议程档：切档隐藏月历网格，仅保留按日分组列表', (tester) async {
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 月档：网格在树内（月历自带星期表头与农历副标签）
    expect(find.byType(OrbitMonthCalendar), findsOneWidget);
    expect(find.text('长按日历快捷新增'), findsOneWidget);

    await _switchViewMode(tester, '议程');

    // 议程档：网格整体退出树，提示改口横滑翻月
    expect(find.byType(OrbitMonthCalendar), findsNothing);
    expect(find.text('左右滑动切换月份'), findsOneWidget);

    // 列表数据不受档位影响（种子任务卡仍在树内；整页 Column 非懒构建）
    expect(find.text('完成移动端重构方案评审'), findsWidgets);

    // 切回月档：网格恢复（注意不要先滚动页面，否则工具栏按钮不可命中）
    await _switchViewMode(tester, '月历', from: '议程');
    expect(find.byType(OrbitMonthCalendar), findsOneWidget);
    expect(find.text('长按日历快捷新增'), findsOneWidget);
  });

  testWidgets('议程档：日期头带休/班徽标（网格已隐藏，徽标只能来自日期头）', (tester) async {
    final bridge = _OctHolidayBridge()..store.seed();
    final now = bridge.store.now();
    // 造两天任务：2026-10-01（mock 休）与 2026-10-10（mock 班）
    final dueMsList = [
      DateTime(2026, 10, 1, 9).millisecondsSinceEpoch,
      DateTime(2026, 10, 10, 9).millisecondsSinceEpoch,
    ];
    for (var i = 0; i < dueMsList.length; i++) {
      final id = 500 + i;
      bridge.store.tasks[id] = {
        'id': id,
        'uuid': 'uuid-holiday-$i',
        'title': '假期任务$i',
        'description': null,
        'project_id': null,
        'priority': 0,
        'status': 'pending',
        'done': 0,
        'done_at': null,
        'due_date': dueMsList[i],
        'start_date': null,
        'repeat_after': 1,
        'repeat_mode': 0,
        'percent_done': 0,
        'position': 500 + i,
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

    // 翻到 2026-10 后切议程档（按当前月差导航，跨月不漂）
    await _navigateToMonth(tester, 2026, 10);
    expect(headerText('10月'), findsOneWidget);
    await _switchViewMode(tester, '议程', from: '月历');

    expect(find.byType(OrbitMonthCalendar), findsNothing);
    expect(find.text('假期任务0'), findsOneWidget);
    expect(find.text('休'), findsWidgets);
    expect(find.text('班'), findsWidgets);
  });

  // ── 时间轴档（docs/07 #74：对标 TickTick 移动端 Timeline）──

  testWidgets('时间轴档：切档隐藏月历网格，只出 24h 网格与时段块', (tester) async {
    final bridge = _timedBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 月档先在树内
    expect(find.byType(OrbitMonthCalendar), findsOneWidget);

    await _switchViewMode(tester, '时间');
    expect(find.byType(OrbitMonthCalendar), findsNothing);
    expect(find.text('时间轴'), findsOneWidget);
    // 两个带时刻任务（显式 start + due 倒推）都出块，倒推块按 due − 时长
    expect(find.text('显式排程块'), findsOneWidget);
    expect(find.text('倒推块'), findsOneWidget);
    // 24h 刻度（每 2 小时标注一次 → 00:00 与 22:00 两端可见）
    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('22:00'), findsOneWidget);
    // 块数徽标存在且 ≥ 本用例的两块
    expect(_badgeCount(tester), greaterThanOrEqualTo(2));
  });

  testWidgets('时间轴档：跨度 日 ⇄ 三日 往返（三日渲染两天块）', (tester) async {
    final bridge = _timedBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);
    await _switchViewMode(tester, '时间');

    // 日档：当天两个块（种子另有带时刻任务，故用本用例两块的存在性断言）
    expect(find.text('显式排程块'), findsOneWidget);
    expect(find.text('倒推块'), findsOneWidget);
    final day1Badge = _badgeCount(tester);

    // 切三日：第二天的块也出现（相邻两日各一个块）
    await tester.tap(find.text('三日'));
    await tester.pumpAndSettle();
    expect(find.text('显式排程块'), findsOneWidget);
    expect(find.text('倒推块'), findsOneWidget);
    expect(find.text('次日块'), findsOneWidget);
    // 徽标计数随跨度增长（种子任务里另有带时刻的任务，故只断言相对关系，
    // 不断言绝对数字——那会把种子数据变化变成假红）
    expect(_badgeCount(tester), greaterThan(day1Badge));

    // 切回日档：次日块退出树
    await tester.tap(find.text('日'));
    await tester.pumpAndSettle();
    expect(find.text('次日块'), findsNothing);
  });

  testWidgets('时间轴档：跨度档补 周 / 两周（对齐桌面 TIMELINE_SPANS）', (tester) async {
    final bridge = _timedBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);
    await _switchViewMode(tester, '时间');

    // 四个跨度档钮齐在；日档只见当天块
    expect(find.text('日'), findsOneWidget);
    expect(find.text('三日'), findsOneWidget);
    expect(find.text('周'), findsOneWidget);
    expect(find.text('两周'), findsOneWidget);
    expect(find.text('次周块'), findsNothing);
    expect(find.text('两周块'), findsNothing);

    // 周档（7 天）：第 5 天的块进入树，两周块仍不可见
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    expect(find.text('次周块'), findsOneWidget);
    expect(find.text('两周块'), findsNothing);

    // 两周档（14 天）：第 9 天的块也进入树
    await tester.tap(find.text('两周'));
    await tester.pumpAndSettle();
    expect(find.text('两周块'), findsOneWidget);

    // 切回日档：跨度外段落整体退出
    await tester.tap(find.text('日'));
    await tester.pumpAndSettle();
    expect(find.text('次周块'), findsNothing);
    expect(find.text('两周块'), findsNothing);
  });

  // ── 时间轴拖拽（docs/07 #75：长按 500ms 拾起 + 纵向改时刻）──

  testWidgets('时间轴拖拽：显式排程块长按下拖 → 落库 start_date（15 分钟吸附）',
      (tester) async {
    _wideSurface(tester);
    final bridge = _timedBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);
    await _switchViewMode(tester, '时间');

    final block = timeslotBlock('显式排程块');
    expect(block, findsOneWidget);

    await _dragTimeslotBlock(tester, block, dy: 48); // 48px = 1 小时

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final t = tasks!.firstWhere((x) => x.title == '显式排程块');
    final now = bridge.store.now();
    final today = DateTime.fromMillisecondsSinceEpoch(now);
    expect(
      t.startDate,
      DateTime(today.year, today.month, today.day, 10).millisecondsSinceEpoch,
      reason: '09:00 下拖 48px（1h）→ 10:00',
    );
    // due 未动（只改起点）
    expect(t.durationMinutes, 60);
  });

  testWidgets('时间轴拖拽：截止倒推块长按下拖 → 改 due_date 且不种 start',
      (tester) async {
    _wideSurface(tester);
    final bridge = _timedBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);
    await _switchViewMode(tester, '时间');

    // 倒推块：due 18:00 / 90 分 → 块起点 16:30
    await _dragTimeslotBlock(tester, timeslotBlock('倒推块'), dy: 48);

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final t = tasks!.firstWhere((x) => x.title == '倒推块');
    final now = bridge.store.now();
    final today = DateTime.fromMillisecondsSinceEpoch(now);
    // 起点 16:30 + 48px(1h) = 17:30 → due = 17:30 + 90 分 = 19:00
    expect(
      t.dueDate,
      DateTime(today.year, today.month, today.day, 19).millisecondsSinceEpoch,
    );
    expect(
      t.startDate,
      isNull,
      reason: '倒推块绝不种 start_date（否则语义从「截止收拢」漂移成「显式排程」）',
    );
  });

  testWidgets('时间轴拖拽：半格内位移不写库（同刻落回）', (tester) async {
    _wideSurface(tester);
    final bridge = _timedBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);
    await _switchViewMode(tester, '时间');

    final before = (await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    ))!
        .firstWhere((x) => x.title == '显式排程块')
        .startDate;

    // 3px = 3.75 分钟 < 半格（7.5）→ 吸回原格 → 无变化
    await _dragTimeslotBlock(tester, timeslotBlock('显式排程块'), dy: 3);

    final after = (await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    ))!
        .firstWhere((x) => x.title == '显式排程块')
        .startDate;
    expect(after, before, reason: '吸附回原格不应产生写库');
  });

  testWidgets('时间轴拖拽：轻点（不长按）仍进详情，不误触发拖拽', (tester) async {
    _wideSurface(tester);
    final bridge = _timedBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);
    await _switchViewMode(tester, '时间');

    await tester.tap(timeslotBlock('显式排程块'));
    await tester.pumpAndSettle();
    expect(find.text('detail:701'), findsOneWidget);

    // 起点未被拖动
    final t = (await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    ))!
        .firstWhere((x) => x.title == '显式排程块');
    final now = bridge.store.now();
    final today = DateTime.fromMillisecondsSinceEpoch(now);
    expect(
      t.startDate,
      DateTime(today.year, today.month, today.day, 9).millisecondsSinceEpoch,
    );
  });

  // 契约前置守卫：seed 的 due 必须是本地零点（纯日期）。
  // 曾经用 `now() + N 天` 造 due 会把跑测时刻带进去，时间轴档按
  // 「块起点日」分桶时，UTC 00:00–01:30 窗口内「明天截止 −90 分钟」的
  // 倒推块会落回今天，把下面那条空态用例变成随跑测时刻漂移的假红
  // （2026-10-11 flutter-mobile CI 即栽在此处）。
  test('种子契约：seed 任务的 due 均为纯日期（无时刻）', () {
    final bridge = _seededBridge();
    for (final t in bridge.store.tasks.values) {
      expect(
        hasTimePart(t['due_date'] as int?),
        isFalse,
        reason: '「${t['title']}」的 due 带了时刻——时间轴档会据此出块',
      );
    }
  });

  testWidgets('时间轴档：无时段时出空态（不是空白网格）', (tester) async {
    // 默认种子任务的 due 均为纯日期 → 无任何时段块（由上一条守卫钉住）
    final bridge = _seededBridge();
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);
    await _switchViewMode(tester, '时间');

    expect(find.byType(OrbitTimelineEmpty), findsOneWidget);
    expect(find.text('暂无时段'), findsOneWidget);
    expect(find.textContaining('没有可排时段的任务'), findsOneWidget);
  });

  testWidgets('选中日列表样式切换：卡片 ⇄ 时间线往返 + 时刻左置', (tester) async {
    final bridge = _seededBridge();
    // 造一条今天 17:00 截止的任务（时刻确定，非零点，时间线左列必渲染）
    final now = DateTime.now();
    final due = DateTime(now.year, now.month, now.day, 17).millisecondsSinceEpoch;
    bridge.store.tasks[9001] = {
      'id': 9001,
      'uuid': 'uuid-style-1',
      'title': '样式切换任务',
      'description': null,
      'project_id': null,
      'priority': 0,
      'status': 'pending',
      'done': 0,
      'done_at': null,
      'due_date': due,
      'start_date': null,
      'repeat_after': 1,
      'repeat_mode': 0,
      'percent_done': 0,
      'position': 9001,
      'is_favorite': 0,
      'my_day_date': null,
      'is_deleted': 0,
      'created_at': due,
      'updated_at': due,
      'deleted_at': null,
      'version': 1,
    };
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    Finder timelineRows() => find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_DayTimelineRow',
          description: '_DayTimelineRow',
        );
    // 卡片样式顶层分段（时间线行内部同样用 OrbitCardSegment 包卡片内容，
    // 故不断言绝对零——顶层分段数 == 时间线行数即「无裸卡片分段」）
    Finder cardSegments() => find.byWidgetPredicate(
          (w) =>
              w is OrbitCardSegment &&
              w.child.runtimeType.toString() == '_DayTaskRow',
          description: 'card OrbitCardSegment',
        );
    int count(Finder f) => f.evaluate().length;

    // 默认卡片样式（右列时刻在卡内）
    await dragListUp(tester, -400);
    expect(count(timelineRows()), 0);
    expect(count(cardSegments()) > 0, isTrue);

    // 切时间线：时刻左置列出现，顶层只剩时间线行内嵌的分段
    await tester.ensureVisible(find.byTooltip('切换为时间线样式'));
    await tester.tap(find.byTooltip('切换为时间线样式'));
    await tester.pumpAndSettle();
    expect(count(timelineRows()) > 0, isTrue);
    expect(count(cardSegments()), count(timelineRows()));
    expect(find.text('17:00'), findsWidgets);

    // 切回卡片
    await tester.tap(find.byTooltip('切换为卡片样式'));
    await tester.pumpAndSettle();
    expect(count(timelineRows()), 0);
    expect(count(cardSegments()) > 0, isTrue);
  });

  // ===== 圆点改期（桌面拖拽圆点的移动形态）=====

  testWidgets('点圆点 → 改期抽屉选「明天」：保留原时刻写 due + `+N` 溢出 + 回执',
      (tester) async {
    final bridge = MockOrbitBridge();
    // 清掉种子任务：全月只有今天 5 条（确定 4 显 + `+1` 溢出、点第一枚可断言）
    bridge.store.tasks.clear();
    final now = DateTime.now();
    final due =
        DateTime(now.year, now.month, now.day, 15, 30).millisecondsSinceEpoch;
    for (var i = 1; i <= 5; i++) {
      final id = 8100 + i;
      bridge.store.tasks[id] = {
        'id': id,
        'uuid': 'uuid-reschedule-$id',
        'title': '改期目标$i',
        'description': null,
        'project_id': null,
        'priority': 2,
        'status': 'pending',
        'done': 0,
        'done_at': null,
        'due_date': due,
        'start_date': null,
        'repeat_after': 1,
        'repeat_mode': 0,
        'percent_done': 0,
        'position': i,
        'is_favorite': 0,
        'my_day_date': null,
        'is_deleted': 0,
        'created_at': due,
        'updated_at': due,
        'deleted_at': null,
        'version': 1,
      };
    }
    await tester.pumpWidget(_wrap(const SizedBox(), bridge));
    await settle(tester);

    // 4 显 + `+1`；圆点槽只属于今天格（SizedBox 10×16 是点按热区几何）
    expect(find.text('+1'), findsOneWidget);
    final slots = find.descendant(
      of: find.byType(OrbitMonthCalendar),
      matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == 10 && w.height == 16),
    );
    expect(slots, findsNWidgets(4));

    // 点第一枚圆点（position 升序 = 8101 的任务）→ 改期抽屉
    await tester.tap(slots.first);
    await tester.pumpAndSettle();
    expect(find.text('改期到'), findsOneWidget);

    await tester.tap(find.text('明天'));
    await tester.pumpAndSettle();
    await settle(tester);

    // 原截止 15:30 保留时刻，只换日期（rescheduleDueMs 带时刻分支）
    final next = DateTime(now.year, now.month, now.day + 1, 15, 30)
        .millisecondsSinceEpoch;
    expect(bridge.store.tasks[8101]!['due_date'], next);
    // 其余任务不受影响（只改点中的那枚）
    expect(bridge.store.tasks[8102]!['due_date'], due);
    expect(find.textContaining('已改期至'), findsOneWidget);
    await drainToastTimers(tester);
  });
}
