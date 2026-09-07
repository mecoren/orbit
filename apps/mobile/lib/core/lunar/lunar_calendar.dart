/// 农历 ↔ 公历换算（1900–2100）
///
/// 移植自 wait-home apps/mobile/lib/core/lunar/lunar_calendar.dart（同源说明
/// 见原文注释：与桌面 TS / Rust 侧同一份 lunarInfo 压缩表）。
///
/// 采用业界通用 calendar.js lunarInfo 位压缩表方案：
/// - 每年一个十六进制值，编码 12/13 个月大小月、闰月序号、闰月大小
/// - 位含义（自高到低）：bit16=闰月大小(1为30天)，bits15-5=12个月大小，
///   bits4-1=闰月月份（0 表示无闰月）
/// - 基准日：1900-01-31 = 农历 1900 年正月初一
/// - 数据来源：jjonline/calendar.js v1.0.3（含 2016 年 2033hex 修正），
///   与 rust_core/src/api/date_calculator.rs 的 LUNAR_INFO_RAW 保持一致，
///   保证双平台换算结果完全一致。修改任一侧时必须同步另一侧。
class LunarCalendar {
  LunarCalendar._();

  /// 农历基准日：1900-01-31（正月初一）
  static final DateTime _baseDate = DateTime(1900, 1, 31);

  /// lunarInfo 压缩表（1900–2100，共 201 项）。
  /// 与 Rust 侧 LUNAR_INFO_RAW 保持逐字节一致。
  static const String _kLunarInfoRaw =
      '0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2,'
      '0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977,'
      '0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970,'
      '0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950,'
      '0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557,'
      '0x06ca0,0x0b550,0x15355,0x04da0,0x0a5b0,0x14573,0x052b0,0x0a9a8,0x0e950,0x06aa0,'
      '0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0,'
      '0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b6a0,0x195a6,'
      '0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570,'
      '0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x055c0,0x0ab60,0x096d5,0x092e0,'
      '0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5,'
      '0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930,'
      '0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530,'
      '0x05aa0,0x076a3,0x096d0,0x04afb,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45,'
      '0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0,'
      '0x14b63,0x09370,0x049f8,0x04970,0x064b0,0x168a6,0x0ea50,0x06b20,0x1a6c4,0x0aae0,'
      '0x0a2e0,0x0d2e3,0x0c960,0x0d557,0x0d4a0,0x0da50,0x05d55,0x056a0,0x0a6d0,0x055d4,'
      '0x052d0,0x0a9b8,0x0a950,0x0b4a0,0x0b6a6,0x0ad50,0x055a0,0x0aba4,0x0a5b0,0x052b0,'
      '0x0b273,0x06930,0x07337,0x06aa0,0x0ad50,0x14b55,0x04b60,0x0a570,0x054e4,0x0d160,'
      '0x0e968,0x0d520,0x0daa0,0x16aa6,0x056d0,0x04ae0,0x0a9d4,0x0a2d0,0x0d150,0x0f252,'
      '0x0d520';

  static final List<int> _info =
      _kLunarInfoRaw.split(',').map((e) => int.parse(e)).toList(growable: false);

  /// 某农历年的闰月月份（0 = 无闰月）
  static int _leapMonth(int y) => _info[y - 1900] & 0xf;

  /// 某农历年闰月的天数（无闰月为 0）
  static int _leapDays(int y) =>
      _leapMonth(y) != 0 ? ((_info[y - 1900] & 0x10000) != 0 ? 30 : 29) : 0;

  /// 某农历年平月 m 的天数
  static int _monthDays(int y, int m) =>
      (_info[y - 1900] & (0x10000 >> m)) != 0 ? 30 : 29;

  /// 某农历年总天数（含闰月）
  static int _yearDays(int y) {
    var sum = 348;
    for (var i = 0x8000; i > 0x8; i >>= 1) {
      sum += (_info[y - 1900] & i) != 0 ? 1 : 0;
    }
    return sum + _leapDays(y);
  }

