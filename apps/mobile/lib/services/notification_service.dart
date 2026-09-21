import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/api/dto.dart';
import '../data/api/orbit_bridge.dart';
import '../shared/widgets/shadcn/orbit_toast.dart';
import 'reminder_snooze.dart';

/// 本地通知服务（Phase 7 平台集成；P2 提醒升级全面改版）
///
/// 三通道协同（ADR 0002 α→β 演进，触发条件即 docs/adr/0002 §六的
/// 「后台停摆问题必须解决」）：
///
/// 1. **前台即时通道**（原状保留）：Rust 20s 轮询 reminderDue 事件到达
///    → [handleReminderDue] 直接 show()。前台通知文案实时、含任务标题。
/// 2. **后台闹钟通道**（新增）：[syncFutureReminders] 把全部未来提醒
///    重排进系统闹钟（zonedSchedule + alarmClock 模式）。闹钟由系统
///    AlarmManager 持有：应用退后台/被杀/Doze 均准时触发；重启后由
///    插件 ScheduledNotificationBootReceiver 自动恢复（manifest 已声明
///    BOOT_COMPLETED）。到点通知由原生 Receiver 直接构建展示——
///    不依赖 Dart 进程存活，彻底解决「后台不提醒」。
/// 3. **推迟操作通道**（新增）：通知上的「推迟 10 分钟/30 分钟/1 小时」
///    action 按钮。payload 携带 taskId|remindAt|title，点击唤醒
///    [onSnoozeBackgroundAction]（后台 isolate，应用被杀也可达）——
///    **不写 Rust DB**（后台 isolate 无法重入 FRB 库）：只重排一条新
///    系统闹钟 + 静默确认通知；DB 的删旧建新由前台启动时
///    [syncFutureReminders] 以数据库为准收敛（DB 旧行到期弹一次后
///    自动清掉，不循环——见 _applySnooze 的 remindAt 比较）。
/// 4. **完成操作通道**（B5，2026-09-09）：通知上的「完成」action 按钮
///    （首位）。前台（进程存活）经 [onCompleteAction] 回调直调桥
///    todoTaskComplete（dbChanges 自然失效缓存+重排闹钟）；后台
///    （进程被杀）与推迟同构——不写 Rust DB，只 cancel 原通知 +
///    静默渠道确认横幅「已标记完成，打开应用后生效」，DB 落地由用户
///    打开应用后自然完成（下次重排时任务已完成则引擎已软删提醒行）。
///
/// 小米 HyperOS 灵动岛（焦点通知）：category=alarm + Importance.high
/// 渠道。小米焦点通知对闹钟/来电类高优通知以灵动岛胶囊呈现，
/// 依据 docs/adr/0002 §五真机验收项「灵动岛形态」。
///
/// 时区：zonedSchedule 需要 tz.TZDateTime；[ensureInitialized] 初始化
/// 本地时区，后台 isolate 入口也各自兜底（tz 库默认 UTC）。
///
/// AOT 可达性注记（实测教训 2026-09-06）：onSnoozeBackgroundAction 经
/// native 入口可达，其调用链上的实例方法（_handleSnoozeResponse 等）
/// 也必须被树摇保留——@pragma('vm:entry-point') 加在**类**上才能覆盖
/// 实例成员；只标静态方法时 AOT 抛 "To access ... from native code,
/// it must be annotated"。
@pragma('vm:entry-point')
class NotificationService {
  NotificationService._();

  /// 全局单例（BootGate ready 时触发初始化，事件流回调消费）
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _granted = false;

  static const _channelId = 'todo_reminder_due';
  static const _channelName = '待办提醒';

  /// 推迟 actionId → 分钟数（前后台回调共用解析）
  static const snoozeActions = {'snooze_10': 10, 'snooze_30': 30, 'snooze_60': 60};

  /// 完成 actionId 集合（B5；与推迟集合互斥，前后台回调共用解析）
  static const completeActions = {'complete'};

