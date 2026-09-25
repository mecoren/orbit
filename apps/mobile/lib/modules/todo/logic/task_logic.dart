import 'package:flutter/material.dart';

import '../../../data/api/dto.dart';
import 'view_mode.dart';
import '../../../core/theme/icon_map.dart';

/// 待办共享业务纯函数（无 UI / 无 IO，可直接单测）
///
/// 语义来源：原 React 版（git 历史 35e563a）：
/// - `shared/task-filters.ts` —— 筛选互斥 ungrouped > projectId > view；
///   排序 position 升序 → created_at 降序；
/// - `shared/task-actions.ts` —— 勾选语义 done=1 + done_at + status=done，
///   取消一律回 pending 并清空 done_at；
/// - `shared/time.ts` —— 相对时间分档与 yyyy-MM-dd 格式化。
///
/// 快捷视图七键（docs/05 §4.1 + 07 报告新增「我的一天」置顶）：
/// 我的一天 / 今天 / 本周 / 全部 / 已完成 / 收藏 / 无日期。

// ---------- 快捷视图定义 ----------

/// 快捷视图 key
enum QuickViewKey { myDay, today, week, all, done, favorite, nodate }

/// [QuickViewKey] 的展示元数据（标签 / 语义色，色值对齐 docs/05 §2.2 quickView 板）
extension QuickViewMeta on QuickViewKey {
  /// 侧栏行文案
  String get label => switch (this) {
        QuickViewKey.myDay => '我的一天',
        QuickViewKey.today => '今天截止',
        QuickViewKey.week => '本周截止',
        QuickViewKey.all => '全部任务',
        QuickViewKey.done => '已完成',
        QuickViewKey.favorite => '收藏',
        QuickViewKey.nodate => '无日期',
      };

  /// 语义色（hex 字符串，UI 层经 hexToColor 转换；nodate 取中性灰）
  String get colorHex => switch (this) {
        QuickViewKey.myDay => '#F59E0B',
        QuickViewKey.today => '#EF4444',
        QuickViewKey.week => '#F59E0B',
        QuickViewKey.all => '#3B82F6',
        QuickViewKey.done => '#22C55E',
        QuickViewKey.favorite => '#8B5CF6',
        QuickViewKey.nodate => '#6B7280',
      };

  /// Material Rounded 图标（docs/05 §4.1 图标映射 + nodate 补充）
  IconData get icon => switch (this) {
        QuickViewKey.myDay => OrbitIcons.sun,
        QuickViewKey.today => OrbitIcons.calendar,
        QuickViewKey.week => OrbitIcons.calendarRange,
        QuickViewKey.all => OrbitIcons.list,
        QuickViewKey.done => OrbitIcons.success,
        QuickViewKey.favorite => OrbitIcons.starOutline,
        QuickViewKey.nodate => OrbitIcons.calendarBlocked,
      };
}

// ---------- 筛选 / 排序 ----------

/// 任务列表筛选输入（三目标互斥，优先级 ungrouped > projectId > quickView）
class TaskFilterInput {
  final QuickViewKey? quickView;
  final int? projectId;
  final bool ungrouped;

  const TaskFilterInput({this.quickView, this.projectId, this.ungrouped = false});
}

/// 按输入过滤任务（互斥语义见 [TaskFilterInput]；时间窗口为本地时区自然日）。
/// [hideDone]：隐藏已完成（Logbook 治理）；quickView=done 完成
/// 集入口下不参与过滤（否则开关把完成视图清成永久空列表）
List<TodoTask> filterTasks(List<TodoTask> tasks, TaskFilterInput input,
    {bool hideDone = false}) {
  final now = DateTime.now();
  final todayStart =
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  final todayEnd = todayStart + 86400000;
  final weekEnd = todayEnd + 6 * 86400000;

  Iterable<TodoTask> list = tasks;

  if (input.ungrouped) {
    // 未分组：projectId 为空
    list = list.where((t) => t.projectId == null);
  } else if (input.projectId != null) {
    list = list.where((t) => t.projectId == input.projectId);
  } else {
    switch (input.quickView) {
      case null:
      case QuickViewKey.all:
        break;
      case QuickViewKey.done:
        list = list.where((t) => t.isDone);
      case QuickViewKey.today:
        list = list.where(
          (t) =>
              t.dueDate != null &&
              t.dueDate! >= todayStart &&
              t.dueDate! < todayEnd,
        );
      case QuickViewKey.week:
        list = list.where(
          (t) =>
              t.dueDate != null &&
              t.dueDate! >= todayStart &&
              t.dueDate! < weekEnd,
        );
      case QuickViewKey.favorite:
        list = list.where((t) => t.isStarred);
      case QuickViewKey.myDay:
        // 我的一天：只显示今天加入的（昨天加入自动退出视图，数据保留）
        list = list.where((t) => t.isInMyDay);
      case QuickViewKey.nodate:
        list = list.where((t) => t.dueDate == null);
    }
  }
  // 隐藏已完成（Logbook 治理）：done 快捷视图是完成集的明确入口，不剔除
  if (hideDone && input.quickView != QuickViewKey.done) {
    list = list.where((t) => !t.isDone);
  }
  return list.toList();
}

