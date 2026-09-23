// 任务列表长按拖动重排测试（#37，2026-09-22 形制收敛）：
// 1. manual 档（默认）渲染 ReorderableListView + 整行长按拾起，**无行尾把手图标**；
// 2. 非手动档（截止时间）不重排（顺序由排序档决定）；
// 3. 长按拾起后拖动 → onReorderItem → todoTaskUpdatePosition 以相邻 position
//    取中值落库（与桌面 midpoint 同口径：prev 缺省 0 / next 缺省 100000）；
// 4. 长按拾起后**手指移动过** → 只落位排序、松手不弹操作菜单（位移判据取行内
//    Listener 的原始指针位移；onReorderItem 只在真换过槽位时才触发，靠不住）；
// 5. 长按拾起后**原地松手**（无位移）→ 仍弹操作菜单（长按手势在 manual 档
//    让位给拖动后，菜单入口由 onReorderEnd 兜回来，功能不欠账）。
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

/// 经页头 ⋮ 下拉面板切排序档（⋮ → 就地展开「排序方式」→ 点档位）
Future<void> _switchSort(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('更多操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('排序方式'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// 长按拾起第一行（越过 500ms 长按阈值进入拖动态），可选再位移
Future<TestGesture> _pickUp(WidgetTester tester, Finder row) async {
  final gesture = await tester.startGesture(tester.getCenter(row));
  // 500ms 长按阈值（kLongPressTimeout）+ 余量：此前的移动只会被当作滚动
  await tester.pump(const Duration(milliseconds: 600));
  return gesture;
}

void main() {
  testWidgets('manual 档：重排列表 + 整行长按拾起（无行尾把手图标）', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    // 默认 manual 档：ReorderableListView + 整行长按拾起监听器
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byType(ReorderableDelayedDragStartListener), findsWidgets);
    // 行尾拖拽把手图标已移除（拖动改为整行长按，列表更干净）
    expect(find.byIcon(OrbitIcons.drag), findsNothing);
  });

  testWidgets('非 manual 档：不重排、无长按拾起（顺序由排序档决定）', (tester) async {
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
    expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
    // 列表本身仍渲染（普通 ListView）
    expect(find.text('完成移动端重构方案评审'), findsOneWidget);
  });

  testWidgets('长按拾起拖动落位：todoTaskUpdatePosition 以相邻中值落库', (tester) async {
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
    final gesture = await _pickUp(tester, firstTile);
    await gesture.moveBy(const Offset(0, 600));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await _settlePastMockLatency(tester);

    // mock 桥直接改 store.position——断言首任务 position 变为非 0 的
    // 大值（>50000，即 (prev+100000)/2 形态），证明中值口径生效
    final storeTask = bridge.store.tasks.values.firstWhere(
      (t) => t['title'] == '完成移动端重构方案评审',
    );
    expect(storeTask['position'] as int, greaterThan(50000));
  });

  testWidgets('长按拾起后拖动落位：不弹操作菜单（有位移即排序，非长按）', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    final gesture = await _pickUp(tester, find.text('完成移动端重构方案评审'));
    await gesture.moveBy(const Offset(0, 600));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await _settlePastMockLatency(tester);

    // 落位（无论换没换槽位）都是排序手势，不该再兜出长按菜单
    expect(find.text('多选'), findsNothing);
    expect(find.text('复制任务'), findsNothing);
  });

  testWidgets('长按拾起后来回拖动回到原位：不弹菜单、不写库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    final gesture = await _pickUp(tester, find.text('完成移动端重构方案评审'));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await _settlePastMockLatency(tester);

    expect(find.text('多选'), findsNothing);
    final storeTask = bridge.store.tasks.values.firstWhere(
      (t) => t['title'] == '完成移动端重构方案评审',
    );
    expect(storeTask['position'] as int, 0, reason: '净位移为零，槽位未变，不写库');
  });

  testWidgets('长按原地松手：manual 档仍弹操作菜单（多选入口在）', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    final gesture = await _pickUp(tester, find.text('完成移动端重构方案评审'));
    await gesture.up();
    await tester.pumpAndSettle();

    // 无位移 → 不走重排，走长按菜单（与改版前的手感一致）
    expect(find.text('多选'), findsOneWidget);
    expect(find.text('复制任务'), findsOneWidget);
    final storeTask = bridge.store.tasks.values.firstWhere(
      (t) => t['title'] == '完成移动端重构方案评审',
    );
    expect(storeTask['position'] as int, 0, reason: '原地松手不该写库');
  });
}
