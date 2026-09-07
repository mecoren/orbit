// 农历模块单元测试（移植自 wait-home 同源 Dart 版）：
// 公历↔农历互推、节气、副标签优先级、干支生肖。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/lunar/chinese_almanac.dart';
import 'package:orbit/core/lunar/lunar_calendar.dart';

void main() {
  group('LunarCalendar.lunarToSolar', () {
    test('2026 年春节（正月初一）落在 2026-02-17', () {
      final d = LunarCalendar.lunarToSolar(2026, 1, 1);
      expect(d, isNotNull);
      expect(d!.year, 2026);
      expect(d.month, 2);
      expect(d.day, 17);
    });

    test('2025 年腊月无三十：lunarToSolar(2025,12,30) 为 null', () {
      expect(LunarCalendar.lunarToSolar(2025, 12, 30), isNull);
      final d = LunarCalendar.lunarToSolar(2025, 12, 29);
      expect(d, isNotNull); // 除夕 = 腊月廿九
    });

    test('越界参数返回 null', () {
      expect(LunarCalendar.lunarToSolar(1900, 1, 1), isNull);
      expect(LunarCalendar.lunarToSolar(2101, 1, 1), isNull);
      expect(LunarCalendar.lunarToSolar(2026, 13, 1), isNull);
      expect(LunarCalendar.lunarToSolar(2026, 1, 31), isNull);
    });
  });

  group('LunarCalendar.solarToLunar', () {
    test('2026-02-17 → 丙午年正月初一', () {
      final l = LunarCalendar.solarToLunar(DateTime(2026, 2, 17));
      expect(l, isNotNull);
      expect(l!.year, 2026);
      expect(l.month, 1);
      expect(l.day, 1);
      expect(l.isLeapMonth, isFalse);
    });

    test('2023-03-22 → 癸卯年闰二月初一', () {
      final l = LunarCalendar.solarToLunar(DateTime(2023, 3, 22));
      expect(l, isNotNull);
      expect(l!.month, 2);
      expect(l.day, 1);
      expect(l.isLeapMonth, isTrue);
    });

    test('农历↔公历往返：整年抽样闭环一致', () {
      for (var i = 0; i < 30; i++) {
        final solar = DateTime(2026, 1, 1 + i * 12);
        final lunar = LunarCalendar.solarToLunar(solar);
        expect(lunar, isNotNull);
        final back = LunarCalendar.lunarToSolar(lunar!.year, lunar.month, lunar.day);
        expect(back, isNotNull);
        expect(back!.year, solar.year);
        expect(back.month, solar.month);
        expect(back.day, solar.day);
      }
    });
  });

  group('ChineseAlmanac', () {
    test('solarTermLabel：2026-02-04 为立春', () {
      expect(ChineseAlmanac.solarTermLabel(DateTime(2026, 2, 4)), '立春');
      expect(ChineseAlmanac.solarTermLabel(DateTime(2026, 2, 5)), isNull);
    });

    test('daySubLabel 优先级：公历节日 > 农历节日 > 节气 > 农历日', () {
      // 公历节日
      expect(ChineseAlmanac.daySubLabel(DateTime(2026, 10, 1)), '国庆节');
      expect(ChineseAlmanac.daySubLabel(DateTime(2026, 1, 1)), '元旦');
      // 农历节日：2026-02-17 春节
      expect(ChineseAlmanac.daySubLabel(DateTime(2026, 2, 17)), '春节');
      // 节气：2026-02-04 立春
      expect(ChineseAlmanac.daySubLabel(DateTime(2026, 2, 4)), '立春');
      // 初一显示月名：2026-03-19 为二月初一
      expect(ChineseAlmanac.daySubLabel(DateTime(2026, 3, 19)), '二月');
      // 普通日显示农历日名：2026-09-08 → 农历七月廿七
      //（2026-09-07 恰为白露，被节气优先级覆盖）
      expect(ChineseAlmanac.daySubLabel(DateTime(2026, 9, 8)), '廿七');
    });

    test('除夕 = 腊月最后一天（2027-02-05 为丙午年腊月廿九）', () {
      expect(ChineseAlmanac.daySubLabel(DateTime(2027, 2, 5)), '除夕');
    });

    test('lunarYearLabel 干支生肖：2026 丙午马年 / 2025 乙巳蛇年 / 1984 甲子鼠年', () {
      expect(ChineseAlmanac.lunarYearLabel(2026), '丙午马年');
      expect(ChineseAlmanac.lunarYearLabel(2025), '乙巳蛇年');
      expect(ChineseAlmanac.lunarYearLabel(1984), '甲子鼠年');
    });
  });
}
