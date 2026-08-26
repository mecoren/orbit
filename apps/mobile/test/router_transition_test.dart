// apps/mobile/test/router_transition_test.dart
// 转场路由冒烟：pageSlideFromRight 构建的页面可正常入栈、动画收敛后渲染目标内容。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:orbit/core/routing/app_router.dart';

void main() {
  testWidgets('pageSlideFromRight 页面入栈后渲染目标内容', (tester) async {
    final router = GoRouter(
      initialLocation: '/a',
      routes: [
        GoRoute(path: '/a', builder: (_, __) => const Scaffold(body: Text('A 页'))),
        GoRoute(
          path: '/b',
          pageBuilder: (_, __) =>
              pageSlideFromRight(const Scaffold(body: Text('B 页'))),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(find.text('A 页'), findsOneWidget);

    final context = tester.element(find.text('A 页'));
    context.push('/b');
    await tester.pumpAndSettle(); // 等滑入动画收敛

    expect(find.text('B 页'), findsOneWidget);

    context.pop();
    await tester.pumpAndSettle(); // 反向播放同样收敛无异常
    expect(find.text('A 页'), findsOneWidget);
  });
}
