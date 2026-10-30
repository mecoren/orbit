// 移动端窗口化下推口径单测（P1，docs/07 #105）：
// 视图态 → ListFilter 的映射一旦与 filterTasks 分叉，列表会「少几条」或
// 「多几条」而没有任何报错——这里把每一档的 SQL 谓词逐字段钉住。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/paged_query.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/logic/view_mode.dart';

/// 固定基准：2026-10-26 12:00 本地（今日界 = 当天零点 / 明日零点）
final int _now = DateTime(2026, 10, 26, 12).millisecondsSinceEpoch;
final int _dayStart = DateTime(2026, 10, 26).millisecondsSinceEpoch;
final int _dayEnd = _dayStart + 86400000;

/// 最小列表行（fromListJson 要求全部列表列存在，缺一会 cast null 崩）
TodoTask _task(int id) => TodoTask.fromListJson(<String, dynamic>{
  'id': id,
  'title': 't$id',
  'description': null,
  'project_id': null,
  'priority': 0,
  'status': 'pending',
  'done': 0,
  'done_at': null,
  'due_date': null,
  'start_date': null,
  'repeat_mode': 0,
  'percent_done': 0,
  'position': 0,
  'is_favorite': 0,
  'my_day_date': null,
  'duration_minutes': null,
  'is_deleted': 0,
  'created_at': 1,
  'updated_at': 1,
});

PagedTaskQuery? _build({
  TaskFilterInput input = const TaskFilterInput(),
  TaskListFilters filters = const TaskListFilters(),
  TaskSortKey sortKey = TaskSortKey.manual,
  TaskSortDir? sortDir,
  String? savedConditions,
}) => buildPagedQuery(
  input: input,
  filters: filters,
  sortKey: sortKey,
  sortDir: sortDir,
  savedConditions: savedConditions,
  nowMs: _now,
);

