// 任务行元信息行回归（M3 / docs/10 §A-4 收口）：
// 行内标签（色点 + 名，超 3 折叠 +N）、行内提醒徽标（铃铛 + HH:mm，
// 到期未完转逾期红）、子任务进度（percent_done 0/100 不显示）。
// 口径与桌面 LabelChips / ReminderChip / percent_done 同源；
// 直接手造 DTO（同 project_color_test 的假时钟口径）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/core/theme/orbit_accents.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'support/orbit_test_app.dart';

TodoTask _task({double percentDone = 0}) => TodoTask(
      id: 1,
      uuid: 'uuid-1',
      title: '元信息测试任务',
      description: null,
      projectId: null,
      priority: 2,
      status: 'pending',
      done: 0,
      doneAt: null,
      dueDate: null,
      startDate: null,
      repeatAfter: 0,
      repeatMode: 0,
      repeatWeekdays: 0,
      repeatEndType: 0,
      repeatEndParam: 0,
      repeatFromDone: 0,
      percentDone: percentDone,
      position: 0,
      isFavorite: 0,
      myDayDate: null,
      isDeleted: 0,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
      deletedAt: null,
      version: 1,
    );

Widget _harness({
  required TodoTask task,
  List<ProjectedTaskLabel> labels = const [],
  ({int id, String clock, bool fired})? reminder,
}) =>
    orbitTestApp(
      home: Scaffold(
        body: ListView(
          children: [
            TodoTaskTile(
              task: task,
              labels: labels,
              reminder: reminder,
              onToggleDone: () {},
              onOpen: () {},
              onDelete: () {},
            ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('标签段：色点 + 名渲染，超 3 个折叠为 +N', (tester) async {
    await tester.pumpWidget(_harness(
      task: _task(),
      labels: const [
        ProjectedTaskLabel(id: 1, title: '工作', hexColor: '#EF4444'),
        ProjectedTaskLabel(id: 2, title: '生活', hexColor: '#22C55E'),
        ProjectedTaskLabel(id: 3, title: '学习', hexColor: '#3B82F6'),
        ProjectedTaskLabel(id: 4, title: '健康', hexColor: '#F59E0B'),
      ],
    ));

    expect(find.text('工作'), findsOneWidget);
    expect(find.text('生活'), findsOneWidget);
    expect(find.text('学习'), findsOneWidget);
    // 第 4 个不直显，只给计数
    expect(find.text('健康'), findsNothing);
    expect(find.text('+1'), findsOneWidget);

    // 色点取标签自身 hex_color（与桌面 LabelChips 同口径）
    final labelDots = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).color == const Color(0xFFEF4444));
    expect(labelDots.length, 1);
  });

  testWidgets('标签段：空表不渲染（不影响既有行）', (tester) async {
    await tester.pumpWidget(_harness(task: _task()));
    expect(find.text('+1'), findsNothing);
  });

  testWidgets('提醒段：未到期 → 铃铛 + HH:mm（次要文本色）', (tester) async {
    await tester.pumpWidget(_harness(
      task: _task(),
      reminder: (id: 1, clock: '09:30', fired: false),
    ));

    expect(find.byIcon(OrbitIcons.notification), findsOneWidget);
    final text = tester.renderObject<RenderParagraph>(find.text('09:30'));
    expect(text.text.style?.color, isNot(OrbitAccents.overdueRed));
  });

  testWidgets('提醒段：已到期且未完成 → 逾期红警示', (tester) async {
    await tester.pumpWidget(_harness(
      task: _task(),
      reminder: (id: 1, clock: '09:30', fired: true),
    ));

    final text = tester.renderObject<RenderParagraph>(find.text('09:30'));
    expect(text.text.style?.color, OrbitAccents.overdueRed);
  });

  testWidgets('提醒段：null 不渲染（无存活提醒）', (tester) async {
    await tester.pumpWidget(_harness(task: _task()));
    expect(find.byIcon(OrbitIcons.notification), findsNothing);
  });

  testWidgets('进度段：50% 显示，0% / 100% 不显示', (tester) async {
    await tester.pumpWidget(_harness(task: _task(percentDone: 50)));
    expect(find.text('50%'), findsOneWidget);
    expect(find.byIcon(OrbitIcons.listChecks), findsOneWidget);

    await tester.pumpWidget(_harness(task: _task(percentDone: 0)));
    await tester.pump();
    expect(find.text('0%'), findsNothing);

    await tester.pumpWidget(_harness(task: _task(percentDone: 100)));
    await tester.pump();
    expect(find.text('100%'), findsNothing);
  });
}
