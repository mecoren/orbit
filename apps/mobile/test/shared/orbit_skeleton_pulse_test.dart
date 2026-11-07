// 骨架占位共享呼吸动画的契约（2026-11-08）
//
// 背景：主列表骨架一次铺 8 行 × 3 块，每块自建 `AnimationController` 就是
// 24 路 ticker 同时逐帧驱动 24 次 opacity 重绘。外层建一路向下传后，
// 每块必须**直接复用**传进来的 `Animation`（`FadeTransition` 只求值不 tick）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_skeleton.dart';

import '../support/orbit_test_app.dart';

/// 只取骨架自身那层 `FadeTransition`（MaterialApp 的路由转场也有同型 widget）
Finder _skeletonFades() => find.descendant(
  of: find.byType(OrbitSkeleton),
  matching: find.byType(FadeTransition),
);

void main() {
  testWidgets('传入 pulse：所有骨架共用同一个 Animation 实例', (tester) async {
    final ctrl = AnimationController(vsync: const TestVSync());
    addTearDown(ctrl.dispose);
    final pulse = Tween<double>(begin: 0.45, end: 1.0).animate(ctrl);

    await tester.pumpWidget(
      orbitTestApp(
        home: Column(
          children: [
            OrbitSkeleton.circle(size: 22, pulse: pulse),
            OrbitSkeleton.line(width: 180, height: 15, pulse: pulse),
            OrbitSkeleton.line(width: 130, height: 12, pulse: pulse),
          ],
        ),
      ),
    );

    final fades = tester.widgetList<FadeTransition>(_skeletonFades()).toList();
    expect(fades, hasLength(3));
    for (final fade in fades) {
      expect(
        identical(fade.opacity, pulse),
        isTrue,
        reason: '共享档必须直接用外部动画，不能各自再包一层 Tween',
      );
    }
  });

  testWidgets('不传 pulse：仍自建呼吸（其余 4 处调用零变化）', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(home: const OrbitSkeleton.line(width: 120)),
    );

    final before = tester
        .widget<FadeTransition>(_skeletonFades())
        .opacity
        .value;
    await tester.pump(const Duration(milliseconds: 300));
    final after = tester.widget<FadeTransition>(_skeletonFades()).opacity.value;
    expect(after, isNot(before), reason: '自建档必须还在呼吸');
  });
}
