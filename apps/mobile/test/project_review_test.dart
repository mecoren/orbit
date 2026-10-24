import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/todo/logic/project_review.dart';

// F1 项目回顾节奏展示层纯函数——与桌面 shared/project-review.test.ts 同口径
// 的关键用例子集（档位映射 / 逾期文案 / 相对时间文案与日历日差）。
void main() {
  group('formatReviewInterval', () {
    test('关闭态：null / 0 / 负数', () {
      expect(formatReviewInterval(null), '关闭');
      expect(formatReviewInterval(0), '关闭');
      expect(formatReviewInterval(-7), '关闭');
    });

    test('档位天数映射预设标签', () {
      expect(formatReviewInterval(1), '每天');
      expect(formatReviewInterval(7), '每周');
      expect(formatReviewInterval(14), '每两周');
      expect(formatReviewInterval(30), '每月');
    });

    test('非档位天数回退「每 N 天」', () {
      expect(formatReviewInterval(10), '每 10 天');
    });

    test('预设档位本身无重复天数', () {
      final days = reviewIntervalPresets.map((p) => p.days).toSet();
      expect(days.length, reviewIntervalPresets.length);
    });
  });

  group('formatOverdueDays', () {
    test('0 与负数 = 今天到期', () {
      expect(formatOverdueDays(0), '今天到期');
      expect(formatOverdueDays(-3), '今天到期');
    });

    test('1 天单复数区分', () {
      expect(formatOverdueDays(1), '已逾期 1 天');
      expect(formatOverdueDays(23), '已逾期 23 天');
    });
  });

  group('formatLastReviewed', () {
    final now = DateTime(2026, 10, 24, 20, 0).millisecondsSinceEpoch;

    test('null = 从未回顾', () {
      expect(formatLastReviewed(null, now), '从未回顾');
    });

    test('按本地日历日差给相对文案', () {
      expect(formatLastReviewed(now, now), '今天回顾过');
      expect(
        formatLastReviewed(
            DateTime(2026, 10, 23, 8, 0).millisecondsSinceEpoch, now),
        '昨天回顾过',
      );
      expect(
        formatLastReviewed(
            DateTime(2026, 10, 14, 23, 30).millisecondsSinceEpoch, now),
        '10 天前回顾',
      );
    });

    test('同日不同钟点不误加一天（日历日差而非 24h 差）', () {
      final early = DateTime(2026, 10, 24, 0, 30).millisecondsSinceEpoch;
      final late = DateTime(2026, 10, 24, 23, 0).millisecondsSinceEpoch;
      expect(formatLastReviewed(late, early), '今天回顾过');
    });

    test('≥30 天回退日期文案', () {
      final fortyDaysAgo =
          DateTime(2026, 10, 24).subtract(const Duration(days: 40));
      expect(formatLastReviewed(
          fortyDaysAgo.millisecondsSinceEpoch, now), '2026/9/14 回顾');
    });
  });
}