void main() {
  group('buildPagedQuery：回退全量的组合', () {
    test('标题排序依赖拼音序 → null', () {
      expect(_build(sortKey: TaskSortKey.title), isNull);
    });
  });

  group('保存筛选器 / 标签筛选下推（2026-10-26 起不再回退全量）', () {
    test('标签筛选走 label_ids 谓词', () {
      final q = _build(filters: const TaskListFilters(labelId: 3))!;
      expect(q.filter.labelIds, [3]);
    });

    test('筛选器条件合并进主窗口谓词', () {
      final q = _build(
        savedConditions: '{"label_ids":[3],"has_reminder":true}',
      )!;
      expect(q.filter.labelIds, [3]);
      expect(q.filter.hasReminder, isTrue);
    });

    test('priority_min 条件必须下推（不能被丢弃，与桌面 #107 同口径）', () {
      final q = _build(savedConditions: '{"priority_min":3}')!;
      expect(q.filter.priorityMin, 3);
    });

    test('标签交集为空 → 空结果（core 里空 label_ids 是「不过滤」）', () {
      final q = _build(
        filters: const TaskListFilters(labelId: 1),
        savedConditions: '{"label_ids":[2]}',
      )!;
      // 恒假集合是唯一表达：空 label_ids 会被 core 当成「没限制」
      expect(q.filter.projectIds, isEmpty);
      expect(q.filter.labelIds, isNull);
    });

    test('done_from 与主窗口 done=false 冲突 → 空结果', () {
      final q = _build(savedConditions: '{"done_from":1234}')!;
      expect(q.filter.projectIds, isEmpty);
    });

    test('条件里空项目集合（脏数据）→ 空结果，与本地过滤同义', () {
      final q = _build(savedConditions: '{"project_ids":[]}')!;
      expect(q.filter.projectIds, isEmpty);
    });

    test('due_overdue 落成 done=false 与截止上界=今日零点', () {
      final q = _build(savedConditions: '{"due_overdue":true}')!;
      expect(q.filter.done, isFalse);
      expect(q.filter.dueTo, _dayStart);
    });
  });

  group('buildPagedQuery：快捷视图 → ListFilter', () {
    test('全部/未完成：主窗口只装未完成行（完成行由完成卡承载）', () {
      final all = _build(
        input: const TaskFilterInput(quickView: QuickViewKey.all),
      )!;
      expect(all.filter.done, isFalse);
      expect(all.sortKey, 'manual');
      expect(all.sortDir, 'asc');

      final undone = _build(
        input: const TaskFilterInput(quickView: QuickViewKey.undone),
      )!;
      expect(undone.filter.done, isFalse);
    });

    test('已完成（Logbook）：done=true，排序保持调用方档位', () {
      final q = _build(
        input: const TaskFilterInput(quickView: QuickViewKey.done),
        sortKey: TaskSortKey.created,
      )!;
      expect(q.filter.done, isTrue);
      expect(q.filter.sortKey, 'created');
      expect(q.filter.sortDir, 'desc'); // BASE_SORT_DIR：created 默认降序
    });

    test('今天：due_to = 明日零点（无下界，含逾期）', () {
      final q = _build(
        input: const TaskFilterInput(quickView: QuickViewKey.today),
      )!;
      expect(q.filter.dueTo, _dayEnd);
      expect(q.filter.dueFrom, isNull);
      expect(q.filter.done, isFalse);
    });

    test('近7天：due_to = 明日零点 + 6 天', () {
      final q = _build(
        input: const TaskFilterInput(quickView: QuickViewKey.week),
      )!;
      expect(q.filter.dueTo, _dayEnd + 6 * 86400000);
    });

    test('我的一天：my_day_today = 本地零点', () {
      final q = _build(
        input: const TaskFilterInput(quickView: QuickViewKey.myDay),
      )!;
      expect(q.filter.myDayToday, _dayStart);
    });

    test('无日期：has_due = false（不受 done 谓词影响）', () {
      final q = _build(
        input: const TaskFilterInput(quickView: QuickViewKey.nodate),
      )!;
      expect(q.filter.hasDue, isFalse);
    });

    test('收藏：favorite_only=true', () {
      final q = _build(
        input: const TaskFilterInput(quickView: QuickViewKey.favorite),
      )!;
      expect(q.filter.favoriteOnly, isTrue);
    });
  });

  group('buildPagedQuery：目标分支优先级与工具栏', () {
    test('ungrouped 优先于项目与快捷视图（与 filterTasks 同序）', () {
      final q = _build(
        input: const TaskFilterInput(
          quickView: QuickViewKey.today,
          projectId: 9,
          ungrouped: true,
        ),
      )!;
      expect(q.filter.ungrouped, isTrue);
      expect(q.filter.projectId, isNull);
      expect(q.filter.dueTo, isNull);
    });

    test('项目集合非空 → project_ids；空集合回落下一档', () {
      final withIds = _build(input: const TaskFilterInput(projectIds: [3, 4]))!;
      expect(withIds.filter.projectIds, [3, 4]);
      expect(withIds.filter.projectId, isNull);

      final emptyIds = _build(
        input: const TaskFilterInput(projectIds: [], projectId: 7),
      )!;
      expect(emptyIds.filter.projectIds, isNull);
      expect(emptyIds.filter.projectId, 7);
    });

    test('状态档：undone/done 映射完成位，pending 等映射 status 等值', () {
      expect(
        _build(filters: const TaskListFilters(status: 'undone'))!.filter.done,
        isFalse,
      );
      expect(
        _build(filters: const TaskListFilters(status: 'done'))!.filter.done,
        isTrue,
      );
      final doing = _build(filters: const TaskListFilters(status: 'doing'))!;
      expect(doing.filter.status, 'doing');
    });

    test('优先级档是等值（priority_eq），不是下限', () {
      final q = _build(filters: const TaskListFilters(priority: 2))!;
      expect(q.filter.priorityEq, 2);
      expect(q.filter.priorityMin, isNull);
    });

    test('开始时间档下推 sort_key=start（2026-10-29，与截止时间同构）', () {
      final q = _build(sortKey: TaskSortKey.start)!;
      expect(q.sortKey, 'start');
      expect(q.filter.sortKey, 'start');
      expect(q.sortDir, 'asc');
    });

    test('显式方向覆盖默认值', () {
      final q = _build(sortKey: TaskSortKey.due, sortDir: TaskSortDir.desc)!;
      expect(q.sortDir, 'desc');
      expect(q.filter.sortDir, 'desc');
    });
  });

  group('派生查询', () {
    final base = _build(
      input: const TaskFilterInput(quickView: QuickViewKey.today),
    )!;

    test('逾期段：强制未完成 + 截止上界收到 now + due 升序', () {
      final f = overdueFilterOf(base, _now);
      expect(f.done, isFalse);
      expect(f.dueTo, _now);
      expect(f.sortKey, 'due');
      expect(f.sortDir, 'asc');
    });

    test('完成卡：done=true + 完成时间倒序', () {
      final f = doneCardFilterOf(base);
      expect(f.done, isTrue);
      expect(f.sortKey, 'done_at');
      expect(f.sortDir, 'desc');
    });

    test('Logbook：done=true + 完成时间倒序', () {
      final f = logbookFilterOf(base);
      expect(f.done, isTrue);
      expect(f.sortKey, 'done_at');
      expect(f.sortDir, 'desc');
    });
  });

  group('mergeOverdueFirst', () {
    test('逾期行前置，主窗口同 id 行去重（否则渲染两份）', () {
      final merged = mergeOverdueFirst(
        [_task(1), _task(2)],
        [_task(3), _task(1), _task(4)],
      );
      expect(merged.map((t) => t.id).toList(), [1, 2, 3, 4]);
    });

    test('无逾期时原样返回（保持窗口顺序）', () {
      final window = [_task(3), _task(1)];
      expect(mergeOverdueFirst(const [], window), same(window));
    });
  });

  group('kanbanColumnsFromBoard：core 组键 → 移动端列键', () {
    test('项目档：{id}/ungrouped 映射为 p{id}/none，列头用组总数', () {
      final board = TodoTaskBoardResult(
        total: 4,
        groups: [
          TodoTaskBoardGroup(key: '7', total: 3, items: [_task(1)]),
          TodoTaskBoardGroup(key: 'ungrouped', total: 1, items: [_task(2)]),
        ],
      );
      final columns =
          kanbanColumnsFromBoard(board, KanbanGroupBy.project, const [
            TodoProject(
              id: 7,
              uuid: 'u7',
              title: '项目七',
              description: null,
              hexColor: '#123456',
              sortOrder: 0,
              parentUuid: null,
              isArchived: 0,
              isDeleted: 0,
              createdAt: 1,
              updatedAt: 1,
              deletedAt: null,
              version: 1,
            ),
          ]);
      expect(columns.map((c) => c.key).toList(), ['p7', 'none']);
      expect(columns[0].tasks.single.id, 1);
      expect(columns[0].totalCount, 3);
      expect(columns[1].totalCount, 1);
    });

    test('优先级档：固定六列（含空列），列头报组总数', () {
      final columns = kanbanColumnsFromBoard(
        const TodoTaskBoardResult(
          total: 2,
          groups: [TodoTaskBoardGroup(key: 'pri:3', total: 2, items: [])],
        ),
        KanbanGroupBy.priority,
        const [],
      );
      expect(columns.length, 6);
      expect(columns.first.key, 'pri:5');
      final pri3 = columns.firstWhere((c) => c.key == 'pri:3');
      expect(pri3.totalCount, 2);
      expect(pri3.tasks, isEmpty);
    });
  });
}
