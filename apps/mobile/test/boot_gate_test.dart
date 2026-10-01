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
import 'package:orbit/modules/todo/providers/todo_providers.dart';
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

/// F76 假桥：exit 轮 cloudSyncForce 拖到 7s——比旧 6s 外层超时长、比修复后
/// 的 18s（15s 空闲窗 + 3s 余量）短，并统计任务缓存拉取次数作失效探针
class _SlowExitForceBridge extends MockOrbitBridge {
  int taskListCalls = 0;
  String? lastForceOrigin;

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
        syncOnChange: false,
        skipTlsVerify: false,
        timeoutSeconds: 30,
        lastSyncedAt: null,
      );

  @override
  Future<SyncResultJson> cloudSyncForce(
      {String origin = 'manual', int waitForIdleMs = 3000}) async {
    lastForceOrigin = origin;
    if (origin == 'exit') {
      await Future<void>.delayed(const Duration(seconds: 7));
    }
    return const SyncResultJson(
      pushedModules: 0,
      pulledModules: 2,
      uploadedAttachments: 0,
      downloadedAttachments: 0,
      durationMs: 910,
      skipped: false,
      errors: [],
    );
  }

  @override
  Future<List<TodoTask>> todoTaskList(ListFilter filter) async {
    taskListCalls++;
    return const [];
  }
}

/// 读取任务缓存作失效探针：被 invalidate 后会经桥重拉（taskListCalls++）
class _TaskCacheProbe extends ConsumerWidget {
  const _TaskCacheProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(todoTasksProvider);
    return const Text('TASK_CACHE_PROBE');
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

  testWidgets('F76：exit 轮同步耗时超过 6s 不被截断，完成后仍失效业务缓存', (tester) async {
    final bridge = _SlowExitForceBridge();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
        child: orbitTestApp(
          home: BootGate(child: const _TaskCacheProbe()),
        ),
      ),
    );
    // 越过启动链路（bootstrap + 首次任务缓存拉取 = taskListCalls 第 1 次）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(bridge.taskListCalls, 1);

    // 模拟退到后台（exit 轮触发）
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(bridge.lastForceOrigin, 'exit');

    // 旧代码：6s 超时在此触发 → TimeoutException → 缓存失效被跳过
    // （taskListCalls 停在 1）→ 断言翻红；修复后 18s 超时放行 7s 同步
    await tester.pump(const Duration(seconds: 7, milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // 同步完成必须走到失效链：任务缓存被重拉（第 2 次）
    expect(bridge.taskListCalls, 2,
        reason: 'exit 轮 >6s 的同步不得被外层超时截断——截断即丢失缓存失效，'
            'UI 停在旧数据直到下次 db-change');
  });
}