// 四象限视图 widget 测试（2×2 格内列表版）：四格齐出、任务按桶落位格内、
// 空象限「没有任务」、点行/勾选回调。
//
// 纯函数口径（轴边界）已在 task_logic_test.dart 覆盖，此处只测装配态交互。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/matrix_view.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_checkbox.dart';

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

Future<void> _pumpMatrix(
  WidgetTester tester, {
  ValueChanged<TodoTask>? onOpen,
  ValueChanged<TodoTask>? onToggleDone,
}) async {
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
          onOpen: onOpen ?? (_) {},
          onToggleDone: onToggleDone ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('概览：四象限格齐出，行动短语 + 计数按桶落位', (tester) async {
    await _pumpMatrix(tester);
    expect(find.text('立即做'), findsOneWidget);
    expect(find.text('计划做'), findsOneWidget);
    expect(find.text('抽空做'), findsOneWidget);
    expect(find.text('可延后'), findsOneWidget);
    // 计数：紧急重要 1 / 重要不紧急 1 / 紧急不重要 1 / 双无 0
    expect(find.text('0'), findsOneWidget);
    // 任务行按桶落格：三个标题全可见（2×2 恒在，无下钻）
    expect(find.text('救火任务'), findsOneWidget);
    expect(find.text('要事任务'), findsOneWidget);
    expect(find.text('杂事任务'), findsOneWidget);
  });

  testWidgets('空象限：格内居中「没有任务」', (tester) async {
    await _pumpMatrix(tester);
    expect(find.text('没有任务'), findsOneWidget);
  });

  testWidgets('点行进详情：onOpen 带回任务', (tester) async {
    TodoTask? opened;
    await _pumpMatrix(tester, onOpen: (t) => opened = t);
    await tester.tap(find.text('救火任务'));
    await tester.pumpAndSettle();
    expect(opened?.id, 1);
  });

  testWidgets('勾选完成：onToggleDone 带回任务', (tester) async {
    TodoTask? toggled;
    await _pumpMatrix(tester, onToggleDone: (t) => toggled = t);
    await tester.tap(find.byType(OrbitCheckbox).first);
    await tester.pumpAndSettle();
    expect(toggled, isNotNull);
  });
}
