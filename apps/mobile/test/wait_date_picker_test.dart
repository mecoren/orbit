// 日期时间面板测试：日视图与日历视图同口径（农历/休班）+ 时间选择区交互
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_month_calendar.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_date_picker.dart';
import 'support/orbit_test_app.dart';
import 'package:orbit/core/theme/icon_map.dart';

void main() {
  /// 挂一个按钮唤起 showTime 面板（日期+时间）。
  /// 面板消费 holidayProvider，故须 ProviderScope + MockOrbitBridge 注入。
  /// 默认 800×600 视口刻意保留：日视图 medium 档下内容高于视口，
  /// 顺带覆盖「面板整页可滚」的短屏路径（不溢出即可）。
  Future<void> openPicker(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orbitBridgeProvider.overrideWithValue(MockOrbitBridge()),
      ],
      child: orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => OrbitDatePicker.pick(
                  context,
                  showTime: true,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  /// 按压后的面板数值 Text 带 ValueKey，直接读 data 避免与月历日期撞文本
  String hourText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('time_hour_value')))
      .data!;

  String minuteText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('time_minute_value')))
      .data!;

  testWidgets('日视图：medium 档月历挂农历副标签与节假日（同日历视图口径）',
      (tester) async {
    await openPicker(tester);

    final calendar = tester.widget<OrbitMonthCalendar>(
      find.byType(OrbitMonthCalendar),
    );
    expect(calendar.size, AppCalendarSize.medium);
    expect(calendar.subLabelBuilder, isNotNull, reason: '农历/节气/节日副标签');
    expect(calendar.holidays, isNotNull, reason: '休/班徽标数据源');
    expect(calendar.showHeader, isFalse, reason: '头部由面板标题栏接管');
  });

  testWidgets('时间选择区：时/分步进行（- 数值 +，无二级弹层）', (tester) async {
    await openPicker(tester);

    expect(find.text('确认'), findsOneWidget);

    // 时分各一组「- / 数值 / +」步进器（线上下拉框已按 v3 收敛为步进器行）
    expect(find.byIcon(OrbitIcons.add), findsNWidgets(2));
    expect(find.byIcon(OrbitIcons.remove), findsNWidgets(2));
    expect(find.byKey(const ValueKey('time_hour_value')), findsOneWidget);
    expect(find.byKey(const ValueKey('time_minute_value')), findsOneWidget);

    // 点步进钮不弹二级弹层（ValueKey 只用于读值，不可点）
    await tester.tap(find.byIcon(OrbitIcons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('确认'), findsOneWidget);
  });

  testWidgets('小时步进：点 + 钮 → 时 +1（23 点回绕 0）', (tester) async {
    final initialHour = DateTime.now().hour;
    await openPicker(tester);
    expect(hourText(tester), initialHour.toString().padLeft(2, '0'));

    // 时行 = 第一组步进器的「+」钮
    await tester.tap(find.byIcon(OrbitIcons.add).first);
    await tester.pump();
    expect(
      hourText(tester),
      ((initialHour + 1) % 24).toString().padLeft(2, '0'),
    );
  });

  testWidgets('分钟步进：点 + 钮 → 分 +5（55 分回绕 00）', (tester) async {
    final initialMinute = DateTime.now().minute;
    await openPicker(tester);
    expect(minuteText(tester), initialMinute.toString().padLeft(2, '0'));

    // 分行 = 第二组步进器的「+」钮
    await tester.tap(find.byIcon(OrbitIcons.add).last);
    await tester.pump();
    expect(
      minuteText(tester),
      ((initialMinute + 5) % 60).toString().padLeft(2, '0'),
    );
  });
}
