// P2 提醒升级真机验收（ADR 0002 §五/§七）——后台闹钟链路 E2E。
//
// 验证命题：
// 1. 建任务 + 未来提醒 → ReminderScheduler 防抖后把提醒排进系统闹钟
//    （flutter_local_notifications pending 列表可查）；
// 2. 全 force-stop 杀进程 → 等待闹钟到点 → 原生 Receiver 弹出系统通知
//    （不依赖 Dart 进程存活——这是「后台不提醒」修复的核心证伪点）；
// 3. 通知带三个推迟 action；点「推迟10分钟」→ 新闹钟重排到 +10min。
//
// 运行：flutter test integration_test/reminder_alarm_e2e_test.dart
//      （模拟器/真机；需授予通知 + 精确闹钟权限，见脚本内 adb 预置）
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

@pragma('vm:entry-point')
void backgroundActionHandler(NotificationResponse response) {
  debugPrint('[e2e-bg] action=${response.actionId} payload=${response.payload}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('提醒→系统闹钟注册→pending 可查', (tester) async {
    // —— 排程侧：直接走插件 API + service 层口径 ——
    final plugin = FlutterLocalNotificationsPlugin();
    const init = InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_orbit'),
    );
    await plugin.initialize(
      settings: init,
      onDidReceiveBackgroundNotificationResponse: backgroundActionHandler,
    );
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));

    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    // 权限由外层 adb 预授（fresh 模拟器上运行时请求弹系统对话框会与
    // integration test 的 pump 循环死锁——真机上无此问题，见 ADR 0002 §五）
    final granted =
        await android?.areNotificationsEnabled() ?? false;
    debugPrint('[e2e] notifications granted=$granted');
    final canExact = await android?.canScheduleExactNotifications();
    debugPrint('[e2e] canScheduleExact=$canExact');
    if (canExact == false) {
      // 精确闹钟未授予：外层脚本已 appops 预授；此处不再弹系统设置页
      //（对话框在 integration test 里会挂起 pump 循环）
      debugPrint('[e2e] exact alarm NOT granted, will fallback in schedule');
    }

    // 与 NotificationService._reminderDetails 同款（三档推迟 action）
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'todo_reminder_due',
        '待办提醒',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        autoCancel: true,
        actions: [
          AndroidNotificationAction('snooze_10', '推迟10分钟'),
          AndroidNotificationAction('snooze_30', '推迟30分钟'),
          AndroidNotificationAction('snooze_60', '推迟1小时'),
        ],
      ),
    );

    // +90 秒触发：测试结束后由外层 force-stop 杀进程，闹钟归零点时
    // 由原生 Receiver 弹通知（Dart 不存活——修复「后台不提醒」的证伪点）
    final fireAt = tz.TZDateTime.from(
      DateTime.now().add(const Duration(seconds: 90)),
      tz.local,
    );
    try {
      await plugin.zonedSchedule(
        id: 990001,
        title: '待办提醒',
        body: 'E2E 后台闹钟验证',
        payload: '990001|${fireAt.millisecondsSinceEpoch}|E2E 后台闹钟验证',
        scheduledDate: fireAt,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.alarmClock,
      );
      debugPrint('[e2e] alarmClock schedule OK at $fireAt');
    } catch (e) {
      // 回落链与 NotificationService._scheduleAlarm 相同口径
      debugPrint('[e2e] alarmClock failed: $e, fallback exact');
      try {
        await plugin.zonedSchedule(
          id: 990001,
          title: '待办提醒',
          body: 'E2E 后台闹钟验证',
          payload: '990001|${fireAt.millisecondsSinceEpoch}|E2E 后台闹钟验证',
          scheduledDate: fireAt,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
        debugPrint('[e2e] exact fallback OK');
      } catch (e2) {
        debugPrint('[e2e] exact fallback failed too: $e2');
        fail('闹钟排程两级均失败');
      }
    }

    // 断言 1：pending 列表可查（系统已接受排程）
    final pending = await plugin.pendingNotificationRequests();
    debugPrint('[e2e] pending count=${pending.length}');
    expect(pending.any((p) => p.id == 990001), isTrue,
        reason: '系统闹钟面应包含 id=990001');

    // 通知外层脚本：本测试结束后 force-stop 应用、等 2.5 分钟、
    // dumpsys notification 断言系统通知已由原生 Receiver 弹出（不依赖
    // Dart 进程）。见 scripts/e2e-reminder-alarm.sh。
    debugPrint('[e2e] STAGE1_DONE');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
