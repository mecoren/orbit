// 子任务转独立任务 mock 桥契约测试——对齐 Rust promote_todo_subtask 语义：
// 软删子任务行 + 承接父任务 project/priority/due 建尾位新任务 + percent 重算。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';

void main() {
  test('promote 后新任务承接父任务上下文 + 子任务行软删', () async {
    final bridge = MockOrbitBridge();
    final parent = await bridge.todoTaskCreate(TodoTaskCreateInput(
      title: '父任务',
      projectId: 1,
      priority: 3,
      dueDate: 1700000000000,
    ));
    final sub = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '长大了的子任务'));

    final created = await bridge.todoSubtaskPromote(sub.id);

    expect(created.title, '长大了的子任务');
    expect(created.projectId, parent.projectId);
    expect(created.priority, parent.priority);
    expect(created.dueDate, parent.dueDate);
    expect(created.done, 0);
    expect(created.status, 'pending');

    // 子任务行软删：默认列表（is_deleted=0 过滤）不再含该行
    final after = await bridge.todoSubtaskList(const ListFilter(pageSize: 100));
    expect(after.where((s) => s.id == sub.id).isEmpty, isTrue);
  });

  test('promote 重算父任务 percent_done（50% → 转走已完成行后 0%）', () async {
    final bridge = MockOrbitBridge();
    final parent = await bridge
        .todoTaskCreate(TodoTaskCreateInput(title: '进度父'));
    final s1 = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '甲'));
    await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '乙'));
    await bridge.todoSubtaskToggleDone(s1.id, true);

    final before = await bridge.todoTaskGet(parent.id);
    expect(before.percentDone, 50.0);

    await bridge.todoSubtaskPromote(s1.id);
    final after = await bridge.todoTaskGet(parent.id);
    expect(after.percentDone, 0.0);
  });

  test('promote 已完成子任务保留 done 状态与 doneAt', () async {
    final bridge = MockOrbitBridge();
    final parent = await bridge
        .todoTaskCreate(TodoTaskCreateInput(title: '父'));
    final sub = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '已完成的子任务'));
    await bridge.todoSubtaskToggleDone(sub.id, true);

    final created = await bridge.todoSubtaskPromote(sub.id);
    expect(created.done, 1);
    expect(created.status, 'done');
    expect(created.doneAt, isNotNull);
  });
}
