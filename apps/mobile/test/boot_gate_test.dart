// BootGate 回归测试：主密码未设置时必须直达主界面。
//
// 背景：曾因 BootGate 订阅已被移除的 syncFinished 流（RustOrbitBridge 对其
// 抛 UnsupportedError，见 ADR 0003——sync 结果经 cloudSyncNow 返回值直达），
// 异常被 _bootstrap 的 catch 静默吞掉，误判为初始化失败而回落解锁页。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/shell/boot_gate.dart';
import 'package:orbit/services/reminder_scheduler.dart';
import 'package:orbit/services/sync_on_change_scheduler.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(
        home: BootGate(child: const Text('MAIN_CONTENT')),
      ),
    );

/// 「修改后立即同步」门控全开的假桥（其余行为同 MockOrbitBridge）
class _OnChangeBridge extends MockOrbitBridge {
  int pushCalls = 0;
  String? lastOrigin;

  @override
  Future<SyncConfigView?> syncConfigGet() async => SyncConfigView(
        id: 1,
        engine: 'webdav',
        endpoint: 'https://dav.example.com',
        bucket: '',
        region: '',
        username: 'demo',
        passwordSet: true,
        basePath: '/orbit/',
        intervalMinutes: 30,
        autoSyncEnabled: true,
        syncOnChange: true,
        skipTlsVerify: false,
        timeoutSeconds: 30,
        lastSyncedAt: null,
      );

  @override
  Future<SyncCryptoStatus> syncCryptoStatus() async =>
      const SyncCryptoStatus(hasPassword: true, isUnlocked: true);

  @override
  Future<SyncResultJson> cloudSyncPushOnly({String origin = 'manual'}) async {
    pushCalls++;
    lastOrigin = origin;
    return const SyncResultJson(
      pushedModules: 1,
      pulledModules: 0,
      uploadedAttachments: 0,
      downloadedAttachments: 0,
      durationMs: 100,
      skipped: false,
      errors: [],
    );
  }
}

void main() {
  // ReminderScheduler / SyncOnChangeScheduler 进程级单例的防抖 Timer 会活过
  // widget 树：fake_async 要求每测试退出时无 pending Timer，逐测试清场
  tearDown(ReminderScheduler.shutdown);
  tearDown(SyncOnChangeScheduler.shutdown);

  testWidgets('主密码未设置：bootstrap 完成后直达主界面而非解锁页', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));

    // 越过 MockOrbitBridge 120ms 人为延迟，再收敛帧
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // 泵过 ReminderScheduler 的 2s 防抖窗口（闹钟重排走 mock 桥 +
    // 通知插件测试桩不真排），避免 fake_async 残留 pending Timer
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // 进入 ready：主内容渲染，解锁页不出现
    expect(find.text('MAIN_CONTENT'), findsOneWidget);
    expect(find.text('请输入主密码解锁'), findsNothing);
  });

  testWidgets('写路径 db-change → 5s 防抖后触发 cloudSyncPushOnly（M6）', (tester) async {
    final bridge = _OnChangeBridge();
    await tester.pumpWidget(_wrap(bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2)); // 越过提醒调度器防抖
    await tester.pumpAndSettle();
    expect(find.text('MAIN_CONTENT'), findsOneWidget);

    // 走真实写路径（Mock 写命令 emit dbChanges，链路与真桥同构）
    final taskId = bridge.store.tasks.keys.first;
    unawaited(bridge.todoTaskUpdate(taskId, '{"title":"改一下"}'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(bridge.pushCalls, 0, reason: '防抖窗口内不推送');

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bridge.pushCalls, 1);
    expect(bridge.lastOrigin, 'background');
  });
}