  /// 通知 id 派生：taskId 域 + 偏移避撞（taskId 正常 ≤ 位数充足；
  /// % 2^30 后加偏移确保 32 位域内且与确认通知 id 不重叠）。
  /// 公开静态供测试锁定口径（B5：三段互斥域）。
  static int alarmIdFor(int taskId) => (taskId % (1 << 30)) + 1;
  static int confirmIdFor(int taskId) => (taskId % (1 << 30)) + 1000000000;

  /// 完成（后台路径）确认横幅 id：确认域再 +500000000，与闹钟/确认域互斥
  static int pendingCompleteIdFor(int taskId) =>
      (taskId % (1 << 30)) + 1000000000 + 500000000;

  /// 权限是否已授予（未初始化 / 被拒均为 false）
  bool get hasPermission => _granted;

  // ── 推迟回调（前台 + 后台 isolate 双入口）──

  /// 后台 isolate 通知 action 回调（top-level @pragma 防 AOT 裁剪）。
  /// payload "taskId|remindAt|title"；统一分发：snooze / complete 二路。
  @pragma('vm:entry-point')
  static void onBackgroundAction(NotificationResponse response) {
    runZonedGuarded(
      () => instance._handleBackgroundAction(response),
      (e, st) => debugPrint('[NotificationService] bg action: $e\n$st'),
    );
  }

  /// 后台 action 分发体：推迟 → 重排闹钟；完成 → cancel 原通知 + 确认横幅
  Future<void> _handleBackgroundAction(NotificationResponse response) async {
    if (snoozeActions.containsKey(response.actionId)) {
      await _handleSnoozeResponse(response);
      return;
    }
    if (completeActions.contains(response.actionId)) {
      await _handleCompleteResponse(response);
    }
  }

  /// 前台收到通知交互（onDidReceiveNotificationResponse）：
  /// - 推迟 action：逻辑与后台回调完全一致（重排闹钟 + 确认通知）
  /// - 正文点击（actionId 空）：autoCancel 已消掉通知，回调 [onNotificationTap]
  ///   跳任务详情（未注入回调时静默——后台 isolate 初始化路径无 UI 上下文）
  void _onForegroundResponse(NotificationResponse response) {
    final minutes = snoozeActions[response.actionId];
    if (minutes != null) {
      runZonedGuarded(
        () => instance._handleSnoozeResponse(response),
        (e, st) => debugPrint('[NotificationService] fg snooze: $e\n$st'),
      );
      return;
    }
    // B5 完成 action：前台进程活着 → 回调直完（BootGate 注入桥调用）
    if (completeActions.contains(response.actionId)) {
      final completeTaskId = taskIdFromPayload(response.payload);
      if (completeTaskId != null) {
        runZonedGuarded(
          () async {
            await _plugin.cancel(id: alarmIdFor(completeTaskId));
            await onCompleteAction?.call(completeTaskId);
          },
          (e, st) => debugPrint('[NotificationService] fg complete: $e\n$st'),
        );
      }
      return;
    }
    final taskId = taskIdFromPayload(response.payload);
    if (taskId != null && onNotificationTap != null) {
      runZonedGuarded(
        () => onNotificationTap!(taskId),
        (e, st) => debugPrint('[NotificationService] fg tap: $e\n$st'),
      );
    }
  }