/// Logbook 完成日分组单元（对标 Things 3 Logbook：完成历史按日聚合）
class DoneDayGroup {
  /// 本地 YYYY-MM-DD
  final String key;
  final DateTime date;
  final List<TodoTask> tasks;

  DoneDayGroup({required this.key, required this.date, required this.tasks});
}

String _dayKey(DateTime d) {
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${p2(d.month)}-${p2(d.day)}';
}

/// 已完成任务按完成日（doneAt 本地日）倒序分组——Logbook 视图数据源
/// （与桌面 groupDoneByDay 同口径：组间倒序最近的在前，组内按完成时刻倒序；
/// doneAt 缺失的脏行兜底落 createdAt 日）
List<DoneDayGroup> groupDoneByDay(List<TodoTask> tasks) {
  final byKey = <String, DoneDayGroup>{};
  for (final t in tasks) {
    final ts = t.doneAt ?? t.createdAt;
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final key = _dayKey(d);
    byKey.putIfAbsent(
      key,
      () => DoneDayGroup(
        key: key,
        date: DateTime(d.year, d.month, d.day),
        tasks: [],
      ),
    ).tasks.add(t);
  }
  final groups = byKey.values.toList()
    ..sort((a, b) => b.date.compareTo(a.date));
  for (final g in groups) {
    g.tasks.sort((a, b) => (b.doneAt ?? b.createdAt)
        .compareTo(a.doneAt ?? a.createdAt));
  }
  return groups;
}

