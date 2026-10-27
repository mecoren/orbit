import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../data/api/dto.dart';
import 'task_logic.dart';

/// 移动端列表窗口化口径（P1 50k 规模档，docs/07 #105）。
///
/// 桌面端在 `task-panel.tsx` 里把「视图态 → ListFilter」的映射写在组件内；
/// 移动端把它抽成纯函数，供列表/表格/看板/矩阵/日历/Logbook 六条读通道共用
/// 同一份下推口径——六处各拼一遍迟早与 `filterTasks` 分叉。
///
/// **回退全量**（返回 null）只剩一类：
/// 标题排序——中文拼音序依赖 localeCompare，SQLite BINARY collation 复刻
/// 不了，下推会让翻页边界与视觉顺序分叉。
///
/// 保存筛选器与列表内标签筛选（2026-10-26）改走下推：core `ListFilter` 补了
/// `label_ids` / `has_reminder` / `has_attachment` / `has_open_subtask` /
/// `created_from` / `done_from` 六个谓词，条件全部能在 SQL 侧表达，故「筛选器
/// 在当前清单内取交集」不再回退万行全量。
class PagedTaskQuery {
  /// 与 core `list_todo_tasks_page` 同口径的过滤器（不含游标/limit）
  final ListFilter filter;

  /// 排序键：manual/due/priority/created/done_at
  final String sortKey;

  /// 排序方向 asc/desc（null 不在本结构里出现：构造时已按档位默认值定死，
  /// 避免同一个游标在不同默认值口径下被复用）
  final String sortDir;

