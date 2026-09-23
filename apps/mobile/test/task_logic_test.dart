// 任务共享纯函数单测：筛选互斥 / 排序 / 勾选 patch 构造 / 时间格式化 /
// 拖拽重排映射 / 标签勾选 diff（Phase 7）
//
// 对应 lib/modules/todo/logic/task_logic.dart（语义来源：原 React 版
// shared/task-filters.ts、shared/task-actions.ts、shared/time.ts）。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';

/// 构造测试用任务（仅关注筛选/排序相关字段，其余取合法默认值）
TodoTask _task({
  required int id,
  String title = 't',
  int? projectId,
  int priority = 0,
  String status = 'pending',
  int done = 0,
  int? doneAt,
  int? dueDate,
  int isFavorite = 0,
  int? myDayDate,
  double position = 0,
  int createdAt = 1000,
}) {
  return TodoTask(
    id: id,
    uuid: 'u$id',
    title: title,
    description: null,
    projectId: projectId,
    priority: priority,
    status: status,
    done: done,
    doneAt: doneAt,
    dueDate: dueDate,
    startDate: null,
    repeatAfter: 1,
    repeatMode: 0,
    repeatWeekdays: 0,
    repeatEndType: 0,
    repeatEndParam: 0,
    repeatFromDone: 0,
    percentDone: 0,
    position: position,
    isFavorite: isFavorite,
    myDayDate: myDayDate,
    isDeleted: 0,
    createdAt: createdAt,
    updatedAt: createdAt,
    deletedAt: null,
    version: 1,
  );
}

