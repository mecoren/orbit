// BootGate 外部直达导航回归：通知 / 小组件点击的防重入门闸不能把
// 「用户停留在详情页期间的后续点击」永久吞掉。
//
// 背景：go_router 的 `push()` Future 要等目标页被 pop 才完成；曾把它当
// 防重入门闸，导致第二条通知点击静默失效、location 被替换时永久锁死。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/shell/boot_gate.dart';
import 'package:orbit/services/notification_service.dart';
import 'package:orbit/services/reminder_scheduler.dart';
import 'package:orbit/services/sync_on_change_scheduler.dart';

GoRouter _router() => GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('启动首页')),
        ),
        GoRoute(
          path: '/todo/:id',
          builder: (_, state) => Scaffold(
            body: Text('详情${state.pathParameters['id']}'),
          ),
        ),
      ],
    );

Widget _wrap(GoRouter router) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(MockOrbitBridge())],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) =>
            BootGate(child: child ?? const SizedBox.shrink()),
      ),
    );

void main() {
  // 调度器是进程级单例，防抖 Timer 会活过 widget 树
  tearDown(() {
    ReminderScheduler.shutdown();
    SyncOnChangeScheduler.shutdown();
    NotificationService.onNotificationTap = null;
  });

  testWidgets('详情停留期间第二次通知点击仍能直达（门闸只做同帧去重）', (tester) async {
    final router = _router();
    await tester.pumpWidget(_wrap(router));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // 泵过提醒调度器的 2s 防抖窗，避免 fake_async 残留 pending Timer
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('启动首页'), findsOneWidget);

    final tap = NotificationService.onNotificationTap;
    expect(tap, isNotNull, reason: 'BootGate ready 后必须注入通知点击回调');

    await tap!(5);
    await tester.pumpAndSettle();
    expect(find.text('详情5'), findsOneWidget);

    // 第一层详情仍在栈顶（push Future 未完成），跨一帧后第二条通知必须生效
    await tester.pump();
    await tap(6);
    await tester.pumpAndSettle();
    expect(find.text('详情6'), findsOneWidget);

    // 两次返回逐层回退，不越级
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('详情5'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('启动首页'), findsOneWidget);
  });

  testWidgets('同一帧重复投递同一事件只推一层详情', (tester) async {
    final router = _router();
    await tester.pumpWidget(_wrap(router));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final tap = NotificationService.onNotificationTap!;
    await Future.wait<void>([tap(5), tap(5)]);
    await tester.pumpAndSettle();
    expect(find.text('详情5'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('启动首页'), findsOneWidget);
  });
}
