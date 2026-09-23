// 卡片分段原语（2026-09-23 任务列表卡片化）：
// - 段位推导（首 / 中 / 末 / 单）与「卡内下标 + 卡内段数」一一对应；
// - `edge = none` 是扁平行：不引入任何绘制层（看板 / 表格 / 搜索等复用场景）；
// - 分段自己画描边与分隔线（不用 BoxDecoration：非均匀 Border 与 borderRadius
//   不能共存，且相邻两段各画横边会叠成 2px）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
