import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/api/orbit_bridge.dart';
import '../shared/widgets/wait_toast.dart';

/// 本地通知服务（Phase 7 平台集成）
///
/// 职责（对齐移动端任务书）：
/// - 初始化插件：Android 小图标用专用剪影 @drawable/ic_stat_orbit
///   （白色轨道剪影，M5 品牌图标族；勿用启动器图标——彩图在状态栏
///   会被系统压成灰块）；
/// - 请求 POST_NOTIFICATIONS 运行时权限，拒绝则静默降级——
///   提醒到期回落应用内 warning toast（[WaitToast] 兜底已存在）；
/// - [handleReminderDue]：reminderDue 事件即时呈现。zonedSchedule 面向
///   未来排程，事件到达即"已到期"，直接 show() 立即弹出（id=提醒主键，
///   同 id 重发自动覆盖，不产生叠影）。
///
/// 时区三件套中的 timezone/flutter_timezone 当前仅做本地时区初始化
/// （为后续定时排程 zonedSchedule 预备），初始化失败不影响 show() 路径。
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

  /// 权限是否已授予（未初始化 / 被拒均为 false）
  bool get hasPermission => _granted;

  /// 初始化插件 + 时区 + 权限请求（幂等，重复调用仅首次生效）
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      const initSettings = InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_orbit'),
      );
      await _plugin.initialize(settings: initSettings);

      // 时区库初始化（失败静默跳过：当前 show() 路径不依赖时区）
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
    } catch (_) {
      _granted = false;
    }
  }

  /// 提醒到期事件出口：有权限 → show() 即时系统通知；
  /// 无权限或展示异常 → 维持 warning toast 兜底（文案与原订阅处一致）。
  Future<void> handleReminderDue(ReminderDueEvent event) async {
    await ensureInitialized();
    if (!_granted) {
      WaitToast.warning('待办提醒：${event.title}');
      return;
    }
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        // 小图标沿用初始化设置（@drawable/ic_stat_orbit）；
        // 22.x 的 AndroidNotificationDetails 无 channelIcon 参数
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    try {
      // id=提醒主键：同 id 重发自动覆盖，不产生叠影
      await _plugin.show(
        id: event.id,
        title: '待办提醒',
        body: event.title,
        notificationDetails: details,
      );
    } catch (_) {
      WaitToast.warning('待办提醒：${event.title}');
    }
  }
}
