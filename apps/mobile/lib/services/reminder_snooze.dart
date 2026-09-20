/// 提醒「推迟」动作的 DB 落地
///
/// 引擎口径（orbit-core `todo_api::advance_fired_reminder`）：提醒到期后
/// **非重复任务的行只清理不续排（软删）、重复任务删旧建新**——与桌面端
/// 「snooze = 软删旧行 + 新建推迟时刻行」（reminder-snooze.ts）同一语义。
///
/// 移动端推迟通道历史上只重排系统闹钟、不写 DB（后台 isolate 无法重入 FRB
/// 库，见 notification_service 模块注释），于是必然踩两个坑：
/// 1. 到期行被引擎清理 → 任务里的提醒凭空消失（用户报「点推迟后提醒被删」）；
/// 2. db-change 触发的全量重排（`cancelAllPendingNotifications` + 按 DB 排）
///    会把刚排上的推迟闹钟一起清掉——DB 里根本没有这条未来提醒 → 推迟失效。
///
/// 本文件把「推迟」落成 DB 事实：软删旧时刻行（若还在）+ 新建推迟时刻行；
/// 之后任何一次重排都以 DB 为准，提醒面与闹钟面自然收敛。
///
/// 两条落地路径：
/// - **前台**（进程存活，[NotificationService.onSnoozeAction]）：点推迟即写库；
/// - **启动补齐**（[ReminderScheduler] 重排前）：后台 isolate 推迟留下的
///   「系统闹钟比 DB 行更晚」状态，由 [planSnoozeLanding] 算计划后写库。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/api/dto.dart';
import '../data/api/orbit_bridge.dart';

/// 系统侧待触发闹钟（插件 pending 解析结果；确认/完成通知域由读取方过滤）
@immutable
class PendingAlarm {
  const PendingAlarm({required this.taskId, required this.remindAt});

  final int taskId;
  final int remindAt;
}

/// 启动补齐计划：软删的旧行 id + 待新建的（taskId → 新时刻）
@immutable
class SnoozeLanding {
  const SnoozeLanding({required this.deleteIds, required this.creates});

  final List<int> deleteIds;
  final List<({int taskId, int remindAt})> creates;

  bool get isEmpty => deleteIds.isEmpty && creates.isEmpty;

  int get count => deleteIds.length + creates.length;
}

