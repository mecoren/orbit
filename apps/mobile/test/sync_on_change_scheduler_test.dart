// SyncOnChangeScheduler 单测（M6「修改后立即同步」写路径触发）
//
// 口径对齐桌面 `sync_scheduler.rs` on-change watcher：5s 滑动防抖 + 四道
// 门控（已配置 → 两个开关 → 已解锁 → 引擎空闲）+ origin=background。
//
// 时间推进用 widget 测试自带的 FakeAsync（`tester.pump(时长)`），不用
// `fake_async` 包——与仓库既有测试范式一致。
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/services/sync_on_change_scheduler.dart';

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
}
