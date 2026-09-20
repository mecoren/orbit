// WaitToast 停留口径回归（2026-09-20 修复）：撤销类浮层曾因「带 action 就不
// 自动收起」而常驻不消失（用户报「提示怎么一直在」）。现口径：
// - 纯提示 → defaultDwell 自动收；
// - 带 onTap 的提醒条 → 不收（等用户点）；
// - 撤销类 → 调用点显式传 undoDwell/窗口时长，到期自动收。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/shared/widgets/wait_toast.dart';

Widget _harness() => MaterialApp(
      navigatorKey: rootNavigatorKey,
      home: const Scaffold(body: SizedBox.expand()),
    );

void main() {
  testWidgets('撤销浮层：undoDwell 到期自动收起', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.global(
      '已调整 1 个任务的优先级',
      actionLabel: '撤销',
      onAction: () {},
      autoDismissAfter: WaitToast.undoDwell,
    );
    await tester.pump();
    expect(find.text('已调整 1 个任务的优先级'), findsOneWidget);

    await tester.pump(WaitToast.undoDwell);
    await tester.pumpAndSettle();
    expect(find.text('已调整 1 个任务的优先级'), findsNothing);
  });

  testWidgets('纯提示：defaultDwell 到期自动收起', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.info('已保存');
    await tester.pump();
    expect(find.text('已保存'), findsOneWidget);

    await tester.pump(WaitToast.defaultDwell);
    await tester.pumpAndSettle();
    expect(find.text('已保存'), findsNothing);
  });

  testWidgets('带 onTap 的提醒条：不设时长则保持常驻等用户点', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.warning('待办提醒：写周报', onTap: () {});
    await tester.pump();
    expect(find.text('待办提醒：写周报'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    expect(find.text('待办提醒：写周报'), findsOneWidget);
  });

  testWidgets('带动作但未给时长：保持常驻（错误引导类需用户处置）', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.global(
      '同步密钥与云端数据不匹配',
      actionLabel: '去恢复',
      onAction: () {},
    );
    await tester.pump();

    await tester.pump(const Duration(seconds: 10));
    expect(find.text('同步密钥与云端数据不匹配'), findsOneWidget);
  });
}
