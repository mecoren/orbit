// 引导式周回顾三组清单（镜像桌面 shared/weekly-review.ts）：逾期 / 无日期 / 停滞。
// 口径与桌面逐字一致：三组只收未完成；逾期以今天零点为界（今天到期不算）；
// 停滞 = updated_at 超 7 天未动；三组可重叠、组内按原序去重。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/weekly_review.dart';

TodoTask _task(
  int id, {
  int? dueDate,
  int? updatedAt,
  int done = 0,
}) =>
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
      durationMinutes: null,
      isDeleted: 0,
      createdAt: 0,
      updatedAt: updatedAt ?? 0,
      deletedAt: null,
      version: 0,
    );

void main() {
  final day = const Duration(days: 1).inMilliseconds;

  group('collectWeeklyReview 三组清单（桌面 weekly-review 同口径）', () {
    test('overdue：逾期未完成；今天到期不算逾期', () {
      final now = DateTime(2026, 10, 17, 20).millisecondsSinceEpoch;
      final todayZero = DateTime(2026, 10, 17).millisecondsSinceEpoch;
      final r = collectWeeklyReview([
        _task(1, dueDate: todayZero - day), // 昨天 → 逾期
        _task(2, dueDate: todayZero + 1), // 今天 → 不算
        _task(3, dueDate: todayZero - day, done: 1), // 已完成
      ], now);
      expect(r.overdue.map((t) => t.id), [1]);
    });

    test('undated：无截止日的未完成任务', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final r = collectWeeklyReview([
        _task(1),
        _task(2, dueDate: now),
        _task(3, done: 1),
      ], now);
      expect(r.undated.map((t) => t.id), [1]);
    });

    test('stalled：updated_at 超 7 天未动的未完成任务', () {
      final now = DateTime(2026, 10, 17, 20).millisecondsSinceEpoch;
      final r = collectWeeklyReview([
        _task(1, updatedAt: now - 8 * day), // 8 天前 → 停滞
        _task(2, updatedAt: now - 3 * day), // 3 天前 → 不停滞
        _task(3, updatedAt: now - 10 * day, done: 1), // 已完成不计
      ], now);
      expect(r.stalled.map((t) => t.id), [1]);
    });

    test('停滞与逾期可重叠（同一任务多组出现）', () {
      final now = DateTime(2026, 10, 17, 20).millisecondsSinceEpoch;
      final overdueDue = DateTime(2026, 10, 10, 9).millisecondsSinceEpoch;
      final r = collectWeeklyReview([
        _task(1, dueDate: overdueDue, updatedAt: now - 10 * day),
      ], now);
      expect(r.overdue.map((t) => t.id), [1]);
      expect(r.stalled.map((t) => t.id), [1]);
    });

    test('空列表三组皆空', () {
      final r = collectWeeklyReview([], DateTime.now().millisecondsSinceEpoch);
      expect(r.overdue, isEmpty);
      expect(r.undated, isEmpty);
      expect(r.stalled, isEmpty);
    });
  });

  test('停滞阈值 7 天', () {
    expect(kReviewStallDays, 7);
  });
}
