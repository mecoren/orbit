// 桥抽象面扩展回归：云同步设置 4 个新方法（测试连接/断开/密码初始化/锁定）
// 在 Mock 与抽象契约上的行为，对齐 crates/orbit-flutter/src/api/sync.rs 语义。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/dto.dart';
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

  group('F77：mock 桥同步契约对齐 core', () {
    test("cloudSyncHistory scope='all' 是三种增量类型的并集，不含其他 sync_type",
        () async {
      final bridge = MockOrbitBridge();
      // 注入一行非增量类型（如全量备份）：core 'all' 口径必须把它排除
      bridge.store.syncHistory.add(SyncHistoryRow(
        id: 999,
        syncType: 'full_backup',
        status: 'success',
        startedAt: 9999999999999,
        finishedAt: 9999999999999,
        pulledCount: 0,
        pushedCount: 0,
        conflictCount: 0,
      ));

      final all = await bridge.cloudSyncHistory(scope: 'all', limit: 50);
      expect(
        all.any((r) => r.syncType == 'full_backup'),
        isFalse,
        reason: "'all' 与 core incremental_history 同口径=三种增量类型并集，"
            "不是「不过滤」",
      );
      expect(all.any((r) => r.syncType == 'incremental'), isTrue);
      expect(all.any((r) => r.syncType == 'push_only'), isTrue);
    });

    test("cloudSyncHistory scope='incremental' 只回 incremental 行", () async {
      final bridge = MockOrbitBridge();
      final rows =
          await bridge.cloudSyncHistory(scope: 'incremental', limit: 50);
      expect(rows, isNotEmpty);
      expect(rows.every((r) => r.syncType == 'incremental'), isTrue);
    });

    test('cloudSyncNow 回传 conflicts 与 changedTables（F42 精确失效链可测）',
        () async {
      final bridge = MockOrbitBridge();
      final r = await bridge.cloudSyncNow();
      expect(r.changedTables, contains('todo_tasks'),
          reason: 'mock 与 core 同口径填充 changed_tables，'
              '缺省会让调用方走保守全量回退而测不到精确失效');
      expect(r.conflicts, isA<int>());
    });
  });

  group('F77：SyncResultJson 契约字段', () {
    test('fromJson 解析 conflicts；缺失时回退 0（旧引擎/mock 兼容）', () {
      final withConflicts = SyncResultJson.fromJson({
        'pushed_modules': 1,
        'pulled_modules': 2,
        'uploaded_attachments': 0,
        'downloaded_attachments': 0,
        'conflicts': 3,
        'duration_ms': 100,
        'skipped': false,
        'errors': <String>[],
        'changed_tables': ['todo_tasks'],
      });
      expect(withConflicts.conflicts, 3);
      expect(withConflicts.changedTables, ['todo_tasks']);

      final without = SyncResultJson.fromJson({
        'pushed_modules': 0,
        'pulled_modules': 0,
        'uploaded_attachments': 0,
        'downloaded_attachments': 0,
        'duration_ms': 0,
        'skipped': false,
        'errors': <String>[],
      });
      expect(without.conflicts, 0);
      expect(without.changedTables, isEmpty);
    });
  });
}