// 看板卡片行内元信息（对齐桌面 kanban-view 卡脚注）：
// 提醒徽标（铃铛 + HH:mm，到期未完转逾期红）+ 子任务进度
// （percent_done 0/100 不显示）。口径与列表行 displayReminder 同源。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/core/theme/orbit_accents.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/kanban_view.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';

import 'support/orbit_test_app.dart';

TodoTask _task({int id = 1, String title = '看板卡', double percentDone = 0}) =>
    TodoTask(
      id: id,
      uuid: 'u$id',
      title: title,
      description: null,
      projectId: null,
      priority: 0,
      status: 'pending',
      done: 0,
      doneAt: null,
      dueDate: null,
      startDate: null,
      repeatAfter: 1,
      repeatMode: 0,
      repeatWeekdays: 0,
      repeatEndType: 0,
      repeatEndParam: 0,
      repeatFromDone: 0,
      repeatMonthMode: 0,
      repeatNthWeek: 0,
      percentDone: percentDone,
      position: 0,
      isFavorite: 0,
      myDayDate: null,
      durationMinutes: null,
      isDeleted: 0,
      createdAt: 1,
      updatedAt: 1,
      deletedAt: null,
      version: 1,
    );

Future<void> _pump(
  WidgetTester tester, {
  required TodoTask task,
  Map<int, List<ProjectedReminder>> remindersByTask = const {},
}) async {
  await tester.pumpWidget(
    orbitTestApp(
      home: Scaffold(
        body: KanbanBoard(
          columns: [
            KanbanColumn(
              key: 'c1',
              title: '待办',
              colorHex: '#3B82F6',
              tasks: [task],
            ),
          ],
          padding: EdgeInsets.zero,
          onToggleDone: (_) {},
          onOpen: (_) {},
          onLongPress: (_) {},
          remindersByTask: remindersByTask,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('提醒徽标：未来最近一条 → 铃铛 + HH:mm（非逾期红）', (tester) async {
    final futureMs =
        DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch;
    await _pump(
      tester,
      task: _task(),
      remindersByTask: {
        1: [ProjectedReminder(id: 7, remindAt: futureMs)],
      },
    );

    expect(find.byIcon(OrbitIcons.notification), findsOneWidget);
    expect(find.text(formatHm(futureMs)), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(OrbitIcons.notification)).color,
      isNot(OrbitAccents.overdueRed),
    );
  });

  testWidgets('提醒徽标：过期未完成 → 逾期红；无提醒不渲染', (tester) async {
    final pastMs =
        DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
    await _pump(
      tester,
      task: _task(),
      remindersByTask: {
        1: [ProjectedReminder(id: 7, remindAt: pastMs)],
      },
    );
    expect(
      tester.widget<Icon>(find.byIcon(OrbitIcons.notification)).color,
      OrbitAccents.overdueRed,
    );

    await _pump(tester, task: _task());
    expect(find.byIcon(OrbitIcons.notification), findsNothing);
  });

  testWidgets('子任务进度：50% 显示；0% / 100% 不显示', (tester) async {
    await _pump(tester, task: _task(percentDone: 50));
    expect(find.text('50%'), findsOneWidget);

    await _pump(tester, task: _task(percentDone: 0));
    expect(find.text('0%'), findsNothing);

    await _pump(tester, task: _task(percentDone: 100));
    expect(find.text('100%'), findsNothing);
  });
}