void main() {
  // 以"今天 00:00 本地时区"推导窗口边界，测试与运行日期无关
  final now = DateTime.now();
  final todayStart =
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  const day = 86400000;

  group('filterTasks 筛选互斥（ungrouped > projectId > view）', () {
    final tasks = [
      _task(id: 1, projectId: 10, dueDate: todayStart + 3600000),
      _task(id: 2, projectId: 10, done: 1, status: 'done'),
      _task(id: 3, projectId: null, isFavorite: 1),
      _task(id: 4, projectId: 20, dueDate: todayStart + day * 2),
      _task(id: 5, projectId: null, done: 1, status: 'done', isFavorite: 1),
      _task(
        id: 6,
        projectId: 10,
        dueDate: todayStart - day, // 昨天截止（today 视图不含）
      ),
    ];

    test('ungrouped 只保留无项目任务，忽略 view 与 projectId', () {
      final result = filterTasks(
        tasks,
        const TaskFilterInput(quickView: QuickViewKey.today, ungrouped: true),
      );
      expect(result.map((t) => t.id), [3, 5]);
    });

    test('projectId 优先于 view，只保留该项目任务', () {
      final result = filterTasks(
        tasks,
        const TaskFilterInput(quickView: QuickViewKey.done, projectId: 10),
      );
      expect(result.map((t) => t.id).toSet(), {1, 2, 6});
    });

    test('view=all 不过滤', () {
      final result =
          filterTasks(tasks, const TaskFilterInput(quickView: QuickViewKey.all));
      expect(result.length, tasks.length);
    });

    test('view=done 只含已完成', () {
      final result = filterTasks(
          tasks, const TaskFilterInput(quickView: QuickViewKey.done));
      expect(result.map((t) => t.id), [2, 5]);
    });

    test('view=today 只含今天截止（≥今日零点 且 <明日零点）', () {
      final onlyToday = filterTasks(
          tasks, const TaskFilterInput(quickView: QuickViewKey.today));
      expect(onlyToday.map((t) => t.id), [1]);

      // 边界：恰为今日零点 → 含；恰为明日零点 → 不含
      final edge = [
        _task(id: 1, dueDate: todayStart),
        _task(id: 2, dueDate: todayStart + day),
      ];
      expect(
        filterTasks(edge, const TaskFilterInput(quickView: QuickViewKey.today))
            .map((t) => t.id),
        [1],
      );
    });

    test('view=week 含今天 ≤ d < 今天+7 的未过期任务', () {
      final result = filterTasks(
          tasks, const TaskFilterInput(quickView: QuickViewKey.week));
      // 1（今天）、4（后天）；6 为昨天不含
      expect(result.map((t) => t.id), [1, 4]);
    });

    test('view=favorite 只含收藏', () {
      final result = filterTasks(
          tasks, const TaskFilterInput(quickView: QuickViewKey.favorite));
      expect(result.map((t) => t.id), [3, 5]);
    });

    test('view=nodate 只含无截止日期任务', () {
      final result = filterTasks(
          tasks, const TaskFilterInput(quickView: QuickViewKey.nodate));
      expect(result.map((t) => t.id), [2, 3, 5]);
    });
  });

  group('sortTasks 排序（position 升序 → created_at 降序）', () {
    test('position 升序；同 position 按 created_at 新的在前', () {
      final tasks = [
        _task(id: 1, position: 2, createdAt: 500),
        _task(id: 2, position: 1, createdAt: 900),
        _task(id: 3, position: 2, createdAt: 800),
        _task(id: 4, position: 2, createdAt: 300),
      ];
      expect(sortTasks(tasks).map((t) => t.id), [2, 3, 1, 4]);
    });

    test('不修改原列表', () {
      final tasks = [_task(id: 2, position: 1), _task(id: 1, position: 0)];
      sortTasks(tasks);
      expect(tasks.map((t) => t.id).toList(), [2, 1]);
    });
  });

  group('勾选语义 patch 构造（done=1+done_at+status=done）', () {
    test('未完成 → 完成：done=1 + done_at=now + status=done', () {
      final patch =
          buildDoneTogglePatch(_task(id: 1, done: 0, status: 'pending'));
      expect(patch['done'], 1);
      expect(patch['status'], 'done');
      expect(patch['done_at'], isNotNull);
    });

    test('完成 → 取消回 pending 并清空 done_at', () {
      final patch = buildDoneTogglePatch(
        _task(id: 1, done: 1, status: 'done', doneAt: 12345),
      );
      expect(patch['done'], 0);
      expect(patch['status'], 'pending');
      expect(patch['done_at'], isNull);
    });
  });

  group('状态三段 patch 构造', () {
    test('选已完成自动补 done_at', () {
      final patch = buildStatusPatch('done');
      expect(patch['status'], 'done');
      expect(patch['done'], 1);
      expect(patch['done_at'], isNotNull);
    });

    test('切走清空 done_at', () {
      final patch = buildStatusPatch('doing');
      expect(patch['status'], 'doing');
      expect(patch['done'], 0);
      expect(patch['done_at'], isNull);
    });
  });

  group('时间展示', () {
    test('formatYmd 输出 yyyy-MM-dd', () {
      final ms = DateTime(2026, 8, 26).millisecondsSinceEpoch;
      expect(formatYmd(ms), '2026-08-26');
    });

    test('formatDateTime 输出 yyyy-MM-dd HH:mm（补零）', () {
      final ms = DateTime(2026, 1, 5, 9, 8).millisecondsSinceEpoch;
      expect(formatDateTime(ms), '2026-01-05 09:08');
    });

    test('formatRelativeTime 分档：刚刚/分钟前/小时前/天前/绝对日期', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      expect(formatRelativeTime(nowMs - 10000), '刚刚');
      expect(formatRelativeTime(nowMs - 120000), '2分钟前');
      expect(formatRelativeTime(nowMs - 7200000), '2小时前');
      expect(formatRelativeTime(nowMs - 3 * 86400000), '3天前');
      expect(
        formatRelativeTime(DateTime(2026, 1, 5, 12).millisecondsSinceEpoch),
        '2026-01-05',
      );
    });

    test('relativeFromNow 未来时间输出 N分钟后/N天后', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      expect(relativeFromNow(nowMs + 1800000), contains('分钟后'));
      expect(relativeFromNow(nowMs + 3 * 86400000), contains('天后'));
    });
  });

  group('逾期与优先级色', () {
    test('isOverdue：有截止日期且早于今日零点且未完成', () {
      expect(
        isOverdue(_task(id: 1, dueDate: todayStart - 1, done: 0)),
        isTrue,
      );
      expect(isOverdue(_task(id: 1, dueDate: todayStart - 1, done: 1)), isFalse);
      expect(isOverdue(_task(id: 1, dueDate: null)), isFalse);
      expect(isOverdue(_task(id: 1, dueDate: todayStart + day)), isFalse);
    });

    test('priorityColor 六档映射，P0「无」浅灰也有色', () {
      expect(priorityColorHex(0), '#D1D5DB');
      expect(priorityColorHex(1), '#6B7280');
      expect(priorityColorHex(2), '#3B82F6');
      expect(priorityColorHex(3), '#F59E0B');
      expect(priorityColorHex(4), '#EF4444');
      expect(priorityColorHex(5), '#DC2626');
    });
  });

  group('emptyMessageFor 空态文案映射', () {
    test('按入口返回对应文案', () {
      expect(
        emptyMessageFor(const TaskFilterInput(projectId: 1)),
        '该项目暂无任务',
      );
      expect(emptyMessageFor(const TaskFilterInput(ungrouped: true)),
          '暂无未分组任务');
      expect(
        emptyMessageFor(
            const TaskFilterInput(quickView: QuickViewKey.today)),
        '今天没有截止的任务',
      );
      expect(
        emptyMessageFor(const TaskFilterInput(quickView: QuickViewKey.week)),
        '本周没有截止的任务',
      );
      expect(
        emptyMessageFor(const TaskFilterInput(quickView: QuickViewKey.done)),
        '暂无已完成任务',
      );
      expect(
        emptyMessageFor(
            const TaskFilterInput(quickView: QuickViewKey.favorite)),
        '暂无收藏任务',
      );
      expect(
        emptyMessageFor(const TaskFilterInput(quickView: QuickViewKey.all)),
        '暂无任务',
      );
    });
  });

  group('reorderItems 拖拽重排映射（侧栏项目段）', () {
    test('向上拖动：尾元素移到头部', () {
      expect(reorderItems([1, 2, 3, 4], 3, 0), [4, 1, 2, 3]);
    });

    test('向下拖动：onReorderItem 已归一化 newIndex（旧位先移除口径）', () {
      // ReorderableListView 把 a 拖到 c 之后：旧 onReorder 回调 (0,3)，
      // 归一化后 onReorderItem 回调 (0,2) —— 直接消费
      expect(reorderItems(['a', 'b', 'c'], 0, 2), ['b', 'c', 'a']);
      // 相邻下移：(0,1) → a 与 b 交换
      expect(reorderItems(['a', 'b', 'c'], 0, 1), ['b', 'a', 'c']);
    });

    test('原位放置不变序', () {
      expect(reorderItems([1, 2, 3], 1, 1), [1, 2, 3]);
    });

    test('不修改原列表', () {
      final src = [1, 2, 3];
      reorderItems(src, 0, 2);
      expect(src, [1, 2, 3]);
    });

    test('越界索引防御性返回原序拷贝', () {
      expect(reorderItems([1, 2, 3], -1, 1), [1, 2, 3]);
      expect(reorderItems([1, 2, 3], 3, 1), [1, 2, 3]);
      expect(reorderItems([1, 2, 3], 1, -1), [1, 2, 3]);
      expect(reorderItems([1, 2, 3], 1, 3), [1, 2, 3]);
    });
  });

  group('diffLabelSelection 标签勾选 diff（详情页标签编辑）', () {
    final taskLabelIdByLabelId = <int, int>{101: 9, 102: 8, 103: 7};

    test('新勾选 → attachLabelIds 携标签 id', () {
      final diff = diffLabelSelection(
        before: {101},
        after: {101, 102},
        taskLabelIdByLabelId: taskLabelIdByLabelId,
      );
      expect(diff.attachLabelIds, [102]);
      expect(diff.detachTaskLabelIds, isEmpty);
    });

    test('取消已挂载勾选 → detachTaskLabelIds 经映射反查关联主键', () {
      final diff = diffLabelSelection(
        before: {101, 102},
        after: {102},
        taskLabelIdByLabelId: taskLabelIdByLabelId,
      );
      expect(diff.attachLabelIds, isEmpty);
      expect(diff.detachTaskLabelIds, [9]);
    });

    test('取消无关联映射的 id 视为已不存在，跳过删除', () {
      final diff = diffLabelSelection(
        before: {999},
        after: {},
        taskLabelIdByLabelId: taskLabelIdByLabelId,
      );
      expect(diff.attachLabelIds, isEmpty);
      expect(diff.detachTaskLabelIds, isEmpty);
    });

    test('增删并存一次算清（批量落库口径）', () {
      final diff = diffLabelSelection(
        before: {101, 102},
        after: {102, 103, 104},
        taskLabelIdByLabelId: taskLabelIdByLabelId,
      );
      expect(diff.attachLabelIds.toSet(), {103, 104});
      expect(diff.detachTaskLabelIds, [9]);
    });

    test('勾选态无变化 → 空 diff', () {
      final diff = diffLabelSelection(
        before: {101},
        after: {101},
        taskLabelIdByLabelId: taskLabelIdByLabelId,
      );
      expect(diff.attachLabelIds, isEmpty);
      expect(diff.detachTaskLabelIds, isEmpty);
    });
  });

  group('labelPaletteHexes 固定 8 色板', () {
    test('共 8 色、无重复、含默认第 4 色 #3B82F6', () {
      expect(labelPaletteHexes.length, 8);
      expect(labelPaletteHexes.toSet().length, 8);
      expect(labelPaletteHexes[3], '#3B82F6');
    });
  });

  group('我的一天（myDay：今天加入命中，昨天/null 不命中）', () {
    test('myDayDate == 今天零点 命中', () {
      final tasks = [_task(id: 1, myDayDate: todayStart)];
      expect(
        filterTasks(tasks, const TaskFilterInput(quickView: QuickViewKey.myDay))
            .map((t) => t.id),
        [1],
      );
    });

    test('昨天加入的不命中（次日自动退出视图）', () {
      final tasks = [_task(id: 1, myDayDate: todayStart - day)];
      expect(
        filterTasks(tasks, const TaskFilterInput(quickView: QuickViewKey.myDay)),
        isEmpty,
      );
    });

    test('null（从未加入）不命中', () {
      final tasks = [_task(id: 1, myDayDate: null)];
      expect(
        filterTasks(tasks, const TaskFilterInput(quickView: QuickViewKey.myDay)),
        isEmpty,
      );
    });
  });

