// 任务行动效接线（对齐微软 To-Do）：完成态标题接 AnimatedStrikethrough、
// 勾选框点按回调。手造 TodoTask（不经 mock bridge 的延迟 Future——testWidgets
// 假时钟下顶层 await 会死锁），固定时长 pump 推进。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_motion.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/shared/widgets/animated_strikethrough.dart';
import 'package:orbit/shared/widgets/circle_checkbox.dart';

Widget _harness(TodoTask task, {required VoidCallback onToggleDone}) =>
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            TodoTaskTile(
              task: task,
              onToggleDone: onToggleDone,
              onLongPress: () {},
              onOpen: () {},
              onDelete: () {},
            ),
          ],
        ),
      ),
    );

TodoTask _task({required int done}) => TodoTask(
      id: 1,
      uuid: 'uuid-motion-1',
      title: '动效测试任务',
      description: null,
      projectId: null,
      priority: 2,
      status: done == 1 ? 'done' : 'pending',
      done: done,
      doneAt: done == 1 ? 1700000000000 : null,
      dueDate: null,
      startDate: null,
      repeatAfter: 0,
      repeatMode: 0,
      repeatWeekdays: 0,
      repeatEndType: 0,
      repeatEndParam: 0,
      repeatFromDone: 0,
      percentDone: 0.0,
      position: 0,
      isFavorite: 0,
      myDayDate: null,
      isDeleted: 0,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
      deletedAt: null,
      version: 1,
    );

/// 标题划线层（仅当完成进度 > 0 时挂载）
Finder _strikeLayer() => find.descendant(
      of: find.byType(AnimatedStrikethrough),
      matching: find.byType(CustomPaint),
    );

void main() {
  testWidgets('待办行：标题可见、无划线层，点勾选框回调一次', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(
      _harness(_task(done: 0), onToggleDone: () => toggles++),
    );
    await tester.pump(AppMotion.fast);

    expect(find.text('动效测试任务'), findsOneWidget);
    expect(_strikeLayer(), findsNothing);

    await tester.tap(find.byType(CircleCheckbox));
    await tester.pump();
    await tester.pump(AppMotion.fast);

    expect(toggles, 1);
  });

  testWidgets('已完成行：挂载即呈完成态（划线层存在、无重播等帧）', (tester) async {
    await tester.pumpWidget(
      _harness(_task(done: 1), onToggleDone: () {}),
    );
    await tester.pump();

    expect(find.text('动效测试任务'), findsOneWidget);
    expect(_strikeLayer(), findsOneWidget);
  });
}
