// 侧滑手势测试（07 #18）：任务行右滑露「完成/恢复」面板、左滑露「删除」面板。
// 直接手造 TodoTask（不经 mock bridge 的延迟 Future——testWidgets 假时钟下
// 顶层 await 会死锁），聚焦手势面板本身。
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';

Widget _harness(TodoTask task) => MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            TodoTaskTile(
              task: task,
              onToggleDone: () {},
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
      uuid: 'uuid-1',
      title: '侧滑测试任务',
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

Future<void> _openPane(WidgetTester tester, Offset delta) async {
  await tester.drag(find.byType(Slidable), delta);
  // BehindMotion 收敛动画：固定时长推进（pumpAndSettle 对无限动画会死等）
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('侧滑：右滑（startActionPane）露「完成」动作', (tester) async {
    await tester.pumpWidget(_harness(_task(done: 0)));

    // 未滑动时不渲染动作面板
    expect(find.text('完成'), findsNothing);

    await _openPane(tester, const Offset(80, 0));
    expect(find.text('完成'), findsOneWidget);
  });

  testWidgets('侧滑：左滑（endActionPane）露「删除」动作', (tester) async {
    await tester.pumpWidget(_harness(_task(done: 0)));

    await _openPane(tester, const Offset(-80, 0));
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('侧滑：已完成任务右滑动作变「恢复」', (tester) async {
    await tester.pumpWidget(_harness(_task(done: 1)));

    await _openPane(tester, const Offset(80, 0));
    expect(find.text('恢复'), findsOneWidget);
  });
}