// ---------- 视图内新增自动带视图标记（#39）----------

group('视图创建默认值（quickViewCreateDefaults + weekDefaultDueMs）', () {
  DateTime d(int m, int day, [int h = 10, int min = 30]) => DateTime(2026, m, day, h, min);
  int zero(int m, int day) =>
      DateTime(2026, m, day).millisecondsSinceEpoch;
  int at18(int m, int day) =>
      DateTime(2026, m, day, 18).millisecondsSinceEpoch;

  test('atViewDueHour：任意时刻归一当日 18:00（保留日期、幂等）', () {
    expect(atViewDueHour(DateTime(2026, 9, 9, 0, 0).millisecondsSinceEpoch),
        at18(9, 9));
    expect(atViewDueHour(DateTime(2026, 9, 9, 23, 59).millisecondsSinceEpoch),
        at18(9, 9));
    expect(atViewDueHour(at18(9, 9)), at18(9, 9));
  });

  test('本周默认截止：周一/周三/周五 → 当周周五 18:00', () {
    expect(weekDefaultDueMs(d(9, 7)), at18(9, 11)); // 周一
    expect(weekDefaultDueMs(d(9, 9)), at18(9, 11)); // 周三
    expect(weekDefaultDueMs(d(9, 11, 23, 59)), at18(9, 11)); // 周五深夜仍算周五
  });

  test('本周默认截止：周六/周日 → 周日 18:00', () {
    expect(weekDefaultDueMs(d(9, 12)), at18(9, 13));
    expect(weekDefaultDueMs(d(9, 13)), at18(9, 13));
  });

  test('本周默认截止：跨月边界 周三 09-30 → 周五 10-02 18:00', () {
    expect(weekDefaultDueMs(d(9, 30)), at18(10, 2));
  });

  test('我的一天 → myDayMs=今天零点；无 dueMs/favorite', () {
    final r = quickViewCreateDefaults(QuickViewKey.myDay, d(9, 9));
    expect(r.myDayMs, zero(9, 9));
    expect(r.dueMs, isNull);
    expect(r.favorite, isNull);
  });

  test('今天截止 → dueMs=今天 18:00', () {
    final r = quickViewCreateDefaults(QuickViewKey.today, d(9, 9));
    expect(r.dueMs, at18(9, 9));
  });

  test('本周截止 → dueMs=当周周五 18:00', () {
    final r = quickViewCreateDefaults(QuickViewKey.week, d(9, 9));
    expect(r.dueMs, at18(9, 11));
  });

  test('收藏 → favorite=1', () {
    final r = quickViewCreateDefaults(QuickViewKey.favorite, d(9, 9));
    expect(r.favorite, 1);
    expect(r.dueMs, isNull);
  });

  test('无标记视图与 null → 全空', () {
    for (final v in [QuickViewKey.all, QuickViewKey.done, null]) {
      final r = quickViewCreateDefaults(v, d(9, 9));
      expect(r.dueMs, isNull);
      expect(r.myDayMs, isNull);
      expect(r.favorite, isNull);
    }
  });
});
// ---------- 逾期置顶分组（性能批次，与桌面 groupOverdueFirst 同口径）----------

