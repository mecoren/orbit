import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/utils/sync_status_text.dart';

/// 云同步状态文案与估算纯函数单测（口径对齐桌面 lib/sync-status.test.ts）
void main() {
  group('deriveSyncUiStatus', () {
    test('未配置优先级最高（即使运行态为同步中）', () {
      expect(
        deriveSyncUiStatus(
          hasConfig: false,
          hasPassword: true,
          isUnlocked: true,
          runStatus: SyncUiStatus.syncing,
        ),
        SyncUiStatus.unconfigured,
      );
    });

    test('有配置但未设置同步密码归 locked', () {
      expect(
        deriveSyncUiStatus(
          hasConfig: true,
          hasPassword: false,
          isUnlocked: false,
          runStatus: SyncUiStatus.idle,
        ),
        SyncUiStatus.locked,
      );
    });

    test('已设置密码但未解锁归 locked', () {
      expect(
        deriveSyncUiStatus(
          hasConfig: true,
          hasPassword: true,
          isUnlocked: false,
          runStatus: SyncUiStatus.idle,
        ),
        SyncUiStatus.locked,
      );
    });

    test('已配置且已解锁时跟随运行态', () {
      for (final run in [
        SyncUiStatus.idle,
        SyncUiStatus.syncing,
        SyncUiStatus.success,
        SyncUiStatus.error,
      ]) {
        expect(
          deriveSyncUiStatus(
            hasConfig: true,
            hasPassword: true,
            isUnlocked: true,
            runStatus: run,
          ),
          run,
        );
      }
    });
  });

  group('syncStatusLabel', () {
    test('各状态文案', () {
      expect(syncStatusLabel(SyncUiStatus.unconfigured), '未配置云同步');
      expect(syncStatusLabel(SyncUiStatus.locked), '同步密码已锁定');
      expect(syncStatusLabel(SyncUiStatus.locked, hasPassword: false), '未设置同步密码');
      expect(syncStatusLabel(SyncUiStatus.idle), '已就绪');
      expect(syncStatusLabel(SyncUiStatus.syncing), '正在同步…');
      expect(syncStatusLabel(SyncUiStatus.success), '同步完成');
      expect(syncStatusLabel(SyncUiStatus.error), '同步失败');
    });
  });

  group('formatLastSynced', () {
    test('null / 0 显示从未同步', () {
      expect(formatLastSynced(null), '从未同步');
      expect(formatLastSynced(0), '从未同步');
    });

    test('毫秒时间戳按本地时区展示（yyyy-MM-dd HH:mm）', () {
      final ts = DateTime(2026, 9, 17, 8, 30).millisecondsSinceEpoch;
      expect(formatLastSynced(ts), '2026-09-17 08:30');
    });
  });

  group('estimateNextSyncAt', () {
    final last = DateTime(2026, 9, 17, 8, 0).millisecondsSinceEpoch;

    test('正常：上次同步 + 间隔分钟', () {
      expect(
        estimateNextSyncAt(
          autoSyncEnabled: true,
          intervalMinutes: 60,
          lastSyncedAtMs: last,
        ),
        last + 60 * 60000,
      );
    });

    test('关闭定时 / 间隔为 0 / 无上次时间 → null', () {
      expect(
        estimateNextSyncAt(
          autoSyncEnabled: false,
          intervalMinutes: 60,
          lastSyncedAtMs: last,
        ),
        isNull,
      );
      expect(
        estimateNextSyncAt(
          autoSyncEnabled: true,
          intervalMinutes: 0,
          lastSyncedAtMs: last,
        ),
        isNull,
      );
      expect(
        estimateNextSyncAt(autoSyncEnabled: true, intervalMinutes: 60),
        isNull,
      );
      expect(
        estimateNextSyncAt(
          autoSyncEnabled: true,
          intervalMinutes: 60,
          lastSyncedAtMs: 0,
        ),
        isNull,
      );
    });
  });

  group('formatNextSync', () {
    test('无估算值说明未启用定时同步', () {
      expect(formatNextSync(null), '未启用定时同步');
    });

    test('有估算值带「约」前缀', () {
      final ts = DateTime(2026, 9, 17, 9, 0).millisecondsSinceEpoch;
      expect(formatNextSync(ts), '约 2026-09-17 09:00');
    });
  });

  group('syncResultSummary', () {
    test('忙时跳过明确提示已有任务', () {
      expect(
        syncResultSummary(pushedModules: 0, pulledModules: 0, skipped: true),
        '已有同步任务在进行中',
      );
    });

    test('正常结果含推拉模块数', () {
      expect(
        syncResultSummary(pushedModules: 2, pulledModules: 1, skipped: false),
        '同步完成：推送 2 模块 / 拉取 1 模块',
      );
    });

    test('无变化且无错误时显示已是最新（而非 0 模块）', () {
      expect(
        syncResultSummary(pushedModules: 0, pulledModules: 0, skipped: false),
        '同步完成：已是最新，无需同步',
      );
    });

    test('0 模块但有错误时仍显示计数加后缀', () {
      expect(
        syncResultSummary(
          pushedModules: 0,
          pulledModules: 0,
          skipped: false,
          errorCount: 1,
        ),
        '同步完成：推送 0 模块 / 拉取 0 模块（1 个非致命错误）',
      );
    });

    test('有非致命错误时追加计数', () {
      expect(
        syncResultSummary(
          pushedModules: 2,
          pulledModules: 1,
          skipped: false,
          errorCount: 3,
        ),
        '同步完成：推送 2 模块 / 拉取 1 模块（3 个非致命错误）',
      );
    });
  });

  group('syncErrorAction', () {
    test('tag 解析：方括号前缀提取，无标签为空', () {
      expect(syncErrorTag('[key_mismatch] 本地密钥与云端密文不匹配'), 'key_mismatch');
      expect(syncErrorTag('[payload_version] 云端载荷版本高于本端'), 'payload_version');
      expect(syncErrorTag('plain message'), '');
    });

    test('key_mismatch 走恢复，payload_version 走升级（F44 翻案防线）', () {
      expect(syncErrorAction('key_mismatch'), SyncErrorAction.recovery);
      expect(syncErrorAction('payload_version'), SyncErrorAction.upgrade);
      expect(
        syncErrorAction('payload_version'),
        isNot(SyncErrorAction.recovery),
      );
    });

    test('密码类走解锁，其余按普通失败', () {
      expect(syncErrorAction('password'), SyncErrorAction.unlock);
      expect(syncErrorAction('not_unlocked'), SyncErrorAction.unlock);
      expect(syncErrorAction('network'), SyncErrorAction.none);
      expect(syncErrorAction('rate_limited'), SyncErrorAction.none);
      expect(syncErrorAction(''), SyncErrorAction.none);
    });
  });
}