/// 排序档位（#26 双端排序；manual = position 拖拽顺序，唯一默认档）。
/// 侧栏计数聚合（单遍扫描出全部视图未完成数 + 项目未完成 Map）。
/// 此前侧栏每个快捷视图行各跑一遍 filterTasks（7 遍全量 + 7 次
/// DateTime.now()），万任务下每次 build 8+ 遍遍历；此函数一遍完成。
/// 口径与 filterTasks 完全一致（today/week 时间窗、myDay 零点判定）。
SidebarCounts computeSidebarCounts(
  List<TodoTask> tasks, {
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final todayStart = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
  final todayEnd = todayStart + 86400000;
  final weekEnd = todayEnd + 6 * 86400000;

  var all = 0, done = 0, today = 0, week = 0, favorite = 0, myDay = 0, nodate = 0;
  final byProject = <int, int>{};

  for (final t in tasks) {
    final undone = !t.isDone;
    if (undone) {
      all++;
      if (t.projectId != null) {
        byProject[t.projectId!] = (byProject[t.projectId!] ?? 0) + 1;
      }
    } else {
      done++;
    }
    if (t.isDone) continue;

    if (t.dueDate != null) {
      if (t.dueDate! >= todayStart && t.dueDate! < todayEnd) today++;
      if (t.dueDate! >= todayStart && t.dueDate! < weekEnd) week++;
    } else {
      nodate++;
    }
    if (t.isStarred) favorite++;
    if (t.isInMyDay) myDay++;
  }

  return SidebarCounts(
    quickView: {
      QuickViewKey.all: all,
      QuickViewKey.done: done,
      QuickViewKey.today: today,
      QuickViewKey.week: week,
      QuickViewKey.favorite: favorite,
      QuickViewKey.myDay: myDay,
      QuickViewKey.nodate: nodate,
    },
    undoneByProject: byProject,
  );
}

/// 单遍计数结果（quickView 含 done 视图的已完成数——badge 口径）
class SidebarCounts {
  const SidebarCounts({required this.quickView, required this.undoneByProject});

  /// 各快捷视图计数（all/today/week/favorite/myDay/nodate = 未完成数，
  /// done 视图 = 已完成数）
  final Map<QuickViewKey, int> quickView;

  /// 各项目未完成数
  final Map<int, int> undoneByProject;
}

enum TaskSortKey { manual, due, priority, title, created }

/// 排序（默认 manual：position 升序 → created_at 降序；#26 增四档）。
/// 返回新列表，不改入参。
List<TodoTask> sortTasks(List<TodoTask> tasks, [TaskSortKey key = TaskSortKey.manual]) {
  final sorted = [...tasks];
  switch (key) {
    case TaskSortKey.due:
      // 无截止沉底，有截止升序（同值落回创建时间降序）
      sorted.sort((a, b) {
        if (a.dueDate == null && b.dueDate == null) {
          return b.createdAt.compareTo(a.createdAt);
        }
        if (a.dueDate == null) return 1;
        if (b.dueDate == null) return -1;
        final c = a.dueDate!.compareTo(b.dueDate!);
        return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
      });
    case TaskSortKey.priority:
      // 优先级大者在前（同值落回拖拽顺序）
      sorted.sort((a, b) {
        final c = b.priority.compareTo(a.priority);
        if (c != 0) return c;
        if (a.position != b.position) return a.position.compareTo(b.position);
        return b.createdAt.compareTo(a.createdAt);
      });
    case TaskSortKey.title:
      // 中文拼音序（与桌面 localeCompare zh-Hans-CN 同语义）
      sorted.sort((a, b) => a.title.compareTo(b.title));
    case TaskSortKey.created:
      sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    case TaskSortKey.manual:
      sorted.sort((a, b) {
        if (a.position != b.position) return a.position.compareTo(b.position);
        return b.createdAt.compareTo(a.createdAt);
      });
  }
  return sorted;
}

/// 逾期置顶分组结果（性能批次 UX 优化，与桌面 groupOverdueFirst 同口径）
class OverdueGroups {
  /// 未完成且截止已过（置顶展示）
  final List<TodoTask> overdue;

  /// 其余任务（无截止/未到期/已完成）
  final List<TodoTask> rest;

  const OverdueGroups({required this.overdue, required this.rest});
}

/// 逾期置顶分组：未完成且 dueDate < now 的任务划入「逾期」区，
/// 其余落 rest 区——Todoist/MS To Do 同款信息层级。
/// 仅判定展示拆分，不重排组内顺序（拖拽 position 语义不受影响）。
OverdueGroups groupOverdueFirst(List<TodoTask> tasks, [int? nowMs]) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final overdue = <TodoTask>[];
  final rest = <TodoTask>[];
  for (final t in tasks) {
    if (!t.isDone && t.dueDate != null && t.dueDate! < now) {
      overdue.add(t);
    } else {
      rest.add(t);
    }
  }
  return OverdueGroups(overdue: overdue, rest: rest);
}

// ---------- 四象限分组（Eisenhower Matrix，对标 TickTick 矩阵视图） ----------

/// 四象限桶位（展示顺序即枚举序：先重要后次要，先紧急后不紧急）
enum EisenhowerQuadrant {
  urgentImportant,
  importantNotUrgent,
  urgentNotImportant,
  neither,
}

/// 四象限的展示元数据：行动短语 + 轴文案（2×2 概览格头两行）
extension EisenhowerQuadrantMeta on EisenhowerQuadrant {
  String get actionLabel => switch (this) {
        EisenhowerQuadrant.urgentImportant => '立即做',
        EisenhowerQuadrant.importantNotUrgent => '计划做',
        EisenhowerQuadrant.urgentNotImportant => '抽空做',
        EisenhowerQuadrant.neither => '可延后',
      };

  String get axisLabel => switch (this) {
        EisenhowerQuadrant.urgentImportant => '紧急 · 重要',
        EisenhowerQuadrant.importantNotUrgent => '不紧急 · 重要',
        EisenhowerQuadrant.urgentNotImportant => '紧急 · 不重要',
        EisenhowerQuadrant.neither => '不紧急 · 不重要',
      };
}