group('groupOverdueFirst 逾期置顶分组', () {
  const now = 1700000000000;

  test('未完成且截止已过 → overdue；其余（无截止/未到期/已完成）→ rest', () {
    final g = groupOverdueFirst([
      _task(id: 1, dueDate: now - 1000),
      _task(id: 2),
      _task(id: 3, dueDate: now + 1000),
      _task(id: 4, done: 1, dueDate: now - 1000),
    ], now);
    expect(g.overdue.map((t) => t.id), [1]);
    expect(g.rest.map((t) => t.id), [2, 3, 4]);
  });

  test('无逾期任务 → overdue 空且 rest 保序', () {
    final g = groupOverdueFirst([_task(id: 1), _task(id: 2)], now);
    expect(g.overdue, isEmpty);
    expect(g.rest.map((t) => t.id), [1, 2]);
  });

  test('dueDate 恰等于 now 不算逾期（未过口径，左开右闭）', () {
    final g = groupOverdueFirst([_task(id: 1, dueDate: now)], now);
    expect(g.overdue, isEmpty);
    expect(g.rest.map((t) => t.id), [1]);
  });

  test('组内保持原相对顺序（不重排）', () {
    final g = groupOverdueFirst([
      _task(id: 3, dueDate: now - 3000),
      _task(id: 1, dueDate: now - 1000),
      _task(id: 2, dueDate: now - 2000),
    ], now);
    expect(g.overdue.map((t) => t.id), [3, 1, 2]);
  });
});

