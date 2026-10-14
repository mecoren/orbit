import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';

// FRB 桥补齐 10 函数的三处同口径回归（Mock 侧可测部分）：
// todo_labels_get / task_labels_get / recalc / get_by_uuid x2 /
// business_count / cloud_sync_force / ping-sha-random。
void main() {
  late MockOrbitBridge bridge;
  setUp(() => bridge = MockOrbitBridge());

  test('todoLabelGet 取回创建的标签', () async {
    final created = await bridge.todoLabelCreate(
      const TodoLabelCreateInput(title: ' parity-label '),
    );
    final got = await bridge.todoLabelGet(created.id);
    expect(got.title, created.title);
  });

  test('todoTaskLabelGet 取回关联补全', () async {
    final label = await bridge.todoLabelCreate(
      const TodoLabelCreateInput(title: 'g'),
    );
    final tasks = await bridge.todoTaskList(const ListFilter());
    expect(tasks, isNotEmpty);
    final link = await bridge.todoTaskLabelCreate(
      TodoTaskLabelCreateInput(taskId: tasks.first.id, labelId: label.id),
    );
    final got = await bridge.todoTaskLabelGet(link.taskLabelId);
    expect(got.title, label.title);
    expect(got.taskLabelId, link.taskLabelId);
  });

  test('todoTaskRecalcPercent 重算不抛', () async {
    final tasks = await bridge.todoTaskList(const ListFilter());
    await bridge.todoTaskRecalcPercent(tasks.first.id);
  });

  test('get_by_uuid 往返 + business_count 计数', () async {
    // A2 瘦行：uuid 属列表通道裁剪列（列表行回落空串），真实 uuid 走单条全列通道
    final listed = (await bridge.todoTaskList(const ListFilter())).first;
    expect(listed.uuid, isEmpty, reason: '列表通道不含 uuid（回落空串）');
    final task = await bridge.todoTaskGet(listed.id);
    final byUuid = await bridge.todoTaskGetByUuid(task.uuid);
    expect(byUuid?.id, task.id);
    final projects = await bridge.todoProjectList(const ListFilter());
    final pByUuid = await bridge.todoProjectGetByUuid(projects.first.uuid);
    expect(pByUuid?.id, projects.first.id);
    expect(await bridge.todoTaskGetByUuid('no-such-uuid'), isNull);
    final n = await bridge.businessCount('todo_tasks');
    expect(n, greaterThan(0));
  });

  test('列表通道瘦行契约：被裁 10 列回落默认值，真值只走单条全列通道（A2）', () async {
    final created = await bridge.todoTaskCreate(TodoTaskCreateInput(
      title: '瘦行契约任务',
      repeatMode: 2,
      repeatAfter: 3,
      repeatWeekdays: 21,
      repeatEndType: 2,
      repeatEndParam: 5,
      repeatFromDone: 1,
      repeatMonthMode: 1,
      repeatNthWeek: 2,
    ));
    final row = (await bridge.todoTaskList(const ListFilter()))
        .firstWhere((t) => t.id == created.id);
    // 被裁列回落默认值（mock 与真桥同口径：mock 摘键、真桥取 gen.TodoTaskListItem）
    expect(row.uuid, isEmpty);
    expect(row.repeatAfter, 0);
    expect(row.repeatWeekdays, 0);
    expect(row.repeatEndType, 0);
    expect(row.repeatEndParam, 0);
    expect(row.repeatFromDone, 0);
    expect(row.repeatMonthMode, 0);
    expect(row.repeatNthWeek, 0);
    expect(row.deletedAt, isNull);
    expect(row.version, 0);
    // 有消费列照常过桥（移动列表/日历的重复徽标读 repeatMode；时间轴读 startDate）
    expect(row.repeatMode, 2);
    expect(row.title, '瘦行契约任务');
    // 单条全列通道是这些列的真值来源
    final full = await bridge.todoTaskGet(created.id);
    expect(full.uuid, isNotEmpty);
    expect(full.repeatAfter, 3);
    expect(full.repeatWeekdays, 21);
    expect(full.repeatEndType, 2);
    expect(full.repeatEndParam, 5);
    expect(full.repeatFromDone, 1);
    expect(full.repeatMonthMode, 1);
    expect(full.repeatNthWeek, 2);
    expect(full.version, 1);
  });

  test('cloudSyncForce 返回结果 + 工具三件套', () async {
    final r = await bridge.cloudSyncForce(origin: 'background');
    expect(r.skipped, isFalse);
    expect(await bridge.ping(), contains('pong'));
    final sha = await bridge.cryptoSha256('abc');
    expect(sha.length, 64);
    final rnd = await bridge.cryptoRandomHex(16);
    expect(rnd.length, 32);
  });
}
