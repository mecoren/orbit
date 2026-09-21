// 通用月历（OrbitMonthCalendar）日格呈现口径：
// 当月日期正常显示（周末走识别蓝），前后月补位日期弱显示（deactivatedText 灰）——
// 翻到某月时只有该月是正常读数，其余月份退到背景。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_month_calendar.dart';
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
}
