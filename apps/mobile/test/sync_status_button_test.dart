// 标题栏云同步图标行为测试：未配置态渲染（引导分支）、已配置+已解锁点击
// 弹出信息面板、面板内「立即同步」成功链路（toast + 面板收起 + 图标回落）。
//
// 测试纪律（复用 sync_settings_page_test 口径）：
// 1. Mock 桥有 120ms 延迟：先发起、pump(300ms) 推进虚拟时钟后再 await；
// 2. 结尾 pump 掉 WaitToast(2.6s)/成功态(1.8s) 计时器，避免残留 Timer 判失败。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/shared/widgets/sync_status_button.dart';

/// WaitToast 经全局 rootNavigatorKey 的 Overlay 插入（wait_toast.dart），
/// 故测试宿主 MaterialApp 必须挂同一 key，否则 toast 静默丢弃。
Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SyncStatusButton(),
          ),
        ),
      ),
    );

/// 越过 Mock 120ms 延迟并收敛帧
Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 收尾：跑完 toast / 成功态计时器，避免残留 Timer
Future<void> _drainTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

const _presetConfig = <String, Object?>{
  'engine': 'webdav',
  'endpoint': 'https://dav.example.com',
  'username': 'demo',
  'password': 'pw',
};

void main() {
  testWidgets('未配置：渲染云图标且提示引导态（不弹信息面板）', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _flush(tester);

    expect(find.byIcon(Icons.cloud_rounded), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).tooltip,
      '未配置云同步',
    );
    expect(find.text('立即同步'), findsNothing);
  });

  testWidgets('已配置且已解锁：点击弹出信息面板（状态/上次/下次 + 立即同步）',
      (tester) async {
    final bridge = MockOrbitBridge();
    final presetConfig = bridge.syncConfigSave(_presetConfig);
    final presetCrypto = bridge.syncCryptoInit('123456');
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);
    await presetConfig;
    await presetCrypto;
    await _flush(tester);

    expect(
      tester.widget<IconButton>(find.byType(IconButton)).tooltip,
      '已就绪',
    );

    await tester.tap(find.byType(IconButton));
    await _flush(tester);

    expect(find.text('云同步'), findsOneWidget);
    expect(find.text('已就绪'), findsOneWidget);
    expect(find.text('上次同步'), findsOneWidget);
    expect(find.text('下次自动同步'), findsOneWidget);
    expect(find.text('立即同步'), findsOneWidget);

    await _drainTimers(tester);
  });

  testWidgets('面板内立即同步：成功 toast + 面板收起', (tester) async {
    final bridge = MockOrbitBridge();
    final presetConfig = bridge.syncConfigSave(_presetConfig);
    final presetCrypto = bridge.syncCryptoInit('123456');
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);
    await presetConfig;
    await presetCrypto;
    await _flush(tester);

    await tester.tap(find.byType(IconButton));
    await _flush(tester);
    expect(find.text('立即同步'), findsOneWidget);

    await tester.tap(find.text('立即同步'));
    await _flush(tester);

    expect(find.text('同步完成：推送 2 模块 / 拉取 1 模块'), findsOneWidget);
    expect(find.text('立即同步'), findsNothing);

    await _drainTimers(tester);
    // 成功态回落后回到待命
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).tooltip,
      '已就绪',
    );
  });
}
