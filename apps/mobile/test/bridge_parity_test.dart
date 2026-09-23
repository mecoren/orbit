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
    // A2 口径：uuid 是列表通道的裁剪列（空串占位），真实 uuid 需走单条全列通道
    final listed = (await bridge.todoTaskList(const ListFilter())).first;
    expect(listed.uuid, isEmpty, reason: '列表通道 uuid 应被裁掉');
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