/// 四象限分组纯函数：已完成不入桶（矩阵只承载未完成工作集，完成历史
/// 交给「已完成」视图）。轴口径——重要 = 优先级 ≥ 高(3)；紧急 = 截止
/// 在今天 24:00 之前（含逾期，本地时区日界）。[nowMs] 供测试注入固定时间。
Map<EisenhowerQuadrant, List<TodoTask>> groupEisenhower(
    List<TodoTask> tasks, [
      int? nowMs,
    ]) {
  final now = DateTime.fromMillisecondsSinceEpoch(
    nowMs ?? DateTime.now().millisecondsSinceEpoch,
  );
  final dayEnd =
      DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch;
  final buckets = {
    for (final q in EisenhowerQuadrant.values) q: <TodoTask>[],
  };
  for (final t in tasks) {
    if (t.isDone) continue;
    final urgent = t.dueDate != null && t.dueDate! < dayEnd;
    final important = t.priority >= 3;
    final q = switch ((urgent, important)) {
      (true, true) => EisenhowerQuadrant.urgentImportant,
      (false, true) => EisenhowerQuadrant.importantNotUrgent,
      (true, false) => EisenhowerQuadrant.urgentNotImportant,
      (false, false) => EisenhowerQuadrant.neither,
    };
    buckets[q]!.add(t);
  }
  return buckets;
}

// ---------- 写操作 patch 构造 ----------

/// 勾选/取消勾选 → todoTaskUpdate 的增量 patch：
/// 完成写 done=1 + done_at=now + status="done"；取消回 status="pending" 并清 done_at。
Map<String, Object?> buildDoneTogglePatch(TodoTask task) {
  if (task.isDone) {
    return {'done': 0, 'done_at': null, 'status': 'pending'};
  }
  return {'done': 1, 'done_at': DateTime.now().millisecondsSinceEpoch, 'status': 'done'};
}

/// 状态三段切换 patch：选 done 自动补 done_at；切走清空 done_at 并回未完成。
Map<String, Object?> buildStatusPatch(String status) {
  if (status == 'done') {
    return {'status': 'done', 'done': 1, 'done_at': DateTime.now().millisecondsSinceEpoch};
  }
  return {'status': status, 'done': 0, 'done_at': null};
}

// ---------- 拖拽重排（侧栏项目段 Phase 7） ----------

/// 通用列表重排（纯函数）：把 [oldIndex] 元素移动到语义插入位 [newIndex]。
///
/// 索引口径为 [ReorderableListView.onReorderItem] 回调（v3.41+）：newIndex
/// 已按"旧元素先移除"归一化，取值 0..length-1；旧版 onReorder 回调需自行
/// 做 oldIndex < newIndex 时 -1 的映射，勿直接传入。
/// 返回新列表，不改入参；索引越界时防御性返回原序拷贝（脏回调不致崩溃）。
List<T> reorderItems<T>(List<T> items, int oldIndex, int newIndex) {
  final n = items.length;
  if (oldIndex < 0 || oldIndex >= n || newIndex < 0 || newIndex >= n) {
    return [...items];
  }
  final reordered = [...items];
  final moved = reordered.removeAt(oldIndex);
  reordered.insert(newIndex, moved);
  return reordered;
}

/// position 取中值（#37 拖拽落位；与桌面 shared/position.ts midpoint 同口径）：
/// 落库行新位次的相邻两条 position 取中值——prev 缺省视为 0（插到最前）、
/// next 缺省视为 100000（插到最后），保持 f64 中值精度到落库时再取整。
double midpointPosition(double? prev, double? next) =>
    ((prev ?? 0) + (next ?? 100000)) / 2;

// ---------- 标签勾选 diff（详情页标签编辑 Phase 7） ----------

/// 固定 8 色板（新建标签选色用；对齐桌面端 PRESET_COLORS，
/// 默认选中第 4 色 #3B82F6 与桌面 LabelManager 一致）
const List<String> labelPaletteHexes = [
  '#EF4444',
  '#F59E0B',
  '#22C55E',
  '#3B82F6',
  '#8B5CF6',
  '#EC4899',
  '#14B8A6',
  '#6B7280',
];

/// 勾选态 diff 结果：待建关联的标签 id 集 / 待删关联主键集
class LabelSelectionDiff {
  /// 新勾选 → 逐条 todoTaskLabelCreate(taskId, labelId)
  final List<int> attachLabelIds;

  /// 取消勾选 → 逐条 todoTaskLabelDelete(taskLabelId)
  final List<int> detachTaskLabelIds;

