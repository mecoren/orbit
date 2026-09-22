// 视图切换过渡：列表 / 看板 / 表格三态经 AnimatedSwitcher 淡入 + 轻微上滑衔接。
//
// key 只跟视图走——切视图播过渡并落定到目标视图；任务增删不经过这里。
// 视图档位持久化进 LocalPrefs：setUp/tearDown 复位到列表档，防止同
// isolate 内后续用例读到脏档位。
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

import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

/// 推进假时钟越过 MockOrbitBridge 的 120ms 人为延迟，再收敛帧
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Future<void> _pumpList(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(_wrap(
    const SubListScreen(query: TaskFilterInput(quickView: QuickViewKey.all)),
    bridge,
  ));
  await _settle(tester);
}

/// 经右上「视图模式」抽屉切到目标视图，停在过渡起播后（不断言 settled）
Future<void> _switchTo(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('视图模式'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pump();
}

void main() {
  setUp(() => LocalPrefs.setString(viewModePrefsKey, TaskViewMode.list.name));
  tearDown(
      () => LocalPrefs.setString(viewModePrefsKey, TaskViewMode.list.name));

  testWidgets('接线存在：列表区由 AnimatedSwitcher 承载', (tester) async {
    await _pumpList(tester, MockOrbitBridge());
    expect(find.byType(AnimatedSwitcher), findsOneWidget);
  });

  testWidgets('切到看板：过渡起播后出现 KanbanBoard，收敛后稳定', (tester) async {
    await _pumpList(tester, MockOrbitBridge());
    expect(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == 'TodoTaskTile'),
      findsWidgets,
    );

    await _switchTo(tester, '看板');
    // 过渡中：目标树已挂载（incoming 淡入起播）
    expect(find.byType(KanbanBoard), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byType(KanbanBoard), findsOneWidget);
  });

  testWidgets('切回列表：任务行恢复渲染', (tester) async {
    await _pumpList(tester, MockOrbitBridge());

    await _switchTo(tester, '表格');
    await tester.pumpAndSettle();

    await _switchTo(tester, '列表');
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == 'TodoTaskTile'),
      findsWidgets,
    );
  });
}
