import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/biometric_provider.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/settings_screen.dart';
import 'package:orbit/services/biometric_service.dart';
import 'package:orbit/data/api/orbit_bridge.dart' show BiometricSecretBundle;

/// 设置页安全卡指纹开关 widget 测试
///
/// 覆盖：指纹可用时展示「指纹解锁」开关；打开 → 密码确认弹窗 → 桥解锁
/// 验证 + 闸门通过 + 三件套落存储（开关翻转）；关闭 → 密码弹窗 + 删键
///（开关回落）。插件经假 gate/store 注入（unlock_biometric_test 同款）。

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

Widget _wrap(MockOrbitBridge bridge, BiometricService service) =>
    ProviderScope(
      overrides: [
        orbitBridgeProvider.overrideWithValue(bridge),
        biometricServiceProvider.overrideWithValue(service),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    );

void main() {
  testWidgets('无指纹硬件：安全卡回退只读提示', (tester) async {
    final bridge = MockOrbitBridge()..store.masterAuthSet = true;
    await tester.pumpWidget(_wrap(
      bridge,
      BiometricService(
        bridge: bridge,
        // isAvailable=false 的替身：安全卡回退只读提示
        gate: _UnavailableGate(),
        store: _FakeStore(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('指纹解锁'), findsNothing);
    expect(find.textContaining('未检测到指纹硬件'), findsOneWidget);
  });

  testWidgets('打开开关：密码确认 → 指纹闸门 → 落键翻转', (tester) async {
    final bridge = MockOrbitBridge()..store.masterAuthSet = true;
    final store = _FakeStore();
    await tester.pumpWidget(_wrap(
      bridge,
      BiometricService(
        bridge: bridge,
        gate: _FakeGate(true),
        store: store,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('指纹解锁'), findsOneWidget);
    final switchFinder = find.byType(Switch);
    expect(switchFinder, findsOneWidget);

    // 开关当前关（value=false）→ 点开 → 弹密码确认
    // （同步卡新增「冲突记录」入口行后开关落到首屏之下：先上滚再点；
    //  不用 ensureVisible——贴顶会被 LiquidGlassTitleBar 浮层遮住点不中）
    await tester.drag(find.byType(ListView).first, const Offset(0, -140));
    await tester.pumpAndSettle();
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(find.text('开启指纹解锁'), findsOneWidget);

    // 输入主密码确认（mock 桥任意非空密码可解锁）
    await tester.enterText(find.byType(TextField), 'test-password');
    await tester.tap(find.text('确认'));
    // masterAuthUnlock 一跳 + enable 内 setup 一跳：120ms x2 + 渲染
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 开关翻转 + 三件套已落存储
    final sw = tester.widget<Switch>(switchFinder);
    expect(sw.value, true);
    expect(store.bundle, isNotNull);
  });

  testWidgets('关闭开关：密码确认 → 删键回落', (tester) async {
    final bridge = MockOrbitBridge()..store.masterAuthSet = true;
    final store = _FakeStore()
      ..bundle = const BiometricSecretBundle(
        encryptedDbKeyBio: 'test-enc',
        biometricKey: 'test-key',
        nonce: 'test-nonce',
      );
    await tester.pumpWidget(_wrap(
      bridge,
      BiometricService(
        bridge: bridge,
        gate: _FakeGate(true),
        store: store,
      ),
    ));
    await tester.pumpAndSettle();

    final switchFinder = find.byType(Switch);
    expect(tester.widget<Switch>(switchFinder).value, true);

    // 同「打开开关」：先上滚再点（同步卡新增入口行后首屏放不下）
    await tester.drag(find.byType(ListView).first, const Offset(0, -140));
    await tester.pumpAndSettle();
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(find.text('关闭指纹解锁'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'test-password');
    await tester.tap(find.text('确认'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(switchFinder).value, false);
    expect(store.bundle, isNull);
  });
}

/// 指纹硬件不可用的闸门替身（isAvailable=false）
class _UnavailableGate implements BiometricGate {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate() async => true;
}
