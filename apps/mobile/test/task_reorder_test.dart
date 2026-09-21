// 任务列表长按拖拽重排测试（#37）：
// 1. manual 档（默认）渲染 ReorderableListView + 行尾拖拽把手；
// 2. 非手动档（截止时间）无把手、无重排列表（顺序由排序档决定）；
// 3. 拖拽把手触发 onReorder → todoTaskUpdatePosition 以相邻 position
//    取中值落库（与桌面 midpoint 同口径：prev 缺省 0 / next 缺省 100000）。
// MockOrbitBridge 注入（同 todo_screens_smoke_test 的延迟越过口径）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'support/orbit_test_app.dart';
import 'package:orbit/core/theme/icon_map.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 打开右上排序菜单切换档位（sort 图标按钮 → PopupMenuItem 文案）
Future<void> _switchSort(WidgetTester tester, String label) async {
  await tester.tap(find.byIcon(OrbitIcons.sort));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('manual 档：渲染重排列表与行尾拖拽把手', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    // 默认 manual 档：ReorderableListView + 把手图标
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byIcon(OrbitIcons.drag), findsWidgets);
  });

  testWidgets('非 manual 档：无把手（顺序由排序档决定）', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    await _switchSort(tester, '截止时间');
    await _settlePastMockLatency(tester);

    expect(find.byType(ReorderableListView), findsNothing);
    expect(find.byIcon(OrbitIcons.drag), findsNothing);
    // 列表本身仍渲染（普通 ListView）
    expect(find.text('完成移动端重构方案评审'), findsOneWidget);
  });

  testWidgets('拖拽落位：todoTaskUpdatePosition 以相邻中值落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    // 种子任务 position：首个任务 0，第二个 1（mock 按创建序累加）。
    // 把首行拖到末尾（oldIndex=0 → newIndex=length-1）：拖拽行新位次为
    // 末尾，next 缺省 100000，prev=末行原 position → 落库值=(prev+100000)/2。
    final firstTile = find.text('完成移动端重构方案评审');
    await tester.drag(firstTile, const Offset(0, 600));
    await tester.pumpAndSettle();
    await _settlePastMockLatency(tester);

    // mock 桥直接改 store.position——断言首任务 position 变为非 0 的
    // 大值（>50000，即 (prev+100000)/2 形态），证明中值口径生效
    final storeTask = bridge.store.tasks.values.firstWhere(
      (t) => t['title'] == '完成移动端重构方案评审',
    );
    expect(storeTask['position'] as int, greaterThan(50000));
  });
}
