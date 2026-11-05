// 滚轮选择弹层原语回归：
// - 时分双列：初值回显 / 环绕标记 / 拖动后确认回传
// - 弹层承载：浮起圆角卡片 + 中文尾栏（不再是 Material 钟面弹窗）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_floating_sheet_card.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_wheel_sheet.dart';
import 'support/orbit_test_app.dart';

void main() {
  testWidgets('时分滚轮：初值回显 + 滑动小时后确认回传', (tester) async {
    ({int hour, int minute})? picked;
    late BuildContext ctx;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    showOrbitTimeWheelSheet(
      ctx,
      title: '每日摘要提醒时刻',
      hour: 8,
      minute: 0,
    ).then((value) => picked = value);
    await tester.pumpAndSettle();

    expect(find.text('每日摘要提醒时刻'), findsOneWidget);
    // 承载与全项目底部弹层同形：浮起圆角卡片（不是 Material 钟面对话框）
    expect(find.byType(OrbitFloatingSheetCard), findsOneWidget);

    // 整屉按内容收缩（handle 12 + 标题 48 + 滚轮 220 + 尾栏 86 ≈ 366）。
    // 回归点：`:` 分隔若用 `Center` 包会撑满 Row 的交叉轴上限，导致整屉被抬到
    // maxHeightFactor（600 视口 → 526），滚轮被居中、上下各留一大片空白
    expect(
      tester.getSize(find.byType(OrbitFloatingSheetCard)).height,
      lessThan(420),
    );

    final hourWheel = tester.widget<OrbitWheelColumn>(
      find.byKey(const ValueKey('orbit-time-wheel-hour')),
    );
    final minuteWheel = tester.widget<OrbitWheelColumn>(
      find.byKey(const ValueKey('orbit-time-wheel-minute')),
    );
    expect(hourWheel.value, 8);
    expect(minuteWheel.value, 0);
    // 时分是周期值：首尾环绕（23→0 / 59→0）
    expect(hourWheel.wrapAround, isTrue);
    expect(minuteWheel.wrapAround, isTrue);

    // 下滑一格 → 08:00 变 07:00
    await tester.drag(
      find.byKey(const ValueKey('orbit-time-wheel-hour')),
      const Offset(0, 44),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(picked, (hour: 7, minute: 0));
  });
}