// ── 侧栏单遍计数聚合（口径与 filterTasks 一致性对照）──
group('computeSidebarCounts 单遍计数', () {
  final n = DateTime.now();
  final todayStart = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
  const day = 86400000;

  test('各视图计数与逐视图 filterTasks 结果一致（口径锁定）', () {
    final tasks = [
      _task(id: 1, dueDate: todayStart + 3600000, isFavorite: 1),
      _task(id: 2, dueDate: todayStart + 2 * day, myDayDate: todayStart),
      _task(id: 3, projectId: 7),
      _task(id: 4, done: 1, doneAt: todayStart, status: 'done'),
      _task(id: 5, dueDate: todayStart - day), // 逾期但在本周窗外
      _task(id: 6),
    ];
    final counts = computeSidebarCounts(tasks);

    for (final key in QuickViewKey.values) {
      final filtered = filterTasks(
          tasks, TaskFilterInput(quickView: key));
      final expected = key == QuickViewKey.done
          ? filtered.length
          : filtered.where((t) => !t.isDone).length;
      expect(counts.quickView[key], expected,
          reason: '$key 视图计数与 filterTasks 漂移');
    }
  });

  test('项目未完成计数与单遍聚合一致', () {
    final tasks = [
      _task(id: 1, projectId: 7),
      _task(id: 2, projectId: 7),
      _task(id: 3, projectId: 9, done: 1, doneAt: 1, status: 'done'),
      _task(id: 4),
    ];
    final counts = computeSidebarCounts(tasks);
    expect(counts.undoneByProject, {7: 2});
  });

  test('空任务列表 → 全零计数 + 空项目 Map', () {
    final counts = computeSidebarCounts(const []);
    expect(counts.quickView.values.every((v) => v == 0), isTrue);
    expect(counts.undoneByProject, isEmpty);
  });

  test('today 窗口尾界与 nodate 口径（无截止才算 nodate）', () {
    final todayDue = _task(id: 1, dueDate: todayStart); // 恰零点 = 今天
    final noDue = _task(id: 2);
    final counts = computeSidebarCounts([todayDue, noDue]);
    expect(counts.quickView[QuickViewKey.today], 1);
    expect(counts.quickView[QuickViewKey.nodate], 1);
  });
});