  /// 公历 → 农历。早于基准日或超出 1900–2100 返回 null。
  static LunarDate? solarToLunar(DateTime solar) {
    final date = DateTime(solar.year, solar.month, solar.day);
    if (date.isBefore(_baseDate) || solar.year < 1900 || solar.year > 2100) {
      return null;
    }
    var offset = date.difference(_baseDate).inDays;

    var year = 1900;
    var temp = 0;
    for (; year < 2101 && offset > 0; year++) {
      temp = _yearDays(year);
      offset -= temp;
    }
    if (offset < 0) {
      offset += temp;
      year--;
    }

    final leap = _leapMonth(year);
    var isLeap = false;
    var month = 1;
    var monthDaysTemp = 0;
    for (; month < 13 && offset > 0; month++) {
      if (leap > 0 && month == leap + 1 && !isLeap) {
        --month;
        isLeap = true;
        monthDaysTemp = _leapDays(year);
      } else {
        monthDaysTemp = _monthDays(year, month);
      }
      if (isLeap && month == leap + 1) isLeap = false;
      offset -= monthDaysTemp;
    }
    // 闰月导致下标重叠时的取反修正
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

  /// 农历 → 公历。无效日期（越界/该年无此闰月/日超当月天数）返回 null。
  ///
  /// 注意 [year]/[month]/[day] 均为农历数字；闰月由 [isLeapMonth] 标记。
  static DateTime? lunarToSolar(
    int year,
    int month,
    int day, {
    bool isLeapMonth = false,
  }) {
    if (year < 1901 || year > 2100) return null;
    if (month < 1 || month > 12 || day < 1 || day > 30) return null;
    final leap = _leapMonth(year);
    if (isLeapMonth && leap != month) return null;

    // 当月最大天数校验
    final maxDay = isLeapMonth ? _leapDays(year) : _monthDays(year, month);
    if (day > maxDay) return null;

    // 年偏移：1900..year-1 各年总天数之和
    var offset = 0;
    for (var i = 1900; i < year; i++) {
      offset += _yearDays(i);
    }

    // 月偏移：构造当年有序月序列 [(月, 是否闰)]，累加目标月之前的天数
    final seq = <(int, bool)>[];
    for (var m = 1; m <= 12; m++) {
      seq.add((m, false));
      if (leap == m) seq.add((m, true));
    }
    final idx =
        seq.indexWhere(((e) => e.$1 == month && e.$2 == isLeapMonth));
    if (idx < 0) return null;
    for (var i = 0; i < idx; i++) {
      final (mm, isl) = seq[i];
      offset += isl ? _leapDays(year) : _monthDays(year, mm);
    }
    offset += day - 1;
    return _baseDate.add(Duration(days: offset));
  }

  // ==================== 中文标签 ====================

  static const List<String> _monthNames = [
    '正月', '二月', '三月', '四月', '五月', '六月',
    '七月', '八月', '九月', '十月', '冬月', '腊月',
  ];

  static const List<String> _dayNames = [
    '初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
    '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
    '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十',
  ];

  /// 农历月份中文标签（如 "六月" / "闰六月"）
  static String monthLabel(int month, {bool leap = false}) {
    if (month < 1 || month > 12) return '';
    return '${leap ? '闰' : ''}${_monthNames[month - 1]}';
  }

  /// 农历日中文标签（如 "初五" / "三十"）
  static String dayLabel(int day) {
    if (day < 1 || day > 30) return '';
    return _dayNames[day - 1];
  }

  /// 完整标签（如 "八月初五"；闰月为 "闰六月初五"），不含年份
  static String fullLabel(LunarDate d) =>
      '${monthLabel(d.month, leap: d.isLeapMonth)}${dayLabel(d.day)}';
}

/// 农历日期值对象
class LunarDate {
  const LunarDate({
    required this.year,
    required this.month,
    required this.day,
    required this.isLeapMonth,
  });

  final int year;

  /// 农历月 1..12
  final int month;

  /// 农历日 1..30
  final int day;
  final bool isLeapMonth;

  @override
  String toString() => 'LunarDate($year-${isLeapMonth ? '闰' : ''}$month-$day)';
}
