// 每日摘要提醒（G3）移动端回归：
// - MockOrbitBridge 的偏好读写与越界校验（与 Rust digest_api 同口径）
// - 计数口径（今日截止 / 逾期 / 今日完成；本地日界 + 仅存活任务）
// - 通知文案与 Rust `summary_body` 同措辞
// - DigestScheduler 在插件不可用（纯测试环境）时静默降级、不抛
//
// 系统闹钟排程（zonedSchedule）不做集成测试——需真机/emulator，
// 与 P2 提醒升级的既有口径一致（notification_snooze_test.dart 同约定）。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/services/digest_scheduler.dart';

/// 直插一条最小任务行（只喂 digestSummary 读的四个字段）
void seedTask(
  MockOrbitBridge bridge,
  int id, {
  required int done,
  int? dueDate,
  int? doneAt,
  int isDeleted = 0,
}) {
  bridge.store.tasks[id] = {
    'id': id,
    'title': 't$id',
    'is_deleted': isDeleted,
    'done': done,
    'due_date': dueDate,
    'done_at': doneAt,
  };
}

void main() {
  late MockOrbitBridge bridge;

  setUp(() {
    bridge = MockOrbitBridge();
    bridge.store.tasks.clear();
  });

  tearDown(DigestScheduler.shutdown);

  group('偏好读写', () {
    test('默认关闭 + 08:00（与 Rust digest_api 一致）', () async {
      final p = await bridge.digestPrefs();
      expect(p.enabled, isFalse, reason: '摘要提醒是打扰型功能，默认不开启');
      expect((p.hour, p.minute), (8, 0));
      expect(p.label, '08:00');
    });

    test('往返 + 越界抛错', () async {
      await bridge.digestSetPrefs(enabled: true, hour: 21, minute: 30);
      final p = await bridge.digestPrefs();
      expect(p.enabled, isTrue);
      expect(p.label, '21:30');

      expect(
        () => bridge.digestSetPrefs(enabled: true, hour: 24, minute: 0),
        throwsA(isA<Exception>()),
      );
      expect(
        () => bridge.digestSetPrefs(enabled: true, hour: 8, minute: 60),
        throwsA(isA<Exception>()),
      );
      // 校验失败不落库
      expect((await bridge.digestPrefs()).label, '21:30');
    });
  });

  group('计数口径', () {
    test('今日截止 / 逾期 / 今日完成三档分离', () async {
      final now = DateTime.now();
      final dayStart =
          DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
      final dayEnd = dayStart + 86400000;

      seedTask(bridge, 1, done: 0, dueDate: dayStart + 3600000); // 今日
      seedTask(bridge, 2, done: 0, dueDate: dayStart - 3600000); // 昨天逾期
      seedTask(bridge, 3, done: 0, dueDate: dayStart - 7 * 86400000); // 上周逾期
      seedTask(bridge, 4, done: 1, dueDate: dayStart + 7200000, doneAt: now.millisecondsSinceEpoch);
      seedTask(bridge, 5, done: 1, doneAt: dayStart - 60000); // 昨天完成
      seedTask(bridge, 6, done: 0); // 无截止
      // 墓碑行不计
      seedTask(bridge, 7, done: 0, dueDate: dayStart + 1000, isDeleted: 1);

      final s = await bridge.digestSummary();
      expect(s.dueToday, 1);
      expect(s.overdue, 2, reason: '无截止不算逾期；墓碑行不算');
      expect(s.doneToday, 1);
      expect(dayEnd, greaterThan(dayStart));
    });

    test('文案与 Rust summary_body 同措辞', () async {
      final now = DateTime.now();
      final dayStart =
          DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;

      // 空表：鼓励语
      expect(await bridge.digestBody(), '今天没有待办，休息一下吧');

      // 只有今日
      seedTask(bridge, 1, done: 0, dueDate: dayStart + 3600000);
      expect(await bridge.digestBody(), '今日 1 项');

      // 加逾期
      seedTask(bridge, 2, done: 0, dueDate: dayStart - 1000);
      expect(await bridge.digestBody(), '今日 1 项 · 逾期 1 项');

      // 加今日完成
      seedTask(bridge, 3, done: 1, doneAt: now.millisecondsSinceEpoch);
      expect(await bridge.digestBody(), '今日 1 项 · 逾期 1 项 · 已完成 1 项');
    });
  });

  group('DigestScheduler', () {
    test('refresh 在插件不可用环境下静默降级（不抛）', () async {
      await bridge.digestSetPrefs(enabled: true, hour: 9, minute: 0);
      final scheduler = DigestScheduler.attachOnce(bridge);
      await scheduler.refresh();
      // 无断言目标：只要求不抛——排程由系统闹钟承担，测试环境无平台通道
      expect(await bridge.digestPrefs(), isA<DigestPrefs>());
    });

    test('关闭态下 refresh 同样不抛', () async {
      final scheduler = DigestScheduler.attachOnce(bridge);
      await scheduler.refresh();
      expect((await bridge.digestPrefs()).enabled, isFalse);
    });
  });
}
