import 'lunar_calendar.dart';

/// 中国历法副标签（农历日 / 节气 / 节日）
///
/// 移植自 wait-home apps/mobile/lib/core/lunar/chinese_almanac.dart
/// （原注释：与桌面端 TS 同源，修改任一侧时必须同步另一侧）。
///
/// 为日历视图提供每日副标签，优先级（参考主流日历应用）：
/// 公历节日 > 农历节日 > 24 节气 > 农历日（初一显示月名）。
///
/// 节气采用 calendar.js sTermInfo 压缩表（1900–2100），与农历表同源。
class ChineseAlmanac {
  ChineseAlmanac._();

  /// 24 节气名（n=1 小寒 … n=24 冬至；n 对应月份 = ceil(n/2)）
  static const List<String> _solarTermNames = [
    '小寒', '大寒', '立春', '雨水', '惊蛰', '春分',
    '清明', '谷雨', '立夏', '小满', '芒种', '夏至',
    '小暑', '大暑', '立秋', '处暑', '白露', '秋分',
    '寒露', '霜降', '立冬', '小雪', '大雪', '冬至',
  ];

  /// sTermInfo 压缩表（1900–2100，共 201 项，来源 calendar.js）
  static const List<String> _sTermInfo = [
    '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
    '97bcf97c3598082c95f8c965cc920f', '97bd0b06bdb0722c965ce1cfcc920f',
    'b027097bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
    '97bcf97c359801ec95f8c965cc920f', '97bd0b06bdb0722c965ce1cfcc920f',
    'b027097bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
    '97bcf97c359801ec95f8c965cc920f', '97bd0b06bdb0722c965ce1cfcc920f',
    'b027097bd097c36b0b6fc9274c91aa', '9778397bd19801ec9210c965cc920e',
    '97b6b97bd19801ec95f8c965cc920f', '97bd09801d98082c95f8e1cfcc920f',
    '97bd097bd097c36b0b6fc9210c8dc2', '9778397bd197c36c9210c9274c91aa',
    '97b6b97bd19801ec95f8c965cc920e', '97bd09801d98082c95f8e1cfcc920f',
    '97bd097bd097c36b0b6fc9210c8dc2', '9778397bd097c36c9210c9274c91aa',
    '97b6b97bd19801ec95f8c965cc920e', '97bcf97c3598082c95f8e1cfcc920f',
    '97bd097bd097c36b0b6fc9210c8dc2', '9778397bd097c36c9210c9274c91aa',
    '97b6b97bd19801ec9210c965cc920e', '97bcf97c3598082c95f8c965cc920f',
    '97bd097bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
    '97b6b97bd19801ec9210c965cc920e', '97bcf97c3598082c95f8c965cc920f',
    '97bd097bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
    '97b6b97bd19801ec9210c965cc920e', '97bcf97c359801ec95f8c965cc920f',
    '97bd097bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
    '97b6b97bd19801ec9210c965cc920e', '97bcf97c359801ec95f8c965cc920f',
    '97bd097bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
    '97b6b97bd19801ec9210c965cc920e', '97bcf97c359801ec95f8c965cc920f',
    '97bd097bd07f595b0b6fc920fb0722', '9778397bd097c36b0b6fc9210c8dc2',
    '9778397bd19801ec9210c9274c920e', '97b6b97bd19801ec95f8c965cc920f',
    '97bd07f5307f595b0b0bc920fb0722', '7f0e397bd097c36b0b6fc9210c8dc2',
    '9778397bd097c36c9210c9274c920e', '97b6b97bd19801ec95f8c965cc920f',
    '97bd07f5307f595b0b0bc920fb0722', '7f0e397bd097c36b0b6fc9210c8dc2',
    '9778397bd097c36c9210c9274c91aa', '97b6b97bd19801ec9210c965cc920e',
    '97bd07f1487f595b0b0bc920fb0722', '7f0e397bd097c36b0b6fc9210c8dc2',
    '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
    '97bcf7f1487f595b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722',
    '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
    '97bcf7f1487f595b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722',
    '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
    '97bcf7f1487f531b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722',
    '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
    '97bcf7f1487f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b6fc920fb0722',
    '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9274c920e',
    '97bcf7f0e47f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722',
    '9778397bd097c36b0b6fc9210c91aa', '97b6b97bd197c36c9210c9274c920e',
    '97bcf7f0e47f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722',
    '9778397bd097c36b0b6fc9210c8dc2', '9778397bd097c36c9210c9274c920e',
    '97b6b7f0e47f531b0723b0b6fb0722', '7f0e37f5307f595b0b0bc920fb0722',
    '7f0e397bd097c36b0b6fc9210c8dc2', '9778397bd097c36b0b70c9274c91aa',
    '97b6b7f0e47f531b0723b0b6fb0721', '7f0e37f1487f595b0b0bb0b6fb0722',
    '7f0e397bd097c35b0b6fc9210c8dc2', '9778397bd097c36b0b6fc9274c91aa',
    '97b6b7f0e47f531b0723b0b6fb0721', '7f0e27f1487f595b0b0bb0b6fb0722',
    '7f0e397bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
    '97b6b7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722',
    '7f0e397bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
    '97b6b7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722',
    '7f0e397bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
    '97b6b7f0e47f531b0723b0787b0721', '7f0e27f0e47f531b0b0bb0b6fb0722',
    '7f0e397bd07f595b0b0bc920fb0722', '9778397bd097c36b0b6fc9210c91aa',
    '97b6b7f0e47f149b0723b0787b0721', '7f0e27f0e47f531b0723b0b6fb0722',
    '7f0e397bd07f595b0b0bc920fb0722', '9778397bd097c36b0b6fc9210c8dc2',
    '977837f0e37f149b0723b0787b0721', '7f07e7f0e47f531b0723b0b6fb0722',
    '7f0e37f5307f595b0b0bc920fb0722', '7f0e397bd097c35b0b6fc9210c8dc2',
    '977837f0e37f14998082b0787b0721', '7f07e7f0e47f531b0723b0b6fb0721',
    '7f0e37f1487f595b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc9210c8dc2',
    '977837f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
    '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722',
    '977837f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
    '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722',
    '977837f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
    '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722',
    '977837f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
    '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722',
    '977837f0e37f14998082b0787b06bd', '7f07e7f0e47f149b0723b0787b0721',
    '7f0e27f0e47f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722',
    '977837f0e37f14998082b0723b06bd', '7f07e7f0e37f149b0723b0787b0721',
    '7f0e27f0e47f531b0723b0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722',
    '977837f0e37f14898082b0723b02d5', '7ec967f0e37f14998082b0787b0721',
    '7f07e7f0e47f531b0723b0b6fb0722', '7f0e37f1487f595b0b0bb0b6fb0722',
    '7f0e37f0e37f14898082b0723b02d5', '7ec967f0e37f14998082b0787b0721',
    '7f07e7f0e47f531b0723b0b6fb0722', '7f0e37f1487f531b0b0bb0b6fb0722',
    '7f0e37f0e37f14898082b0723b02d5', '7ec967f0e37f14998082b0787b06bd',
    '7f07e7f0e47f531b0723b0b6fb0721', '7f0e37f1487f531b0b0bb0b6fb0722',
    '7f0e37f0e37f14898082b072297c35', '7ec967f0e37f14998082b0787b06bd',
    '7f07e7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722',
    '7f0e37f0e37f14898082b072297c35', '7ec967f0e37f14998082b0787b06bd',
    '7f07e7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722',
    '7f0e37f0e366aa89801eb072297c35', '7ec967f0e37f14998082b0787b06bd',
    '7f07e7f0e47f149b0723b0787b0721', '7f0e27f1487f531b0b0bb0b6fb0722',
    '7f0e37f0e366aa89801eb072297c35', '7ec967f0e37f14998082b0723b06bd',
    '7f07e7f0e47f149b0723b0787b0721', '7f0e27f0e47f531b0723b0b6fb0722',
    '7f0e37f0e366aa89801eb072297c35', '7ec967f0e37f14998082b0723b06bd',
    '7f07e7f0e37f14998083b0787b0721', '7f0e27f0e47f531b0723b0b6fb0722',
    '7f0e37f0e366aa89801eb072297c35', '7ec967f0e37f14898082b0723b02d5',
    '7f07e7f0e37f14998082b0787b0721', '7f07e7f0e47f531b0723b0b6fb0722',
    '7f0e36665b66aa89801e9808297c35', '665f67f0e37f14898082b0723b02d5',
    '7ec967f0e37f14998082b0787b0721', '7f07e7f0e47f531b0723b0b6fb0722',
    '7f0e36665b66a449801e9808297c35', '665f67f0e37f14898082b0723b02d5',
    '7ec967f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
    '7f0e36665b66a449801e9808297c35', '665f67f0e37f14898082b072297c35',
    '7ec967f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
    '7f0e26665b66a449801e9808297c35', '665f67f0e37f1489801eb072297c35',
    '7ec967f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
    '7f0e27f1487f531b0b0bb0b6fb0722',
  ];

