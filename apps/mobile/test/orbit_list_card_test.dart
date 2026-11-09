// 卡片分段原语（2026-09-23 任务列表卡片化）：
// - 段位推导（首 / 中 / 末 / 单）与「卡内下标 + 卡内段数」一一对应；
// - `edge = none` 是扁平行：不引入任何绘制层（看板 / 表格 / 搜索等复用场景）；
// - 分段自己画描边与分隔线（不用 BoxDecoration：非均匀 Border 与 borderRadius
//   不能共存，且相邻两段各画横边会叠成 2px）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_shapes.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_list_card.dart';

import 'support/orbit_test_app.dart';

/// 指定段位段内的绘制层（描边 + 卡面由 painter 承担）
Finder _paintIn(OrbitCardEdge edge) {
  final segment = find.byWidgetPredicate(
    (w) => w is OrbitCardSegment && w.edge == edge,
  );
  return find.descendant(of: segment, matching: find.byType(CustomPaint));
}

Widget _harness(OrbitCardEdge edge) => orbitTestApp(
      home: Scaffold(
        body: OrbitCardSegment(
          edge: edge,
          child: const SizedBox(height: 48, child: Text('行')),
        ),
      ),
    );

void main() {
  group('OrbitCardEdge.of：段位推导', () {
    test('单段 = single（四角全圆）', () {
      expect(OrbitCardEdge.of(0, 1), OrbitCardEdge.single);
    });

    test('两段 = 首 + 末', () {
      expect(OrbitCardEdge.of(0, 2), OrbitCardEdge.first);
      expect(OrbitCardEdge.of(1, 2), OrbitCardEdge.last);
    });

    test('多段 = 首 / 中 / 末', () {
      expect(OrbitCardEdge.of(0, 4), OrbitCardEdge.first);
      expect(OrbitCardEdge.of(1, 4), OrbitCardEdge.middle);
      expect(OrbitCardEdge.of(2, 4), OrbitCardEdge.middle);
      expect(OrbitCardEdge.of(3, 4), OrbitCardEdge.last);
    });
  });

  testWidgets('edge=none：零额外绘制层（扁平行口径不变）', (tester) async {
    await tester.pumpWidget(_harness(OrbitCardEdge.none));

    expect(find.text('行'), findsOneWidget);
    expect(_paintIn(OrbitCardEdge.none), findsNothing);
  });

  // 2026-11-09 真机反馈：动作按钮四角全圆时，贴行的内侧会凹出一条月牙缝，
  // 看着像两块断开的卡；口径收在原语层，回收站 / 待办列表共用。
  group('swipeActionRadius：内侧恒直边，外侧随段位', () {
    const r = AppShapes.radiusMedium;

    test('中段 / 扁平行：四角全直，面板与行无缝相连', () {
      for (final edge in const [OrbitCardEdge.middle, OrbitCardEdge.none]) {
        for (final startPane in const [true, false]) {
          expect(
            edge.swipeActionRadius(startPane: startPane),
            BorderRadius.zero,
            reason: '$edge / startPane=$startPane',
          );
        }
      }
    });

    test('startActionPane：外侧左角随段位圆，内侧右角恒直', () {
      final first = OrbitCardEdge.first.swipeActionRadius(startPane: true);
      expect(first.topLeft.x, r);
      expect(first.bottomLeft.x, 0);
      expect(first.topRight.x, 0);
      expect(first.bottomRight.x, 0);

      final last = OrbitCardEdge.last.swipeActionRadius(startPane: true);
      expect(last.topLeft.x, 0);
      expect(last.bottomLeft.x, r);
      expect(last.topRight.x, 0);
      expect(last.bottomRight.x, 0);

      final single = OrbitCardEdge.single.swipeActionRadius(startPane: true);
      expect(single.topLeft.x, r);
      expect(single.bottomLeft.x, r);
      expect(single.topRight.x, 0);
      expect(single.bottomRight.x, 0);
    });

    test('endActionPane：外侧右角随段位圆，内侧左角恒直', () {
      final first = OrbitCardEdge.first.swipeActionRadius(startPane: false);
      expect(first.topRight.x, r);
      expect(first.bottomRight.x, 0);
      expect(first.topLeft.x, 0);
      expect(first.bottomLeft.x, 0);

      final last = OrbitCardEdge.last.swipeActionRadius(startPane: false);
      expect(last.topRight.x, 0);
      expect(last.bottomRight.x, r);
      expect(last.topLeft.x, 0);
      expect(last.bottomLeft.x, 0);

      final single = OrbitCardEdge.single.swipeActionRadius(startPane: false);
      expect(single.topRight.x, r);
      expect(single.bottomRight.x, r);
      expect(single.topLeft.x, 0);
      expect(single.bottomLeft.x, 0);
    });
  });

  // 侧滑接缝：卡面四角半径是纯函数，直接断言几何（不用 fake-async 下会卡住的
  // RepaintBoundary.toImage 截图）。抹平侧必须真的置 0，否则圆角仍会凹出月牙缝。
  group('cornerRadii：接缝侧抹平', () {
    const r = AppShapes.radiusMedium;

    test('首段：默认圆上两角，抹平左 / 右只影响对应一侧', () {
      expect(
        OrbitCardEdge.first.cornerRadii(r),
        (topLeft: r, topRight: r, bottomLeft: 0.0, bottomRight: 0.0),
      );
      expect(
        OrbitCardEdge.first.cornerRadii(r, squareLeft: true),
        (topLeft: 0.0, topRight: r, bottomLeft: 0.0, bottomRight: 0.0),
      );
      expect(
        OrbitCardEdge.first.cornerRadii(r, squareRight: true),
        (topLeft: r, topRight: 0.0, bottomLeft: 0.0, bottomRight: 0.0),
      );
    });

    test('末段：默认圆下两角，抹平右 / 左只影响对应一侧', () {
      expect(
        OrbitCardEdge.last.cornerRadii(r),
        (topLeft: 0.0, topRight: 0.0, bottomLeft: r, bottomRight: r),
      );
      expect(
        OrbitCardEdge.last.cornerRadii(r, squareRight: true),
        (topLeft: 0.0, topRight: 0.0, bottomLeft: r, bottomRight: 0.0),
      );
    });

    test('单段 / 中段：单段四角全圆，中段恒直', () {
      expect(
        OrbitCardEdge.single.cornerRadii(r, squareLeft: true),
        (topLeft: 0.0, topRight: r, bottomLeft: 0.0, bottomRight: r),
      );
      expect(
        OrbitCardEdge.middle.cornerRadii(r),
        (topLeft: 0.0, topRight: 0.0, bottomLeft: 0.0, bottomRight: 0.0),
      );
    });
  });

  testWidgets('squareLeft/squareRight：默认关闭，不影响既有卡片外观',
      (tester) async {
    await tester.pumpWidget(_harness(OrbitCardEdge.single));
    final segment =
        tester.widget<OrbitCardSegment>(find.byType(OrbitCardSegment));
    expect(segment.squareLeft, isFalse);
    expect(segment.squareRight, isFalse);
    expect(_paintIn(OrbitCardEdge.single), findsOneWidget);
  });

  testWidgets('卡片段：每段恰有一层自绘描边，且描边不占布局', (tester) async {
    for (final edge in const [
      OrbitCardEdge.first,
      OrbitCardEdge.middle,
      OrbitCardEdge.last,
      OrbitCardEdge.single,
    ]) {
      await tester.pumpWidget(_harness(edge));

      expect(_paintIn(edge), findsOneWidget, reason: '$edge 段应有自绘描边层');
      // 描边是画上去的，不参与布局：段高仍由子组件决定
      expect(tester.getSize(find.byType(OrbitCardSegment)).height, 48);
      expect(tester.getSize(find.text('行')).height, 48);
    }
  });
}
