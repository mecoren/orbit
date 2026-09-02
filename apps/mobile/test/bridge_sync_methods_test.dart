// 桥抽象面扩展回归：云同步设置 4 个新方法（测试连接/断开/密码初始化/锁定）
// 在 Mock 与抽象契约上的行为，对齐 crates/orbit-flutter/src/api/sync.rs 语义。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';

void main() {
  group('MockOrbitBridge 同步扩展方法', () {
    test('syncTestConnection：无凭据且未配置 → [config] 校验失败', () async {
      final bridge = MockOrbitBridge();
      await expectLater(
        bridge.syncTestConnection({
          'engine': 'webdav',
          'endpoint': 'https://dav.example.com',
          'username': '',
          'password': '',
        }),
        throwsException,
      );
    });

    test('syncTestConnection：已存配置回填凭据后成功返回条目数', () async {
      final bridge = MockOrbitBridge();
      await bridge.syncConfigSave({
        'engine': 'webdav',
        'endpoint': 'https://dav.example.com',
        'username': 'demo',
        'password': 'pw',
      });
      final n = await bridge.syncTestConnection({
        'engine': 'webdav',
        'endpoint': 'https://dav.example.com',
        'username': '',
        'password': '',
      });
      expect(n, isA<int>());
    });

    test('syncDisconnect：清除配置后 syncConfigGet 返回 null', () async {
      final bridge = MockOrbitBridge();
      await bridge.syncConfigSave({
        'engine': 'webdav',
        'endpoint': 'https://dav.example.com',
      });
      expect(await bridge.syncConfigGet(), isNotNull);
      await bridge.syncDisconnect();
      expect(await bridge.syncConfigGet(), isNull);
    });

    test('syncCryptoInit + status：设置后 hasPassword/isUnlocked 均为 true',
        () async {
      final bridge = MockOrbitBridge();
      expect((await bridge.syncCryptoStatus()).hasPassword, isFalse);
      await bridge.syncCryptoInit('123456', remember: true);
      final s = await bridge.syncCryptoStatus();
      expect(s.hasPassword, isTrue);
      expect(s.isUnlocked, isTrue);
    });

    test('syncCryptoLock：锁定后 isUnlocked 为 false（Data Key 出内存）',
        () async {
      final bridge = MockOrbitBridge();
      await bridge.syncCryptoInit('123456');
      await bridge.syncCryptoLock();
      final s = await bridge.syncCryptoStatus();
      expect(s.isUnlocked, isFalse);
      expect(s.hasPassword, isTrue);
    });
  });
}
