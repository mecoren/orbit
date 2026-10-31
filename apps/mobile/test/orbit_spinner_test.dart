// OrbitSpinner 原语口径：方形占位按 size、几何按环比例推导、默认取主题强调色、
// 永续绕行不冻结、卸载释放 ticker。
// 2026-10-31 换承载为 flutter_miuix 的 MiuixInfiniteProgressIndicator（HyperOS
// 系统加载态同源），故断言落在「组件契约」而非某个内部 painter 的字段名。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/orbit_accents.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_spinner.dart';

import 'support/orbit_test_app.dart';

/// 组件内唯一的 Miuix 无限进度指示器
MiuixInfiniteProgressIndicator _indicatorOf(WidgetTester tester) =>
    tester.widget<MiuixInfiniteProgressIndicator>(
      find.descendant(
        of: find.byType(OrbitSpinner),
        matching: find.byType(MiuixInfiniteProgressIndicator),
      ),
    );

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
    expect(_indicatorOf(tester).color, OrbitAccents.themeAccent);
  });

  testWidgets('显式传色（主题色按钮 / 深底遮罩用法）覆盖默认色', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(
        body: Center(child: OrbitSpinner(size: 16, color: Colors.white)),
      ),
    ));

    expect(_indicatorOf(tester).color, Colors.white);
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

  testWidgets('描边宽度与绕行点尺寸按 size 比例推导（组件刻意不暴露这两个参数）',
      (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: OrbitSpinner(size: 40))),
    ));

    final indicator = _indicatorOf(tester);
    expect(indicator.strokeWidth, closeTo(40 * OrbitSpinnerMetrics.strokeRatio, 0.001));
    expect(indicator.orbitingDotSize,
        closeTo(40 * OrbitSpinnerMetrics.dotRatio, 0.001));
  });

  testWidgets('semanticLabel 透传为更具体的 Semantics 标签', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(
        body: Center(child: OrbitSpinner(semanticLabel: '正在加载')),
      ),
    ));

    expect(find.bySemanticsLabel('正在加载'), findsOneWidget);
  });

  testWidgets('semanticLabel 为 null 时保留库内置「进度」语义，不注入调用方文案',
      (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: OrbitSpinner())),
    ));

    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('正在加载'), findsNothing);
    handle.dispose();
  });

  testWidgets('点持续绕行：多帧推进后仍在绘制且无异常', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: OrbitSpinner(size: 24))),
    ));

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(MiuixInfiniteProgressIndicator), findsOneWidget);
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
