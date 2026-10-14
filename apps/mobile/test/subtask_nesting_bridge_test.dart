// M10 子任务多层嵌套 mock 桥契约测试——对齐本轮给 mock 落的新语义：
// create 带 parentUuid 挂父、update patch parent_uuid 三态、删除整棵子树
// 软删、promote 子孙整棵随迁（task_id 改挂 + 直接子女提顶层 + 新任务
// percent 重算）、随迁后 subtask_tree 还原层级、percent 全树聚合。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/modules/todo/logic/subtask_tree.dart';

void main() {
  test('create 带 parentUuid 挂父；update patch 三态（挂父/提顶层）', () async {
    final bridge = MockOrbitBridge();
    final t = await bridge.todoTaskCreate(TodoTaskCreateInput(title: '任务'));
    final a = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: t.id, title: '甲'));
    final b = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: t.id, title: '乙', parentUuid: a.uuid));

    expect(b.parentUuid, a.uuid, reason: 'create 应透传父引用');

    // 提顶层：patch 显式 null（三态里的 Some(None)）
    final lifted = await bridge.todoSubtaskUpdate(b.id, '{"parent_uuid":null}');
    expect(lifted.parentUuid, isNull);

    // 重新挂父：patch 给父 uuid
    final nested = await bridge.todoSubtaskUpdate(b.id, '{"parent_uuid":"${a.uuid}"}');
    expect(nested.parentUuid, a.uuid);
  });

  test('删除父行带走整棵子树（软删），旁支不受牵连', () async {
    final bridge = MockOrbitBridge();
    final t = await bridge.todoTaskCreate(TodoTaskCreateInput(title: '任务'));
    final a = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: t.id, title: '甲'));
    final b = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: t.id, title: '乙', parentUuid: a.uuid));
    final c = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: t.id, title: '丙', parentUuid: b.uuid));
    await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: t.id, title: '旁支'));

    await bridge.todoSubtaskDelete(a.id);

    // 默认列表过滤 is_deleted=0：整棵子树（甲/乙/丙）消失，只剩旁支
    // （列表是全表口径，种子任务的子任务不受影响，按 taskId 收窄）
    final live = await bridge.todoSubtaskList(const ListFilter(pageSize: 100));
    final taskLive = live.where((s) => s.taskId == t.id).toList();
    expect(taskLive.map((s) => s.title), ['旁支']);
    expect(taskLive.where((s) => s.id == a.id || s.id == b.id || s.id == c.id),
        isEmpty);
  });

  test('promote 子孙随迁：task_id 改挂新任务，直接子女提顶层，深层父链接保持',
      () async {
    final bridge = MockOrbitBridge();
    final parent = await bridge.todoTaskCreate(TodoTaskCreateInput(title: '父任务'));
    final a = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '甲'));
    final b = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '乙', parentUuid: a.uuid));
    await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '丙', parentUuid: b.uuid));

    final created = await bridge.todoSubtaskPromote(a.id);
    expect(created.title, '甲');

    // 新任务详情：乙提顶层、丙仍挂乙（parent_uuid 链接保持 uuid 不变）
    final detail = await bridge.todoTaskGetDetail(created.id);
    final newB = detail.subtasks.firstWhere((s) => s.title == '乙');
    final newC = detail.subtasks.firstWhere((s) => s.title == '丙');
    expect(newB.taskId, created.id);
    expect(newC.taskId, created.id);
    expect(newB.parentUuid, isNull, reason: '直接子女提顶层（源行已软删）');
    expect(newC.parentUuid, newB.uuid, reason: '深层父链接保持');

    // 父任务侧：甲整棵子树迁走，存活列表为空
    final parentLive =
        await bridge.todoSubtaskList(const ListFilter(pageSize: 100));
    expect(parentLive.where((s) => s.taskId == parent.id), isEmpty);
  });

  test('随迁后 subtask_tree 还原层级：三层链 b=0/c=1/d=2', () async {
    final bridge = MockOrbitBridge();
    final parent = await bridge.todoTaskCreate(TodoTaskCreateInput(title: '父任务'));
    final a = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '甲'));
    final b = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '乙', parentUuid: a.uuid));
    final c = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '丙', parentUuid: b.uuid));
    await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: parent.id, title: '丁', parentUuid: c.uuid));

    final created = await bridge.todoSubtaskPromote(a.id);
    final detail = await bridge.todoTaskGetDetail(created.id);
    expect(detail.subtasks, hasLength(3), reason: '甲/乙/丙/丁迁走乙丙丁三行');
    final nodes = flattenSubtaskTree(buildSubtaskTree(detail.subtasks), (_) => false);
    final byTitle = {for (final n in nodes) n.subtask.title: n};
    expect(byTitle['乙']!.depth, 0, reason: '直接子女提顶层');
    expect(byTitle['丙']!.depth, 1);
    expect(byTitle['丁']!.depth, 2, reason: '三层链整体随迁，深度连续');
  });

  test('percent 全树聚合：嵌套子孙的勾选照样进父任务进度', () async {
    final bridge = MockOrbitBridge();
    final t = await bridge.todoTaskCreate(TodoTaskCreateInput(title: '任务'));
    final a = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: t.id, title: '甲'));
    await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: t.id, title: '乙', parentUuid: a.uuid));

    await bridge.todoSubtaskToggleDone(a.id, true);
    final after = await bridge.todoTaskGet(t.id);
    expect(after.percentDone, 50.0, reason: '两层共 2 行，完成 1 行 = 50%（全树聚合）');
  });
}
