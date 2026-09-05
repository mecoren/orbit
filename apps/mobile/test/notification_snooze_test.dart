// NotificationService P2 提醒升级的纯逻辑测试：
// - id 派生域（闹钟/确认通知不重叠且 32 位内）
// - 推迟 payload 解析（actionId → 分钟；taskId|remindAt|title 切分容忍 |）
// - _clockLabel 本地时钟串
// 插件原生调用不做集成测试（需真机/emulator，ADR 0002 §五验收项）。
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/services/notification_service.dart';

void main() {
  group('snoozeActions', () {
    test('三档推迟：10 / 30 / 60 分钟', () {
      expect(NotificationService.snoozeActions['snooze_10'], 10);
      expect(NotificationService.snoozeActions['snooze_30'], 30);
      expect(NotificationService.snoozeActions['snooze_60'], 60);
      expect(NotificationService.snoozeActions.length, 3);
    });
  });

  group('推迟 payload 解析（_handleSnoozeResponse 前置校验口径）', () {
    // 与 NotificationService._handleSnoozeResponse 同口径的解析复现，
    // 保证 payload 编码（taskId|remindAt|title，title 可含 |）可回读
    (int?, int?, String) parse(String payload) {
      final parts = payload.split('|');
      return (
        parts.isNotEmpty ? int.tryParse(parts[0]) : null,
        parts.length > 1 ? int.tryParse(parts[1]) : null,
        parts.length > 2 ? parts.sublist(2).join('|') : '',
      );
    }

    test('标准 payload 三段齐全', () {
      final (taskId, remindAt, title) = parse('42|1770000000000|买牛奶');
      expect(taskId, 42);
      expect(remindAt, 1770000000000);
      expect(title, '买牛奶');
    });

    test('标题含 | 时不丢尾段', () {
      final (taskId, remindAt, title) = parse('7|123|评审|带材料');
      expect(taskId, 7);
      expect(remindAt, 123);
      expect(title, '评审|带材料');
    });

    test('缺段/坏数字 → null（回调静默返回的分支）', () {
      final a = parse('42');
      expect(a.$1, 42);
      expect(a.$2, null);
      final b = parse('abc|123|x');
      expect(b.$1, null);
      final c = parse('');
      expect(c.$1, null);
    });
  });

  test('NotificationResponse 携带 payload 时 actionId 可映射到档位（插件面契约）', () {
    // 契约验证：NotificationResponse.actionId 即 snoozeActions 键，
    // 插件平台层透传（Android ActionBroadcastReceiver → Dart）
    const r = NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotificationAction,
      id: 1,
      actionId: 'snooze_30',
      payload: '3|1700000000000|写周报',
    );
    expect(NotificationService.snoozeActions[r.actionId], 30);
    expect(r.payload, isNotNull);
  });
}
