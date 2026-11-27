// 列表状态筛选多选（2026-11-27 对齐桌面 #118）：
// 1. 「全部」= 空集；点真实状态 chip 可多档并选（不是单选互斥）；
// 2. 「待办 + 进行中」两档齐选时「未完成」派生快捷档同步点亮；
// 3. 「全部」一键清空。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_filter_chip.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Future<void> _openFilterSheet(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多操作'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('筛选'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('筛选'));
  await tester.pumpAndSettle();
}

OrbitFilterChip _chip(WidgetTester tester, String label, {int index = 0}) =>
    tester.widget<OrbitFilterChip>(
      find.widgetWithText(OrbitFilterChip, label).at(index),
    );

void main() {
  testWidgets('状态筛选多选：可并选、未完成派生档联动、全部清空', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(query: TaskFilterInput(quickView: QuickViewKey.all)),
      bridge,
    ));
    await _settlePastMockLatency(tester);
    await _openFilterSheet(tester);

    // 初始：全部选中，其余未选
    expect(_chip(tester, '全部').selected, isTrue);
    expect(_chip(tester, '待办').selected, isFalse);
    expect(_chip(tester, '进行中').selected, isFalse);
    expect(_chip(tester, '已完成').selected, isFalse);
    expect(_chip(tester, '未完成').selected, isFalse);

    // 点「待办」：不再单选互斥（全部退出）
    await tester.tap(find.widgetWithText(OrbitFilterChip, '待办'));
    await tester.pumpAndSettle();
    expect(_chip(tester, '全部').selected, isFalse);
    expect(_chip(tester, '待办').selected, isTrue);

    // 再点「进行中」：两档同时选中
    await tester.tap(find.widgetWithText(OrbitFilterChip, '进行中'));
    await tester.pumpAndSettle();
    expect(_chip(tester, '待办').selected, isTrue);
    expect(_chip(tester, '进行中').selected, isTrue);
    // 两档齐选 = 未完成派生档
    expect(_chip(tester, '未完成').selected, isTrue);

    // 再点「已完成」：三档并选，未完成派生档退出
    await tester.tap(find.widgetWithText(OrbitFilterChip, '已完成'));
    await tester.pumpAndSettle();
    expect(_chip(tester, '待办').selected, isTrue);
    expect(_chip(tester, '进行中').selected, isTrue);
    expect(_chip(tester, '已完成').selected, isTrue);
    expect(_chip(tester, '未完成').selected, isFalse);

    // 全部：一键清空
    await tester.tap(find.widgetWithText(OrbitFilterChip, '全部').first);
    await tester.pumpAndSettle();
    expect(_chip(tester, '全部').selected, isTrue);
    expect(_chip(tester, '待办').selected, isFalse);
    expect(_chip(tester, '进行中').selected, isFalse);
    expect(_chip(tester, '已完成').selected, isFalse);
  });
}
