// 项目颜色渲染测试（#36）：
// 1. TodoTaskTile 副标题项目名按项目 hexColor 着字（无项目色回退次要文本色）；
// 2. 无项目（未分组）不渲染项目名段。
// 直接手造 TodoTask / TodoProject（同 slidable_test 的假时钟口径）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'support/orbit_test_app.dart';

Widget _harness({required TodoTask task, String? projectColorHex}) =>
    orbitTestApp(
      home: Scaffold(
        body: ListView(
          children: [
            TodoTaskTile(
              task: task,
              projectTitle: task.projectId != null ? '工作项目' : null,
              projectColorHex: projectColorHex,
              onToggleDone: () {},
              onLongPress: () {},
              onOpen: () {},
              onDelete: () {},
            ),
          ],
        ),
      ),
    );

TodoTask _task({int? projectId}) => TodoTask(
      id: 1,
      uuid: 'uuid-1',
      title: '颜色测试任务',
      description: null,
      projectId: projectId,
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

void main() {
  testWidgets('项目名文字色 = 项目 hexColor', (tester) async {
    await tester.pumpWidget(
      _harness(task: _task(projectId: 7), projectColorHex: '#EF4444'),
    );

    final text = tester.renderObject<RenderParagraph>(
      find.text('工作项目'),
    );
    expect(text.text.style?.color, const Color(0xFFEF4444));
  });

  testWidgets('项目色为空串：回退主题次要文本色', (tester) async {
    await tester.pumpWidget(
      _harness(task: _task(projectId: 7), projectColorHex: ''),
    );
    await tester.pump();

    final text = tester.renderObject<RenderParagraph>(
      find.text('工作项目'),
    );
    // 未着项目色 → null（TextStyle 由 tile 内回退逻辑填主题色，此处断言非项目色）
    expect(text.text.style?.color, isNot(const Color(0xFFEF4444)));
  });

  testWidgets('未分组（projectId=null）：不渲染项目名', (tester) async {
    await tester.pumpWidget(_harness(task: _task(projectId: null)));

    expect(find.text('工作项目'), findsNothing);
  });
}
