// 看板/表格视图多选批量（G6，对齐桌面 kanban-view.tsx / task-table-view.tsx）：
// 桌面两视图均有完整多选批量（选择态卡片 + 批量条 + runBatch），移动端此前
// 被误限制在列表档（注释称「桌面看板无多选」系误判）：
// 1. 看板/表格档长按菜单含「多选」项；
// 2. 进入选择态后卡片/行换装为选区形态，点选/取消选中；
// 3. 选择态页头显示「已选 N 项」+ 全选/退出，底部批量工具条在位。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Future<void> _pumpList(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(_wrap(
    const SubListScreen(
      query: TaskFilterInput(quickView: QuickViewKey.all),
    ),
    bridge,
  ));
  await _settlePastMockLatency(tester);
}

/// 经 ⋮ 面板切视图档（⋮ → 就地展开「视图」→ 点档位）
Future<void> _switchView(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('更多操作'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('视图'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('视图'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('$label视图'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('$label视图'));
  await tester.pumpAndSettle();
}

/// 长按第一行（越过 500ms 长按阈值）后原地松手 → 兜出操作菜单
Future<void> _longPress(String title, WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(find.text(title)));
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 长按菜单项可能被挤出可视区，点前先 ensureVisible
Future<void> _tapInMenu(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('看板档长按菜单含「多选」，进入选择态后页头/批量工具条就位',
      (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);
    await _switchView(tester, '看板');

    await _longPress('完成移动端重构方案评审', tester);
    await _tapInMenu(tester, '多选');

    // 选择态页头 + 底部批量工具条（跨视图共用，与列表档同口径）；
    // 「退出多选」是 IconButton tooltip（图标钮无文字）
    expect(find.textContaining('已选'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.byTooltip('退出多选'), findsOneWidget);
    // 批量动作条（横排九项）在位
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('表格档长按菜单含「多选」，进入选择态可点选/取消', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);
    await _switchView(tester, '表格');

    await _longPress('完成移动端重构方案评审', tester);
    await _tapInMenu(tester, '多选');

    // 进入即选中被长按那条 → 「已选 1 项」
    expect(find.text('已选 1 项'), findsOneWidget);

    // 点另一行卡片/行标题切换选中态 → 「已选 2 项」
    await tester.tap(find.text('采购周末露营物资'));
    await _settlePastMockLatency(tester);
    expect(find.text('已选 2 项'), findsOneWidget);

    // 再点同一行取消 → 回到「已选 1 项」
    await tester.tap(find.text('采购周末露营物资'));
    await _settlePastMockLatency(tester);
    expect(find.text('已选 1 项'), findsOneWidget);
  });
}
