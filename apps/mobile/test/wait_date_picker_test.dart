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

  testWidgets('小时下拉：点框弹滚轮 → 上滑一格 → 确认落值', (tester) async {
    final initialHour = DateTime.now().hour;
    await openPicker(tester);
    expect(hourText(tester), initialHour.toString().padLeft(2, '0'));

    // 点小时下拉框 → 弹出滚轮弹层
    await tester.tap(find.byKey(const ValueKey('time_hour_value')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoPicker), findsOneWidget);

    // 滚轮上滑一格（itemExtent 44）→ 选中项 +1
    await tester.drag(find.byType(CupertinoPicker), const Offset(0, -44));
    await tester.pumpAndSettle();

    // 确认弹层（弹层在上层，取 last）→ 数值 +1（模 24）
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    expect(hourText(tester), ((initialHour + 1) % 24).toString().padLeft(2, '0'));
  });

  testWidgets('分钟下拉：点框弹滚轮 → 上滑一格 → 确认落值', (tester) async {
    final initialMinute = DateTime.now().minute;
    await openPicker(tester);
    expect(minuteText(tester), initialMinute.toString().padLeft(2, '0'));

    // 点分钟下拉框 → 弹出滚轮弹层
    await tester.tap(find.byKey(const ValueKey('time_minute_value')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoPicker), findsOneWidget);

    await tester.drag(find.byType(CupertinoPicker), const Offset(0, -44));
    await tester.pumpAndSettle();

    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    expect(
        minuteText(tester), ((initialMinute + 1) % 60).toString().padLeft(2, '0'));
  });
}