  const PagedTaskQuery({
    required this.filter,
    required this.sortKey,
    required this.sortDir,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PagedTaskQuery &&
          filter == other.filter &&
          sortKey == other.sortKey &&
          sortDir == other.sortDir;

  @override
  int get hashCode => Object.hash(filter, sortKey, sortDir);

  @override
  String toString() => 'PagedTaskQuery($sortKey/$sortDir, $filter)';
}

/// 列表/表格单页行数（与桌面 `TASK_PAGE_WINDOW` 同值）。
///
/// 200 条 ≈ 首屏一屏半：首屏桥往返体积与可交互时间随页长线性下降，同时
/// 滚到尾部前有足够余量预取下一页。
const int kTaskPageWindow = 200;

/// 逾期置顶段单次上限（逾期集天然有界；超限只显示最早逾期的 200 条）。
const int kOverduePageLimit = 200;

/// 看板/四象限每列上限（与桌面 `BOARD_PAGE_LIMIT` 同值）。
const int kBoardPageLimit = 60;

/// 列表尾部「已完成 N」卡内直显条数（与 `_doneInlineMax` 同口径）。
const int kDoneCardLimit = 20;

/// 各档默认排序方向（与 [baseSortDir] 同源，避免两处各写一份）
String _defaultDir(TaskSortKey key) =>
    baseSortDir[key] == TaskSortDir.desc ? 'desc' : 'asc';

/// 视图态 → 分页查询规格；返回 null = 该组合必须回退全量通道（见类文档）。
///
/// [nowMs]：逾期/快捷视图的本地日界基准（调用方每分钟 tick 一次，避免
/// 跨零点后一直用旧值）。
///
/// [savedConditions]：当前生效的保存筛选器条件 JSON（null = 未选）。条件与
/// 当前列表范围（项目/清单聚合/快捷视图/工具栏筛选）**取交集**，见
/// [mergeSavedFilterConditions]。
///
/// 主窗口**恒只装未完成行**：列表档的完成行由尾部「已完成 N」卡独立查询
/// 承载（`doneCardFilterOf`），看板/表格/矩阵与改版前一致地隐藏完成行。
/// 唯一例外是「已完成」快捷视图（Logbook），它本身就是完成集。
PagedTaskQuery? buildPagedQuery({
  required TaskFilterInput input,
  required TaskListFilters filters,
  required TaskSortKey sortKey,
  required TaskSortDir? sortDir,
  String? savedConditions,
  required int nowMs,
}) {
  if (sortKey == TaskSortKey.title) return null;

  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final dayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  final dayEnd = dayStart + 86400000;

  // 目标互斥优先级与 filterTasks 逐字一致：
  // ungrouped > projectIds（非空）> projectId > quickView
  int? projectId;
  List<int>? projectIds;
  var ungrouped = false;
  QuickViewKey? quickView = input.quickView;
  if (input.ungrouped) {
    ungrouped = true;
    quickView = null;
  } else if (input.projectIds != null && input.projectIds!.isNotEmpty) {
    projectIds = input.projectIds;
    quickView = null;
  } else if (input.projectId != null) {
    projectId = input.projectId;
    quickView = null;
  }

  bool? done;
  String? status;
  bool? favoriteOnly;
  int? myDayToday;
  bool? hasDue;
  int? dueTo;
  switch (quickView) {
    case null:
    case QuickViewKey.all:
      break;
    case QuickViewKey.done:
      done = true;
    case QuickViewKey.undone:
      done = false;
    case QuickViewKey.today:
      // 今天 = 逾期 + 今日到期（due < 明日零点）；due_to 的 NULL 不命中
      // 正好与 filterTasks 的「要求 due 非空」同口径
      dueTo = dayEnd;
    case QuickViewKey.week:
      dueTo = dayEnd + 6 * 86400000;
    case QuickViewKey.favorite:
      favoriteOnly = true;
    case QuickViewKey.myDay:
      myDayToday = dayStart;
    case QuickViewKey.nodate:
      hasDue = false;
  }

  // 主窗口只装未完成行：done 视图是完成集的明确入口，保持 true
  if (quickView != QuickViewKey.done) {
    done = false;
  }

  // 列表内筛选：状态/优先级可下推；优先级档是等值（priority_eq）
  switch (filters.status) {
    case 'undone':
      done = false;
    case 'done':
      // 与 applyTaskListFilters 的 `isDone || status == 'done'` 同义：
      // 完成位是真值，status 只是派生列
      done = true;
    case final s?:
      status = s;
  }

  final sortKeyString = switch (sortKey) {
    TaskSortKey.manual => 'manual',
    TaskSortKey.due => 'due',
    TaskSortKey.priority => 'priority',
    TaskSortKey.created => 'created',
    // title 已在上面回退；此处兜底走 manual 不会被执行
    TaskSortKey.title => 'manual',
  };
  final sortDirString = sortDir == null
      ? _defaultDir(sortKey)
      : (sortDir == TaskSortDir.desc ? 'desc' : 'asc');
  var filter = ListFilter(
    done: done,
    status: status,
    priorityEq: filters.priority,
    // 列表内标签筛选（单值档）与保存筛选器共用 label_ids 谓词
    labelIds: filters.labelId == null ? null : [filters.labelId!],
    projectId: projectId,
    projectIds: projectIds,
    ungrouped: ungrouped ? true : null,
    favoriteOnly: favoriteOnly,
    myDayToday: myDayToday,
    hasDue: hasDue,
    dueTo: dueTo,
    sortKey: sortKeyString,
    sortDir: sortDirString,
  );
  if (savedConditions != null) {
    filter = mergeSavedFilterConditions(filter, savedConditions, nowMs: nowMs);
  }
  return PagedTaskQuery(
    // 排序键必须随 filter 过桥（core 是读 filter.sort_key 排的，不是另一个
    // 参数位）；PagedTaskQuery.sortKey 只作移动端内的可读标记
    filter: filter,
    sortKey: sortKeyString,
    sortDir: sortDirString,
  );
}

/// 保存筛选器条件 → `ListFilter`（**与当前列表范围取交集**，2026-10-26）。
///
/// 语义与本地过滤 [applySavedFilterConditions] 逐键对齐（#35/#71 的 14 键），
/// 区别只在「在哪算」：条件全部能表达成 core 谓词后改为 SQL 下推，窗口化
/// 通道不再因选了筛选器而回退万行全量。
///
/// 交集规则：
/// - 项目：两侧 `project_ids` 求交（筛选器自己限了项目时取更窄的一侧）；
///   与 `ungrouped` 冲突、或交集为空 → 空结果。
/// - 标签：`label_ids` 也是「任一命中」，两侧求交——列表内标签档是单值，
///   故交集等价于 AND。交集为空 → 空结果。
/// - 优先级：两键各自保留（SQL `priority = ? AND priority >= ?` 天然相交）。
/// - 区间：截止/创建/完成的下界取 max、上界取 min（半开区间，右端不含）。
/// - 完成态：`done_from` 隐含已完成；与主窗口的 `done = false` 冲突 → 空结果。
/// - 条件 JSON 损坏：忽略本条件（与本地过滤同口径，不静默清空列表）。
ListFilter mergeSavedFilterConditions(
  ListFilter base,
  String rawConditions, {
  required int nowMs,
}) {
  Map<String, dynamic> c;
  try {
    c = jsonDecode(rawConditions) as Map<String, dynamic>;
  } catch (_) {
    return base;
  }

  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final dayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;

  var dueFrom = base.dueFrom;
  var dueTo = base.dueTo;
  void raiseFrom(int? v) {
    if (v == null) return;
    dueFrom = dueFrom == null ? v : math.max(dueFrom!, v);
  }

  void lowerTo(int? v) {
    if (v == null) return;
    dueTo = dueTo == null ? v : math.min(dueTo!, v);
  }

  var impossible = false;

  // ── 项目：交集 ──
  var projectId = base.projectId;
  var projectIds = base.projectIds;
  final condProjects = (c['project_ids'] as List?)
      ?.map((e) => (e as num).toInt())
      .toList(growable: false);
  if (condProjects != null) {
    if (condProjects.isEmpty) {
      // 条件里「没选项目」= 不限，不收缩范围
    } else if (base.ungrouped == true) {
      impossible = true; // 未分组任务不可能属于某个具体项目
    } else if (projectIds != null) {
      final allowed = condProjects.toSet();
      projectIds = [
        for (final id in projectIds)
          if (allowed.contains(id)) id,
      ];
    } else if (projectId != null) {
      projectIds = condProjects.contains(projectId) ? [projectId] : const [];
      projectId = null;
    } else {
      // 当前列表不限项目 → 条件自己的项目范围生效
      projectIds = condProjects;
    }
  }

  // ── 标签：两侧都是「任一命中」，求交 ──
  var labelIds = base.labelIds;
  final condLabels = (c['label_ids'] as List?)
      ?.map((e) => (e as num).toInt())
      .toList(growable: false);
  if (condLabels != null && condLabels.isNotEmpty) {
    if (labelIds == null || labelIds.isEmpty) {
      labelIds = condLabels;
    } else {
      final wanted = condLabels.toSet();
      labelIds = [
        for (final id in labelIds)
          if (wanted.contains(id)) id,
      ];
    }
  }

  // ── 状态 / 完成态 ──
  var status = base.status;
  final condStatus = c['status'] as String?;
  if (condStatus != null) {
    if (status != null && status != condStatus) impossible = true;
    status = condStatus;
  }
  var done = base.done;
  if (c['due_overdue'] == true) {
    // 逾期 = 未完成且已过今日零点（与本地过滤同义）
    lowerTo(dayStart);
    if (done == true) impossible = true;
    done = false;
  }
  final doneFrom = c['done_from'] == null
      ? base.doneFrom
      : math.max(
          (c['done_from'] as num).toInt(),
          base.doneFrom ?? (c['done_from'] as num).toInt(),
        );
  if (c['done_from'] != null) {
    // done_from 隐含只看已完成：与主窗口 done=false 冲突即空
    if (done == false) impossible = true;
    done = true;
  }

  // ── 截止区间 ──
  final withinDays = (c['due_within_days'] as num?)?.toInt();
  if (withinDays != null) {
    raiseFrom(dayStart);
    lowerTo(dayStart + withinDays * 86400000);
  }
  if (c['due_from'] != null) raiseFrom((c['due_from'] as num).toInt());
  if (c['due_until'] != null) lowerTo((c['due_until'] as num).toInt());

  if (impossible) {
    // 空集合谓词 = 空结果（core 侧 `project_ids: []` 走恒假子句，
    // 刻意不写成「不加子句」——那会变成全量）
    return ListFilter(
      projectIds: const [],
      sortKey: base.sortKey,
      sortDir: base.sortDir,
    );
  }

  return ListFilter(
    keyword: base.keyword,
    page: base.page,
    pageSize: base.pageSize,
    done: done,
    status: status,
    priorityMin: base.priorityMin,
    priorityEq: base.priorityEq,
    projectId: projectId,
    projectIds: projectIds,
    favoriteOnly:
        base.favoriteOnly == true || c['favorite_only'] == true ? true : null,
    myDayToday: base.myDayToday,
    ungrouped: base.ungrouped,
    excludeDueBefore: base.excludeDueBefore,
    hasDue: base.hasDue,
    sortKey: base.sortKey,
    sortDir: base.sortDir,
    dueFrom: dueFrom,
    dueTo: dueTo,
    startFrom: base.startFrom,
    startTo: base.startTo,
    labelIds: labelIds,
    hasReminder: c['has_reminder'] == null
        ? base.hasReminder
        : c['has_reminder'] == true,
    hasAttachment: c['has_attachment'] == null
        ? base.hasAttachment
        : c['has_attachment'] == true,
    hasOpenSubtask: c['has_open_subtask'] == null
        ? base.hasOpenSubtask
        : c['has_open_subtask'] == true,
    createdFrom: c['created_from'] == null
        ? base.createdFrom
        : math.max(
            (c['created_from'] as num).toInt(),
            base.createdFrom ?? (c['created_from'] as num).toInt(),
          ),
    doneFrom: doneFrom,
  );
}

/// 逾期置顶段查询：同一套谓词，截止上界收到「现在」并强制未完成。
///
/// 主列表**不**带 excludeDueBefore（那会让 queryKey 挂上时间戳、每分钟重拉
/// 首屏）；两段合并时按 id 去重即可（见 `mergeOverdueFirst`）。
ListFilter overdueFilterOf(PagedTaskQuery query, int nowMs) => ListFilter(
      done: false,
      status: query.filter.status,
      priorityMin: query.filter.priorityMin,
      priorityEq: query.filter.priorityEq,
      projectId: query.filter.projectId,
      projectIds: query.filter.projectIds,
      ungrouped: query.filter.ungrouped,
      favoriteOnly: query.filter.favoriteOnly,
      myDayToday: query.filter.myDayToday,
      hasDue: query.filter.hasDue,
      // 保存筛选器条件必须一起带过来：否则「筛选器只留某标签」时逾期段
      // 仍会把别的标签行置顶出来（主列表与置顶段各说各话）。
      labelIds: query.filter.labelIds,
      hasReminder: query.filter.hasReminder,
      hasAttachment: query.filter.hasAttachment,
      hasOpenSubtask: query.filter.hasOpenSubtask,
      createdFrom: query.filter.createdFrom,
      doneFrom: query.filter.doneFrom,
      dueTo: nowMs,
      sortKey: 'due',
      sortDir: 'asc',
    );

/// 列表尾部「已完成」窗口：完成时刻倒序取前 N 条（卡内直显）。
ListFilter doneCardFilterOf(PagedTaskQuery query) => ListFilter(
      done: true,
      projectId: query.filter.projectId,
      projectIds: query.filter.projectIds,
      ungrouped: query.filter.ungrouped,
      favoriteOnly: query.filter.favoriteOnly,
      myDayToday: query.filter.myDayToday,
      hasDue: query.filter.hasDue,
      // 「已完成 N」卡与主窗口共用筛选器条件（标签/存在性/时间下界）
      labelIds: query.filter.labelIds,
      hasReminder: query.filter.hasReminder,
      hasAttachment: query.filter.hasAttachment,
      hasOpenSubtask: query.filter.hasOpenSubtask,
      createdFrom: query.filter.createdFrom,
      doneFrom: query.filter.doneFrom,
      sortKey: 'done_at',
      sortDir: 'desc',
    );

/// Logbook 通道：完成时刻倒序键集分页。
ListFilter logbookFilterOf(PagedTaskQuery query) => ListFilter(
      done: true,
      status: query.filter.status,
      priorityMin: query.filter.priorityMin,
      priorityEq: query.filter.priorityEq,
      projectId: query.filter.projectId,
      projectIds: query.filter.projectIds,
      ungrouped: query.filter.ungrouped,
      favoriteOnly: query.filter.favoriteOnly,
      myDayToday: query.filter.myDayToday,
      hasDue: query.filter.hasDue,
      // Logbook 与主窗口同一套筛选器条件（含 done_from 的时间下界）
      labelIds: query.filter.labelIds,
      hasReminder: query.filter.hasReminder,
      hasAttachment: query.filter.hasAttachment,
      hasOpenSubtask: query.filter.hasOpenSubtask,
      createdFrom: query.filter.createdFrom,
      doneFrom: query.filter.doneFrom,
      sortKey: 'done_at',
      sortDir: 'desc',
    );

/// 逾期段与主窗口合并：按 id 去重，逾期行在前。
///
/// 主窗口里同一行仍在其原排序位置（逾期只是视觉置顶），不去重会渲染两份
/// ——两枚 checkbox 是灾难（桌面同款注释）。
List<TodoTask> mergeOverdueFirst(List<TodoTask> overdue, List<TodoTask> window) {
  if (overdue.isEmpty) return window;
  final pinned = {for (final t in overdue) t.id};
  return [
    ...overdue,
    for (final t in window)
      if (!pinned.contains(t.id)) t,
  ];
}

/// 范围查询全量翻页（日历等需要「范围内所有行」的场景）。
///
/// 循环键集游标直到尾页；[maxRows] 是防御上限——日历单屏（3 个月）超过
/// 5000 行说明查询条件漏了范围，宁可少画也不把内存打穿。
Future<List<TodoTask>> fetchAllTaskPages(
  Future<TodoTaskPage> Function(ListCursor? cursor) fetch, {
  int maxRows = 5000,
}) async {
  final rows = <TodoTask>[];
  ListCursor? cursor;
  while (rows.length < maxRows) {
    final page = await fetch(cursor);
    rows.addAll(page.items);
    if (!page.hasMore || page.nextCursor == null) break;
    cursor = page.nextCursor;
  }
  return rows;
}

/// 日志用：把查询规格压成一行（诊断/测试断言排序档）
@visibleForTesting
String debugPagedQuery(PagedTaskQuery q) => '${q.sortKey}/${q.sortDir}';
