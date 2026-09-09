import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/services/notification_service.dart';

/// B5 通知「完成」按钮：action 集合与 id 派生口径
/// （通知行为本身属平台集成面，纯逻辑口径在此锁定）
void main() {
  test('completeActions 仅含 complete，且与推迟 actionId 互斥', () {
    expect(NotificationService.completeActions, {'complete'});
    final snooze = NotificationService.snoozeActions.keys.toSet();
    expect(
      NotificationService.completeActions.intersection(snooze),
      isEmpty,
    );
  });

  test('通知 id 派生口径：闹钟域/确认域/待完成域三段互斥', () {
    expect(NotificationService.alarmIdFor(5), (5 % (1 << 30)) + 1);
    expect(NotificationService.confirmIdFor(5), (5 % (1 << 30)) + 1000000000);
    // 待完成确认横幅：确认域再 +500000000，不与任一域重叠
    expect(
      NotificationService.pendingCompleteIdFor(5),
      (5 % (1 << 30)) + 1000000000 + 500000000,
    );
    // 三域互斥（同 taskId 三个 id 两两不等）
    final a = NotificationService.alarmIdFor(7);
    final c = NotificationService.confirmIdFor(7);
    final p = NotificationService.pendingCompleteIdFor(7);
    expect(a != c && c != p && a != p, isTrue);
  });

  test('taskIdFromPayload 既有口径不受影响', () {
    expect(NotificationService.taskIdFromPayload('3|1700000000000|写周报'), 3);
    expect(NotificationService.taskIdFromPayload(null), isNull);
    expect(NotificationService.taskIdFromPayload('abc|x|y'), isNull);
  });
}