  const LabelSelectionDiff({
    this.attachLabelIds = const [],
    this.detachTaskLabelIds = const [],
  });
}

/// 由前后勾选态计算关联增删（纯函数）：
/// - 新勾选且详情中未挂载 → 进 [LabelSelectionDiff.attachLabelIds]；
/// - 取消勾选且仍挂载 → 经 taskLabelIdByLabelId 反查关联主键进
///   [LabelSelectionDiff.detachTaskLabelIds]（无映射视为已不存在，跳过）。
LabelSelectionDiff diffLabelSelection({
  required Set<int> before,
  required Set<int> after,
  required Map<int, int> taskLabelIdByLabelId,
}) {
  final added = after.difference(before).toList();
  final detached = <int>[
    for (final id in before.difference(after))
      if (taskLabelIdByLabelId[id] != null) taskLabelIdByLabelId[id]!,
  ];
  return LabelSelectionDiff(
    attachLabelIds: added,
    detachTaskLabelIds: detached,
  );
}

// ---------- 时间展示 ----------

const int _msPerMinute = 60000;
const int _msPerHour = 3600000;
const int _msPerDay = 86400000;

String _two(int n) => n.toString().padLeft(2, '0');

/// 本地时区自然日零点毫秒（表单快捷项 / 日期选择器回填共用归一化）
int dateToMidnightMs(DateTime d) =>
    DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;

/// yyyy-MM-dd（本地时区）
String formatYmd(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}

/// 行右侧截止日期短标签（相对化，TickTick 版式的日期列用）：
/// 今天 / 明天 / 昨天 / 同年 `M月D日` / 跨年 `yyyy年M月D日`。
///
/// 按**本地时区日界**判相对（不做时长差比较——同一天任何时刻都算「今天」，
/// 逾期与否仍由 [isOverdue] 单独判定，两者互不干扰）。
String formatDueLabel(int ms, {DateTime? now}) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  return switch (diff) {
    0 => '今天',
    1 => '明天',
    -1 => '昨天',
    _ => d.year == n.year
        ? '${d.month}月${d.day}日'
        : '${d.year}年${d.month}月${d.day}日',
  };
}

/// yyyy-MM-dd HH:mm（本地时区）
String formatDateTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${formatYmd(ms)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// 过去时间相对展示：<1min 刚刚；<1h N分钟前；<24h N小时前；<7d N天前；否则绝对日期
String formatRelativeTime(int ms) {
  final diff = DateTime.now().millisecondsSinceEpoch - ms;
  if (diff < _msPerMinute) return '刚刚';
  if (diff < _msPerHour) return '${diff ~/ _msPerMinute}分钟前';
  if (diff < _msPerDay) return '${diff ~/ _msPerHour}小时前';
  if (diff < 7 * _msPerDay) return '${diff ~/ _msPerDay}天前';
  return formatYmd(ms);
}

/// 未来时间相对展示：N分钟后 / N小时后 / N天后（提醒行用）；过去时间回落 [formatRelativeTime]
String relativeFromNow(int ms) {
  final diff = DateTime.now().millisecondsSinceEpoch - ms;
  if (diff <= 0) {
    final ahead = -diff;
    if (ahead < _msPerHour) return '${ahead ~/ _msPerMinute}分钟后';
    if (ahead < _msPerDay) return '${ahead ~/ _msPerHour}小时后';
    return '${ahead ~/ _msPerDay}天后';
  }
  return formatRelativeTime(ms);
}

// ---------- 行内提醒徽标（镜像桌面 reminder-meta.ts） ----------

/// 行内提醒展示载荷：一条提醒 + 派生态（[fired] = 已到期且任务未完成）
typedef DisplayReminder = ({int id, String clock, bool fired});

/// HH:mm（本地时区；行内提醒徽标与通知副标题同口径）
String formatHm(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_two(d.hour)}:${_two(d.minute)}';
}