/// 计算启动补齐计划（纯函数，可单测）
///
/// 规则（保守优先：宁可不动，也不凭空造出用户已删的提醒）：
/// - 闹钟时刻 `at` 晚于该任务最新一条未删提醒 → 判为后台推迟产物：
///   删该旧行 + 新建 `at` 行；
/// - 已有 `remind_at == at` 的行 → 已落地，不动；
/// - 所有行都比 `at` 晚 → 异常态，交给重排的 cancelAll 收敛，不动 DB；
/// - 同一任务多个闹钟只落地一次（新的那个）；
/// - **孤儿闹钟**（该任务一条提醒行都没有，[activeTaskIds] 非空时才启用）：
///   DB 旧行已被引擎「到期即清理」删掉、后台 isolate 又写不了库——这是最常见
///   的后台推迟形态。仅当任务存活且未完成、且 `at` 落在 `(now, now+窗口]`
///   内才补建（窗口默认 24h，覆盖三档推迟 + 补扫）；其余视为用户删提醒后的
///   残留闹钟，交给 cancelAll 清掉，不复活。
SnoozeLanding planSnoozeLanding({
  required List<PendingAlarm> pending,
  required List<TodoReminder> reminders,
  Set<int>? activeTaskIds,
  int? nowMs,
  Duration orphanWindow = const Duration(hours: 24),
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final byTask = <int, List<TodoReminder>>{};
  for (final r in reminders) {
    if (r.isDeleted != 0) continue;
    byTask.putIfAbsent(r.taskId, () => <TodoReminder>[]).add(r);
  }

  final deleteIds = <int>[];
  final creates = <({int taskId, int remindAt})>[];
  final handled = <int>{};

  for (final p in pending) {
    if (!handled.add(p.taskId)) continue;
    final rows = byTask[p.taskId];
    if (rows == null || rows.isEmpty) {
      // 孤儿闹钟 → 后台推迟产物（仅 activeTaskIds 非空时启用）
      if (activeTaskIds == null || !activeTaskIds.contains(p.taskId)) continue;
      if (p.remindAt <= now ||
          p.remindAt > now + orphanWindow.inMilliseconds) {
        continue;
      }
      creates.add((taskId: p.taskId, remindAt: p.remindAt));
      continue;
    }
    if (rows.any((r) => r.remindAt == p.remindAt)) continue;
    final older = rows.where((r) => r.remindAt < p.remindAt).toList()
      ..sort((a, b) => b.remindAt.compareTo(a.remindAt));
    if (older.isEmpty) continue;
    // 只推进最新的一条旧行；更早的历史行由引擎到期清理兜底
    deleteIds.add(older.first.id);
    creates.add((taskId: p.taskId, remindAt: p.remindAt));
  }
  return SnoozeLanding(deleteIds: deleteIds, creates: creates);
}

/// 前台推迟落地：软删「触发这条通知的那一行」（`remind_at` 与通知 payload
/// 精确同刻），再新建 `nextAt` 行——对齐引擎 snooze 的删旧建新。
///
/// 只碰同刻行是有意为之：引擎可能已为重复任务续排了下一实例行、
/// 用户也可能手排了其他提醒，都不该被这次推迟顺手清掉。
///
/// 桥调用逐条 try/catch：任一步失败都不阻断推迟本身——系统闹钟已在侧，
/// 用户至少会收到下一次提醒；DB 面由下次启动的补齐/引擎清理收敛。
Future<void> landSnoozeInDb(
  OrbitBridge bridge, {
  required int taskId,
  required int fromRemindAt,
  required int nextAt,
}) async {
  // 推迟时刻已成过去（用户很久没回前台，闹钟早响过）：丢弃该意图——
  // 补建一条过去时刻的行只会被引擎立刻消费并再弹一次
  if (nextAt <= DateTime.now().millisecondsSinceEpoch) return;
  List<TodoReminder> rows;
  try {
    rows = await bridge.todoReminderList(const ListFilter(pageSize: 5000));
  } catch (_) {
    rows = const <TodoReminder>[];
  }
  // 同刻行已存在（连点两次推迟）：幂等跳过，避免堆两条
  if (rows.any((r) =>
      r.isDeleted == 0 && r.taskId == taskId && r.remindAt == nextAt)) {
    return;
  }
  for (final r in rows) {
    if (r.isDeleted != 0 || r.taskId != taskId) continue;
    if (r.remindAt != fromRemindAt) continue;
    try {
      await bridge.todoReminderDelete(r.id);
    } catch (_) {}
  }
  try {
    await bridge.todoReminderCreate(
      TodoReminderCreateInput(taskId: taskId, remindAt: nextAt),
    );
  } catch (_) {}
}

/// 暂存的一条推迟意图
@immutable
class SnoozeIntent {
  const SnoozeIntent({
    required this.taskId,
    required this.fromRemindAt,
    required this.nextAt,
  });

  final int taskId;
  final int fromRemindAt;
  final int nextAt;
}

/// 后台推迟暂存文件（JSON Lines，一行一条）
///
/// 为什么必须落文件：通知 action 在 App **不在前台**时由
/// `onDidReceiveBackgroundNotificationResponse` 在**独立后台 isolate** 里回调
/// （见 ADR 0002 §三）——那里既不能重入 FRB 库，也看不到主 isolate 里注入的
/// `NotificationService.onSnoozeAction`（静态字段不跨 isolate 共享）。于是
/// 「点推迟 → 提醒消失」在 App 退到后台时依旧复现。
///
/// dart:io 不依赖插件注册，后台 isolate 可写；App 下次启动（BootGate ready）
/// 先 [drain] 写回 DB 再挂调度器，才不会被首次全量重排（cancelAll）清掉。
/// 存 `Directory.systemTemp`（App cache）：被系统清理只意味着退回旧行为
/// （推迟丢失），不影响正常流程。
class SnoozeSpool {
  SnoozeSpool._();

  static File get file =>
      File('${Directory.systemTemp.path}/orbit_snooze_pending.jsonl');

  /// 追加一条推迟记录（失败静默：绝不阻断推迟本身）
  static Future<void> append({
    required int taskId,
    required int fromRemindAt,
    required int nextAt,
  }) async {
    try {
      await file.writeAsString(
        '${jsonEncode({
              'task_id': taskId,
              'from': fromRemindAt,
              'next': nextAt,
            })}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// 取出全部记录并清空文件（脏行忽略；失败返回已读到的部分）
  static Future<List<SnoozeIntent>> drain() async {
    final out = <SnoozeIntent>[];
    try {
      if (!await file.exists()) return out;
      final lines = await file.readAsLines();
      await file.delete();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final j = jsonDecode(line) as Map<String, dynamic>;
          out.add(SnoozeIntent(
            taskId: (j['task_id'] as num).toInt(),
            fromRemindAt: (j['from'] as num).toInt(),
            nextAt: (j['next'] as num).toInt(),
          ));
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }
}

/// 执行启动补齐计划；返回是否确有写入（调用方据此决定要不要重读提醒表）
Future<bool> applySnoozeLanding(OrbitBridge bridge, SnoozeLanding plan) async {
  if (plan.isEmpty) return false;
  var changed = false;
  for (final id in plan.deleteIds) {
    try {
      await bridge.todoReminderDelete(id);
      changed = true;
    } catch (_) {}
  }
  for (final c in plan.creates) {
    try {
      await bridge.todoReminderCreate(
        TodoReminderCreateInput(taskId: c.taskId, remindAt: c.remindAt),
      );
      changed = true;
    } catch (_) {}
  }
  return changed;
}
