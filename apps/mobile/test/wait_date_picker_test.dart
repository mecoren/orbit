// 日期时间面板时间选择区测试：下拉框结构 + 滚轮选择交互
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/wait_date_picker.dart';

void main() {
  /// 挂一个按钮唤起 showTime 面板（日期+时间）
  Future<void> openPicker(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => WaitDatePicker.pick(
                context,
                showTime: true,
              ),
              child: const Text('打开'),
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

  testWidgets('时间选择区：时/分下拉框 + 下拉箭头（无步进钮）', (tester) async {
    await openPicker(tester);

    expect(find.text('确认'), findsOneWidget);

    // 新布局结构：时/分单位标签各一
    expect(find.text('时'), findsOneWidget);
    expect(find.text('分'), findsOneWidget);

    // 下拉箭头 ×2，步进 +/- 钮已移除
    expect(find.byIcon(Icons.expand_more_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.add_rounded), findsNothing);
    expect(find.byIcon(Icons.remove_rounded), findsNothing);
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
