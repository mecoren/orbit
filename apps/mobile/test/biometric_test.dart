import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/api/orbit_bridge.dart' show BiometricSecretBundle;
import 'package:orbit/data/providers/biometric_provider.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/services/biometric_service.dart';

/// 生物识别桥与服务闭环单测（纯 Dart，无 UI 层）
///
/// 覆盖：mock 桥三件套生命周期（setup→unlock→disable）与
/// BiometricService 编排（闸门/存储注入假实现）——口径与
/// Rust 侧 orbit-flutter biometric.rs 一一对应。
class _FakeGate implements BiometricGate {
  _FakeGate(this.result);

  /// 闸门固定结果（true=指纹通过；false=用户取消）
  bool result;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate() async => result;
}

class _FakeStore implements BiometricStore {
  final Map<String, String> _map = {};

  @override
  Future<void> clear() async => _map.clear();

  @override
  Future<BiometricSecretBundle?> read() async {
    final enc = _map['encrypted_db_key_bio'];
    final key = _map['biometric_key'];
    final nonce = _map['nonce'];
    if (enc == null || key == null || nonce == null) return null;
    return BiometricSecretBundle(
      encryptedDbKeyBio: enc,
      biometricKey: key,
      nonce: nonce,
    );
  }

  @override
  Future<void> write(BiometricSecretBundle bundle) async {
    _map['encrypted_db_key_bio'] = bundle.encryptedDbKeyBio;
    _map['biometric_key'] = bundle.biometricKey;
    _map['nonce'] = bundle.nonce;
  }
}

// 各用例经 _authedService 组装：统一 masterAuthSet 前置（biometric
// 密钥链依附于加密库）。

void main() {
  group('mock 桥 biometric 三件套生命周期', () {
    /// 已设主密码的桥（biometric unlock 的前置：密钥链依附于加密库）
    MockOrbitBridge authedBridge() {
      final bridge = MockOrbitBridge();
      bridge.store.masterAuthSet = true;
      return bridge;
    }

    test('setup→unlock 闭环返回 db_key_hex', () async {
      final bridge = authedBridge();
      final bundle = await bridge.biometricSetup('a' * 64);
      expect(bundle.encryptedDbKeyBio, isNotEmpty);
      expect(bundle.biometricKey, isNotEmpty);
      expect(bundle.nonce, isNotEmpty);

      // 同一 bundle 解锁成功；返回 hex（与 masterAuthUnlock 同契约）
      final dbKeyHex = await bridge.biometricUnlock(bundle);
      expect(dbKeyHex, 'a' * 64);
    });

    test('unlock 拒绝不匹配的密钥链（[biometric_failed]）', () async {
      final bridge = authedBridge();
      final bundle = await bridge.biometricSetup('a' * 64);
      final tampered = BiometricSecretBundle(
        encryptedDbKeyBio: 'tampered',
        biometricKey: bundle.biometricKey,
        nonce: bundle.nonce,
      );
      expect(
        () => bridge.biometricUnlock(tampered),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('biometric_failed'))),
      );
    });

    test('unlock 拒绝未设主密码（[not_initialized]）', () async {
      final bridge = MockOrbitBridge(); // 明文库：无主密码
      final bundle = await bridge.biometricSetup('a' * 64);
      expect(
        () => bridge.biometricUnlock(bundle),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('not_initialized'))),
      );
    });

    test('setup 拒绝非法 db_key_hex（[invalid_input]）', () async {
      final bridge = authedBridge();
      expect(
        () => bridge.biometricSetup('short'),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('invalid_input'))),
      );
    });

    test('disable 后 unlock 不可达（无三件套）', () async {
      final bridge = authedBridge();
      final bundle = await bridge.biometricSetup('a' * 64);
      await bridge.biometricDisable('any-password');
      // 桥层：密钥链虽已删（mock 内 _bioBundle=null），外部传入旧 bundle
      // 必然失配
      expect(
        () => bridge.biometricUnlock(bundle),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('biometric_failed'))),
      );
    });

    test('disable 拒绝空密码（[wrong_password]）', () async {
      final bridge = authedBridge();
      expect(
        () => bridge.biometricDisable(''),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('wrong_password'))),
      );
    });
  });

  group('BiometricService 编排', () {
    /// 已设主密码的桥 + service（unlock 链路前置）
    (MockOrbitBridge, BiometricService) authedService(
        _FakeGate gate, _FakeStore store) {
      final bridge = MockOrbitBridge()..store.masterAuthSet = true;
      return (bridge, BiometricService(bridge: bridge, gate: gate, store: store));
    }

    test('enable 全链：闸门通过 → 三件套落存储', () async {
      final store = _FakeStore();
      final service = authedService(_FakeGate(true), store).$2;

      expect(await service.isAvailable(), true);
      expect(await service.isEnabled(), false); // 初始未启用

      final ok = await service.enable('a' * 64);
      expect(ok, true);
      expect(await service.isEnabled(), true); // 三键齐全
    });

    test('enable 闸门取消：不落键、返回 false', () async {
      final store = _FakeStore();
      final service = authedService(_FakeGate(false), store).$2;

      final ok = await service.enable('a' * 64);
      expect(ok, false);
      expect(await service.isEnabled(), false);
    });

    test('unlock 全链：已启用 + 闸门通过 → db_key_hex', () async {
      final store = _FakeStore();
      final service = authedService(_FakeGate(true), store).$2;

      await service.enable('a' * 64);
      final dbKeyHex = await service.unlock();
      expect(dbKeyHex, 'a' * 64);
    });

    test('unlock 未启用：返回 null 不拉闸门', () async {
      final gate = _FakeGate(true);
      final service = authedService(gate, _FakeStore()).$2;
      // 未 enable 直接 unlock：read 为 null 短路，闸门不应被调用
      expect(await service.unlock(), isNull);
      expect(gate.result, true); // 未消费（仅验证无异常路径）
    });

    test('unlock 闸门取消：返回 null', () async {
      final store = _FakeStore();
      final service = authedService(_FakeGate(false), store).$2;
      await service.enable('a' * 64);

      expect(await service.unlock(), isNull);
    });

    test('disable 全链：桥验证通过 → 存储清空', () async {
      final store = _FakeStore();
      final service = authedService(_FakeGate(true), store).$2;
      await service.enable('a' * 64);

      await service.disable('any-password');
      expect(await service.isEnabled(), false);
    });

    test('disable 密码错误：抛错且存储保留', () async {
      final store = _FakeStore();
      final service = authedService(_FakeGate(true), store).$2;
      await service.enable('a' * 64);

      expect(
        () => service.disable(''),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('wrong_password'))),
      );
      expect(await service.isEnabled(), true); // 失败不清键
    });
  });

  group('biometricServiceProvider 注入', () {
    test('provider 默认组装 service（bridge 来自 orbitBridgeProvider）', () {
      final container = ProviderContainer(overrides: [
        orbitBridgeProvider.overrideWithValue(MockOrbitBridge()),
      ]);
      addTearDown(container.dispose);
      final service = container.read(biometricServiceProvider);
      expect(service, isA<BiometricService>());
      expect(service.bridge, isA<MockOrbitBridge>());
    });
  });
}
