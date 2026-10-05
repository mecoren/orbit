// 列表内过滤 + 看板分列 + 视图档位持久化（纯函数/纯偏好，无 IO）。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/logic/view_mode.dart';
import 'package:orbit/services/local_prefs.dart';

TodoTask _task({
  required int id,
  String status = 'pending',
  int priority = 0,
  int? projectId,
  int? dueDate,
  String title = 't',
}) =>
    TodoTask(
      id: id,
      uuid: 'u$id',
      title: title,
      description: null,
      projectId: projectId,
      priority: priority,
      status: status,
      done: status == 'done' ? 1 : 0,
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
      position: id.toDouble(),
      isFavorite: 0,
      myDayDate: null,
      durationMinutes: null,
      isDeleted: 0,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: null,
      version: 1,
    );

TodoProject _project(int id, String title) => TodoProject(
      id: id,
      uuid: 'p$id',
      title: title,
      description: null,
      hexColor: '#4E8CFF',
      sortOrder: id.toDouble(),
      // M8：顶层项目（本文件不测层级，统一 null）
      parentUuid: null,
      isArchived: 0,
      isDeleted: 0,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: null,
      version: 1,
    );

void main() {
  group('TaskListFilters', () {
    test('copyWith 未传参保持原值，显式 null 清除该档', () {
      const f = TaskListFilters(status: 'doing', priorityMin: 3, labelId: 7);

      final kept = f.copyWith(labelId: 9);
      expect(kept.status, 'doing');
      expect(kept.priorityMin, 3);
      expect(kept.labelId, 9);

      final cleared = f.copyWith(status: null);
      expect(cleared.status, isNull);
      expect(cleared.priorityMin, 3);
      expect(cleared.activeCount, 2);
    });

    test('isEmpty / activeCount', () {
      expect(TaskListFilters.empty.isEmpty, isTrue);
      expect(TaskListFilters.empty.activeCount, 0);
      expect(const TaskListFilters(status: 'done').activeCount, 1);
    });
  });

  group('applyTaskListFilters', () {
    final tasks = [
      _task(id: 1, status: 'pending', priority: 1),
      _task(id: 2, status: 'doing', priority: 3),
      _task(id: 3, status: 'done', priority: 5),
    ];

    test('空档位原样返回', () {
      expect(applyTaskListFilters(tasks, TaskListFilters.empty), tasks);
    });

    test('状态档', () {
      final r = applyTaskListFilters(
          tasks, const TaskListFilters(status: 'doing'));
      expect(r.map((t) => t.id), [2]);
    });

    test('优先级下限档（含等于）', () {
      final r = applyTaskListFilters(
          tasks, const TaskListFilters(priorityMin: 3));
      expect(r.map((t) => t.id), [2, 3]);
    });

    test('标签档：依赖投影索引，投影缺失时结果为空', () {
      final tasksWithLabel = [_task(id: 1), _task(id: 2)];
      final index = indexLabelIdsByTask(const [
        TaskLabelsProjection(taskId: 1, labels: [
          ProjectedTaskLabel(id: 7, title: '紧急', hexColor: '#F44336'),
        ]),
      ]);
      expect(
        applyTaskListFilters(tasksWithLabel,
            const TaskListFilters(labelId: 7), labelIdsByTask: index)
            .map((t) => t.id),
        [1],
      );
      expect(
        applyTaskListFilters(tasksWithLabel,
            const TaskListFilters(labelId: 7)).isEmpty,
        isTrue,
      );
    });

    test('多档叠加为交集', () {
      final r = applyTaskListFilters(
        tasks,
        const TaskListFilters(status: 'doing', priorityMin: 1),
      );
      expect(r.map((t) => t.id), [2]);
    });
  });

  group('groupTasksForKanban', () {
    test('按状态：固定 pending → doing → done 三列（含空列）', () {
      final cols = groupTasksForKanban(
        [_task(id: 1, status: 'doing')],
        KanbanGroupBy.status,
        const [],
      );
      expect(cols.map((c) => c.key), ['pending', 'doing', 'done']);
      expect(cols[0].tasks, isEmpty);
      expect(cols[1].tasks.single.id, 1);
    });

    test('按项目：仅有任务的项目 + 未分组列', () {
      final cols = groupTasksForKanban(
        [
          _task(id: 1, projectId: 10),
          _task(id: 2, projectId: 10),
          _task(id: 3),
        ],
        KanbanGroupBy.project,
        [_project(10, '工作'), _project(20, '空项目')],
      );
      expect(cols.map((c) => c.key), ['p10', 'none']);
      expect(cols.first.title, '工作');
      expect(cols.first.tasks, hasLength(2));
      expect(cols.last.title, '未分组');
    });

    test('按项目：无未分组任务时不出现未分组列', () {
      final cols = groupTasksForKanban(
        [_task(id: 1, projectId: 10)],
        KanbanGroupBy.project,
        [_project(10, '工作')],
      );
      expect(cols.map((c) => c.key), ['p10']);
    });

    test('按优先级：固定 P5 → P0 六列（含空列）', () {
      final cols = groupTasksForKanban(
        [_task(id: 1, priority: 4), _task(id: 2)],
        KanbanGroupBy.priority,
        const [],
      );
      expect(
        cols.map((c) => c.key),
        ['pri:5', 'pri:4', 'pri:3', 'pri:2', 'pri:1', 'pri:0'],
      );
      expect(cols[1].tasks.single.id, 1);
      expect(cols[1].title, '紧急');
      expect(cols.last.tasks.single.id, 2);
      expect(cols.last.title, '无');
    });

    test('按标签：有任务标签各一列 + 未贴标签（多标签取最小 id 单归属）', () {
      ProjectedTaskLabel l(int id, String title) =>
          ProjectedTaskLabel(id: id, title: title, hexColor: '#3B82F6');
      final cols = groupTasksForKanban(
        [_task(id: 1), _task(id: 2), _task(id: 3)],
        KanbanGroupBy.label,
        const [],
        labelsByTask: {
          1: [l(9, '乙'), l(3, '甲')],
          2: [l(9, '乙')],
        },
      );
      expect(cols.map((c) => c.key), ['lbl:9', 'lbl:3', 'lbl:none']);
      expect(cols[0].tasks.single.id, 2);
      // 任务 1 主标签 = 最小 id 3，只出现在甲列
      expect(cols[1].tasks.single.id, 1);
      expect(cols[2].tasks.single.id, 3);
    });

    test('按截止日期：逾期 / 今天 / 本周 / 以后 / 无日期五桶', () {
      final now = DateTime(2026, 10, 5, 12); // 周一
      final t0 = DateTime(2026, 10, 5).millisecondsSinceEpoch;
      const day = 86400000;
      final cols = groupTasksForKanban(
        [
          _task(id: 1, dueDate: t0 - day),
          _task(id: 2, dueDate: t0 + 3600000),
          _task(id: 3, dueDate: t0 + 3 * day),
          _task(id: 4, dueDate: t0 + 30 * day),
          _task(id: 5),
        ],
        KanbanGroupBy.due,
        const [],
        now: now,
      );
      expect(
        cols.map((c) => c.key),
        ['due:overdue', 'due:today', 'due:week', 'due:later', 'due:none'],
      );
      expect(cols.map((c) => c.tasks.single.id), [1, 2, 3, 4, 5]);
    });
  });

  group('视图档位持久化', () {
    test('LocalPrefs 未载入时回落默认档', () {
      expect(loadViewMode(), TaskViewMode.list);
      expect(loadKanbanGroupBy(), KanbanGroupBy.project);
    });

    test('getEnum 忽略脏值与未知值', () {
      expect(
        LocalPrefs.getEnum('nope', TaskViewMode.values,
            fallback: TaskViewMode.table),
        TaskViewMode.table,
      );
    });

    test('预置值可被读取（含大小写/dirty 回落）', () async {
      await LocalPrefs.setString(viewModePrefsKey, 'kanban');
      expect(loadViewMode(), TaskViewMode.kanban);
      await LocalPrefs.setString(kanbanGroupByPrefsKey, 'status');
      expect(loadKanbanGroupBy(), KanbanGroupBy.status);

      await LocalPrefs.setString(viewModePrefsKey, 'dirty-value');
      expect(loadViewMode(), TaskViewMode.list);

      // 收尾：清空键，避免影响同进程内后续用例
      await LocalPrefs.setString(viewModePrefsKey, '');
      await LocalPrefs.setString(kanbanGroupByPrefsKey, '');
    });
  });
}
