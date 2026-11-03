import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_pull_to_refresh.dart';

/// 下拉刷新指示器口径（2026-11-03 改自绘后）：
/// - 下拉未过阈值：文案「下拉刷新」，松手回弹、不触发刷新；
/// - 越过阈值：保持拉长圆（文案「释放刷新」），此时不画绕行点；
/// - 松手吸附回阈值：收成正常圆 + 环内绕行点，文案「正在刷新…」（驻留时长由
///   `onRefresh` 的 Future 决定）。
///
/// 注意不能对刷新态用 `pumpAndSettle`——绕行点是无限循环动画。
Future<void> _pumpRefresh(
  WidgetTester tester, {
  required Future<void> Function() onRefresh,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OrbitPullToRefresh(
          onRefresh: onRefresh,
          displacement: 20,
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: 30,
            itemBuilder: (_, i) => SizedBox(height: 60, child: Text('row$i')),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<TestGesture> _pullDown(WidgetTester tester, double distance) async {
  final gesture = await tester.startGesture(const Offset(200, 400));
  await gesture.moveBy(Offset(0, distance / 3));
  await tester.pump();
  await gesture.moveBy(Offset(0, distance / 3));
  await tester.pump();
  await gesture.moveBy(Offset(0, distance / 3));
  await tester.pump();
  return gesture;
}

void main() {
  testWidgets('未过阈值：显示「下拉刷新」，松手回弹且不触发刷新', (tester) async {
    var calls = 0;
    await _pumpRefresh(tester, onRefresh: () async => calls++);

    final gesture = await _pullDown(tester, 40);
    expect(find.text('下拉刷新'), findsOneWidget);
    expect(find.text('释放刷新'), findsNothing);

    await gesture.up();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(calls, 0, reason: '未过阈值松手不得触发刷新');
    expect(find.text('下拉刷新'), findsNothing, reason: '回弹后刷新头应收起');
  });

  testWidgets('越过阈值：显示「释放刷新」，松手后收圆进入刷新态并触发一次', (tester) async {
    var calls = 0;
    final pending = Completer<void>();
    await _pumpRefresh(
      tester,
      onRefresh: () {
        calls++;
        return pending.future;
      },
    );

    final gesture = await _pullDown(tester, 180);
    expect(find.text('释放刷新'), findsOneWidget, reason: '阈值态仍是拉长圆 + 释放刷新');
    expect(find.text('正在刷新…'), findsNothing, reason: '未松手不得出现绕行点/刷新文案');

    await gesture.up();
    // 弹簧吸附回阈值后才会切到 refreshing（临界阻尼收尾约 1.1s）
    for (var i = 0; i < 30 && find.text('正在刷新…').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(calls, 1, reason: '越过阈值松手必须触发一次刷新');
    expect(find.text('正在刷新…'), findsOneWidget, reason: '收圆后进入刷新态');

    pending.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
