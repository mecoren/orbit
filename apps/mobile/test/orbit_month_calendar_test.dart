// 通用月历（OrbitMonthCalendar）日格呈现口径：
// 当月日期正常显示（周末走识别蓝），前后月补位日期弱显示（deactivatedText 灰）——
// 翻到某月时只有该月是正常读数，其余月份退到背景。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_month_calendar.dart';
import 'package:table_calendar/table_calendar.dart' show CalendarFormat;
import 'support/orbit_test_app.dart';

void main() {
  Future<void> pumpMonth(WidgetTester tester, DateTime month) async {
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(body: OrbitMonthCalendar(month: month, showHeader: false)),
    ));
    await tester.pumpAndSettle();
  }

  Color colorOf(WidgetTester tester, String day) =>
      tester.widget<Text>(find.text(day)).style!.color!;

  testWidgets('当月日期正常显示、前后月补位日期弱显示', (tester) async {
    // 2026-02 网格 = 1/26..1/31 + 2/1..2/28 + 3/1..3/8；
    // 1/29（周四）、1/31（周六）为补位格，2/10（周二）、2/14（周六）为当月格
    // —— 四者在网格中均无同名日号，find.text 无歧义
    await pumpMonth(tester, DateTime(2026, 2));

    // 补位格：弱显示（退到 deactivatedText 灰，周末识别蓝一并退掉）
    expect(colorOf(tester, '29'), AppColors.light.deactivatedText);
    expect(colorOf(tester, '31'), AppColors.light.deactivatedText);

    // 当月格：正常显示（普通日主文字色、周末识别蓝）
    expect(colorOf(tester, '10'), AppColors.light.titleText);
    expect(colorOf(tester, '14'), ChineseCalendarColors.weekend);
  });

  testWidgets('dimOutsideMonth=false：补位日期不弱化（周条跨月周口径）', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: OrbitMonthCalendar(
          month: DateTime(2026, 2),
          showHeader: false,
          dimOutsideMonth: false,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 同一批补位格转正常读数：工作日主文字色、周末识别蓝（与当月格同档）
    expect(colorOf(tester, '29'), AppColors.light.titleText);
    expect(colorOf(tester, '31'), ChineseCalendarColors.weekend);
  });

  // ===== 纵向收展手势（月 ⇄ 周，轴锁定口径）=====
  // 只有「纵向位移 ≥40px 且达到横向位移 1.2 倍」的手势才步进档位；横滑
  // 翻周/翻月带出的斜向弧线不得触发收展（table_calendar 内置检测只累计
  // 纵向分量 25px 即触发，先纵后横的弧线会被误判——2026-09-26 实测）。

  /// 多档月历（month ⇄ week），返回 onFormatChange 的捕获列表
  Future<List<CalendarFormat>> pumpFormatCalendar(
    WidgetTester tester,
    CalendarFormat format,
  ) async {
    final captured = <CalendarFormat>[];
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: OrbitMonthCalendar(
          month: DateTime(2026, 2),
          focusedDay: DateTime(2026, 2, 10),
          showHeader: false,
          calendarFormat: format,
          availableCalendarFormats: const {
            CalendarFormat.month: '月',
            CalendarFormat.week: '周',
          },
          onFormatChange: captured.add,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return captured;
  }

  /// 网格上的手势起点（周条/首行日格内）
  Offset gridPoint(WidgetTester tester) =>
      tester.getTopLeft(find.byType(OrbitMonthCalendar)) +
      const Offset(100, 60);

  Future<void> dragPath(WidgetTester tester, List<Offset> moves) async {
    final gesture = await tester.startGesture(gridPoint(tester));
    for (final move in moves) {
      await gesture.moveBy(move);
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('月档直线上滑收成周条（基线）', (tester) async {
    final captured = await pumpFormatCalendar(tester, CalendarFormat.month);
    await dragPath(tester, const [Offset(0, -40), Offset(0, -80)]);
    expect(captured, [CalendarFormat.week]);
  });

  testWidgets('月档横滑翻月不误触发收展（基线）', (tester) async {
    final captured = await pumpFormatCalendar(tester, CalendarFormat.month);
    await dragPath(tester, const [Offset(-80, 0), Offset(-120, 0)]);
    expect(captured, isEmpty);
  });

  testWidgets('周档下先纵后横的弧线不触发收展（斜向误触发回归）', (tester) async {
    final captured = await pumpFormatCalendar(tester, CalendarFormat.week);
    // 先纵向 60px（越过触摸斜率），再横向 160px：用户意图是横滑翻周
    await dragPath(
        tester, const [Offset(0, 30), Offset(0, 30), Offset(-160, 0)]);
    expect(captured, isEmpty);
  });

  testWidgets('周档上滑已在边界，不再重复上报当前档', (tester) async {
    final captured = await pumpFormatCalendar(tester, CalendarFormat.week);
    await dragPath(tester, const [Offset(0, -40), Offset(0, -40)]);
    expect(captured, isEmpty);
  });

  // ===== 事件圆点（≤4 点 + `+N` 溢出；点按改期）=====

  testWidgets('事件圆点：≤4 点 + `+N` 溢出；点按回调携带 (日期, 圆点)；窄屏不溢出',
      (tester) async {
    // 360dp 窄屏（格内宽 ~42dp）：4 圆点 + `+1` 必须靠弹性槽收窄放下，
    // 溢出会直接以 RenderFlex 异常砸红用例
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final taps = <(DateTime, CalendarEventDot)>[];
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: OrbitMonthCalendar(
          month: DateTime(2026, 2),
          showHeader: false,
          // 仅 2/10 挂 5 个圆点（4 显 + 1 溢出）；其余日无圆点
          eventDotsBuilder: (d) => d.day == 10
              ? [
                  for (var i = 1; i <= 5; i++)
                    CalendarEventDot(
                      color: const Color(0xFF3B82F6),
                      taskId: i,
                      title: '任务$i',
                    ),
                ]
              : const <CalendarEventDot>[],
          onEventDotTap: (d, dot) => taps.add((d, dot)),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 4 显 + `+1`（第 5 个只进计数）
    expect(find.text('+1'), findsOneWidget);
    final slots = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 10 && w.height == 16);
    expect(slots, findsNWidgets(4));

    // 点第一枚圆点：回调携带格日期与本枚载荷（任务 id 保序对应）。
    // 格日期来自 table_calendar（UTC 零时刻），只比日期字段不比 isUtc
    await tester.tap(slots.first);
    await tester.pump();
    expect(taps, hasLength(1));
    expect(taps.first.$1.year, 2026);
    expect(taps.first.$1.month, 2);
    expect(taps.first.$1.day, 10);
    expect(taps.first.$2.taskId, 1);
    expect(taps.first.$2.title, '任务1');
  });
}
