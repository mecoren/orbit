import 'package:flutter/material.dart';

import '../../../data/api/dto.dart';
import 'task_logic.dart' show viewDueHour, buildStatusPatch;
import 'undo_stack.dart';
import '../../../core/theme/icon_map.dart';

/// 批量动作（对齐桌面 `shared/batch-actions.ts` 的动作集）
///
/// 桌面批量工具条的动作全集：完成态切换（完成/未完成）、状态推进
/// （移入进行中/移回待办）、设置优先级、批量改期、移动到项目、
/// 加入我的一天、收藏/取消收藏、删除；移动端另保留「加标签」
///（桌面批量无此项的移动便利入口）。一级动作横排 + 横向滚动，
/// 参数型动作各自开抽屉；双向动作（完成/状态/我的一天/收藏）的目标值
/// 一律从选中集当前态派生（batchXxxTarget 系列），按钮文案保持短中性。
enum BatchAction {
  toggleDone,
  status,
  myDay,
  favorite,
  priority,
  reschedule,
  moveProject,
  addLabel,
  delete,
}

/// 批量工具条动作元数据（图标 + 文案）
extension BatchActionMeta on BatchAction {
  String get label => switch (this) {
        BatchAction.toggleDone => '完成',
        BatchAction.status => '状态',
        BatchAction.myDay => '我的一天',
        BatchAction.favorite => '收藏',
        BatchAction.priority => '优先级',
        BatchAction.reschedule => '改期',
        BatchAction.moveProject => '移项目',
        BatchAction.addLabel => '加标签',
        BatchAction.delete => '删除',
      };

  IconData get icon => switch (this) {
        BatchAction.toggleDone => OrbitIcons.success,
        BatchAction.status => OrbitIcons.playCircle,
        BatchAction.myDay => OrbitIcons.sun,
        BatchAction.favorite => OrbitIcons.star,
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

/// 批量状态推进目标：选中集里只要还有未完成的就推进到「进行中」，
/// 全为已完成则「移回待办」（桌面工具条动态文案同语义）
bool batchStatusToDoingTarget(Iterable<TodoTask> selected) =>
    selected.any((t) => !t.isDone);

/// 批量我的一天目标：全都在今天 → 移出；否则加入（桌面只给「加入」单向，
/// 移动按双向动作组口径派生，避免全选中集已在今天时的空操作）
bool batchMyDayJoinTarget(Iterable<TodoTask> selected) =>
    !selected.every((t) => t.isInMyDay);

/// 批量收藏目标：全都已收藏 → 取消收藏；否则收藏
bool batchFavoriteTarget(Iterable<TodoTask> selected) =>
    !selected.every((t) => t.isStarred);

/// 批量「我的一天」目标毫秒：加入 = 今天本地零点（桌面 batchUpdateMyDay
/// 同口径，视图按日判断）；移出 = 0（调用方约定，与改期档 clear 同）
int batchMyDayMs(bool join, [DateTime? now]) {
  if (!join) return 0;
  final n = now ?? DateTime.now();
  return DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
}

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
  int? myDayMs,
  bool? favorite,
  bool? statusToDoing,
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
    case BatchAction.myDay:
      if (myDayMs == null) return null;
      // 0 = 移出（已不在今天则跳过）；加入时已是今天的也跳过——
      // 昨天遗留的 my_day_date 不等于今天零点，仍会改写到今天
      if (myDayMs == 0) {
        return task.myDayDate == null ? null : {'my_day_date': null};
      }
      return task.isInMyDay ? null : {'my_day_date': myDayMs};
    case BatchAction.favorite:
      if (favorite == null || task.isStarred == favorite) return null;
      return {'is_favorite': favorite ? 1 : 0};
    case BatchAction.status:
      if (statusToDoing == null) return null;
      final target = statusToDoing ? 'doing' : 'pending';
      // 已完成任务不因「移入进行中」被取消完成（移回待办才是显式取消）
      if (statusToDoing && task.isDone) return null;
      if (task.status == target && !task.isDone) return null;
      // 三段切换联动 done/done_at（同 buildStatusPatch，单任务口径）
      return buildStatusPatch(target);
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

/// 批量动作的浮层文案；[toward] 仅双向动作（状态/我的一天/收藏）需要——
/// true = 正向（进行中/加入/收藏），false = 反向，null 落反向措辞
String batchUndoLabel(BatchAction action, int count, {bool? toward}) =>
    switch (action) {
      BatchAction.delete => '已删除 $count 个任务',
      BatchAction.toggleDone => '已更新 $count 个任务的完成状态',
      BatchAction.status => toward == true
          ? '已推进 $count 个任务到进行中'
          : '已将 $count 个任务移回待办',
      BatchAction.myDay => toward == true
          ? '已将 $count 个任务加入我的一天'
          : '已将 $count 个任务移出我的一天',
      BatchAction.favorite => toward == true
          ? '已收藏 $count 个任务'
          : '已取消收藏 $count 个任务',
      BatchAction.priority => '已调整 $count 个任务的优先级',
      BatchAction.reschedule => '已调整 $count 个任务的截止时间',
      BatchAction.moveProject => '已移动 $count 个任务',
      BatchAction.addLabel => '已为 $count 个任务加标签',
    };
