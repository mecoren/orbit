import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/triage.dart';

// F2 收件箱分诊纯逻辑——与桌面 shared/triage.test.ts 同口径的关键用例子集。
void main() {
  TodoTask task(int id,
      {double position = 0, int createdAt = 0, int? projectId, int done = 0}) {
    return TodoTask(
      id: id,
      uuid: 'u$id',
      title: 't$id',
      description: null,
      projectId: projectId,
      priority: 0,
      status: done == 1 ? 'done' : 'pending',
      done: done,
      doneAt: null,
      dueDate: null,
      startDate: null,
      repeatAfter: 0,
      repeatMode: 0,
      repeatWeekdays: 0,
      repeatEndType: 0,
      repeatEndParam: 0,
      repeatFromDone: 0,
      repeatMonthMode: 0,
      repeatNthWeek: 0,
      percentDone: 0,
      position: position,
      isFavorite: 0,
      myDayDate: null,
      durationMinutes: null,
      isDeleted: 0,
      createdAt: createdAt,
      updatedAt: 0,
      deletedAt: null,
      version: 1,
    );
  }

  group('collectTriageQueue', () {
    test('只收未分组的未完成任务', () {
      final queue = collectTriageQueue([
        task(1),
        task(2, projectId: 5),
        task(3, done: 1),
        task(4),
      ]);
      expect(queue.map((t) => t.id), [1, 4]);
    });

    test('排序对齐未分组列表 manual 档：position 升序 → createdAt 降序', () {
      final queue = collectTriageQueue([
        task(1, position: 3, createdAt: 100),
        task(2, position: 1, createdAt: 50),
        task(3, position: 1, createdAt: 90),
      ]);
      expect(queue.map((t) => t.id), [3, 2, 1]);
    });
  });

  group('formatTriageSummary', () {
    test('归属与排期合计「已分诊」；删除为 0 时省略', () {
      expect(formatTriageSummary(3, 2, 1, 0), '已分诊 5 · 跳过 1');
      expect(formatTriageSummary(3, 2, 1, 2), '已分诊 5 · 跳过 1 · 删除 2');
    });
  });

  group('TodoTask.copyWith（分诊快照的就地字段覆盖）', () {
    test('可空字段经 clear 旗标归 null（撤销移项目）', () {
      final assigned = task(1).copyWith(projectId: 3);
      expect(assigned.projectId, 3);
      final undone = assigned.copyWith(clearProjectId: true);
      expect(undone.projectId, isNull);
    });

    test('清日期与优先级覆盖互不串扰', () {
      final base = task(1).copyWith(dueDate: 1700000000000, priority: 3);
      final cleared = base.copyWith(clearDueDate: true);
      expect(cleared.dueDate, isNull);
      expect(cleared.priority, 3);
    });
  });
}