/// 行内提醒选取（镜像桌面 `displayReminder`）：
/// 有未来行取**最近**一条（下一个将响的时刻），全过期取**最早**一条
/// （展示「错过了什么」而非最后一响）；已完成实例不再警示。
///
/// [rows] 来自 `task_reminders_projection`（core 侧已滤软删），此处仍按
/// remind_at 升序兜底排序——契约漂移时不至于选错一条。
DisplayReminder? displayReminder(
  List<ProjectedReminder> rows,
  int nowMs, {
  required bool taskDone,
}) {
  if (rows.isEmpty) return null;
  final sorted = [...rows]..sort((a, b) => a.remindAt.compareTo(b.remindAt));
  final future = sorted.where((r) => r.remindAt > nowMs).toList();
  final pick = future.isNotEmpty ? future.first : sorted.first;
  return (
    id: pick.id,
    clock: formatHm(pick.remindAt),
    fired: !taskDone && pick.remindAt <= nowMs,
  );
}

// ---------- 提醒预设档（相对快捷入口） ----------

/// 提醒预设锚定时刻：9:00（「截止当天 9:00」「今天/明天 9:00」共用，
/// 与 `viewDueHour` 的 18:00 分开——提醒发生在开工时刻，截止在收工时刻）
const int reminderPresetHour = 9;

/// 提醒快捷预设（TickTick 式相对档）。
///
/// 提交口径不变：产物仍是**绝对毫秒时刻**（`todo_reminders.remind_at`），
/// 本函数只负责「少几次滚动」的输入便捷层，零 schema 变更。
///
/// - 有截止日期 → 以截止时刻为基准：截止当天 9:00 / 前推 1 小时·30·15 分钟；
/// - 无截止日期 → 以今天零点为基准：今天 9:00 / 明天 9:00。
///
/// 相同时刻的档位去重（如截止恰好是当天 9:00 时，「截止当天 9:00」与
/// 「截止前 N 分钟」不会重复出现）；已过期的档位**不过滤**——与日期面板
/// 允许选过去时刻同口径，用户可能就是要补记一条。
List<({String label, int ms})> reminderPresets({int? dueDate, DateTime? now}) {
  final n = now ?? DateTime.now();
  final out = <({String label, int ms})>[];
  if (dueDate != null) {
    final due = DateTime.fromMillisecondsSinceEpoch(dueDate);
    out
      ..add((
        label: '截止当天 ${_two(reminderPresetHour)}:00',
        ms: DateTime(due.year, due.month, due.day, reminderPresetHour)
            .millisecondsSinceEpoch,
      ))
      ..add((
        label: '截止前 1 小时',
        ms: dueDate - const Duration(hours: 1).inMilliseconds,
      ))
      ..add((
        label: '截止前 30 分钟',
        ms: dueDate - const Duration(minutes: 30).inMilliseconds,
      ))
      ..add((
        label: '截止前 15 分钟',
        ms: dueDate - const Duration(minutes: 15).inMilliseconds,
      ));
  } else {
    final today = DateTime(n.year, n.month, n.day, reminderPresetHour);
    out
      ..add((
        label: '今天 ${_two(reminderPresetHour)}:00',
        ms: today.millisecondsSinceEpoch,
      ))
      ..add((
        label: '明天 ${_two(reminderPresetHour)}:00',
        ms: today.add(const Duration(days: 1)).millisecondsSinceEpoch,
      ));
  }
  // 同刻去重（保留首个标签——「截止当天 9:00」优先于相对档）
  final seen = <int>{};
  return [
    for (final p in out)
      if (seen.add(p.ms)) p,
  ];
}

// ---------- 派生判定 ----------

/// 逾期：有截止日期、早于今日零点且未完成（日期段标 #F44336）
bool isOverdue(TodoTask task) {
  if (task.dueDate == null || task.isDone) return false;
  final now = DateTime.now();
  final todayStart =
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  return task.dueDate! < todayStart;
}

/// 优先级 0–5 语义色 hex（P0「无」浅灰 #D1D5DB——列表/日历/选择器/统计图全部同色；docs/05 §2.2 priority 板）
String priorityColorHex(int priority) => switch (priority) {
      0 => '#D1D5DB',
      1 => '#6B7280',
      2 => '#3B82F6',
      3 => '#F59E0B',
      4 => '#EF4444',
      5 => '#DC2626',
      _ => '#D1D5DB',
    };

/// 勾选框描边优先级色 hex（列表行优先级着色的唯一入口）：
/// P0「无」返回 null——回落组件默认中性灰描边，无优先级不该产生视觉噪音。
String? priorityRingHex(int priority) =>
    priority <= 0 ? null : priorityColorHex(priority);

