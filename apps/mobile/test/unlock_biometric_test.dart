import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/api/orbit_bridge.dart' show BiometricSecretBundle;
import 'package:orbit/data/providers/biometric_provider.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/auth/unlock_page.dart';
import 'package:orbit/services/biometric_service.dart';

/// UnlockPage 指纹入口 widget 测试
///
/// 覆盖：未启用指纹时按钮不出现（界面与原先一致）；已启用时按钮出现、
/// 点击走通闸门+解密并回调 onUnlocked(db_key_hex)；闸门取消时停留本页。
/// local_auth/secure_storage 均为真插件，测试环境必炸——经
/// BiometricGate/BiometricStore 注入假实现（BadgeService 注入口同款）。

class _FakeGate implements BiometricGate {
  _FakeGate(this.result);
  bool result;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate() async => result;
}

class _FakeStore implements BiometricStore {
  BiometricSecretBundle? bundle;

  @override
  Future<void> clear() async => bundle = null;

  @override
  Future<BiometricSecretBundle?> read() async => bundle;

  @override
  Future<void> write(BiometricSecretBundle b) async => bundle = b;
}

/// 桥与存储同装同一三件套（mock 桥 unlock 校验三键全等）
BiometricSecretBundle _syncBundle(MockOrbitBridge bridge) {
  final b = BiometricSecretBundle(
    encryptedDbKeyBio: 'test-enc',
    biometricKey: 'test-key',
    nonce: 'test-nonce',
  );
  bridge.bioBundleForTest = b;
  return b;
}

void main() {
  testWidgets('未启用指纹：解锁页不出现指纹按钮', (tester) async {
    final bridge = MockOrbitBridge()..store.masterAuthSet = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          orbitBridgeProvider.overrideWithValue(bridge),
          biometricServiceProvider.overrideWithValue(BiometricService(
            bridge: bridge,
            gate: _FakeGate(true),
            store: _FakeStore(), // 无三件套 = 未启用
          )),
        ],
        child: const MaterialApp(home: UnlockPage(onUnlocked: fail)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('指纹解锁'), findsNothing);
    expect(find.text('解锁'), findsOneWidget);
  });

  testWidgets('已启用指纹：点击指纹按钮走通解锁回调', (tester) async {
    final bridge = MockOrbitBridge()..store.masterAuthSet = true;
    final store = _FakeStore()..bundle = _syncBundle(bridge);
    String? unlockedKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          orbitBridgeProvider.overrideWithValue(bridge),
          biometricServiceProvider.overrideWithValue(BiometricService(
            bridge: bridge,
            gate: _FakeGate(true),
            store: store,
          )),
        ],
        child: MaterialApp(
          home: UnlockPage(onUnlocked: (key) => unlockedKey = key),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('指纹解锁'), findsOneWidget);
    await tester.tap(find.text('指纹解锁'));
    // mock 桥 120ms 人为延迟（unlock 内桥一跳）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(unlockedKey, 'a' * 64);
  });

  testWidgets('闸门取消：停留解锁页不回调', (tester) async {
    final bridge = MockOrbitBridge()..store.masterAuthSet = true;
    final store = _FakeStore()..bundle = _syncBundle(bridge);
    var called = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          orbitBridgeProvider.overrideWithValue(bridge),
          biometricServiceProvider.overrideWithValue(BiometricService(
            bridge: bridge,
            gate: _FakeGate(false), // 用户取消指纹
            store: store,
          )),
        ],
        child: MaterialApp(
          home: UnlockPage(onUnlocked: (_) => called = true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('指纹解锁'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(called, false);
    expect(find.text('指纹解锁'), findsOneWidget); // 仍在解锁页
  });
}
