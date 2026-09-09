// 统计页冒烟（backlog #25）：MockOrbitBridge 注入，验证 stats 聚合链路
// 渲染总览卡 / streak 行 / 热力图卡 / 三分布卡不抛布局异常，
// 并抽验 mock 口径（种子数据的已完成数会反映在总览卡上）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/stats_screen.dart';
import 'package:orbit/shared/utils/hex_color.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(home: child),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('统计页：总览卡/热力图/分布卡渲染', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const StatsScreen(), bridge));
    await _settle(tester);

    // 总览五卡标签
    expect(find.text('总任务'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('未完成'), findsOneWidget);
    expect(find.text('近 7 天完成'), findsOneWidget);
    expect(find.text('近 30 天完成'), findsOneWidget);

    // streak 行 + 热力图卡
    expect(find.text('完成热力图'), findsOneWidget);

    // 三分布卡（逐段滚动到底可见）
    await tester.scrollUntilVisible(
      find.text('项目分布'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(
      find.text('优先级分布'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(
      find.text('星期分布（已完成）'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('项目分布'), findsOneWidget);
    expect(find.text('优先级分布'), findsOneWidget);
    expect(find.text('星期分布（已完成）'), findsOneWidget);

    // 分布条颜色口径：完成段实色 + 未完成段同色 25% 弱化（2026-09-09 增强）
    // —— mock 种子「生活」项目 #2DB87A 仅 1 条未完成任务，只有弱化段；
    // 优先级「高」(3→#F59E0B) 同样只有未完成段；两处反向锁定弱化段=同色而非固定灰。
    final bars = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.color)
        .toSet();
    final lifeColor = hexToColor('#2DB87A').withValues(alpha: 0.25);
    expect(bars, contains(lifeColor));
    final highPrio = hexToColor(priorityColorHex(3)).withValues(alpha: 0.25);
    expect(bars, contains(highPrio));
  });

  testWidgets('统计页空态：无任务时页面级空态替代报表（2026-09-09）', (tester) async {
    final bridge = MockOrbitBridge();
    // 清空种子任务：mock 的 statsAggregate 按 store 现算，total 必为 0
    bridge.store.tasks.clear();
    await tester.pumpWidget(_wrap(const StatsScreen(), bridge));
    await _settle(tester);

    expect(find.text('统计'), findsOneWidget); // 标题栏仍在
    expect(find.textContaining('暂无统计数据'), findsOneWidget);
    expect(find.text('总任务'), findsNothing); // 零值报表不再渲染
    expect(find.text('完成热力图'), findsNothing);
  });
}
