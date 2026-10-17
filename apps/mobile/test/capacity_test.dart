// 今日容量纯函数（镜像桌面 shared/capacity.ts）：今日排程量 / 容量档位 / 文案。
// 口径与桌面逐字一致：只累计今日截止未完成的时长（逾期不计，归顺延面）；
// 档位 ok < 80% tight < 100% over（≥100% 归 over 警示档）；未设预算只报已排量。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/capacity.dart';

TodoTask _task(int id, {int? dueDate, int? durationMinutes, int done = 0}) =>
    TodoTask(
      id: id,
      uuid: 'u$id',
      title: 't$id',
      description: null,
      projectId: null,
      priority: 0,
      status: 'pending',
      done: done,
      doneAt: null,
      dueDate: dueDate,
      startDate: null,
      repeatAfter: 0,
      repeatMode: 0,
      repeatWeekdays: 0,
      repeatEndType: 0,
      repeatEndParam: 0,
      repeatFromDone: 0,
      repeatMonthMode: 0,
      repeatNthWeek: 0,
      percentDone: 0,
      position: id * 100,
      isFavorite: 0,
      myDayDate: null,
      durationMinutes: durationMinutes,
      isDeleted: 0,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: null,
      version: 0,
    );

void main() {
  group('todayLoadMinutes 今日排程量（桌面 capacity 同口径）', () {
    test('只累计今日截止未完成时长；未设时长不计', () {
      final now = DateTime(2026, 10, 17, 20).millisecondsSinceEpoch;
      final todayDue = DateTime(2026, 10, 17, 18).millisecondsSinceEpoch;
      final tomorrowDue = DateTime(2026, 10, 18, 18).millisecondsSinceEpoch;
      final load = todayLoadMinutes([
        _task(1, dueDate: todayDue, durationMinutes: 60),
        _task(2, dueDate: todayDue, durationMinutes: 30),
        _task(3, dueDate: todayDue), // 未设时长
        _task(4, dueDate: tomorrowDue, durationMinutes: 120), // 明天
        _task(5, dueDate: todayDue, durationMinutes: 90, done: 1), // 已完成
      ], now);
      expect(load, 90);
    });

    test('逾期任务不计入今日排程（归顺延处置面）', () {
      final now = DateTime(2026, 10, 17, 20).millisecondsSinceEpoch;
      final yesterday = DateTime(2026, 10, 16, 18).millisecondsSinceEpoch;
      expect(todayLoadMinutes([_task(1, dueDate: yesterday, durationMinutes: 60)], now), 0);
    });

    test('非正时长视同未设（防御脏值）', () {
      final now = DateTime(2026, 10, 17, 20).millisecondsSinceEpoch;
      final todayDue = DateTime(2026, 10, 17, 18).millisecondsSinceEpoch;
      expect(todayLoadMinutes([_task(1, dueDate: todayDue, durationMinutes: -30)], now), 0);
      expect(todayLoadMinutes([_task(1, dueDate: todayDue, durationMinutes: 0)], now), 0);
    });

    test('空列表 / 全未设时长 → 0', () {
      expect(todayLoadMinutes([], DateTime.now().millisecondsSinceEpoch), 0);
      expect(todayLoadMinutes([_task(1)], DateTime.now().millisecondsSinceEpoch), 0);
    });
  });

  group('capacityStatus 容量档位', () {
    test('无预算（null）/ 非正 → unknown', () {
      expect(capacityStatus(600, null).level, CapacityLevel.unknown);
      expect(capacityStatus(60, 0).level, CapacityLevel.unknown);
      expect(capacityStatus(60, -1).level, CapacityLevel.unknown);
    });

    test('充足 < 80% ≤ 偏紧 < 100% ≤ 超载', () {
      expect(capacityStatus(383, 480).level, CapacityLevel.ok);
      expect(capacityStatus(384, 480).level, CapacityLevel.tight);
      expect(capacityStatus(479, 480).level, CapacityLevel.tight);
      expect(capacityStatus(480, 480).level, CapacityLevel.over);
      expect(capacityStatus(600, 480).level, CapacityLevel.over);
      expect(capacityStatus(0, 480).level, CapacityLevel.ok);
    });

    test('超出分钟数只在超载时为正', () {
      expect(capacityStatus(600, 480).overBy, 120);
      expect(capacityStatus(400, 480).overBy, 0);
      expect(capacityStatus(400, null).overBy, 0);
    });
  });

  group('formatMinutesShort 分钟→短文案', () {
    test('整小时 / 带分钟 / 不足小时', () {
      expect(formatMinutesShort(480), '8h');
      expect(formatMinutesShort(510), '8h30m');
      expect(formatMinutesShort(45), '45m');
      expect(formatMinutesShort(0), '0m');
      expect(formatMinutesShort(-10), '0m');
    });
  });

  group('capacityHint 容量提示文案（双端统一措辞）', () {
    test('充足/偏紧 → 已排 X / 预算 Y', () {
      expect(capacityHint(120, 480), '今日已排 2h / 预算 8h');
      expect(capacityHint(400, 480), '今日已排 6h40m / 预算 8h');
    });

    test('超载带超出量；恰好排满报「已排满」', () {
      expect(capacityHint(600, 480), '今日已排 10h · 超出 2h');
      expect(capacityHint(480, 480), '今日已排 8h · 已排满');
    });

    test('未设预算 → 只报已排量', () {
      expect(capacityHint(120, null), '今日已排 2h');
      expect(capacityHint(0, null), '今日已排 0m');
    });
  });

  test('默认预算 480 分钟（8 小时工作日）', () {
    expect(kDefaultCapacityMinutes, 480);
  });
}
