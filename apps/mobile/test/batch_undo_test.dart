// 批量动作补丁 + 撤销栈（纯函数/纯数据结构，无 IO）。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/batch_actions.dart';
import 'package:orbit/modules/todo/logic/undo_stack.dart';

TodoTask _task({
  required int id,
  String status = 'pending',
  int priority = 0,
  int? projectId,
  int? dueDate,
  int done = 0,
}) =>
    TodoTask(
      id: id,
      uuid: 'u$id',
      title: 't$id',
      description: null,
      projectId: projectId,
      priority: priority,
      status: status,
      done: done,
      doneAt: done == 1 ? 111 : null,
      dueDate: dueDate,
      startDate: null,
      repeatAfter: 1,
      repeatMode: 0,
      repeatWeekdays: 0,
      repeatEndType: 0,
      repeatEndParam: 0,
      repeatFromDone: 0,
      percentDone: 0,
      position: id.toDouble(),
      isFavorite: 0,
      myDayDate: null,
      isDeleted: 0,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: null,
      version: 1,
    );

void main() {
  group('UndoStack', () {
    test('空条目不入栈（无反向动作的操作不占撤销位）', () {
      final s = UndoStack();
      s.push(const UndoEntry(label: '无动作', createdAt: 0));
      expect(s.isEmpty, isTrue);
      expect(s.pop(), isNull);
    });

    test('push/pop 为 LIFO', () {
      final s = UndoStack();
      s.push(const UndoEntry(label: 'a', restoreTaskIds: [1], createdAt: 1));
      s.push(const UndoEntry(label: 'b', restoreTaskIds: [2], createdAt: 2));
      expect(s.last?.label, 'b');
      expect(s.pop()?.label, 'b');
      expect(s.pop()?.label, 'a');
      expect(s.isEmpty, isTrue);
    });

    test('超出上界 FIFO 淘汰最旧条目', () {
      final s = UndoStack();
      for (var i = 0; i < UndoStack.maxDepth + 5; i++) {
        s.push(UndoEntry(label: '$i', restoreTaskIds: [i], createdAt: i));
      }
      expect(s.length, UndoStack.maxDepth);
      // 最早的 5 条被淘汰，栈底为第 5 条
      var popped = 0;
      UndoEntry? entry;
      while ((entry = s.pop()) != null) {
        popped++;
        if (s.isEmpty) break;
      }
      expect(popped, UndoStack.maxDepth);
      expect(entry?.label, '5');
    });
  });

  group('批量完成态', () {
    test('选中集含未完成 → 目标为完成', () {
      expect(batchToggleDoneTarget([_task(id: 1), _task(id: 2, done: 1)]), isTrue);
      expect(
        batchToggleDoneTarget([_task(id: 1, done: 1, status: 'done')]),
        isFalse,
      );
    });

    test('补丁含 done_at / status 联动；值已相同返回 null', () {
      final t = _task(id: 1);
      final patch = batchDonePatch(t, done: true)!;
      expect(patch['done'], 1);
      expect(patch['status'], 'done');
      expect(patch['done_at'], isNotNull);

      expect(batchDonePatch(t, done: false), isNull);
    });
  });

  group('批量字段补丁', () {
    test('优先级：同值跳过，异值出补丁', () {
      final t = _task(id: 1, priority: 3);
      expect(
        batchFieldPatch(t, action: BatchAction.priority, priority: 3),
        isNull,
      );
      expect(
        batchFieldPatch(t, action: BatchAction.priority, priority: 5),
        {'priority': 5},
      );
    });

    test('改期：清除截止出 null 值；同日出补丁视为无需变更', () {
      final now = DateTime(2026, 9, 19, 9);
      final sameDay = batchRescheduleMs(BatchReschedule.today, now);
      final t = _task(id: 1, dueDate: sameDay);
      expect(
        batchFieldPatch(t, action: BatchAction.reschedule, dueMs: sameDay),
        isNull,
      );
      expect(
        batchFieldPatch(t, action: BatchAction.reschedule, dueMs: 0),
        {'due_date': null},
      );
    });

    test('移动项目：未分组 → null 与已有值区分', () {
      final t = _task(id: 1, projectId: 7);
      expect(
        batchFieldPatch(t, action: BatchAction.moveProject, projectId: 7),
        isNull,
      );
      expect(
        batchFieldPatch(t, action: BatchAction.moveProject, projectId: null),
        {'project_id': null},
      );
    });
  });

  group('反向补丁', () {
    test('按原快照回滚字段', () {
      final t = _task(id: 9, priority: 2, projectId: 4, status: 'doing');
      final inverse = inversePatchOf(t, {'priority': 5, 'project_id': null});
      expect(inverse.taskId, 9);
      expect(inverse.patch, {'priority': 2, 'project_id': 4});
    });

    test('完成态回滚还原 done/done_at/status（调用方须传全量完成补丁）', () {
      final t = _task(id: 9, status: 'doing', done: 1);
      final donePatch = batchDonePatch(_task(id: 9), done: true)!;
      final inverse = inversePatchOf(t, donePatch);
      // 三键齐回滚：只倒 done 会留下「未完成但 status=done」的不一致行
      expect(inverse.patch.keys.toSet(), {'done', 'done_at', 'status'});
      expect(inverse.patch['done'], 1);
      expect(inverse.patch['done_at'], 111);
      expect(inverse.patch['status'], 'doing');
    });
  });

  group('改期档位', () {
    final now = DateTime(2026, 9, 19, 9); // 周六

    test('今天 / 明天 / 下周 落在当日 18:00（本地时区）', () {
      int hourOf(int ms) => DateTime.fromMillisecondsSinceEpoch(ms).hour;
      int dayOf(int ms) => DateTime.fromMillisecondsSinceEpoch(ms).day;

      final today = batchRescheduleMs(BatchReschedule.today, now);
      expect(dayOf(today), 19);
      expect(hourOf(today), 18);

      final tomorrow = batchRescheduleMs(BatchReschedule.tomorrow, now);
      expect(dayOf(tomorrow), 20);

      // 周六 → 下周一（周一起始周）
      final nextWeek = batchRescheduleMs(BatchReschedule.nextWeek, now);
      expect(dayOf(nextWeek), 21);
    });

    test('清除返回 0（调用方转 null）', () {
      expect(batchRescheduleMs(BatchReschedule.clear, now), 0);
    });
  });

  group('浮层文案', () {
    test('按动作与条数生成', () {
      expect(batchUndoLabel(BatchAction.delete, 3), '已删除 3 个任务');
      expect(batchUndoLabel(BatchAction.addLabel, 1), '已为 1 个任务加标签');
    });
  });
}
