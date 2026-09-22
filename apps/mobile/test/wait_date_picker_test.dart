// 日期时间面板测试：日视图与日历视图同口径（农历/休班）+ 时间选择区交互
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  /// 标签字形的水平中心（Text 局部坐标）。
  ///
  /// 底部按钮经 `Expanded` 拉满宽后，标签 Text 的盒子与按钮同宽，字形落位由
  /// `textAlign` 决定——故只能量字形，量 Text 盒子量不出居中与否。
  double glyphCenterX(WidgetTester tester, String label) {
    final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: label.length),
    );
    return boxes
        .map((box) => box.toRect())
        .reduce((a, b) => a.expandToInclude(b))
        .center
        .dx;
  }

  testWidgets('底部双按钮：标签水平居中（贴左即 TextAlign.start 回归）',
      (tester) async {
    await openPicker(tester);

    for (final label in ['取消', '确认']) {
      final labelBoxWidth = tester.getSize(find.text(label)).width;
      expect(
        glyphCenterX(tester, label),
        moreOrLessEquals(labelBoxWidth / 2, epsilon: 1),
        reason: '$label 应居中于按钮内',
      );
    }
  });

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

  testWidgets('时间选择区：时/分下拉框 + 下拉箭头（无步进钮）', (tester) async {
    await openPicker(tester);

    expect(find.text('确认'), findsOneWidget);

    // 布局结构：时/分单位标签各一
    expect(find.text('时'), findsOneWidget);
    expect(find.text('分'), findsOneWidget);

    // 下拉箭头 ×2，步进 +/- 钮不存在
    expect(find.byIcon(OrbitIcons.expandMore), findsNWidgets(2));
    expect(find.byIcon(OrbitIcons.add), findsNothing);
    expect(find.byIcon(OrbitIcons.remove), findsNothing);
  });

  testWidgets('小时下拉：点框弹滚轮 → 滑一格 → 确认落值', (tester) async {
    final initialHour = DateTime.now().hour;
    await openPicker(tester);
    expect(hourText(tester), initialHour.toString().padLeft(2, '0'));

    // 点小时下拉框 → 弹出滚轮弹层
    await tester.tap(find.byKey(const ValueKey('time_hour_value')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoPicker), findsOneWidget);

    // 滚轮滑动方向随边界自适应：ListWheel 无环绕语义——初始在末项（23 点）
    // 时上滑会被 maxScrollExtent 钳住，改下滑 -1；否则上滑 +1。
    final atLast = initialHour == 23;
    await tester.drag(find.byType(CupertinoPicker),
        Offset(0, atLast ? 44 : -44));
    await tester.pumpAndSettle();

    // 确认弹层（弹层在上层，取 last）→ 数值按滑动方向 ±1
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    final expected = atLast ? initialHour - 1 : initialHour + 1;
    expect(hourText(tester), expected.toString().padLeft(2, '0'));
  });

  testWidgets('分钟下拉：点框弹滚轮 → 滑一格 → 确认落值', (tester) async {
    final initialMinute = DateTime.now().minute;
    await openPicker(tester);
    expect(minuteText(tester), initialMinute.toString().padLeft(2, '0'));

    // 点分钟下拉框 → 弹出滚轮弹层
    await tester.tap(find.byKey(const ValueKey('time_minute_value')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoPicker), findsOneWidget);

    // 边界自适应（同小时用例）：末项 59 分下滑 -1，否则上滑 +1
    final atLast = initialMinute == 59;
    await tester.drag(find.byType(CupertinoPicker),
        Offset(0, atLast ? 44 : -44));
    await tester.pumpAndSettle();

    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    final expected = atLast ? initialMinute - 1 : initialMinute + 1;
    expect(minuteText(tester), expected.toString().padLeft(2, '0'));
  });
}