  /// 公历节日表：key = month * 100 + day
  static const Map<int, String> _solarFestivals = {
    101: '元旦',
    214: '情人节',
    308: '妇女节',
    312: '植树节',
    401: '愚人节',
    501: '劳动节',
    504: '青年节',
    601: '儿童节',
    701: '建党节',
    801: '建军节',
    903: '抗战胜利',
    910: '教师节',
    918: '九一八',
    930: '烈士纪念日',
    1001: '国庆节',
    1213: '国家公祭日',
    1224: '平安夜',
    1225: '圣诞节',
  };

  /// 农历节日表：key = 农历月 * 100 + 农历日
  static const Map<int, String> _lunarFestivals = {
    101: '春节',
    115: '元宵节',
    202: '龙抬头',
    505: '端午节',
    707: '七夕节',
    715: '中元节',
    815: '中秋节',
    909: '重阳节',
    1208: '腊八节',
  };

  /// 计算 y 年第 n 个节气（n: 1..24）落在当月几号；越界返回 null
  static int? _termDay(int y, int n) {
    if (y < 1900 || y > 2100 || n < 1 || n > 24) return null;
    final table = _sTermInfo[y - 1900];
    // 6 段 5 位 hex → 十进制字符串，再按 [0,1][1,2][3,1][4,2] 切片拼接
    final parts = <String>[
      for (var i = 0; i < 6; i++)
        int.parse(table.substring(i * 5, i * 5 + 5), radix: 16).toString(),
    ];
    final calday = <String>[
      for (final p in parts) ...[
        p.substring(0, 1),
        p.substring(1, 3),
        p.substring(3, 4),
        p.substring(4, 6),
      ],
    ];
    return int.tryParse(calday[n - 1]);
  }

