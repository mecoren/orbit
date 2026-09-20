// 提醒「推迟」落库回归（2026-09-20 修复）：
// 引擎到期处置（advance_fired_reminder）会把非重复任务的提醒行软删，移动端
// 推迟通道若只排系统闹钟不写 DB，就会出现「提醒被删 + 重排 cancelAll 把推迟
// 闹钟一并清掉」→ 用户表现为点推迟后提醒直接消失。本文件锁定两条落地路径：
// 前台 landSnoozeInDb（删旧建新）与启动 planSnoozeLanding（后台补齐计划）。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/services/reminder_snooze.dart';

TodoReminder _row(int id, int taskId, int remindAt, {int isDeleted = 0}) =>
    TodoReminder(
      id: id,
      uuid: 'uuid-$id',
      taskId: taskId,
      remindAt: remindAt,
      isDeleted: isDeleted,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: null,
      version: 1,
    );

void main() {
  group('planSnoozeLanding（后台推迟的启动补齐计划）', () {
    test('闹钟晚于最新旧行 → 删旧行 + 建新时刻行', () {
      final plan = planSnoozeLanding(
        pending: const [PendingAlarm(taskId: 1, remindAt: 2000)],
        reminders: [_row(10, 1, 1000)],
      );
      expect(plan.deleteIds, [10]);
      expect(plan.creates, [(taskId: 1, remindAt: 2000)]);
      expect(plan.isEmpty, isFalse);
      expect(plan.count, 2);
    });

    test('多行只推进最新那条旧行', () {
      final plan = planSnoozeLanding(
        pending: const [PendingAlarm(taskId: 1, remindAt: 3000)],
        reminders: [_row(10, 1, 1000), _row(11, 1, 2000)],
      );
      expect(plan.deleteIds, [11]);
      expect(plan.creates, [(taskId: 1, remindAt: 3000)]);
    });

    test('已有同刻行 → 已落地，空计划', () {
      final plan = planSnoozeLanding(
        pending: const [PendingAlarm(taskId: 1, remindAt: 2000)],
        reminders: [_row(10, 1, 2000)],
      );
      expect(plan.isEmpty, isTrue);
    });

    test('该任务无提醒行 → 用户删过，不复活', () {
      final plan = planSnoozeLanding(
        pending: const [PendingAlarm(taskId: 9, remindAt: 2000)],
        reminders: [_row(10, 1, 1000)],
      );
      expect(plan.isEmpty, isTrue);
    });

    test('行都比闹钟晚 → 异常态不动 DB（交给 cancelAll 收敛）', () {
      final plan = planSnoozeLanding(
        pending: const [PendingAlarm(taskId: 1, remindAt: 500)],
        reminders: [_row(10, 1, 1000)],
      );
      expect(plan.isEmpty, isTrue);
    });

    test('已软删行不参与判定', () {
      final plan = planSnoozeLanding(
        pending: const [PendingAlarm(taskId: 1, remindAt: 2000)],
        reminders: [_row(10, 1, 1000, isDeleted: 1), _row(11, 1, 1500)],
      );
      expect(plan.deleteIds, [11]);
    });

    test('同任务多个闹钟只落地一次', () {
      final plan = planSnoozeLanding(
        pending: const [
          PendingAlarm(taskId: 1, remindAt: 2000),
          PendingAlarm(taskId: 1, remindAt: 3000),
        ],
        reminders: [_row(10, 1, 1000)],
      );
      expect(plan.deleteIds, hasLength(1));
      expect(plan.creates, hasLength(1));
    });

    test('孤儿闹钟 + 任务存活 + 未来时刻 → 补建（后台推迟最常见形态）', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final plan = planSnoozeLanding(
        pending: [PendingAlarm(taskId: 1, remindAt: nowMs + 600000)],
        reminders: const <TodoReminder>[],
        activeTaskIds: {1},
        nowMs: nowMs,
      );
      expect(plan.deleteIds, isEmpty);
      expect(plan.creates, [(taskId: 1, remindAt: nowMs + 600000)]);
    });

    test('孤儿闹钟但未启用 activeTaskIds（日常重排）→ 保守不补建', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final plan = planSnoozeLanding(
        pending: [PendingAlarm(taskId: 1, remindAt: nowMs + 600000)],
        reminders: const <TodoReminder>[],
        nowMs: nowMs,
      );
      expect(plan.isEmpty, isTrue);
    });

    test('孤儿闹钟但任务已删/已完成 → 不复活', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final plan = planSnoozeLanding(
        pending: [PendingAlarm(taskId: 1, remindAt: nowMs + 600000)],
        reminders: const <TodoReminder>[],
        activeTaskIds: {2},
        nowMs: nowMs,
      );
      expect(plan.isEmpty, isTrue);
    });

    test('孤儿闹钟时刻已过期或超出 24h 窗口 → 不补建', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final expired = planSnoozeLanding(
        pending: [PendingAlarm(taskId: 1, remindAt: nowMs - 1000)],
        reminders: const <TodoReminder>[],
        activeTaskIds: {1},
        nowMs: nowMs,
      );
      expect(expired.isEmpty, isTrue);

      final tooFar = planSnoozeLanding(
        pending: [PendingAlarm(taskId: 1, remindAt: nowMs + 48 * 3600 * 1000)],
        reminders: const <TodoReminder>[],
        activeTaskIds: {1},
        nowMs: nowMs,
      );
      expect(tooFar.isEmpty, isTrue);
    });
  });

  group('landSnoozeInDb（前台推迟落库）', () {
    test('软删旧时刻行并按新时刻建行', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge
          .todoTaskCreate(const TodoTaskCreateInput(title: '推迟落地'));
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final from = nowMs - 600000; // 到期那一刻
      final next = nowMs + 600000; // 推迟 10 分钟后
      final old = await bridge.todoReminderCreate(
        TodoReminderCreateInput(taskId: task.id, remindAt: from),
      );

      await landSnoozeInDb(bridge,
          taskId: task.id, fromRemindAt: from, nextAt: next);

      final rows = await bridge.todoReminderList(const ListFilter(pageSize: 100));
      final mine = rows.where((r) => r.taskId == task.id).toList();
      expect(mine, hasLength(1), reason: '旧行删掉、只剩推迟后的新行');
      expect(mine.single.remindAt, next);
      expect(bridge.store.reminders.containsKey(old.id), isFalse);
    });

    test('同刻行已存在 → 幂等不重复建', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge
          .todoTaskCreate(const TodoTaskCreateInput(title: '重复推迟'));
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final from = nowMs - 600000;
      final next = nowMs + 600000;
      await bridge.todoReminderCreate(
        TodoReminderCreateInput(taskId: task.id, remindAt: next),
      );

      await landSnoozeInDb(bridge,
          taskId: task.id, fromRemindAt: from, nextAt: next);
      await landSnoozeInDb(bridge,
          taskId: task.id, fromRemindAt: from, nextAt: next);

      final rows = await bridge.todoReminderList(const ListFilter(pageSize: 100));
      expect(rows.where((r) => r.taskId == task.id), hasLength(1));
    });

    test('不误删其他时刻的行（重复续排/手排提醒）', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge
          .todoTaskCreate(const TodoTaskCreateInput(title: '多提醒'));
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final from = nowMs - 600000;
      final next = nowMs + 600000;
      final other = nowMs + 3600000;
      await bridge.todoReminderCreate(
        TodoReminderCreateInput(taskId: task.id, remindAt: from),
      );
      await bridge.todoReminderCreate(
        TodoReminderCreateInput(taskId: task.id, remindAt: other),
      );

      await landSnoozeInDb(bridge,
          taskId: task.id, fromRemindAt: from, nextAt: next);

      final rows = await bridge.todoReminderList(const ListFilter(pageSize: 100));
      final times = rows
          .where((r) => r.taskId == task.id)
          .map((r) => r.remindAt)
          .toList()
        ..sort();
      expect(times, [next, other]);
    });

    test('推迟时刻已成过去 → 丢弃不补建（避免立刻再弹一次）', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge
          .todoTaskCreate(const TodoTaskCreateInput(title: '过期意图'));

      await landSnoozeInDb(bridge,
          taskId: task.id, fromRemindAt: 1, nextAt: 1);

      final rows = await bridge.todoReminderList(const ListFilter(pageSize: 100));
      expect(rows.where((r) => r.taskId == task.id), isEmpty);
    });

    test('原时刻行已不存在（引擎已清理）→ 只建新行', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge
          .todoTaskCreate(const TodoTaskCreateInput(title: '引擎已清理'));
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final next = nowMs + 600000;

      await landSnoozeInDb(bridge,
          taskId: task.id, fromRemindAt: nowMs - 600000, nextAt: next);

      final rows = await bridge.todoReminderList(const ListFilter(pageSize: 100));
      final mine = rows.where((r) => r.taskId == task.id).toList();
      expect(mine, hasLength(1));
      expect(mine.single.remindAt, next);
    });
  });

  group('SnoozeSpool（后台 isolate 的推迟暂存文件）', () {
    Future<void> clean() async {
      if (await SnoozeSpool.file.exists()) await SnoozeSpool.file.delete();
    }

    setUp(clean);
    tearDown(clean);

    test('append → drain 往返并清空文件', () async {
      await SnoozeSpool.append(taskId: 7, fromRemindAt: 1000, nextAt: 2000);
      await SnoozeSpool.append(taskId: 8, fromRemindAt: 3000, nextAt: 4000);

      final intents = await SnoozeSpool.drain();
      expect(intents, hasLength(2));
      expect(intents.first.taskId, 7);
      expect(intents.first.fromRemindAt, 1000);
      expect(intents.first.nextAt, 2000);
      expect(intents.last.taskId, 8);
      // drain 即清空：再取为空，不会重复落地
      expect(await SnoozeSpool.file.exists(), isFalse);
      expect(await SnoozeSpool.drain(), isEmpty);
    });

    test('脏行忽略，不影响同文件其他记录', () async {
      await SnoozeSpool.file.writeAsString(
        'not-a-json\n{"task_id":5,"from":1,"next":2}\n',
      );
      final intents = await SnoozeSpool.drain();
      expect(intents, hasLength(1));
      expect(intents.single.taskId, 5);
    });
  });

  group('applySnoozeLanding（启动补齐执行）', () {
    test('按计划删旧建新', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge
          .todoTaskCreate(const TodoTaskCreateInput(title: '补齐执行'));
      final old = await bridge.todoReminderCreate(
        TodoReminderCreateInput(taskId: task.id, remindAt: 1000),
      );

      final changed = await applySnoozeLanding(
        bridge,
        SnoozeLanding(
          deleteIds: [old.id],
          creates: [(taskId: task.id, remindAt: 2000)],
        ),
      );

      expect(changed, isTrue);
      final rows = await bridge.todoReminderList(const ListFilter(pageSize: 100));
      final mine = rows.where((r) => r.taskId == task.id).toList();
      expect(mine, hasLength(1));
      expect(mine.single.remindAt, 2000);
    });

    test('空计划不写库', () async {
      final bridge = MockOrbitBridge();
      final changed = await applySnoozeLanding(
        bridge,
        const SnoozeLanding(deleteIds: [], creates: []),
      );
      expect(changed, isFalse);
    });
  });
}
