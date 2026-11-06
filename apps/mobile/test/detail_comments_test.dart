// 详情页评论区预览上限（2026-11-06）：最多露出 3 条篇幅，超出时列表上方
// 常驻「共 N 条评论 · 上下滑动查看」，并在区块内滚动查看剩余条目。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/detail_screen.dart';

import 'support/orbit_test_app.dart';

Future<void> _pumpDetail(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: const DetailScreen(taskId: 5)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('输入评论...'), 300);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('评论超过 3 条：出现滑动提示且列表限高', (tester) async {
    final bridge = MockOrbitBridge();
    // mock 的评论写路径是真异步（含延迟），必须在 runAsync 里推进
    await tester.runAsync(() async {
      for (var i = 0; i < 3; i++) {
        await bridge.todoCommentCreate(
          TodoCommentCreateInput(taskId: 5, content: '补充评论 $i'),
        );
      }
    });

    await _pumpDetail(tester, bridge);

    expect(find.textContaining('条评论 · 上下滑动查看'), findsOneWidget);
    // 预览区限高 3 条篇幅（3 × 84）
    expect(
      tester.getSize(find.byKey(detailCommentsListKey)).height,
      closeTo(252, 0.5),
    );
  });

  testWidgets('评论不超过 3 条：不出现滑动提示', (tester) async {
    await _pumpDetail(tester, MockOrbitBridge());

    expect(find.textContaining('上下滑动查看'), findsNothing);
  });
}