/// 优先级 0–5 文案（P0 显"无"）
String priorityLabel(int priority) => switch (priority) {
      1 => '低',
      2 => '中',
      3 => '高',
      4 => '紧急',
      5 => '立即处理',
      _ => '无',
    };

/// 状态语义色 hex（docs/05 §2.2 status 板）
String statusColorHex(String status) => switch (status) {
      'doing' => '#3B82F6',
      'done' => '#22C55E',
      _ => '#6B7280',
    };

/// 状态文案
String statusLabel(String status) => switch (status) {
      'doing' => '进行中',
      'done' => '已完成',
      _ => '待办',
    };

/// 子列表空态文案映射（按入口八种，docs/05 §4.2）
String emptyMessageFor(TaskFilterInput input) {
  if (input.projectId != null) return '该项目暂无任务';
  if (input.ungrouped) return '暂无未分组任务';
  return switch (input.quickView) {
    QuickViewKey.done => '暂无已完成任务',
    QuickViewKey.today => '今天没有截止的任务',
    QuickViewKey.week => '本周没有截止的任务',
    QuickViewKey.favorite => '暂无收藏任务',
    QuickViewKey.nodate => '暂无无日期的任务',
    _ => '暂无任务',
  };
}

// ---------- 视图内新增自动带视图标记（#39，2026-09-09）----------

/// 视图默认截止时刻：18:00（用户口径 2026-09-09 修订；与桌面 atViewDueHour 同源）
const int viewDueHour = 18;

/// 时间戳移到当日 18:00（保留日期、替换时刻；本地时区）
int atViewDueHour(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime(d.year, d.month, d.day, viewDueHour).millisecondsSinceEpoch;
}

/// 本周默认截止：当周周五 18:00；周末（周六/周日）→ 周日 18:00。
/// 周一起始周（与日历网格一致）。与桌面 view-create-defaults.ts 同源。
int weekDefaultDueMs([DateTime? now]) {
  final n = now ?? DateTime.now();
  final zero = DateTime(n.year, n.month, n.day);
  final monday = zero.subtract(Duration(days: (zero.weekday - 1) % 7));
  // 周内（周一~周五）锚当周周五；周末锚周日
  final dayOffset = zero.weekday >= 1 && zero.weekday <= 5 ? 4 : 6;
  return atViewDueHour(
      monday.add(Duration(days: dayOffset)).millisecondsSinceEpoch);
}

/// 视图创建默认值（快捷视图内新建自动带本视图标记，防止任务创建后
/// 不满足过滤条件从当前视图「立刻消失」）。
/// 注入优先级：NLP 显式值（明天/#项目）> 手动选择 > 本视图默认；
/// 仅创建分支生效，编辑态不受影响。
class QuickViewCreateDefaults {
  /// 预填的截止日期（today/week 视图；表单字段可见可改）
  final int? dueMs;

  /// 静默附加的我的一天标记（my_day 视图）
  final int? myDayMs;

  /// 静默附加的收藏标记（favorite 视图）
  final int? favorite;

  const QuickViewCreateDefaults({this.dueMs, this.myDayMs, this.favorite});
}

QuickViewCreateDefaults quickViewCreateDefaults(
  QuickViewKey? view, [
  DateTime? now,
]) {
  if (view == null) return const QuickViewCreateDefaults();
  final n = now ?? DateTime.now();
  final midnight = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
  switch (view) {
    case QuickViewKey.myDay:
      return QuickViewCreateDefaults(myDayMs: midnight);
    case QuickViewKey.today:
      return QuickViewCreateDefaults(dueMs: atViewDueHour(midnight));
    case QuickViewKey.week:
      return QuickViewCreateDefaults(dueMs: weekDefaultDueMs(n));
    case QuickViewKey.favorite:
      return const QuickViewCreateDefaults(favorite: 1);
    default:
      return const QuickViewCreateDefaults();
  }
}

// ---------- 列表内过滤（对齐桌面 task-panel 工具栏三枚筛选） ----------

/// copyWith 的「未传参」哨兵：区分「不修改」与「显式置 null（清除该档）」
const Object _keepFilterValue = Object();

/// 列表内附加过滤档（null = 该维度不限制）
///
/// 与桌面 `task-panel.tsx` 工具栏三枚筛选同口径：
/// - [status]：'pending' | 'doing' | 'done'；
/// - [priorityMin]：优先级下限（>= 该值，桌面为下拉档位）；
/// - [labelId]：命中该标签（需要任务→标签投影辅助判据）。
///
/// 与 `filterTasks` 正交：先按入口/快捷视图筛，再叠加本档。
class TaskListFilters {
  final String? status;
  final int? priorityMin;
  final int? labelId;

