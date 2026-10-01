// SyncOnChangeScheduler 单测（M6「修改后立即同步」写路径触发）
//
// 口径对齐桌面 `sync_scheduler.rs` on-change watcher：5s 滑动防抖 + 四道
// 门控（已配置 → 两个开关 → 已解锁 → 引擎空闲）+ origin=background。
//
// 时间推进用 widget 测试自带的 FakeAsync（`tester.pump(时长)`），不用
// `fake_async` 包——与仓库既有测试范式一致。
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/services/sync_on_change_scheduler.dart';
import 'support/orbit_test_app.dart';

/// 仿真 FRB 错误形态：AnyhowException 的 toString 就是裸消息（无
/// "Exception: " 前缀）——Dart 原生 Exception 会带前缀，破坏 syncErrorTag
/// 的 `^[\[(\w+)\]` 提取，测试必须与生产错误形态一致
class _AnyhowLike implements Exception {
  _AnyhowLike(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 门控可调的假桥：默认全开（已配置 + 两开关开 + 已设密码已解锁 + 引擎空闲）；
/// 各方法无延迟（不走 Mock 的 120ms），并记录探测次数以断言门控短路
class _GatedBridge extends MockOrbitBridge {
  bool configured = true;
  bool syncOnChange = true;
  bool autoSyncEnabled = true;
  bool hasPassword = true;
  bool unlocked = true;
  bool running = false;

  int pushCalls = 0;
  String? lastOrigin;
  int cryptoProbes = 0;
  int runningProbes = 0;

  /// 非空时推送挂起（模拟慢推送）
  Completer<void>? pushGate;

  /// 非空时推送抛错（模拟 core 上抛，如 [key_mismatch]）
  Object? pushError;

  @override
  Future<SyncConfigView?> syncConfigGet() async => configured
      ? SyncConfigView(
          id: 1,
          engine: 'webdav',
          endpoint: 'https://dav.example.com',
          bucket: '',
          region: '',
          username: 'demo',
          passwordSet: true,
          basePath: '/orbit/',
          intervalMinutes: 30,
          autoSyncEnabled: autoSyncEnabled,
          syncOnChange: syncOnChange,
          skipTlsVerify: false,
          timeoutSeconds: 30,
          lastSyncedAt: null,
        )
      : null;

  @override
  Future<SyncCryptoStatus> syncCryptoStatus() async {
    cryptoProbes++;
    return SyncCryptoStatus(hasPassword: hasPassword, isUnlocked: unlocked);
  }

  @override
  Future<bool> cloudSyncIsRunning() async {
    runningProbes++;
    return running;
  }

  @override
  Future<SyncResultJson> cloudSyncPushOnly({String origin = 'manual'}) async {
    pushCalls++;
    lastOrigin = origin;
    if (pushError != null) throw pushError!;
    if (pushGate != null) await pushGate!.future;
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
  // 进程级单例的防抖 Timer 会活过测试体：fake_async 要求退出时无 pending
  tearDown(SyncOnChangeScheduler.shutdown);

  testWidgets('门控全开：满 5s 防抖后推送一次，origin=background', (tester) async {
    final bridge = _GatedBridge();
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    await tester.pumpWidget(const SizedBox());

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 4));
    expect(bridge.pushCalls, 0, reason: '未满防抖窗口不应推送');

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(bridge.pushCalls, 1);
    expect(bridge.lastOrigin, 'background');
  });

  testWidgets('5s 滑动窗口：连续编辑合并为一次推送', (tester) async {
    final bridge = _GatedBridge();
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    await tester.pumpWidget(const SizedBox());

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 3));
    scheduler.onDbChange(); // 新事件重置窗口
    await tester.pump(const Duration(seconds: 4));
    expect(bridge.pushCalls, 0, reason: '距最后一次编辑仅 4s');

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(bridge.pushCalls, 1);
  });

  testWidgets('开关关闭：不推送，且门控短路不再探测解锁态', (tester) async {
    final bridge = _GatedBridge()..syncOnChange = false;
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    await tester.pumpWidget(const SizedBox());

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(bridge.pushCalls, 0);
    expect(bridge.cryptoProbes, 0, reason: '开关未开即返回，省一次 IPC');
  });

  testWidgets('自动同步总开关关闭：不推送（桌面同口径）', (tester) async {
    final bridge = _GatedBridge()..autoSyncEnabled = false;
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    await tester.pumpWidget(const SizedBox());

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(bridge.pushCalls, 0);
  });

  testWidgets('未配置云同步：不推送', (tester) async {
    final bridge = _GatedBridge()..configured = false;
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    await tester.pumpWidget(const SizedBox());

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(bridge.pushCalls, 0);
    expect(bridge.cryptoProbes, 0);
  });

  testWidgets('同步密码未解锁：不推送', (tester) async {
    final bridge = _GatedBridge()..unlocked = false;
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    await tester.pumpWidget(const SizedBox());

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(bridge.pushCalls, 0);
    expect(bridge.cryptoProbes, 1);
    expect(bridge.runningProbes, 0, reason: '未解锁即返回，不探测引擎');
  });

  testWidgets('引擎忙：本轮让位；空闲后新写入正常推送', (tester) async {
    final bridge = _GatedBridge()..running = true;
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    await tester.pumpWidget(const SizedBox());

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bridge.pushCalls, 0);
    expect(bridge.runningProbes, 1);

    bridge.running = false;
    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bridge.pushCalls, 1);
  });

  testWidgets('推送进行中的新写入：本轮不并发，结束后补一轮防抖', (tester) async {
    final bridge = _GatedBridge()..pushGate = Completer<void>();
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    await tester.pumpWidget(const SizedBox());

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bridge.pushCalls, 1, reason: '首轮已开始并挂起');

    scheduler.onDbChange(); // 推送中的新写入
    await tester.pump(const Duration(seconds: 6));
    expect(bridge.pushCalls, 1, reason: '进行中不并发第二轮');

    bridge.pushGate!.complete();
    await tester.pump(); // 首轮落定 → 补排防抖窗口
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bridge.pushCalls, 2);
  });

  testWidgets('推送成功后回调 onPushed（用于刷新同步配置缓存）', (tester) async {
    final bridge = _GatedBridge();
    var notified = 0;
    final scheduler = SyncOnChangeScheduler.attachOnce(
      bridge,
      onPushed: () => notified++,
    );
    await tester.pumpWidget(const SizedBox());

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(notified, 1);
  });

  testWidgets('F77：push 失败为 key_mismatch 时弹恢复引导 toast（对齐桌面 emit 引导）', (tester) async {
    final bridge = _GatedBridge()
      ..pushError = _AnyhowLike(
          '[key_mismatch] Data Key 与云端密文不匹配：本地已解锁但解密云端数据失败');
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    // WaitToast.global 经 rootNavigatorKey 取浮层：必须用与生产同构的壳
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
        child: orbitTestApp(home: const SizedBox()),
      ),
    );
    await tester.pump();

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bridge.pushCalls, 1, reason: '推送确实发起了');
    expect(
      find.text('同步密钥与云端数据不匹配'),
      findsOneWidget,
      reason: 'key_mismatch 不得静默吞掉——桌面端 on-change 失败会引导恢复页，'
          '移动端此前任何失败都无提示（F77）',
    );

    // 收尾推掉 toast 停留计时器：带 action 钮的恢复 toast 是常驻档
    //（onAction 非空 → showDuration=holdForever），必须按常驻档收尾
    await drainToastTimers(tester, holdForever: true);
  });

  testWidgets('F77：push 失败为网络类错误时不弹恢复引导（维持静默口径）', (tester) async {
    final bridge = _GatedBridge()..pushError = _AnyhowLike('[network] 连接超时');
    final scheduler = SyncOnChangeScheduler.attachOnce(bridge);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
        child: orbitTestApp(home: const SizedBox()),
      ),
    );
    await tester.pump();

    scheduler.onDbChange();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bridge.pushCalls, 1);
    expect(find.text('同步密钥与云端数据不匹配'), findsNothing,
        reason: '非密钥类失败维持「失败静默不打扰」口径');
    await drainToastTimers(tester);
  });
}