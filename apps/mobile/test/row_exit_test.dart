// 行退场：标准分支的删除 / 离场型完成先播 300ms _RowExit 再收敛；
// 写失败不进退场；看板分支保持即时失效（无 ghost 停留）。
//
// FakeAsync 约束（同 pull_to_refresh）：mock 真 Timer，靠 pump 推进。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/kanban_view.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/logic/view_mode.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/services/local_prefs.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_checkbox.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _pumpList(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(_wrap(
    const SubListScreen(query: TaskFilterInput(quickView: QuickViewKey.all)),
    bridge,
  ));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Finder _tileOf(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == 'TodoTaskTile'),
    );

/// ghost 退场包装（私有类，按类型名直查——同 TodoTaskTile 的既有手法）
Finder _rowExit() => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_RowExit',
    );

void main() {
  setUp(() => LocalPrefs.setString(viewModePrefsKey, TaskViewMode.list.name));
  tearDown(
      () => LocalPrefs.setString(viewModePrefsKey, TaskViewMode.list.name));

  testWidgets('完成退场：ghost 停留 300ms 后行消失', (tester) async {
    await _pumpList(tester, MockOrbitBridge());
    // 默认 manual 重排档不进退场（仅标准列表分支）：先从 ⋮ 面板切到截止时间排序
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('排序方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('截止时间'));
    await tester.pumpAndSettle();

    const title = '完成移动端重构方案评审';
    expect(_tileOf(title), findsOneWidget);

    // 点勾选：写库（120ms）→ ghost 起播
    await tester.tap(
      find.descendant(of: _tileOf(title), matching: find.byType(CircleCheckbox)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 退场窗内：旧对象仍在树上，且正被 _RowExit 包裹播退场
    expect(_tileOf(title), findsOneWidget);
    expect(
      _rowExit(),
      findsOneWidget,
      reason: '失效延迟窗内 ghost 行必须仍在树上播退场',
    );

    // 窗后：失效触发，行收敛消失
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(_tileOf(title), findsNothing);
  });

  testWidgets('看板分支：完成后即时失效，无 ghost 停留', (tester) async {
    await _pumpList(tester, MockOrbitBridge());

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('看板视图'));
    await tester.pumpAndSettle();
    expect(find.byType(KanbanBoard), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(KanbanBoard),
        matching: find.byType(CircleCheckbox),
      ).first,
    );
    // 写完即失效：旧值重查中卡片仍在，但绝不能挂 ghost（无 _RowExit）
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.descendant(
        of: find.byType(KanbanBoard),
        matching: find.byType(CircleCheckbox),
      ),
      findsWidgets,
      reason: '旧值重查中，卡片仍在树上',
    );
    expect(
      _rowExit(),
      findsNothing,
      reason: '看板分支走即时失效，不播退场',
    );
    await tester.pumpAndSettle();
  });
}
