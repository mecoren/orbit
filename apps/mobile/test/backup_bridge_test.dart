// 桥接层 P0 批次口径锁定（全量备份 / 通知历史 / 同步历史 / 标签·模板·筛选器更新）。
//
// Mock 是移动端测试的默认注入实现（详见 AGENTS 移动端约定），故新桥方法
// 先在 mock 侧锁语义，再由 RustOrbitBridge 同口径转发（三处同口径）。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';

void main() {
  late MockOrbitBridge bridge;

  setUp(() {
    bridge = MockOrbitBridge();
  });

  group('全量备份', () {
    test('未解锁同步密码时导出被拒绝（对齐 Rust ensure_unlocked）', () async {
      await expectLater(
        bridge.fullBackupExport(),
        throwsA(predicate((e) => e.toString().contains('[not_unlocked]'))),
      );
    });

    test('导出：写入本地清单 + 清单表计数来自内存库', () async {
      await bridge.syncCryptoInit('sync-pass');
      final result = await bridge.fullBackupExport();

      expect(result.localPath, isNotNull);
      expect(result.manifest.tableCounts, isNotEmpty);
      expect(
        result.manifest.tableCounts
            .firstWhere((c) => c.table == 'todo_tasks')
            .count,
        bridge.store.tasks.length,
      );
      expect(result.manifest.totalRecords, greaterThan(0));

      final list = await bridge.fullBackupListLocal();
      expect(list, hasLength(1));
      expect(list.first.filename, endsWith('.orfullsync'));
    });

    test('uploadCloud 但未配置云同步：与 Rust 同口径直接报 [config]', () async {
      await bridge.syncCryptoInit('sync-pass');
      await expectLater(
        bridge.fullBackupExport(uploadCloud: true),
        throwsA(predicate((e) => e.toString().contains('[config]'))),
      );
    });

    test('uploadCloud 且已配置：本地 + 云端副本各一份', () async {
      await bridge.syncCryptoInit('sync-pass');
      bridge.store.syncConfigured = true;
      final result = await bridge.fullBackupExport(uploadCloud: true);

      expect(result.cloudUploaded, isTrue);
      expect(result.cloudPath, isNotNull);
      expect(await bridge.fullBackupListCloud(), hasLength(1));
    });

    test('恢复预览：抽样任务带项目名与完成态统计', () async {
      await bridge.syncCryptoInit('sync-pass');
      final preview = await bridge.fullBackupPeekLocal(const [1, 2, 3]);

      expect(preview.sampleTasks, isNotEmpty);
      expect(preview.sampleTasks.length, lessThanOrEqualTo(10));
      expect(preview.taskStats.total, bridge.store.tasks.length);
      expect(preview.schemaMismatch, isFalse);
      expect(preview.manifest.deviceId, isNotEmpty);
    });

    test('导入：广播 table="*" 事件（前端回退全量失效）', () async {
      await bridge.syncCryptoInit('sync-pass');
      final events = <String>[];
      final sub = bridge.dbChanges.listen((e) => events.add(e.table));

      final result = await bridge.fullBackupImport(const [9, 9]);
      await Future<void>.delayed(Duration.zero);

      expect(result.successCount, bridge.store.tasks.length);
      expect(events, contains('*'));
      await sub.cancel();
    });

    test('删除本地备份：清单即时收敛', () async {
      await bridge.syncCryptoInit('sync-pass');
      final entry = (await bridge.fullBackupExport()).filePath;
      await bridge.fullBackupDeleteLocal(entry);
      expect(await bridge.fullBackupListLocal(), isEmpty);
    });
  });

  group('自动备份偏好', () {
    test('默认值：调度关闭 + 本地/云端开关开（与 core BackupPrefs::default 同口径）',
        () async {
      final prefs = await bridge.backupPrefsGet();
      expect(prefs.scheduleType, 'off');
      expect(prefs.localBackupEnabled, isTrue);
      expect(prefs.cloudBackupEnabled, isTrue);
      expect(prefs.nextBackupAt, 0);
    });

    test('保存后回读一致', () async {
      final saved = await bridge.backupPrefsSave(
        BackupPrefs.initial.copyWith(
          scheduleType: 'daily',
          scheduleTime: '08:30',
          keepLatest: true,
        ),
      );
      expect(saved.scheduleType, 'daily');
      expect(saved.keepLatest, isTrue);

      final read = await bridge.backupPrefsGet();
      expect(read.scheduleTime, '08:30');
      expect(read.keepLatest, isTrue);
    });
  });

  group('通知历史', () {
    test('列表按时间倒序；kind 过滤生效', () async {
      final all = await bridge.notificationLogList();
      expect(all, isNotEmpty);
      for (var i = 1; i < all.length; i++) {
        expect(all[i - 1].createdAt, greaterThanOrEqualTo(all[i].createdAt));
      }

      final due = await bridge.notificationLogList(kind: 'reminder_due');
      expect(due, isNotEmpty);
      expect(due.every((r) => r.kind == 'reminder_due'), isTrue);
    });

    test('清空返回删除行数并置空', () async {
      final removed = await bridge.notificationLogClear();
      expect(removed, greaterThan(0));
      expect(await bridge.notificationLogList(), isEmpty);
    });
  });

  group('同步历史', () {
    test('scope 过滤 + limit 夹紧', () async {
      expect((await bridge.cloudSyncHistory()).length, greaterThanOrEqualTo(2));
      final push = await bridge.cloudSyncHistory(scope: 'push_only');
      expect(push.every((r) => r.syncType == 'push_only'), isTrue);

      final one = await bridge.cloudSyncHistory(limit: 1);
      expect(one, hasLength(1));
    });
  });

  group('组织能力写路径', () {
    test('标签改名/改色', () async {
      final label = (await bridge.todoLabelList(const ListFilter())).first;
      final updated = await bridge.todoLabelUpdate(
        label.id,
        '{"title":"已改名","hex_color":"#123456"}',
      );
      expect(updated.title, '已改名');
      expect(updated.hexColor, '#123456');
    });

    test('模板更新（payload 白名单校验）', () async {
      final tpl = await bridge.templateCreate('周会', '{"title":"周会"}');
      final updated = await bridge.templateUpdate(
        tpl.id,
        '周会模板',
        '{"title":"周会","priority":3}',
      );
      expect(updated.name, '周会模板');
      expect(updated.payload, contains('priority'));

      await expectLater(
        bridge.templateUpdate(tpl.id, '坏模板', '{"nope":1}'),
        throwsA(isA<Exception>()),
      );
    });

    test('筛选器更新：保留 id/uuid，仅替换名称与条件', () async {
      final sf = await bridge.savedFilterCreate('逾期', '{"due_overdue":true}');
      final updated = await bridge.savedFilterUpdate(
        sf.id,
        '逾期+收藏',
        '{"due_overdue":true,"favorite_only":true}',
      );
      expect(updated.id, sf.id);
      expect(updated.uuid, sf.uuid);
      expect(updated.name, '逾期+收藏');

      final all = await bridge.savedFiltersList();
      expect(all.where((f) => f.id == sf.id), hasLength(1));
    });
  });
}