// ---------- Logbook 治理：隐藏已完成 + 完成日分组（2026-09-12）----------

  group('filterTasks hideDone 隐藏已完成（Logbook 治理）', () {
    test('hideDone 剔除已完成任务', () {
      final tasks = [
        _task(id: 1),
        _task(id: 2, done: 1, doneAt: 100, status: 'done'),
      ];
      final out = filterTasks(tasks, const TaskFilterInput(), hideDone: true);
      expect(out.map((t) => t.id), [1]);
    });

    test('hideDone 缺省不隐藏（现行为不变）', () {
      final tasks = [_task(id: 1, done: 1, doneAt: 100, status: 'done')];
      final out = filterTasks(tasks, const TaskFilterInput());
      expect(out.map((t) => t.id), [1]);
    });

    test('done 视图下 hideDone 不生效（完成集入口）', () {
      final tasks = [_task(id: 1, done: 1, doneAt: 100, status: 'done')];
      final out = filterTasks(
          tasks, const TaskFilterInput(quickView: QuickViewKey.done),
          hideDone: true);
      expect(out.map((t) => t.id), [1]);
    });

    test('项目视图下 hideDone 同样生效', () {
      final tasks = [
        _task(id: 1, projectId: 5),
        _task(id: 2, projectId: 5, done: 1, doneAt: 100, status: 'done'),
      ];
      final out = filterTasks(
          tasks, const TaskFilterInput(projectId: 5),
          hideDone: true);
      expect(out.map((t) => t.id), [1]);
    });
  });

  group('groupDoneByDay 完成日分组（Logbook 数据源）', () {
    test('按完成日倒序分组、组内完成时刻倒序', () {
      final d10 = DateTime(2026, 9, 10);
      final d12 = DateTime(2026, 9, 12);
      final tasks = [
        _task(id: 1, done: 1, doneAt: d10.add(const Duration(hours: 9)).millisecondsSinceEpoch),
        _task(id: 2, done: 1, doneAt: d12.add(const Duration(hours: 20)).millisecondsSinceEpoch),
        _task(id: 3, done: 1, doneAt: d12.add(const Duration(hours: 8)).millisecondsSinceEpoch),
      ];
      final groups = groupDoneByDay(tasks);
      expect(groups.map((g) => g.key), ['2026-09-12', '2026-09-10']);
      expect(groups.first.tasks.map((t) => t.id), [2, 3]);
    });

    test('doneAt 缺失兜底落 createdAt 日', () {
      final d10 = DateTime(2026, 9, 10, 15);
      final tasks = [
        _task(id: 1, done: 1, doneAt: null, createdAt: d10.millisecondsSinceEpoch),
      ];
      final groups = groupDoneByDay(tasks);
      expect(groups.single.key, '2026-09-10');
    });

    test('空集返回空', () {
      expect(groupDoneByDay(const []), isEmpty);
    });
  });

