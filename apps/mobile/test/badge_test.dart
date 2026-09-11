import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/badge_count.dart';
import 'package:orbit/services/badge_service.dart';

/// B6 Android 图标角标：计数纯函数 + BadgeService 注入式更新
///（插件真实调用属平台集成面，不 mock 通道——注入函数测逻辑）
void main() {
  TodoTask task(int? due, {bool done = false}) => TodoTask(
        id: 1,
        uuid: 'u',
        title: 't',
        description: null,
        projectId: null,
        priority: 0,
        status: done ? 'done' : 'pending',
        done: done ? 1 : 0,
        doneAt: null,
        dueDate: due,
        startDate: null,
        repeatAfter: 0,
        repeatMode: 0,
        repeatWeekdays: 0,
        repeatEndType: 0,
        repeatEndParam: 0,
        repeatFromDone: 0,
        percentDone: 0,
        position: 0,
        isFavorite: 0,
        myDayDate: null,
        isDeleted: 0,
        createdAt: 0,
        updatedAt: 0,
        deletedAt: null,
        version: 0,
      );

  group('dueTodayOrOverdueCount（今天截止或已逾期的未完成数）', () {
    final now = DateTime(2026, 9, 9, 12);
    final todayZero = DateTime(2026, 9, 9).millisecondsSinceEpoch;
    final tomorrowZero = todayZero + 24 * 3600 * 1000;

    test('今天截止计入', () {
      expect(dueTodayOrOverdueCount([task(todayZero)], now), 1);
    });

    test('逾期计入（昨天/上月）', () {
      expect(
        dueTodayOrOverdueCount(
          [task(todayZero - 24 * 3600 * 1000), task(todayZero - 30 * 24 * 3600 * 1000)],
          now,
        ),
        2,
      );
    });

    test('明日截止不计入', () {
      expect(dueTodayOrOverdueCount([task(tomorrowZero)], now), 0);
    });

    test('已完成/无日期不计入', () {
      expect(
        dueTodayOrOverdueCount([task(todayZero, done: true), task(null)], now),
        0,
      );
    });

    test('空列表为 0', () {
      expect(dueTodayOrOverdueCount([], now), 0);
    });
  });

  group('BadgeService', () {
    test('正常更新透传 count', () async {
      final calls = <int>[];
      final svc = BadgeService(setBadge: (n) async => calls.add(n));
      await svc.update(3);
      expect(calls, [3]);
    });

    test('count 0 显式清零（传 0 而非跳过）', () async {
      final calls = <int>[];
      final svc = BadgeService(setBadge: (n) async => calls.add(n));
      await svc.update(0);
      expect(calls, [0]);
    });

    test('ROM 不支持抛错全吞不炸', () async {
      final svc = BadgeService(setBadge: (n) async => throw Exception('rom'));
      await svc.update(3); // 不抛即通过
    });
  });
}