  /// 若 date 恰为节气日，返回节气名；否则 null
  static String? solarTermLabel(DateTime date) {
    final month = date.month;
    for (final n in <int>[month * 2 - 1, month * 2]) {
      final day = _termDay(date.year, n);
      if (day != null && day == date.day) {
        return _solarTermNames[n - 1];
      }
    }
    return null;
  }

  /// 公历节日名；非节日返回 null
  static String? solarFestivalLabel(DateTime date) {
    return _solarFestivals[date.month * 100 + date.day];
  }

  /// 农历节日名；非节日返回 null（除夕 = 腊月最后一天）
  static String? lunarFestivalLabel(LunarDate lunar) {
    final festival = _lunarFestivals[lunar.month * 100 + lunar.day];
    if (festival != null) return festival;
    // 除夕：腊月（12月，非闰月）最后一天
    if (!lunar.isLeapMonth && lunar.month == 12) {
      final maxDay = LunarCalendar.lunarToSolar(lunar.year, 12, 30) != null
          ? 30
          : 29;
      if (lunar.day == maxDay) return '除夕';
    }
    return null;
  }

  /// 每日副标签（日历视图用）
  ///
  /// 优先级：公历节日 > 农历节日 > 节气 > 农历日（初一显示月名，如"八月"）
  static String? daySubLabel(DateTime date) {
    final solar = solarFestivalLabel(date);
    if (solar != null) return solar;
    final lunar = LunarCalendar.solarToLunar(date);
    if (lunar != null) {
      final lunarFestival = lunarFestivalLabel(lunar);
      if (lunarFestival != null) return lunarFestival;
    }
    final term = solarTermLabel(date);
    if (term != null) return term;
    if (lunar == null) return null;
    // 初一显示月名，其余显示农历日
    if (lunar.day == 1) {
      return LunarCalendar.monthLabel(lunar.month, leap: lunar.isLeapMonth);
    }
    return LunarCalendar.dayLabel(lunar.day);
  }

  // ===== 农历干支生肖（年视图标题用） =====

  static const String _gan = '甲乙丙丁戊己庚辛壬癸';
  static const String _zhi = '子丑寅卯辰巳午未申酉戌亥';
  static const String _zodiac = '鼠牛虎兔龙蛇马羊猴鸡狗猪';

  /// 公历年的农历干支生肖标签（如 2026 → 丙午马年、2025 → 乙巳蛇年）
  ///
  /// 以公历年直推（与 Days Matter 年视图标题一致）：
  /// 天干 = (year - 4) % 10，地支 = (year - 4) % 12。
  /// 与桌面端 almanac.ts 的 lunarYearLabel 保持同源。
  static String lunarYearLabel(int year) {
    final idx = year - 4;
    return '${_gan[idx % 10]}${_zhi[idx % 12]}${_zodiac[idx % 12]}年';
  }
}