import 'package:flutter/material.dart';

import '../../../data/api/dto.dart';
import 'task_logic.dart' show viewDueHour;
import 'undo_stack.dart';
import '../../../core/theme/icon_map.dart';

/// 批量动作（对齐桌面 `shared/batch-actions.ts` 的动作集裁剪版）
///
/// 裁剪说明：桌面批量工具条含「移入进行中 / 移回待办 / 设置优先级 /
/// 批量改期 / 移动到项目 / 加入我的一天 / 收藏 / 删除」共 8 类。移动端
/// 一屏底部工具条放不下，故收敛为 6 个一级动作 + 参数型动作各自开抽屉：
/// 完成态切换（完成/取消完成视选中集当前态二选一）、优先级、改期、
/// 移项目、加标签、删除。
enum BatchAction { toggleDone, priority, reschedule, moveProject, addLabel, delete }

/// 批量工具条动作元数据（图标 + 文案）
extension BatchActionMeta on BatchAction {
  String get label => switch (this) {
        BatchAction.toggleDone => '完成',
        BatchAction.priority => '优先级',
        BatchAction.reschedule => '改期',
        BatchAction.moveProject => '移项目',
        BatchAction.addLabel => '加标签',
        BatchAction.delete => '删除',
      };

  IconData get icon => switch (this) {
        BatchAction.toggleDone => OrbitIcons.success,
        BatchAction.priority => OrbitIcons.flag,
        BatchAction.reschedule => OrbitIcons.calendar,
        BatchAction.moveProject => OrbitIcons.folder,
        BatchAction.addLabel => OrbitIcons.tag,
        BatchAction.delete => OrbitIcons.delete,
      };
}

/// 改期快捷档（对齐桌面 batch-actions 的批量改期档位）
enum BatchReschedule { today, tomorrow, nextWeek, clear }

extension BatchRescheduleMeta on BatchReschedule {
  String get label => switch (this) {
        BatchReschedule.today => '今天',
        BatchReschedule.tomorrow => '明天',
        BatchReschedule.nextWeek => '下周',
        BatchReschedule.clear => '清除截止',
      };
}

/// 批量完成态目标：选中集里只要还有未完成的就统一置完成，否则统一取消完成
/// （桌面同语义：按钮文案随选中集状态派生）
bool batchToggleDoneTarget(Iterable<TodoTask> selected) =>
    selected.any((t) => !t.isDone);

/// 批量完成的字段补丁（含 done_at / status 联动，口径同 `buildDoneTogglePatch`）
Map<String, Object?>? batchDonePatch(TodoTask task, {required bool done}) {
  if (done == task.isDone) return null;
  if (done) {
    return {
      'done': 1,
      'done_at': DateTime.now().millisecondsSinceEpoch,
      'status': 'done',
    };
  }
  return {'done': 0, 'done_at': null, 'status': 'pending'};
}

/// 单任务在某批量动作下的字段补丁；返回 null = 该任务无需变更
///（值已相同则跳过，避免无意义写库与事件风暴）
Map<String, Object?>? batchFieldPatch(
  TodoTask task, {
  required BatchAction action,
  int? priority,
  int? dueMs,
  int? projectId,
}) {
  switch (action) {
    case BatchAction.priority:
      if (priority == null || task.priority == priority) return null;
      return {'priority': priority};
    case BatchAction.reschedule:
      if (dueMs == null) return null;
      final same = dueMs == 0
          ? task.dueDate == null
          : task.dueDate != null && _sameDay(task.dueDate!, dueMs);
      if (same) return null;
      return {'due_date': dueMs == 0 ? null : dueMs};
    case BatchAction.moveProject:
      if (task.projectId == projectId) return null;
      return {'project_id': projectId};
    case BatchAction.toggleDone:
    case BatchAction.addLabel:
    case BatchAction.delete:
      return null;
  }
}

/// 反向补丁：把任务回滚到当前快照（撤销用）
UndoTaskPatch inversePatchOf(TodoTask task, Map<String, Object?> patch) {
  final inverse = <String, Object?>{};
  for (final key in patch.keys) {
    inverse[key] = switch (key) {
      'priority' => task.priority,
      'due_date' => task.dueDate,
      'project_id' => task.projectId,
      'done' => task.done,
      'done_at' => task.doneAt,
      'status' => task.status,
      'is_favorite' => task.isFavorite,
      'my_day_date' => task.myDayDate,
      _ => null,
    };
  }
  return UndoTaskPatch(taskId: task.id, patch: inverse);
}

bool _sameDay(int a, int b) {
  final da = DateTime.fromMillisecondsSinceEpoch(a);
  final db = DateTime.fromMillisecondsSinceEpoch(b);
  return da.year == db.year && da.month == db.month && da.day == db.day;
}

/// 改期档 → 目标时间戳（0 = 清除；本地时区自然日）
int batchRescheduleMs(BatchReschedule choice, [DateTime? now]) {
  if (choice == BatchReschedule.clear) return 0;
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final target = switch (choice) {
    BatchReschedule.today => today,
    BatchReschedule.tomorrow => today.add(const Duration(days: 1)),
    // 下周 = 下周一（周一起始周，与日历网格一致）
    BatchReschedule.nextWeek =>
      today.add(Duration(days: 8 - today.weekday)),
    BatchReschedule.clear => today,
  };
  // 与单条改期同口径：落在当日 18:00（viewDueHour），避免批量改期后
  // 显得"还没到期就标红"
  return DateTime(target.year, target.month, target.day, viewDueHour)
      .millisecondsSinceEpoch;
}

/// 批量动作的浮层文案
String batchUndoLabel(BatchAction action, int count) => switch (action) {
      BatchAction.delete => '已删除 $count 个任务',
      BatchAction.toggleDone => '已更新 $count 个任务的完成状态',
      BatchAction.priority => '已调整 $count 个任务的优先级',
      BatchAction.reschedule => '已调整 $count 个任务的截止时间',
      BatchAction.moveProject => '已移动 $count 个任务',
      BatchAction.addLabel => '已为 $count 个任务加标签',
    };