  /// payload "taskId|remindAt|title" → taskId；解析失败返回 null。
  /// 公开静态供测试复现口径（前台/冷启动两路点击共用）。
  static int? taskIdFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    return int.tryParse(payload.split('|')[0]);
  }

  /// 通知正文点击回调（taskId → 跳任务详情）。
  /// 由 UI 层（BootGate）注入：服务层不持有路由/context。
  /// 注意仅前台有效——冷启动（应用被杀后点通知拉起）点击不经过
  /// onDidReceiveNotificationResponse，走 [consumeLaunchPayload]。
  static Future<void> Function(int taskId)? onNotificationTap;

  /// 通知「完成」action 回调（B5）：前台进程存活时经此直调桥完成任务。
  /// 由 UI 层（BootGate）注入（与 onNotificationTap 同构：服务层不持桥）。
  /// 后台 isolate 不可达（FRB 不可重入）——后台路径只做 UI 层处置。
  static Future<void> Function(int taskId)? onCompleteAction;

  /// 通知「推迟 N 分钟」action 回调：前台进程存活时把推迟落成 DB 事实
  /// （软删旧行 + 新建新时刻行，见 reminder_snooze.dart）。
  ///
  /// 为什么必须落库：引擎到期处置（advance_fired_reminder）会把非重复任务的
  /// 提醒行软删；不落库时「提醒行没了 + DB 里没有未来提醒 → 重排 cancelAll
  /// 把刚排的推迟闹钟也清掉」→ 用户表现为「点推迟后提醒被删、且不再提醒」。
  /// 后台 isolate 不可达（FRB 不可重入）——那条路径由启动补齐兜底。
  static Future<void> Function(
    int taskId,
    int fromRemindAt,
    int nextAt,
  )? onSnoozeAction;

  /// 推迟执行体：解析 payload → 重排系统闹钟 + 静默确认通知。
  /// 全部走插件原生 API（不依赖 FRB/DB），前后台 isolate 皆可运行。
  Future<void> _handleSnoozeResponse(NotificationResponse response) async {
    final minutes = snoozeActions[response.actionId];
    final parts = (response.payload ?? '').split('|');
    if (minutes == null || parts.length < 3) return;
    final taskId = int.tryParse(parts[0]);
    final remindAt = int.tryParse(parts[1]);
    final title = parts.sublist(2).join('|');
    if (taskId == null || remindAt == null) return;

    await _ensureSelfContained();

    // 起算点：刚到点就点推迟 = 原时刻；补扫（过期较久才点）取现在——
    // 否则新时刻仍落在过去，排程会被跳过/立即触发
    final now = DateTime.now().millisecondsSinceEpoch;
    final nextAt = (remindAt > now ? remindAt : now) + minutes * 60 * 1000;
    // 推迟意图落地（两条通道，幂等可叠加）：
    // 1. 主 isolate 暂时不写 spool（避免每次前台推迟都留一份冗余文件）
    // 2. 暂存文件：后台 isolate 无法重入 FRB、也读不到主 isolate 注入的回调，
    //    只能写本机文件，由下次启动（BootGate ready）drain 后写回 DB
    if (onSnoozeAction == null) {
      // 后台 isolate：写暂存文件（systemTemp 不可写时静默失效——那种情况下由
      // 重排时的「孤儿闹钟补齐」兜底，见 reminder_snooze.dart）
      await SnoozeSpool.append(
        taskId: taskId,
        fromRemindAt: remindAt,
        nextAt: nextAt,
      );
      debugPrint('[NotificationService] snooze → spool(task=$taskId)');
    } else {
      try {
        await onSnoozeAction!.call(taskId, remindAt, nextAt);
        debugPrint('[NotificationService] snooze landed(task=$taskId)');
      } catch (e) {
        // 即时落库失败：退回 spool，下次启动补齐
        debugPrint('[NotificationService] snooze land failed: $e');
        await SnoozeSpool.append(
          taskId: taskId,
          fromRemindAt: remindAt,
          nextAt: nextAt,
        );
      }
    }
    final clock = _clockLabel(nextAt);
    await _scheduleAlarm(
      id: alarmIdFor(taskId),
      title: '待办提醒',
      body: title,
      remindAt: nextAt,
      payload: '$taskId|$nextAt|$title',
    );
    await _plugin.show(
      id: confirmIdFor(taskId),
      title: '已推迟 $minutes 分钟',
      body: '$title · $clock 再提醒你',
      notificationDetails: _quietDetails(),
    );
  }

  /// 完成执行体（后台路径）：cancel 原通知 + 静默确认横幅。
  /// 全部走插件原生 API（不依赖 FRB/DB），与推迟通道同构——后台
  /// isolate 无法写 Rust DB，DB 落地由用户打开应用后自然完成。
  Future<void> _handleCompleteResponse(NotificationResponse response) async {
    final taskId = taskIdFromPayload(response.payload);
    if (taskId == null) return;
    final title = _payloadTitle(response.payload);
    await _ensureSelfContained();
    try {
      await _plugin.cancel(id: alarmIdFor(taskId));
    } catch (_) {}
    try {
      await _plugin.show(
        id: pendingCompleteIdFor(taskId),
        title: '待办完成',
        body: '$title 已标记完成，打开应用后生效',
        notificationDetails: _quietDetails(),
      );
    } catch (_) {}
  }

  /// payload 第三段起的任务标题（与推迟解析同容错：缺失回退占位）
  static String _payloadTitle(String? payload) {
    final parts = (payload ?? '').split('|');
    return parts.length >= 3 ? parts.sublist(2).join('|') : '待办任务';
  }

  /// 时钟串 HH:mm（本地时区；后台 isolate 与前台共用）
  static String _clockLabel(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// 后台 isolate 自足初始化：tz 库 + 插件（无权限请求，静默失败容忍）。
  ///
  /// 时区注意：**不依赖 FlutterTimezone**——后台 isolate 里插件可能
  /// 拿不到时区标识；_scheduleAlarm 用 tz.UTC 构造 TZDateTime 即可
  /// （TZDateTime.from(DateTime.fromMillisecondsSinceEpoch, UTC) 与
  /// 任意时区产生相同绝对 epoch，alarmClock 只关心绝对时刻；
  /// 显示用 _clockLabel 走 DateTime 本地构造同样正确）。
  Future<void> _ensureSelfContained() async {
    tzdata.initializeTimeZones();
    // initialize 幂等（engine 已初始化时直接返回）
    try {
      const initSettings = InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_orbit'),
      );
      await _plugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: _onForegroundResponse,
        onDidReceiveBackgroundNotificationResponse: onBackgroundAction,
      );
    } catch (_) {
      /* 已初始化或后台受限：容忍，继续 show/schedule */
    }
  }

  /// 静默确认通知样式（低调渠道，不震不响）
  static NotificationDetails _quietDetails() => const NotificationDetails(
        android: AndroidNotificationDetails(
          'todo_reminder_info',
          '提醒反馈',
          importance: Importance.low,
          priority: Priority.low,
        ),
      );

  // ── 初始化（BootGate 主 isolate）──

  /// 初始化插件 + 时区 + 权限请求（幂等，重复调用仅首次生效）
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      const initSettings = InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_orbit'),
      );
      await _plugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: _onForegroundResponse,
        onDidReceiveBackgroundNotificationResponse: onBackgroundAction,
      );

      // 时区库初始化（zonedSchedule 依赖；失败 fallback UTC 仍可用）
      tzdata.initializeTimeZones();
      try {
        final local = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(local.identifier));
      } catch (_) {}

      // Android 13+ 运行时请求；13 以下由系统视为已授权返回 true。
      // 用户拒绝 → false，调用方静默降级 toast，不再二次骚扰。
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      _granted = await android?.requestNotificationsPermission() ?? false;
      if (_granted) {
        // Android 12+ 精确闹钟引导（targetSdk 36 下 SCHEDULE_EXACT_ALARM
        // 不再默认授予）：弹系统「闹钟和提醒」授权页一次；拒绝则
        // alarmClock/exact 排程回落 inexactAllowWhileIdle（Doze 下允许
        // 延迟），通知仍会到达——可用性优先，不阻塞。
        // canScheduleExactNotifications: null = 平台不可达，容忍
        final canExact = await android?.canScheduleExactNotifications();
        if (canExact == false) {
          await android?.requestExactAlarmsPermission();
        }
      }
    } catch (_) {
      _granted = false;
    }
  }

  // ── 通道 1：前台即时通知（reminderDue 事件）──

  /// 提醒到期事件出口：有权限 → show() 即时系统通知；
  /// 无权限或展示异常 → 维持 warning toast 兜底（文案与原订阅处一致）。
  /// 兜底 toast 与通知正文点击均挂 [onNotificationTap] 跳任务详情。
  ///
  /// 双通道去重：show() 与闹钟到点的原生 notify 同 id（alarmIdFor(taskId)），
  /// 后到者覆盖前者——同刻双弹天然合并为一条。
  /// 推迟产物识别：若本事件的 remind_at 早于该任务当前系统闹钟的排程
  /// （用户点过推迟、后台未写 DB 的旧行），静默删掉这条僵尸行不弹。
  Future<void> handleReminderDue(
    ReminderDueEvent event, {
    Future<void> Function(int reminderId)? onZombieCleanup,
  }) async {
    await ensureInitialized();
    final isSnoozed = await _isSnoozedOut(event.taskId, event.remindAt);
    if (isSnoozed) {
      // 推迟产物：新时间闹钟已在系统侧，旧行到期不弹——交给调用方删行
      //（删行失败静默：下次到期再判一次，不产生循环弹）
      try {
        await onZombieCleanup?.call(event.id);
      } catch (_) {}
      return;
    }
    if (!_granted) {
      WaitToast.warning('待办提醒：${event.title}', onTap: () {
        onNotificationTap?.call(event.taskId);
      });
      return;
    }
    try {
      await _plugin.show(
        id: alarmIdFor(event.taskId),
        title: '待办提醒',
        body: event.title,
        notificationDetails: _reminderDetails(
          payload: '${event.taskId}|${event.remindAt}|${event.title}',
        ),
      );
    } catch (_) {
      WaitToast.warning('待办提醒：${event.title}', onTap: () {
        onNotificationTap?.call(event.taskId);
      });
    }
  }

  /// 本行 remindAt 是否已被推迟甩在身后：任务系统闹钟存在比它更晚的
  /// 排程 → 用户推迟过（payload 解析回 remindAt 比较）。
  /// pending 列表不可用时保守返回 false（不吞正常提醒）。
  Future<bool> _isSnoozedOut(int taskId, int remindAt) async {
    try {
      final pending = await _plugin.pendingNotificationRequests();
      final myId = alarmIdFor(taskId);
      for (final p in pending) {
        if (p.id != myId) continue;
        final parts = (p.payload ?? '').split('|');
        final pendingAt = parts.length > 1 ? int.tryParse(parts[1]) : null;
        if (pendingAt != null && pendingAt > remindAt) return true;
      }
    } catch (_) {}
    return false;
  }

  /// 系统侧闹钟域 pending（启动补齐用）：解析 payload 得 taskId|remindAt，
  /// 跳过确认/完成通知域（id ≥ 1e9）。读取失败返回空表（保守：不落地）。
  Future<List<PendingAlarm>> pendingAlarms() async {
    final out = <PendingAlarm>[];
    try {
      final pending = await _plugin.pendingNotificationRequests();
      for (final p in pending) {
        if (p.id <= 0 || p.id >= 1000000000) continue; // 闹钟域之外
        final parts = (p.payload ?? '').split('|');
        if (parts.length < 2) continue;
        final taskId = int.tryParse(parts[0]);
        final at = int.tryParse(parts[1]);
        if (taskId == null || at == null) continue;
        out.add(PendingAlarm(taskId: taskId, remindAt: at));
      }
    } catch (_) {}
    return out;
  }

  /// 取消某任务的系统闹钟（用户手动删掉提醒行时调用）
  ///
  /// 必要性：「后台推迟产物」与「用户删提醒后的残留闹钟」在系统侧无法区分
  /// （都是只有 payload、没有 DB 行）；不主动取消，下次重排的孤儿补齐会把
  /// 用户刚删掉的提醒又建回来（planSnoozeLanding 的 activeTaskIds 规则）。
  Future<void> cancelAlarmFor(int taskId) async {
    try {
      await _plugin.cancel(id: alarmIdFor(taskId));
    } catch (_) {}
  }

  // ── 通道 2：后台闹钟全量重排 ──

  /// 全量重排后台闹钟（启动/提醒数据变更后调用）：
  /// - cancelAllPendingNotifications 清掉本插件全部 pending 闹钟；
  /// - 过去时间跳过（DB 里的历史行不该再闹；前台轮询负责 24h 补弹）；
  /// - 未来提醒逐条 zonedSchedule(alarmClock)。
  /// 返回排上的条数（测试/日志用）。
  Future<int> syncFutureReminders(List<TodoReminder> reminders) async {
    await ensureInitialized();
    if (!_granted) return 0;
    try {
      await _plugin.cancelAllPendingNotifications();
    } catch (_) {
      /* 清空失败继续重排：同 id zonedSchedule 覆盖旧闹钟 */
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    var count = 0;
    for (final r in reminders) {
      if (r.isDeleted != 0 || r.remindAt <= now) continue;
      // 标题缺失（任务可能已被删）：仍排闹钟，正文回退应用名
      final body = r.reminderTitle ?? '待办任务';
      final ok = await _scheduleAlarm(
        id: alarmIdFor(r.taskId),
        title: '待办提醒',
        body: body,
        remindAt: r.remindAt,
        payload: '${r.taskId}|${r.remindAt}|$body',
      );
      if (ok) count++;
    }
    return count;
  }

  /// 冷启动拉起消费：应用被杀期间点通知正文 → 系统以 launch payload
  /// 拉起应用（不走 onDidReceiveNotificationResponse）。BootGate ready 后
  /// 调用一次：解析 launch payload 里的 taskId，有则经 [onNotificationTap]
  /// 跳任务详情。非提醒拉起（正常图标启动）payload 为空，直接返回。
  Future<void> consumeLaunchNotification() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      final payload = details?.notificationResponse?.payload;
      final taskId = taskIdFromPayload(payload);
      if (taskId != null && onNotificationTap != null) {
        await onNotificationTap!(taskId);
      }
    } catch (e) {
      debugPrint('[NotificationService] launch consume: $e');
    }
  }

  /// 单条系统闹钟排程。alarmClock（闹钟级、Doze 免疫）→ 无精确闹钟权限
  /// 回落 exactAllowWhileIdle → 再失败 inexactAllowWhileIdle（尽力而为）。
  ///
  /// TZDateTime 用 tz.UTC 构造：from(absolute DateTime, UTC) 产生的
  /// 绝对时刻与本地时区完全相同（alarmClock 只看 epoch），从而把
  /// 「后台 isolate 拿不到本地时区标识」从失败面中整体移除。
  Future<bool> _scheduleAlarm({
    required int id,
    required String title,
    required String body,
    required int remindAt,
    required String payload,
  }) async {
    final scheduled = DateTime.fromMillisecondsSinceEpoch(remindAt);
    final tzDate = tz.TZDateTime.from(scheduled, tz.UTC);
    Future<void> put(AndroidScheduleMode mode) => _plugin.zonedSchedule(
          id: id,
          title: title,
          body: body,
          payload: payload,
          scheduledDate: tzDate,
          notificationDetails: _reminderDetails(payload: payload),
          androidScheduleMode: mode,
        );
    // 后台 isolate 排程失败曾静默（实测 2026-09-06：确认通知弹出但闹钟
    // 未注册）——三级回退逐一留痕，排障依据
    try {
      await put(AndroidScheduleMode.alarmClock);
      return true;
    } catch (e) {
      debugPrint('[NotificationService] alarmClock failed: $e');
    }
    try {
      await put(AndroidScheduleMode.exactAllowWhileIdle);
      return true;
    } catch (e) {
      debugPrint('[NotificationService] exact failed: $e');
    }
    try {
      await put(AndroidScheduleMode.inexactAllowWhileIdle);
      return true;
    } catch (e) {
      debugPrint('[NotificationService] inexact failed: $e');
      return false;
    }
  }

  /// 提醒通知样式：三个推迟 action + 灵动岛（alarm 类别）高优渠道。
  /// payload 贯穿 show/zonedSchedule 两条路径（推迟回退解析用）。
  static NotificationDetails _reminderDetails({required String payload}) {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        importance: Importance.high,
        priority: Priority.high,
        // 小米 HyperOS 焦点通知（灵动岛）：闹钟类高优通知走灵动岛胶囊
        category: AndroidNotificationCategory.alarm,
        autoCancel: true,
        actions: [
          AndroidNotificationAction('complete', '完成'),
          AndroidNotificationAction('snooze_10', '推迟10分钟'),
          AndroidNotificationAction('snooze_30', '推迟30分钟'),
          AndroidNotificationAction('snooze_60', '推迟1小时'),
        ],
      ),
    );
  }
}
