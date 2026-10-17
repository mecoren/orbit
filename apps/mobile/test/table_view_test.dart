// 表格视图（七列压缩形态，对齐桌面 task-table-view）：
// - 表头与数据行必须共用同一列几何——勾选框布局盒是热区下限
//   `OrbitCheckbox.minHitExtent`（44，视觉 20 居中），表头首格此前按视觉宽
//   占位，整表列错位约 20px（2026-10-15 修复，此处锁定）；
// - 时长列取值（formatDurationMinutes 同口径）与未设置占位「—」；
// - 标题列只读指示（星标/我的一天/进度）与截止列提醒铃铛（桌面同位同源）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/core/theme/orbit_accents.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/table_view.dart';

import 'support/orbit_test_app.dart';

/// 构造测试用任务（仅关注表格列相关字段，其余取合法默认值）
TodoTask _task({
  int id = 1,
  String title = '写周报',
  int? dueDate,
  int? durationMinutes,
  double percentDone = 0,
  int isFavorite = 0,
  int? myDayDate,
}) {
  return TodoTask(
    id: id,
    uuid: 'u$id',
    title: title,
    description: null,
    projectId: null,
    priority: 0,
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
    repeatMonthMode: 0,
    repeatNthWeek: 0,
    percentDone: percentDone,
    position: 0,
    isFavorite: isFavorite,
    myDayDate: myDayDate,
    durationMinutes: durationMinutes,
    isDeleted: 0,
    createdAt: 1,
    updatedAt: 1,
    deletedAt: null,
    version: 1,
  );
}

Widget _harness(
  List<TodoTask> tasks, {
  Map<int, List<ProjectedReminder>> remindersByTask = const {},
}) =>
    orbitTestApp(
      home: Scaffold(
        body: TaskTableView(
          tasks: tasks,
          padding: EdgeInsets.zero,
          onToggleDone: (_) {},
          onOpen: (_) {},
          onLongPress: (_) {},
          onToggleFavorite: (_) {},
          onToggleMyDay: (_) {},
          remindersByTask: remindersByTask,
        ),
      ),
    );

void main() {
  testWidgets('表头五列渲染（标签/截止/时长标签位齐全）', (tester) async {
    await tester.pumpWidget(_harness([_task()]));

    expect(find.text('标题'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    expect(find.text('截止'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);
  });

  testWidgets('表头与数据行同列几何：标题左沿逐像素对齐', (tester) async {
    await tester.pumpWidget(_harness([_task(title: '写周报')]));

    final headerTitle = tester.getTopLeft(find.text('标题')).dx;
    final rowTitle = tester.getTopLeft(find.text('写周报')).dx;
    expect(rowTitle, headerTitle);
  });

  testWidgets('时长右沿与表头对齐；未设置渲染占位', (tester) async {
    final due = DateTime.now()
        .add(const Duration(days: 2))
        .millisecondsSinceEpoch;
    await tester.pumpWidget(_harness([
      _task(id: 1, title: '有值', dueDate: due, durationMinutes: 90),
      _task(id: 2, title: '无值'),
    ]));

    // 有值行：时长文案格式与桌面同口径（90 分钟 → 1h30m）
    expect(find.text('1h30m'), findsOneWidget);
    final headerDuration = tester.getTopRight(find.text('时长')).dx;
    final rowDuration = tester.getTopRight(find.text('1h30m')).dx;
    expect(rowDuration, headerDuration);

    // 无值行：项目/标签/截止/时长四列皆有「—」占位（保持列对齐）
    // 数量 = 2 行 ×（项目 + 标签）+ 无值行（截止 + 时长）= 6
    final dashes = find.text('—');
    expect(dashes, findsNWidgets(6));
    // 截止/时长两列的占位右沿与各自表头逐像素对齐（右对齐列口径）
    final dashRights = [
      for (var i = 0; i < 6; i++) tester.getTopRight(dashes.at(i)).dx,
    ];
    expect(dashRights, contains(headerDuration));
    expect(dashRights, contains(tester.getTopRight(find.text('截止')).dx));
  });

  testWidgets('标题列行内开关：星标 / 我的一天 / 子任务进度', (tester) async {
    final now = DateTime.now();
    final todayZero =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    await tester.pumpWidget(_harness([
      _task(
        id: 1,
        title: '带指示',
        percentDone: 50,
        isFavorite: 1,
        myDayDate: todayZero,
      ),
    ]));

    expect(find.byIcon(OrbitIcons.star), findsOneWidget);
    expect(find.byIcon(OrbitIcons.sunrise), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);

    // 0/100 不显示（桌面表格同口径）；星标/我的一天**恒显可点**（G8：
    // 对齐桌面 hover 开关钮——无 hover 的触控映射 = 恒显，未激活弱化灰）
    await tester.pumpWidget(_harness([
      _task(id: 1, title: '满进度', percentDone: 100),
    ]));
    await tester.pump();
    expect(find.text('100%'), findsNothing);
    expect(find.byIcon(OrbitIcons.star), findsOneWidget);
    expect(find.byIcon(OrbitIcons.sunrise), findsOneWidget);
  });

  testWidgets('截止列提醒铃铛：有存活提醒才有，到期未完转逾期红', (tester) async {
    final futureMs =
        DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch;
    final pastMs =
        DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch;

    await tester.pumpWidget(_harness(
      [_task(id: 1, title: '有提醒', dueDate: futureMs)],
      remindersByTask: {
        1: [ProjectedReminder(id: 5, remindAt: futureMs)],
      },
    ));
    expect(
      tester.widget<Icon>(find.byIcon(OrbitIcons.notification)).color,
      isNot(OrbitAccents.overdueRed),
    );

    await tester.pumpWidget(_harness(
      [_task(id: 1, title: '已响', dueDate: pastMs)],
      remindersByTask: {
        1: [ProjectedReminder(id: 5, remindAt: pastMs)],
      },
    ));
    await tester.pump();
    expect(
      tester.widget<Icon>(find.byIcon(OrbitIcons.notification)).color,
      OrbitAccents.overdueRed,
    );

    await tester.pumpWidget(_harness([_task(id: 1, title: '无提醒')]));
    await tester.pump();
    expect(find.byIcon(OrbitIcons.notification), findsNothing);
  });
}
