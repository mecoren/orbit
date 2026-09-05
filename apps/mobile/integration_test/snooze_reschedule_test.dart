// 推迟重排链路验证：zonedSchedule 在【应用进程内】排一条新闹钟
// （模拟 NotificationService._scheduleAlarm 口径），断言 pending 注册成功。
// 后台 isolate 场景的差别只在于运行环境；先证明排程 API 在运行时无阻塞。
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('zonedSchedule 重排：pending 注册 + 读取回 payload', (tester) async {
    final plugin = FlutterLocalNotificationsPlugin();
    const init = InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_orbit'),
    );
    await plugin.initialize(settings: init);
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));

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

    // 模拟 _handleSnoozeResponse 的排程口径：原 20:24 + 10min
    final fireAt = tz.TZDateTime.from(
      DateTime.now().add(const Duration(minutes: 2)),
      tz.local,
    );
    var scheduled = false;
    try {
      await plugin.zonedSchedule(
        id: 990002,
        title: '待办提醒',
        body: 'SNOOZE_RESCHEDULE_TEST',
        payload: '1|${fireAt.millisecondsSinceEpoch}|SNOOZE_RESCHEDULE_TEST',
        scheduledDate: fireAt,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.alarmClock,
      );
      scheduled = true;
    } catch (e) {
      debugPrint('[snooze-e2e] alarmClock failed: $e');
      try {
        await plugin.zonedSchedule(
          id: 990002,
          title: '待办提醒',
          body: 'SNOOZE_RESCHEDULE_TEST',
          payload: '1|${fireAt.millisecondsSinceEpoch}|SNOOZE_RESCHEDULE_TEST',
          scheduledDate: fireAt,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
        scheduled = true;
      } catch (e2) {
        debugPrint('[snooze-e2e] exact failed too: $e2');
      }
    }
    expect(scheduled, isTrue, reason: '两级排程至少一级成功');

    final pending = await plugin.pendingNotificationRequests();
    debugPrint('[snooze-e2e] pending count=${pending.length}');
    final mine = pending.where((p) => p.id == 990002).toList();
    expect(mine.length, 1, reason: '990002 应在 pending 列表');
    debugPrint('[snooze-e2e] payload=${mine.first.payload}');
    debugPrint('[snooze-e2e] STAGE_DONE');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