  const TaskListFilters({this.status, this.priorityMin, this.labelId});

  static const empty = TaskListFilters();

  bool get isEmpty => status == null && priorityMin == null && labelId == null;

  /// 已启用的过滤维度数（标题栏角标用）
  int get activeCount =>
      (status != null ? 1 : 0) +
      (priorityMin != null ? 1 : 0) +
      (labelId != null ? 1 : 0);

  TaskListFilters copyWith({
    Object? status = _keepFilterValue,
    Object? priorityMin = _keepFilterValue,
    Object? labelId = _keepFilterValue,
  }) =>
      TaskListFilters(
        status:
            identical(status, _keepFilterValue) ? this.status : status as String?,
        priorityMin: identical(priorityMin, _keepFilterValue)
            ? this.priorityMin
            : priorityMin as int?,
        labelId:
            identical(labelId, _keepFilterValue) ? this.labelId : labelId as int?,
      );
}

/// 应用列表内过滤（纯函数；[labelIdsByTask] 为空表时标签档不生效——投影未就绪）
List<TodoTask> applyTaskListFilters(
  List<TodoTask> tasks,
  TaskListFilters filters, {
  Map<int, Set<int>> labelIdsByTask = const {},
}) {
  if (filters.isEmpty) return tasks;
  Iterable<TodoTask> list = tasks;
  final status = filters.status;
  if (status != null) {
    list = list.where((t) => t.status == status);
  }
  final priorityMin = filters.priorityMin;
  if (priorityMin != null) {
    list = list.where((t) => t.priority >= priorityMin);
  }
  final labelId = filters.labelId;
  if (labelId != null) {
    list = list.where((t) => labelIdsByTask[t.id]?.contains(labelId) ?? false);
  }
  return list.toList();
}

/// 任务 → 标签 id 集索引（由桥投影构造；同一任务多标签走并集，不做交集）
Map<int, Set<int>> indexLabelIdsByTask(List<TaskLabelsProjection> rows) => {
      for (final r in rows) r.taskId: {for (final l in r.labels) l.id},
    };

// ---------- 看板分列 ----------

/// 看板单列（按项目/按状态两种维度共用同一渲染单元）
class KanbanColumn {
  /// 稳定键（项目列 = 'p{id}' / 'none'；状态列 = 'pending' 等）
  final String key;
  final String title;

  /// 列头色点（项目列取项目色；状态列取状态语义色；未分组取中性灰）
  final String colorHex;
  final List<TodoTask> tasks;

  const KanbanColumn({
    required this.key,
    required this.title,
    required this.colorHex,
    required this.tasks,
  });
}

/// 看板分列（纯函数）：
/// - 按项目：有任务的项目各一列 + 「未分组」列（无任务的项目不出现，
///   与桌面 kanban-view 同口径——空列在移动端横滑语境下是纯噪音）；
/// - 按状态：固定 pending → doing → done 三列（含空列，状态列本身即语义）。
List<KanbanColumn> groupTasksForKanban(
  List<TodoTask> tasks,
  KanbanGroupBy by,
  List<TodoProject> projects,
) {
  if (by == KanbanGroupBy.status) {
    const order = ['pending', 'doing', 'done'];
    return [
      for (final s in order)
        KanbanColumn(
          key: s,
          title: statusLabel(s),
          colorHex: statusColorHex(s),
          tasks: tasks.where((t) => t.status == s).toList(),
        ),
    ];
  }

  final byProject = <int?, List<TodoTask>>{};
  for (final t in tasks) {
    byProject.putIfAbsent(t.projectId, () => []).add(t);
  }
  final columns = <KanbanColumn>[
    for (final p in projects)
      if (byProject.containsKey(p.id))
        KanbanColumn(
          key: 'p${p.id}',
          title: p.title,
          colorHex: p.hexColor,
          tasks: byProject[p.id]!,
        ),
  ];
  final ungrouped = byProject[null];
  if (ungrouped != null) {
    columns.add(KanbanColumn(
      key: 'none',
      title: '未分组',
      colorHex: '#6B7280',
      tasks: ungrouped,
    ));
  }
  return columns;
}
