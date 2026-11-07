// 农历前缀和改造的等价性用例（2026-11-08）
//
// 改造内容：年份定位由「从 1900 起逐年线性累减」改为「前缀和 + 二分」，
// `_yearDays` 由 12 步位循环改为相邻前缀和相减。两者必须逐字节同结果。
//
// 本用例把**旧算法原样内联**（同一张压缩表，见 `debugLunarInfo`），
// 1900-01-31 至 2100-12-31 逐日对比——这是这次改动的唯一验收线。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/lunar/lunar_calendar.dart';

/// 旧实现（改造前 `LunarCalendar.solarToLunar` 的逐行复制）
class _Legacy {
  static final DateTime base = DateTime(1900, 1, 31);
  static final List<int> info = LunarCalendar.debugLunarInfo;

  static int leapMonth(int y) => info[y - 1900] & 0xf;

  static int leapDays(int y) =>
      leapMonth(y) != 0 ? ((info[y - 1900] & 0x10000) != 0 ? 30 : 29) : 0;

  static int monthDays(int y, int m) =>
      (info[y - 1900] & (0x10000 >> m)) != 0 ? 30 : 29;

  static int yearDays(int y) {
    var sum = 348;
    for (var i = 0x8000; i > 0x8; i >>= 1) {
      sum += (info[y - 1900] & i) != 0 ? 1 : 0;
    }
    return sum + leapDays(y);
  }

  static LunarDate? solarToLunar(DateTime solar) {
    final date = DateTime(solar.year, solar.month, solar.day);
    if (date.isBefore(base) || solar.year < 1900 || solar.year > 2100) {
      return null;
    }
    var offset = date.difference(base).inDays;

    var year = 1900;
    var temp = 0;
    for (; year < 2101 && offset > 0; year++) {
      temp = yearDays(year);
      offset -= temp;
    }
    if (offset < 0) {
      offset += temp;
      year--;
    }

    final leap = leapMonth(year);
    var isLeap = false;
    var month = 1;
    var monthDaysTemp = 0;
    for (; month < 13 && offset > 0; month++) {
      if (leap > 0 && month == leap + 1 && !isLeap) {
        --month;
        isLeap = true;
        monthDaysTemp = leapDays(year);
      } else {
        monthDaysTemp = monthDays(year, month);
      }
      if (isLeap && month == leap + 1) isLeap = false;
      offset -= monthDaysTemp;
    }
    if (offset == 0 && leap > 0 && month == leap + 1) {
      if (isLeap) {
        isLeap = false;
      } else {
        isLeap = true;
        --month;
      }
    }
    if (offset < 0) {
      offset += monthDaysTemp;
      --month;
    }
    return LunarDate(
      year: year,
      month: month,
      day: offset + 1,
      isLeapMonth: isLeap,
    );
  }
}

String _fmt(LunarDate? d) => d == null
    ? 'null'
    : '${d.year}-${d.isLeapMonth ? '闰' : ''}${d.month}-${d.day}';

void main() {
  test('1900-01-31 ~ 2100-12-31 逐日与旧算法一致', () {
    final start = DateTime(1900, 1, 31);
    final end = DateTime(2100, 12, 31);
    var mismatches = 0;
    final samples = <String>[];

    for (
      var d = start;
      !d.isAfter(end);
      d = d.add(const Duration(days: 1))
    ) {
      final now = LunarCalendar.solarToLunar(d);
      final old = _Legacy.solarToLunar(d);
      if (_fmt(now) != _fmt(old)) {
        mismatches++;
        if (samples.length < 5) {
          samples.add(
            '$d: 新 ${_fmt(now)} ≠ 旧 ${_fmt(old)}',
          );
        }
      }
    }

    expect(
      mismatches,
      0,
      reason: '前缀和/二分改造必须与旧逐年循环逐日同结果：$samples',
    );
  });

  test('按日缓存不改变结果（同一天重复换算一致）', () {
    final dates = [
      DateTime(1900, 1, 31),
      DateTime(2026, 11, 8),
      DateTime(2026, 2, 17),
      DateTime(2100, 12, 31),
    ];
    for (final d in dates) {
      final a = LunarCalendar.solarToLunar(d);
      final b = LunarCalendar.solarToLunar(d);
      expect(_fmt(b), _fmt(a), reason: '$d 缓存前后必须同值');
    }
  });

  test('公历 → 农历 → 公历 往返闭合（抽样每月 1/15 日）', () {
    // 反向换算只支持农历 1901..2100（`lunarToSolar` 既有边界），故公历起点
    // 晚于农历 1901 年正月初一；1900 年内的抽样跳过而不是判失败。
    for (var y = 1901; y <= 2100; y++) {
      for (var m = 1; m <= 12; m++) {
        for (final day in const [1, 15]) {
          final solar = DateTime(y, m, day);
          final lunar = LunarCalendar.solarToLunar(solar);
          expect(lunar, isNotNull, reason: '$solar 应有农历结果');
          if (lunar!.year < 1901) continue;
          final back = LunarCalendar.lunarToSolar(
            lunar.year,
            lunar.month,
            lunar.day,
            isLeapMonth: lunar.isLeapMonth,
          );
          expect(
            back,
            solar,
            reason: '$solar → ${_fmt(lunar)} → $back 往返不闭合',
          );
        }
      }
    }
  });
}
