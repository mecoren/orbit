import 'package:flutter/material.dart';

import '../../../data/api/dto.dart';

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
        QuickViewKey.myDay => Icons.wb_sunny_rounded,
        QuickViewKey.today => Icons.calendar_today_rounded,
        QuickViewKey.week => Icons.date_range_rounded,
        QuickViewKey.all => Icons.list_alt_rounded,
        QuickViewKey.done => Icons.check_circle_outline_rounded,
        QuickViewKey.favorite => Icons.star_border_rounded,
        QuickViewKey.nodate => Icons.event_busy_rounded,
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

/// 按输入过滤任务（互斥语义见 [TaskFilterInput]；时间窗口为本地时区自然日）
List<TodoTask> filterTasks(List<TodoTask> tasks, TaskFilterInput input) {
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
  return list.toList();
}

/// 排序固定：position 升序 → created_at 降序（同 position 新任务在前）。
/// 返回新列表，不改入参。
List<TodoTask> sortTasks(List<TodoTask> tasks) {
  final sorted = [...tasks]..sort((a, b) {
      if (a.position != b.position) return a.position.compareTo(b.position);
      return b.createdAt.compareTo(a.createdAt);
    });
  return sorted;
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

// ---------- 派生判定 ----------

/// 逾期：有截止日期、早于今日零点且未完成（日期段标 #F44336）
bool isOverdue(TodoTask task) {
  if (task.dueDate == null || task.isDone) return false;
  final now = DateTime.now();
  final todayStart =
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  return task.dueDate! < todayStart;
}

/// 优先级 0–5 语义色 hex（index 0 = 无优先级不显色点；docs/05 §2.2 priority 板）
String priorityColorHex(int priority) => switch (priority) {
      1 => '#6B7280',
      2 => '#3B82F6',
      3 => '#F59E0B',
      4 => '#EF4444',
      5 => '#DC2626',
      _ => '',
    };

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