// ---------- 提醒相对档（M2：TickTick 式快捷）----------

group('reminderPresets 提醒快捷档', () {
  test('有截止日期：当天 9:00 + 前推 1 小时 / 30 / 15 分钟', () {
    final due = DateTime(2026, 9, 23, 18).millisecondsSinceEpoch;
    final out = reminderPresets(dueDate: due);
    expect(out.map((p) => p.label), [
      '截止当天 09:00',
      '截止前 1 小时',
      '截止前 30 分钟',
      '截止前 15 分钟',
    ]);
    expect(out[0].ms, DateTime(2026, 9, 23, 9).millisecondsSinceEpoch);
    expect(out[1].ms, due - const Duration(hours: 1).inMilliseconds);
    expect(out[2].ms, due - const Duration(minutes: 30).inMilliseconds);
    expect(out[3].ms, due - const Duration(minutes: 15).inMilliseconds);
  });

  test('无截止日期：今天 / 明天 9:00（按传入 now 锚定本地日界）', () {
    final out = reminderPresets(now: DateTime(2026, 9, 23, 20, 30));
    expect(out.map((p) => p.label), ['今天 09:00', '明天 09:00']);
    expect(out[0].ms, DateTime(2026, 9, 23, 9).millisecondsSinceEpoch);
    expect(out[1].ms, DateTime(2026, 9, 24, 9).millisecondsSinceEpoch);
  });

  test('同刻去重：截止 09:15 时「当天 9:00」与「前 15 分钟」合并', () {
    final due = DateTime(2026, 9, 23, 9, 15).millisecondsSinceEpoch;
    final out = reminderPresets(dueDate: due);
    expect(out.length, 3);
    expect(out.first.label, '截止当天 09:00');
    expect(out.map((p) => p.ms).toSet().length, out.length);
  });

  test('过期档位不过滤（与日期面板允许选过去同口径）', () {
    final now = DateTime(2026, 9, 23, 20);
    final out = reminderPresets(dueDate: now.millisecondsSinceEpoch);
    expect(out.length, 4);
    expect(out.every((p) => p.ms < now.millisecondsSinceEpoch), isTrue);
  });
});

// ---------- 行内提醒徽标（M3：镜像桌面 reminder-meta.ts）----------

group('displayReminder 行内提醒选取', () {
  ProjectedReminder r(int id, int at) => ProjectedReminder(id: id, remindAt: at);

  test('无存活提醒 → null（调用方不渲染徽标）', () {
    expect(displayReminder(const [], 1000, taskDone: false), isNull);
  });

  test('有未来行 → 取最近一条（下一个将响的时刻）', () {
    final d = displayReminder([r(1, 5000), r(2, 3000), r(3, 9000)], 1000,
        taskDone: false);
    expect(d!.id, 2);
    expect(d.fired, isFalse);
  });

  test('全部已过期 → 取最早一条（展示错过了哪一响）', () {
    final d = displayReminder([r(1, 900), r(2, 300), r(3, 700)], 1000,
        taskDone: false);
    expect(d!.id, 2);
    expect(d.fired, isTrue);
  });

  test('已完成实例不警示（过期也按 muted 展示）', () {
    final d = displayReminder([r(1, 900)], 1000, taskDone: true);
    expect(d!.fired, isFalse);
  });

  test('恰在 now 视为已到期（与桌面 <= 口径一致）', () {
    expect(displayReminder([r(1, 1000)], 1000, taskDone: false)!.fired, isTrue);
  });

  test('未按序传入也选得对（按 remind_at 兜底排序）', () {
    final d = displayReminder([r(1, 8000), r(2, 2000)], 1000, taskDone: false);
    expect(d!.id, 2);
  });

  test('formatHm 输出 HH:mm 补零（徽标时钟口径）', () {
    expect(formatHm(DateTime(2026, 9, 23, 9, 5).millisecondsSinceEpoch),
        '09:05');
  });
});
}
