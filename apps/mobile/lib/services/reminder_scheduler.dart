import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/api/dto.dart';
import '../data/api/orbit_bridge.dart';
import 'notification_service.dart';
import 'reminder_snooze.dart';

/// 提醒调度协调器（P2 提醒升级：后台闹钟通道的 DB 侧入口）
///
/// 职责：让系统闹钟（NotificationService.syncFutureReminders）与
/// SQLite todo_reminders 表保持收敛：
/// - **启动**：BootGate ready 后 [attachOnce] 首次全量重排；
/// - **增量**：dbChanges 流（Rust EVENT_BUS 转发，含云同步落库）→
///   防抖 2s 重排。任何提醒行的增删（含桌面端续排、推迟、云同步）
///   都会触发，保证闹钟面 = DB 未来集合；
/// - **标题 join**：闹钟通知正文需要任务标题，todo_reminders_list 不含
///   任务列——由注入的 [taskSnapshot] 读单份任务缓存（B6，此前每次重排
///   直拉全量任务，与列表缓存完全重复）；快照不可用（null，缓存未就绪）
///   时回落直拉一次。缓存上限为 taskListPageSize，超出窗口的提醒任务
///   会 join 不到（旧直拉同为有上限口径）。
///
/// 重排幂等（cancelAll + 全量 zonedSchedule），频繁触发只有插件层
/// 开销，无正确性风险。已删任务的提醒行由任务删除级联清掉（orbit-core
/// FK ON DELETE CASCADE + 软删语义），标题 join 不到时正文回退应用名。
///
/// 生命周期：进程级单例（与 BootGate「ready 后常驻」一致）；
/// [shutdown] 仅测试用——widget 测试的 fake_async 环境要求
/// 退出时无 pending Timer（防抖定时器必须可撤销）。
class ReminderScheduler {
  ReminderScheduler._(this._bridge, this._taskSnapshot);

  final OrbitBridge _bridge;

  /// 任务快照读取口（B6）：返回 null 表示缓存未就绪（回落直拉）
  final List<TodoTask>? Function()? _taskSnapshot;

  Timer? _debounce;
  bool _syncing = false;
  bool _attached = false;
  bool _shutdown = false;

  static ReminderScheduler? _instance;

  /// 单例工厂（bridge 与任务快照口注入一次；快照口可缺省=总是直拉）
  static ReminderScheduler attachOnce(
    OrbitBridge bridge, {
    List<TodoTask>? Function()? taskSnapshot,
  }) {
    _instance ??= ReminderScheduler._(bridge, taskSnapshot);
    final s = _instance!;
    if (!s._attached && !s._shutdown) {
      s._attached = true;
      s._rescheduleSoon(); // 启动即全量重排（幂等）
    }
    return s;
  }

  /// dbChanges 转发口（由 BootGate 的唯一 dbChanges 订阅转发——
  /// FRB subscribe_db_changes 是 Rust 侧单播闸设计，第二次 listen
  /// 静默收不到事件，调度器不得自行订阅流）
  void onDbChange() {
    _rescheduleSoon();
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

  /// 回前台补落地（resumed 调用；不跑全量重排）
  ///
  /// 后台点「推迟 N 分钟」后：系统侧多了个更晚的闹钟、DB 里没有对应提醒
  ///（旧行已被引擎到期清理）。若用户切回前台时恰好没有别的 db-change，孤儿
  /// 闹钟就一直没有落地机会，下一次重排的 cancelAll 会把它清掉——必须在这里
  /// 补一次（见 planSnoozeLanding 的孤儿规则）。
  Future<int> landPendingSnoozes() async {
    if (_syncing || _shutdown) return 0;
    try {
      return await _landPendingSnoozes();
    } catch (e, st) {
      debugPrint('[ReminderScheduler] 推迟落地失败: $e\n$st');
      return 0;
    }
  }

  /// 孤儿闹钟落地实现；返回实际写入项数（0 = 无可落地/写入失败）
  Future<int> _landPendingSnoozes({
    Future<List<TodoTask>> Function()? loadTasks,
  }) async {
    final pending = await NotificationService.instance.pendingAlarms();
    if (pending.isEmpty) return 0;
    final reminders = await _bridge.todoReminderList(
      const ListFilter(pageSize: 5000),
    );
    final List<TodoTask> all;
    if (loadTasks != null) {
      all = await loadTasks();
    } else {
      all = _taskSnapshot?.call() ??
          await _bridge.todoTaskList(const ListFilter(pageSize: 5000));
    }
    final activeTaskIds = <int>{
      for (final t in all)
        if (t.isDeleted == 0 && t.done == 0) t.id,
    };
    final plan = planSnoozeLanding(
      pending: pending,
      reminders: reminders,
      activeTaskIds: activeTaskIds,
    );
    if (plan.isEmpty) return 0;
    final landed = await applySnoozeLanding(_bridge, plan);
    debugPrint('[ReminderScheduler] 推迟落地 $landed（${plan.count} 项）');
    return landed ? plan.count : 0;
  }

  /// 立即全量重排（幂等；手动触发口）
  Future<void> rescheduleNow() async {
    if (_syncing || _shutdown) return; // 上一轮未完成：防抖会再触发
    _syncing = true;
    try {
      var rows = await _bridge.todoReminderList(
        const ListFilter(pageSize: 5000),
      );
      // 任务快照：推迟落地（孤儿闹钟的「任务存活未完成」校验）与标题 join 共用。
      // B6：优先读单份任务缓存；null（未就绪）回落直拉一次——故做成懒加载，
      // 两条支路各自触发一次即可
      List<TodoTask>? tasks;
      Future<List<TodoTask>> loadTasks() async =>
          tasks ??= _taskSnapshot?.call() ??
              await _bridge.todoTaskList(const ListFilter(pageSize: 5000));

      // 后台推迟补齐。**必须在下面的 cancelAll 重排之前**：推迟意图只存在于
      // 系统侧（App 不在前台时 action 由后台 isolate 回调，写不了 DB），DB 里的
      // 旧行又已被引擎「到期即清理」删掉——不先落成 DB 事实，紧随的 cancelAll
      // 会把推迟闹钟一并清掉，提醒彻底丢失（2026-09-20「点推迟后提醒消失」）
      if (await _landPendingSnoozes(loadTasks: loadTasks) > 0) {
        rows = await _bridge.todoReminderList(
          const ListFilter(pageSize: 5000),
        );
      }
      final enriched = <TodoReminder>[];
      if (rows.isNotEmpty) {
        // join 任务标题（闹钟正文/推迟 payload 自包含），并过滤不该再
        // 闹的行：任务已删（软删残留行——级联清理由轮询守护兜底）或
        // 已完成（P1#10 语义：完成实例不再续排/提醒）
        final all = await loadTasks();
        final taskById = <int, TodoTask>{};
        for (final t in all) {
          taskById[t.id] = t;
        }
        for (final r in rows) {
          if (r.isDeleted != 0) continue;
          final task = taskById[r.taskId];
          if (task == null || task.isDeleted != 0 || task.done != 0) continue;
          enriched.add(r.withTitle(task.title));
        }
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
