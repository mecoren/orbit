// 重复规则常量与标签（镜像桌面端 repeat.ts）单测
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/todo/logic/repeat_logic.dart';

/// 固定时刻构造（#72 月高级语义断言用；本地时区）
int at(int y, int m, int d, [int h = 18, int mi = 0]) =>
    DateTime(y, m, d, h, mi).millisecondsSinceEpoch;

void main() {
  group('repeatLabel', () {
    test('mode=0 不重复', () {
      expect(repeatLabel(RepeatMode.none, 0), '不重复');
    });

    test('预设档位：间隔 1 时省略数字', () {
      expect(repeatLabel(RepeatMode.daily, 1), '每天');
      expect(repeatLabel(RepeatMode.weekly, 1), '每周');
      expect(repeatLabel(RepeatMode.monthly, 1), '每月');
      expect(repeatLabel(RepeatMode.yearly, 1), '每年');
    });

    test('自定义间隔：每 N 单位', () {
      expect(repeatLabel(RepeatMode.daily, 3), '每 3 天');
      expect(repeatLabel(RepeatMode.weekly, 2), '每 2 周');
      expect(repeatLabel(RepeatMode.monthly, 6), '每 6 个月');
      expect(repeatLabel(RepeatMode.yearly, 2), '每 2 年');
    });

    test('after<=0 按间隔 1 兜底（防脏数据）', () {
      expect(repeatLabel(RepeatMode.daily, 0), '每天');
    });
  });

  group('repeatLabelExt 扩展后缀', () {
    test('次数档：剩 N 次', () {
      expect(
        repeatLabelExt(RepeatMode.daily, 1,
            endType: RepeatEnd.afterCount, endParam: 3),
        '每天（剩 3 次）',
      );
    });

    test('日期档：至 yyyy/M/d（结束日毫秒值）', () {
      final ms = DateTime(2026, 12, 31, 23, 59, 59).millisecondsSinceEpoch;
      expect(
        repeatLabelExt(RepeatMode.daily, 1,
            endType: RepeatEnd.onDate, endParam: ms),
        '每天（至 2026/12/31）',
      );
    });
  });

  group('自定义单位 ↔ mode 映射', () {
    test('四单位映射正确', () {
      expect(modeForUnit(RepeatUnit.day), RepeatMode.daily);
      expect(modeForUnit(RepeatUnit.week), RepeatMode.weekly);
      expect(modeForUnit(RepeatUnit.month), RepeatMode.monthly);
      expect(modeForUnit(RepeatUnit.year), RepeatMode.yearly);
    });

    test('单位中文标签', () {
      expect(RepeatUnit.day.label, '天');
      expect(RepeatUnit.year.label, '年');
    });

    test('unitForMode：mode 回推自定义单位（不重复归「天」）', () {
      expect(unitForMode(RepeatMode.weekly), RepeatUnit.week);
      expect(unitForMode(RepeatMode.monthly), RepeatUnit.month);
      expect(unitForMode(RepeatMode.yearly), RepeatUnit.year);
      expect(unitForMode(RepeatMode.daily), RepeatUnit.day);
      expect(unitForMode(RepeatMode.none), RepeatUnit.day);
    });
  });

  group('nextRepeatAt / nextRepeatLabel（对齐桌面端 repeat.ts）', () {
    final base = DateTime(2026, 1, 1, 9).millisecondsSinceEpoch;

    test('不重复 / 无锚点：返回 null', () {
      expect(nextRepeatAt(base, RepeatMode.none, 1, base), isNull);
      expect(nextRepeatLabel(RepeatMode.none, 1, base, base), isNull);
      expect(nextRepeatLabel(RepeatMode.daily, 1, null, base), isNull);
    });

    test('每天：取越过 from 的第一次发生', () {
      expect(
        nextRepeatAt(base, RepeatMode.daily, 1, base),
        DateTime(2026, 1, 2, 9).millisecondsSinceEpoch,
      );
    });

    test('每月：日号超目标月天数截断到月末（1/31 → 2/28）', () {
      final jan31 = DateTime(2026, 1, 31, 9).millisecondsSinceEpoch;
      expect(
        nextRepeatAt(jan31, RepeatMode.monthly, 1, jan31),
        DateTime(2026, 2, 28, 9).millisecondsSinceEpoch,
      );
    });

    test('标签：M月d日（周X）', () {
      // 2026-01-05 是周一 → 每周 +1 周落在 1/12（周一）
      final monday = DateTime(2026, 1, 5, 9).millisecondsSinceEpoch;
      expect(nextRepeatLabel(RepeatMode.weekly, 1, monday, monday),
          '1月12日（周一）');
    });

    test('fromDone=1：从完成时刻起算一个完整周期', () {
      final monday = DateTime(2026, 1, 5, 9).millisecondsSinceEpoch;
      expect(
        nextRepeatLabel(RepeatMode.daily, 1, monday, monday, fromDone: 1),
        '1月6日（周二）',
      );
    });

    test('锚点早于 from 时快进到 from 之后（长期逾期不落过去）', () {
      final next = nextRepeatAt(
        base,
        RepeatMode.daily,
        1,
        DateTime(2026, 1, 10, 8).millisecondsSinceEpoch,
      );
      // 首个 > from(1/10 08:00) 的发生 = 1/10 09:00
      expect(next, DateTime(2026, 1, 10, 9).millisecondsSinceEpoch);
    });
  });

  test('预设列表：不重复 + 四预设', () {
    expect(repeatPresets.length, 5);
    expect(repeatPresets.first.label, '不重复');
  });

  // ---------- #72 每月第 N 个星期 X（与 Rust 同口径，固定日期锁定）----------

  group('nthWeekLabel / firstWeekdayInMask', () {
    test('序数中文 + 末；非法序数 null', () {
      expect(nthWeekLabel(2), '第 2 个');
      expect(nthWeekLabel(repeatNthLast), '最后一个');
      expect(nthWeekLabel(0), isNull);
      expect(nthWeekLabel(9), isNull);
    });

    test('掩码最低位（周一=0）', () {
      expect(firstWeekdayInMask(0x15), 0); // 一三五
      expect(firstWeekdayInMask(2), 1); // 周二
      expect(firstWeekdayInMask(0), isNull);
    });
  });

  group('repeatLabelExt 月高级语义', () {
    test('每月第 2 个周二 / 每 2 个月最后一个周五', () {
      expect(
        repeatLabelExt(RepeatMode.monthly, 1,
            weekdays: 2, monthMode: RepeatMonthMode.nth, nthWeek: 2),
        '每月第 2 个周二',
      );
      expect(
        repeatLabelExt(RepeatMode.monthly, 2,
            weekdays: 16,
            monthMode: RepeatMonthMode.nth,
            nthWeek: repeatNthLast),
        '每 2 个月最后一个周五',
      );
    });

    test('日号模式与非法配置回落「每月」', () {
      expect(repeatLabelExt(RepeatMode.monthly, 1), '每月');
      expect(
        repeatLabelExt(RepeatMode.monthly, 1,
            weekdays: 0, monthMode: RepeatMonthMode.nth, nthWeek: 2),
        '每月',
      );
      expect(
        repeatLabelExt(RepeatMode.monthly, 1,
            weekdays: 2, monthMode: RepeatMonthMode.nth, nthWeek: 9),
        '每月',
      );
    });

    test('后缀照常拼接（按完成日）', () {
      expect(
        repeatLabelExt(RepeatMode.monthly, 1,
            weekdays: 2,
            fromDone: 1,
            monthMode: RepeatMonthMode.nth,
            nthWeek: 2),
        '每月第 2 个周二（按完成日）',
      );
    });
  });

  group('nthWeekdayInMonth', () {
    test('第 2 个周二 / 末个周五 / 缺月 null', () {
      expect(nthWeekdayInMonth(2026, 1, 2, 1), 13); // 1 月第 2 个周二
      expect(nthWeekdayInMonth(2026, 4, repeatNthLast, 4), 24); // 4 月末个周五
      expect(nthWeekdayInMonth(2026, 7, 5, 0), isNull); // 7 月无第 5 个周一
      expect(nthWeekdayInMonth(2026, 8, 5, 0), 31); // 8 月第 5 个周一
    });
  });

  group('nextMonthlyNth', () {
    test('第 2 个周二：1/13 → 2/10，时刻沿用', () {
      final base = at(2026, 1, 13);
      expect(nextMonthlyNth(base, 1, 1, 2, base), at(2026, 2, 10));
      expect(nextMonthlyNth(at(2026, 1, 13, 18, 30), 1, 1, 2, base),
          at(2026, 2, 10, 18, 30));
    });

    test('第 5 个周一跳过缺月：6/29 → 8/31', () {
      final base = at(2026, 6, 29, 9);
      expect(nextMonthlyNth(base, 1, 0, 5, base), at(2026, 8, 31, 9));
    });

    test('末个周五 + 每 2 月', () {
      expect(nextMonthlyNth(at(2026, 3, 27, 9), 1, 4, repeatNthLast, at(2026, 3, 27, 9)),
          at(2026, 4, 24, 9));
      expect(nextMonthlyNth(at(2026, 1, 13), 2, 1, 2, at(2026, 1, 13)),
          at(2026, 3, 10));
    });
  });

  group('nextRepeatLabel 月高级语义', () {
    test('nth 规则预览具体日期', () {
      final base = at(2026, 1, 13);
      expect(
        nextRepeatLabel(RepeatMode.monthly, 1, base, base,
            weekdays: 2, monthMode: RepeatMonthMode.nth, nthWeek: 2),
        '2月10日（周二）',
      );
    });

    test('非法配置回落日号预览', () {
      final base = at(2026, 1, 31, 9);
      expect(
        nextRepeatLabel(RepeatMode.monthly, 1, base, base,
            weekdays: 0, monthMode: RepeatMonthMode.nth, nthWeek: 2),
        '2月28日（周六）',
      );
    });
  });
}
