import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/api/dto.dart';
import '../data/api/orbit_bridge.dart';
import 'notification_service.dart';

/// 提醒调度协调器（P2 提醒升级：后台闹钟通道的 DB 侧入口）
///
/// 职责：让系统闹钟（NotificationService.syncFutureReminders）与
/// SQLite todo_reminders 表保持收敛：
/// - **启动**：BootGate ready 后 [attachOnce] 首次全量重排；
/// - **增量**：dbChanges 流（Rust EVENT_BUS 转发，含云同步落库）→
///   防抖 2s 重排。任何提醒行的增删（含桌面端续排、推迟、云同步）
///   都会触发，保证闹钟面 = DB 未来集合；
/// - **标题 join**：闹钟通知正文需要任务标题，todo_reminders_list 不含
///   任务列——拉全量任务 join（一次性 map，数据量 MVP 级可接受）。
///
/// 重排幂等（cancelAll + 全量 zonedSchedule），频繁触发只有插件层
/// 开销，无正确性风险。已删任务的提醒行由任务删除级联清掉（orbit-core
/// FK ON DELETE CASCADE + 软删语义），标题 join 不到时正文回退应用名。
///
/// 生命周期：进程级单例（与 BootGate「ready 后常驻」一致）；
/// [shutdown] 仅测试用——widget 测试的 fake_async 环境要求
/// 退出时无 pending Timer（防抖定时器必须可撤销）。
class ReminderScheduler {
  ReminderScheduler._(this._bridge);

  final OrbitBridge _bridge;

  Timer? _debounce;
  bool _syncing = false;
  bool _attached = false;
  bool _shutdown = false;

  static ReminderScheduler? _instance;

  /// 单例工厂（bridge 注入一次）
  static ReminderScheduler attachOnce(OrbitBridge bridge) {
    _instance ??= ReminderScheduler._(bridge);
    final s = _instance!;
    s._attach(bridge);
    return s;
  }

  void _attach(OrbitBridge bridge) {
    if (_attached || _shutdown) return;
    _attached = true;
    _rescheduleSoon(); // 启动即全量重排（幂等）
    // dbChanges：本地写 + 云同步 pull 落库都广播（bridge 侧已合并）
    bridge.dbChanges.listen((_) => _rescheduleSoon());
  }

  /// 防抖重排：2s 窗口内多次变更合并一次全量重排
  void _rescheduleSoon() {
    if (_shutdown) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => rescheduleNow());
  }

  /// 测试清理口：取消防抖定时器（fake_async 断言无 pending Timer）。
  /// 生产进程不调用——单例与进程同生命周期。
  static void shutdown() {
    _instance?._shutdown = true;
    _instance?._debounce?.cancel();
    _instance = null;
  }

  /// 立即全量重排（幂等；手动触发口）
  Future<void> rescheduleNow() async {
    if (_syncing || _shutdown) return; // 上一轮未完成：防抖会再触发
    _syncing = true;
    try {
      final reminders = await _bridge.todoReminderList(
        const ListFilter(pageSize: 5000),
      );
      final enriched = <TodoReminder>[];
      if (reminders.isNotEmpty) {
        // join 任务标题（闹钟正文/推迟 payload 自包含）
        final tasks =
            await _bridge.todoTaskList(const ListFilter(pageSize: 5000));
        final titleById = <int, String>{};
        for (final t in tasks) {
          titleById[t.id] = t.title;
        }
        enriched.addAll([
          for (final r in reminders) r.withTitle(titleById[r.taskId]),
        ]);
      }
      final n =
          await NotificationService.instance.syncFutureReminders(enriched);
      debugPrint('[ReminderScheduler] 闹钟重排 $n 条');
    } catch (e, st) {
      debugPrint('[ReminderScheduler] 重排失败: $e\n$st');
    } finally {
      _syncing = false;
    }
  }
}
