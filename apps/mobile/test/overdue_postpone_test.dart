// 逾期区「顺延」一键改期今天：manual 档横幅卡（默认档）与标准分支头行按钮
// 两个入口，写库口径（due_date → 今天 18:00）+ 撤销浮层联动。
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

/// 推进假时钟越过 MockOrbitBridge 的 120ms 人为延迟，再收敛帧
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 造一条逾期未完成任务（截止 = 两天前零点后 9:00）
Map<String, dynamic> _overdueTask(MockOrbitBridge bridge, int id) {
  final now = DateTime.now();
  final due = DateTime(now.year, now.month, now.day - 2, 9);
  return {
    'id': id,
    'uuid': 'uuid-postpone-$id',
    'title': '逾期任务$id',
    'description': null,
    'project_id': null,
    'priority': 2,
    'status': 'pending',
    'done': 0,
    'done_at': null,
    'due_date': due.millisecondsSinceEpoch,
    'start_date': null,
    'repeat_after': 1,
    'repeat_mode': 0,
    'percent_done': 0,
    'position': id,
    'is_favorite': 0,
    'my_day_date': null,
    'is_deleted': 0,
    'created_at': bridge.store.now(),
    'updated_at': bridge.store.now(),
    'deleted_at': null,
    'version': 1,
  };
}

/// 顺延落点（与实现同口径）：18:00 收工时刻已过则顺延到明天 18:00
/// （逾期桶按时刻级判定，今天 18:00 已过时任务必须越过当前时刻才离开逾期区）
DateTime _expectedDue(DateTime now) {
  final today18 = DateTime(now.year, now.month, now.day, 18);
  return now.isBefore(today18)
      ? today18
      : today18.add(const Duration(days: 1));
}

void main() {
  testWidgets('manual 档（默认）：逾期横幅卡「顺延」改期到 18:00 收工时刻',
      (tester) async {
    final bridge = MockOrbitBridge();
    // 构造即自动种子化：清空后只留本用例的逾期任务，断言与种子数据解耦
    bridge.store.tasks.clear();
    bridge.store.tasks[7001] = _overdueTask(bridge, 7001);
    await tester.pumpWidget(_wrap(
      const SubListScreen(query: TaskFilterInput(quickView: QuickViewKey.all)),
      bridge,
    ));
    await _settle(tester);

    // manual 档逾期平铺无头行：顺延入口 = 列表上方的横幅卡
    expect(find.text('逾期 · 1'), findsOneWidget);
    expect(find.text('顺延'), findsOneWidget);

    await tester.tap(find.text('顺延'));
    await _settle(tester);

    // 落库口径：18:00 收工时刻（batchRescheduleMs 同口径）
    final expected = _expectedDue(DateTime.now());
    final dueMs = bridge.store.tasks[7001]!['due_date'] as int;
    final due = DateTime.fromMillisecondsSinceEpoch(dueMs);
    expect(due, expected);

    // 撤销浮层出现；快进过 5s 自动收起 Timer（防 pending timer 断言）
    expect(find.textContaining('已顺延 1 个任务'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 逾期区清空：横幅随之消失，任务落普通区且日期标签改口语化 18:00
    expect(find.text('逾期 · 1'), findsNothing);
    expect(find.text(formatDueShort(dueMs)), findsOneWidget);
  });

  testWidgets('标准分支（截止排序）：逾期区头行挂「顺延」，改期后头行消失',
      (tester) async {
    final bridge = MockOrbitBridge();
    bridge.store.tasks.clear();
    bridge.store.tasks[7002] = _overdueTask(bridge, 7002);
    await tester.pumpWidget(_wrap(
      const SubListScreen(query: TaskFilterInput(quickView: QuickViewKey.all)),
      bridge,
    ));
    await _settle(tester);

    // 切到「截止时间」排序进标准分支：⋮ 面板 → 排序方式（就地展开）→ 截止时间
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('排序方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('截止时间'));
    await tester.pumpAndSettle();

    // 标准分支：头行在任务卡首段，顺延按钮可点
    expect(find.text('逾期 · 1'), findsOneWidget);
    expect(find.text('顺延'), findsOneWidget);
    await tester.tap(find.text('顺延'));
    await _settle(tester);

    expect(find.textContaining('已顺延 1 个任务'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('逾期 · 1'), findsNothing);
  });
}
