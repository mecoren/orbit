// 表格视图（七列压缩形态，对齐桌面 task-table-view）：
// - 表头与数据行必须共用同一列几何——勾选框布局盒是热区下限
//   `OrbitCheckbox.minHitExtent`（44，视觉 20 居中），表头首格此前按视觉宽
//   占位，整表列错位约 20px（2026-10-15 修复，此处锁定）；
// - 时长列取值（formatDurationMinutes 同口径）与未设置占位「—」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/table_view.dart';

import 'support/orbit_test_app.dart';

/// 构造测试用任务（仅关注表格列相关字段，其余取合法默认值）
TodoTask _task({
  int id = 1,
  String title = '写周报',
  int? dueDate,
  int? durationMinutes,
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
    percentDone: 0,
    position: 0,
    isFavorite: 0,
    myDayDate: null,
    durationMinutes: durationMinutes,
    isDeleted: 0,
    createdAt: 1,
    updatedAt: 1,
    deletedAt: null,
    version: 1,
  );
}

Widget _harness(List<TodoTask> tasks) => orbitTestApp(
      home: Scaffold(
        body: TaskTableView(
          tasks: tasks,
          padding: EdgeInsets.zero,
          onToggleDone: (_) {},
          onOpen: (_) {},
          onLongPress: (_) {},
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
}
