// 详情页分组版式回归：与设置页同构（2026-11-06 对齐）——
// 卡外分组小标题（左 28 = 卡外距 12 + 行内距 16）、分组卡左右外距 12、
// 信息区行间分隔线左缩进与行标题同一条竖线。
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/layout/orbit_breakpoints.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/detail_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_button.dart';

import 'support/orbit_test_app.dart';

void main() {
  late MockOrbitBridge bridge;

  setUp(() => bridge = MockOrbitBridge());

  Future<void> pumpDetail(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
        child: orbitTestApp(home: const DetailScreen(taskId: 5)),
      ),
    );
    // 两轮推进：详情就绪后信息区才启动 todoProjectsProvider 的 mock 延迟
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets('分组标题与卡内行标题同一条竖线，卡片左右外距 12', (tester) async {
    await pumpDetail(tester);

    // 详情限宽 760 居中：内容区左缘 = (屏宽 - min(屏宽, 760)) / 2
    final screenWidth = tester.getSize(find.byType(DetailScreen)).width;
    final contentLeft =
        (screenWidth - screenWidth.clamp(0, OrbitBreakpoints.contentMaxWidth)) /
        2;
    final titleLeft = tester.getTopLeft(find.text('信息')).dx;
    final rowLeft = tester.getTopLeft(find.text('优先级')).dx;

    expect(titleLeft, closeTo(contentLeft + 28, 0.5));
    expect(rowLeft, closeTo(titleLeft, 0.5));

    // 标题卡（首个分组卡）左右各留 12
    final card = find.byType(MiuixCard).first;
    expect(tester.getTopLeft(card).dx, closeTo(contentLeft + 12, 0.5));
    expect(
      tester.getTopRight(card).dx,
      closeTo(screenWidth - contentLeft - 12, 0.5),
    );
  });

  testWidgets('信息区行间分隔线左边与行标题同线', (tester) async {
    await pumpDetail(tester);

    // 分隔线左缘 = 卡外距 12 + 行内距 16，与行标题同线
    final divider = find.byType(MiuixHorizontalDivider).first;
    final rowLeft = tester.getTopLeft(find.text('优先级')).dx;
    expect(tester.getTopLeft(divider).dx, closeTo(rowLeft, 0.5));
  });

  testWidgets('分组标题的 trailing 贴齐卡片内容右缘', (tester) async {
    await pumpDetail(tester);
    // 详情页是懒构建列表：描述区默认在视口外，得先滚进来才有「编辑」按钮
    await tester.scrollUntilVisible(find.text('描述'), 300);
    await tester.pumpAndSettle();

    final screenWidth = tester.getSize(find.byType(DetailScreen)).width;
    final contentLeft =
        (screenWidth - screenWidth.clamp(0, OrbitBreakpoints.contentMaxWidth)) /
        2;
    // 标题行右内边距 16（相对内容区；卡外距 12 由分组卡承担），
    // trailing 右缘只留这一档——不再跟标题同缩进 28
    final editRight = tester.getTopRight(
      find.widgetWithText(OrbitButton, '编辑').first,
    ).dx;
    expect(editRight, closeTo(screenWidth - contentLeft - 16, 0.5));
  });

  testWidgets('信息区九行之间各有一条分隔线', (tester) async {
    await pumpDetail(tester);

    // 信息区九行 → 八条分隔线（其余区块的块内容不插线）
    expect(find.byType(MiuixHorizontalDivider), findsNWidgets(8));
  });
}
