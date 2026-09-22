// OrbitSkeleton 原语口径：三种形态尺寸正确、呼吸动画可泵帧、无 ticker 泄漏。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_skeleton.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('三种形态：尺寸符合约定', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(
        body: Column(
          children: [
            OrbitSkeleton.line(width: 120),
            OrbitSkeleton.block(width: 200, height: 96),
            OrbitSkeleton.circle(size: 22),
          ],
        ),
      ),
    ));

    final found =
        find.byType(OrbitSkeleton).evaluate().map((e) => e.widget).toList();
    expect(found, hasLength(3));
    expect(
      tester.getSize(find.byWidget(found[0])),
      const Size(120, 14),
      reason: 'line 默认高 14',
    );
    expect(
      tester.getSize(find.byWidget(found[1])),
      const Size(200, 96),
    );
    expect(
      tester.getSize(find.byWidget(found[2])),
      const Size(22, 22),
      reason: 'circle 正方形',
    );
  });

  testWidgets('呼吸动画：泵帧不报错，卸载不泄漏 ticker', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: OrbitSkeleton.block(width: 200)),
    ));

    // 泵过一个完整呼吸周期 + 零头：FadeTransition 每帧重建必须稳定
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(OrbitSkeleton), findsOneWidget);

    // 卸载：controller 正常 dispose，不触发 ticker 泄漏断言
    await tester.pumpWidget(orbitTestApp(home: const SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(OrbitSkeleton), findsNothing);
  });
}
