// 四象限视图 widget 测试：概览 2×2 计数 → 点格下钻全量列表 → 返回概览。
//
// 纯函数口径（轴边界）已在 task_logic_test.dart 覆盖，此处只测装配态交互。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/matrix_view.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_list_card.dart';

import 'support/orbit_test_app.dart';

TodoTask _task({
  required int id,
  String title = 't',
  int priority = 0,
  int? dueDate,
}) {
  return TodoTask(
    id: id,
    uuid: 'u$id',
    title: title,
    description: null,
    projectId: null,
    priority: priority,
    status: 'pending',
    done: 0,
    doneAt: null,
    dueDate: dueDate,
    startDate: null,
    repeatAfter: 1,
    repeatMode: 0,
    repeatWeekdays: 0,
    repeatEndType: 0,
    repeatEndParam: 0,
    repeatFromDone: 0,
    percentDone: 0,
    position: 0,
    isFavorite: 0,
    myDayDate: null,
    isDeleted: 0,
    createdAt: 1000,
    updatedAt: 1000,
    deletedAt: null,
    version: 1,
  );
}

Future<void> _pumpMatrix(WidgetTester tester) async {
  final now = DateTime.now();
  final tasks = [
    _task(id: 1, title: '救火任务', priority: 3, dueDate: now.millisecondsSinceEpoch),
    _task(id: 2, title: '要事任务', priority: 4),
    _task(id: 3, title: '杂事任务', priority: 0, dueDate: now.millisecondsSinceEpoch),
  ];
  await tester.pumpWidget(
    orbitTestApp(
      // 生产装配在 SubListScreen 的 Scaffold 内（InkWell 需要 Material 祖先）
      home: Scaffold(
        body: EisenhowerMatrixBoard(
          tasks: tasks,
          padding: EdgeInsets.zero,
          buildTile: (task, {edge = OrbitCardEdge.none}) => ListTile(
            key: ValueKey('tile-${task.id}'),
            title: Text(task.title),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('概览：四象限格齐出，计数按桶落位', (tester) async {
    await _pumpMatrix(tester);
    expect(find.text('立即做'), findsOneWidget);
    expect(find.text('计划做'), findsOneWidget);
    expect(find.text('抽空做'), findsOneWidget);
    expect(find.text('可延后'), findsOneWidget);
    // 计数：紧急重要 1 / 重要不紧急 1 / 紧急不重要 1 / 双无 0
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('下钻：点象限格进入全量列表，行复用列表档构造', (tester) async {
    await _pumpMatrix(tester);
    await tester.tap(find.text('立即做'));
    await tester.pumpAndSettle();
    // 轴文案是下钻态专属：概览格里没有
    expect(find.text('紧急 · 重要 · 1 项'), findsOneWidget);
    expect(find.byKey(const ValueKey('tile-1')), findsOneWidget);
    // 其余象限任务不串桶
    expect(find.byKey(const ValueKey('tile-2')), findsNothing);
  });

  testWidgets('返回：下钻态点返回行回到 2×2 概览', (tester) async {
    await _pumpMatrix(tester);
    await tester.tap(find.text('立即做'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('紧急 · 重要 · 1 项'));
    await tester.pumpAndSettle();
    // 回到概览：轴行文案消失，四格回归
    expect(find.text('紧急 · 重要 · 1 项'), findsNothing);
    expect(find.text('计划做'), findsOneWidget);
  });
}
