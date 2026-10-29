// OrbitSpinner 原语口径：方形占位按 size、几何按环比例推导、默认取主题强调色、
// 永续绕行不冻结、卸载释放 ticker。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_motion.dart';
import 'package:orbit/core/theme/orbit_accents.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_spinner.dart';

import 'support/orbit_test_app.dart';

/// 取组件自身子树的 painter（Scaffold 的 Material 也会建 CustomPaint，必须限定范围）。
dynamic _painterOf(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find.descendant(
        of: find.byType(OrbitSpinner),
        matching: find.byType(CustomPaint),
      ),
    )
    .painter;

void main() {
  testWidgets('按 size 渲染方形占位', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: OrbitSpinner(size: 24))),
    ));

    expect(tester.getSize(find.byType(OrbitSpinner)), const Size(24, 24));
  });

  testWidgets('默认尺寸 20、默认色取主题强调色', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: OrbitSpinner())),
    ));

    expect(tester.getSize(find.byType(OrbitSpinner)), const Size(20, 20));
    expect(_painterOf(tester).color, OrbitAccents.themeAccent);
  });

  testWidgets('显式传色（主题色按钮 / 深底遮罩用法）覆盖默认色', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(
        body: Center(child: OrbitSpinner(size: 16, color: Colors.white)),
      ),
    ));

    expect(_painterOf(tester).color, Colors.white);
    expect(tester.takeException(), isNull);
  });

  testWidgets('亮/暗两种主题下均能构建', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(orbitTestApp(
        home: const Scaffold(body: Center(child: OrbitSpinner())),
        brightness: brightness,
      ));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('描边宽度按 size 比例推导（组件刻意不暴露该参数）', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: OrbitSpinner(size: 40))),
    ));

    expect(_painterOf(tester).strokeWidth, closeTo(40 * 0.08, 0.001));
  });

  testWidgets('semanticLabel 透传为 Semantics 标签', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(
        body: Center(child: OrbitSpinner(semanticLabel: '正在加载')),
      ),
    ));

    expect(find.bySemanticsLabel('正在加载'), findsOneWidget);
  });

  testWidgets('semanticLabel 为 null 时不注入语义节点', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: OrbitSpinner())),
    ));

    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('正在加载'), findsNothing);
    handle.dispose();
  });

  testWidgets('点持续绕行：多帧推进相位变化且仍在绘制', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: OrbitSpinner(size: 24))),
    ));

    final ownPaint = find.descendant(
      of: find.byType(OrbitSpinner),
      matching: find.byType(CustomPaint),
    );
    expect(ownPaint, findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    final phase1 = _painterOf(tester).animation.value as double;
    await tester.pump(const Duration(milliseconds: 300));

    expect(_painterOf(tester).animation.value as double, isNot(phase1));
    expect(_painterOf(tester).animation.isAnimating, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duration 变更不抛异常（控制器时长同步）', (tester) async {
    Widget build(Duration d) => orbitTestApp(
          home: Scaffold(body: Center(child: OrbitSpinner(duration: d))),
        );

    await tester.pumpWidget(build(AppMotion.spinnerOrbit));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(build(const Duration(milliseconds: 400)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });

  testWidgets('卸载时释放动画控制器（dispose 不抛异常）', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: OrbitSpinner())),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(orbitTestApp(home: const SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });
}
