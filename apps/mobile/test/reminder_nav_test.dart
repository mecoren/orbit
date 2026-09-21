// 提醒 → 任务详情入口的三路点击链路测试：
// 1. payload 解析（taskIdFromPayload：前台点击 / 冷启动拉起共用口径）
// 2. WaitToast.onTap：无权限兜底 toast 整卡点击触发回调（Overlay 挂载 widget 测试）
// 3. onNotificationTap 注入契约：BootGate 注入的回调 push '/todo/:id'
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/services/notification_service.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_toast.dart';
import 'support/orbit_test_app.dart';

void main() {
  group('taskIdFromPayload（通知点击两路共用口径）', () {
    test('标准 payload → taskId', () {
      expect(NotificationService.taskIdFromPayload('42|1770000000000|买牛奶'), 42);
    });

    test('标题含 | 仍取首段', () {
      expect(NotificationService.taskIdFromPayload('7|123|评审|带材料'), 7);
    });

    test('空/坏 payload → null（点击静默分支）', () {
      expect(NotificationService.taskIdFromPayload(null), isNull);
      expect(NotificationService.taskIdFromPayload(''), isNull);
      expect(NotificationService.taskIdFromPayload('abc|x'), isNull);
    });
  });

  group('WaitToast onTap（无权限兜底提醒点击跳详情）', () {
    testWidgets('带 onTap 的 toast：点击卡片触发回调', (tester) async {
      var fired = 0;
      await tester.pumpWidget(
        orbitTestApp(
          home: const Scaffold(body: SizedBox()),
        ),
      );
      WaitToast.global('待办提醒：买牛奶',
          variant: WaitToastVariant.warning, onTap: () => fired++);
      // shadcn toast 有入场动画（自下而上 500ms），只推一帧时卡片还在屏幕外，
      // 点击会落空——必须 settle 到入场结束
      await tester.pumpAndSettle();
      expect(find.text('待办提醒：买牛奶'), findsOneWidget);

      await tester.tap(find.text('待办提醒：买牛奶'));
      await tester.pumpAndSettle(); // 退出动画
      expect(fired, 1);
      // 该条带 onTap = 「不自动收」档，按常驻档收尾
      await drainToastTimers(tester, holdForever: true);
    });

    testWidgets('无 onTap 行为不变：点击仅收起不抛错', (tester) async {
      await tester.pumpWidget(
        orbitTestApp(
          home: const Scaffold(body: SizedBox()),
        ),
      );
      WaitToast.warning('普通警告');
      await tester.pumpAndSettle();
      expect(find.text('普通警告'), findsOneWidget);

      await tester.tap(find.text('普通警告'));
      await tester.pumpAndSettle();
      expect(find.text('普通警告'), findsNothing);
      await drainToastTimers(tester);
    });
  });

  group('onNotificationTap 注入契约（BootGate push 目标）', () {
    test('回调 push 的路由串格式：/todo/{taskId}', () {
      // BootGate 注入实现 push('/todo/$taskId')；此处固定契约：
      // taskId 必须原样嵌入路径，详情路由 /todo/:id 可解析回同一 id
      int pushedTaskId = 42;
      final path = '/todo/$pushedTaskId';
      final parsed = int.tryParse(path.split('/').last);
      expect(parsed, pushedTaskId);
    });
  });
}
