/**
 * 中国历法副标签（桌面端 TS 版）
 *
 * 移植自 wait-home apps/desktop/src/modules/important-date/almanac.ts
 * （原文件注释：与 mobile/lib/core/lunar/chinese_almanac.dart 同源：
 * - 24 节气（calendar.js sTermInfo 压缩表，1900–2100）
 * - 公历/农历节日表
 * - 每日副标签优先级：公历节日 > 农历节日 > 节气 > 农历日（初一显示月名）
 * 修改任一侧时必须同步另一侧。）
 */
import { lunarToSolarDate, LUNAR_INFO } from "./lunar";

/** 24 节气名（n=1 小寒 … n=24 冬至） */
const SOLAR_TERM_NAMES = [
  "小寒", "大寒", "立春", "雨水", "惊蛰", "春分",
  "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
  "小暑", "大暑", "立秋", "处暑", "白露", "秋分",
  "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
] as const;

/** sTermInfo 压缩表（1900–2100，共 201 项，来源 calendar.js） */
const S_TERM_INFO: string[] = [
  "9778397bd097c36b0b6fc9274c91aa", "97b6b97bd19801ec9210c965cc920e",
  "97bcf97c3598082c95f8c965cc920f", "97bd0b06bdb0722c965ce1cfcc920f",
  "b027097bd097c36b0b6fc9274c91aa", "97b6b97bd19801ec9210c965cc920e",
  "97bcf97c359801ec95f8c965cc920f", "97bd0b06bdb0722c965ce1cfcc920f",
  "b027097bd097c36b0b6fc9274c91aa", "97b6b97bd19801ec9210c965cc920e",
  "97bcf97c359801ec95f8c965cc920f", "97bd0b06bdb0722c965ce1cfcc920f",
  "b027097bd097c36b0b6fc9274c91aa", "9778397bd19801ec9210c965cc920e",
  "97b6b97bd19801ec95f8c965cc920f", "97bd09801d98082c95f8e1cfcc920f",
  "97bd097bd097c36b0b6fc9210c8dc2", "9778397bd197c36c9210c9274c91aa",
  "97b6b97bd19801ec95f8c965cc920e", "97bd09801d98082c95f8e1cfcc920f",
  "97bd097bd097c36b0b6fc9210c8dc2", "9778397bd097c36c9210c9274c91aa",
  "97b6b97bd19801ec95f8c965cc920e", "97bcf97c3598082c95f8e1cfcc920f",
  "97bd097bd097c36b0b6fc9210c8dc2", "9778397bd097c36c9210c9274c91aa",
  "97b6b97bd19801ec9210c965cc920e", "97bcf97c3598082c95f8c965cc920f",
  "97bd097bd097c35b0b6fc920fb0722", "9778397bd097c36b0b6fc9274c91aa",
  "97b6b97bd19801ec9210c965cc920e", "97bcf97c3598082c95f8c965cc920f",
  "97bd097bd097c35b0b6fc920fb0722", "9778397bd097c36b0b6fc9274c91aa",
  "97b6b97bd19801ec9210c965cc920e", "97bcf97c359801ec95f8c965cc920f",
  "97bd097bd097c35b0b6fc920fb0722", "9778397bd097c36b0b6fc9274c91aa",
  "97b6b97bd19801ec9210c965cc920e", "97bcf97c359801ec95f8c965cc920f",
  "97bd097bd097c35b0b6fc920fb0722", "9778397bd097c36b0b6fc9274c91aa",
  "97b6b97bd19801ec9210c965cc920e", "97bcf97c359801ec95f8c965cc920f",
  "97bd097bd07f595b0b6fc920fb0722", "9778397bd097c36b0b6fc9210c8dc2",
  "9778397bd19801ec9210c9274c920e", "97b6b97bd19801ec95f8c965cc920f",
  "97bd07f5307f595b0b0bc920fb0722", "7f0e397bd097c36b0b6fc9210c8dc2",
  "9778397bd097c36c9210c9274c920e", "97b6b97bd19801ec95f8c965cc920f",
  "97bd07f5307f595b0b0bc920fb0722", "7f0e397bd097c36b0b6fc9210c8dc2",
  "9778397bd097c36c9210c9274c91aa", "97b6b97bd19801ec9210c965cc920e",
  "97bd07f1487f595b0b0bc920fb0722", "7f0e397bd097c36b0b6fc9210c8dc2",
  "9778397bd097c36b0b6fc9274c91aa", "97b6b97bd19801ec9210c965cc920e",
  "97bcf7f1487f595b0b0bb0b6fb0722", "7f0e397bd097c35b0b6fc920fb0722",
  "9778397bd097c36b0b6fc9274c91aa", "97b6b97bd19801ec9210c965cc920e",
  "97bcf7f1487f595b0b0bb0b6fb0722", "7f0e397bd097c35b0b6fc920fb0722",
  "9778397bd097c36b0b6fc9274c91aa", "97b6b97bd19801ec9210c965cc920e",
  "97bcf7f1487f531b0b0bb0b6fb0722", "7f0e397bd097c35b0b6fc920fb0722",
  "9778397bd097c36b0b6fc9274c91aa", "97b6b97bd19801ec9210c965cc920e",
  "97bcf7f1487f531b0b0bb0b6fb0722", "7f0e397bd07f595b0b6fc920fb0722",
  "9778397bd097c36b0b6fc9274c91aa", "97b6b97bd19801ec9274c920e",
  "97bcf7f0e47f531b0b0bb0b6fb0722", "7f0e397bd07f595b0b0bc920fb0722",
  "9778397bd097c36b0b6fc9210c91aa", "97b6b97bd197c36c9210c9274c920e",
  "97bcf7f0e47f531b0b0bb0b6fb0722", "7f0e397bd07f595b0b0bc920fb0722",
  "9778397bd097c36b0b6fc9210c8dc2", "9778397bd097c36c9210c9274c920e",
  "97b6b7f0e47f531b0723b0b6fb0722", "7f0e37f5307f595b0b0bc920fb0722",
  "7f0e397bd097c36b0b6fc9210c8dc2", "9778397bd097c36b0b70c9274c91aa",
  "97b6b7f0e47f531b0723b0b6fb0721", "7f0e37f1487f595b0b0bb0b6fb0722",
  "7f0e397bd097c35b0b6fc9210c8dc2", "9778397bd097c36b0b6fc9274c91aa",
  "97b6b7f0e47f531b0723b0b6fb0721", "7f0e27f1487f595b0b0bb0b6fb0722",
  "7f0e397bd097c35b0b6fc920fb0722", "9778397bd097c36b0b6fc9274c91aa",
  "97b6b7f0e47f531b0723b0b6fb0721", "7f0e27f1487f531b0b0bb0b6fb0722",
  "7f0e397bd097c35b0b6fc920fb0722", "9778397bd097c36b0b6fc9274c91aa",
  "97b6b7f0e47f531b0723b0b6fb0721", "7f0e27f1487f531b0b0bb0b6fb0722",
  "7f0e397bd097c35b0b6fc920fb0722", "9778397bd097c36b0b6fc9274c91aa",
  "97b6b7f0e47f531b0723b0787b0721", "7f0e27f0e47f531b0b0bb0b6fb0722",
  "7f0e397bd07f595b0b0bc920fb0722", "9778397bd097c36b0b6fc9210c91aa",
  "97b6b7f0e47f149b0723b0787b0721", "7f0e27f0e47f531b0723b0b6fb0722",
  "7f0e397bd07f595b0b0bc920fb0722", "9778397bd097c36b0b6fc9210c8dc2",
  "977837f0e37f149b0723b0787b0721", "7f07e7f0e47f531b0723b0b6fb0722",
  "7f0e37f5307f595b0b0bc920fb0722", "7f0e397bd097c35b0b6fc9210c8dc2",
  "977837f0e37f14998082b0787b0721", "7f07e7f0e47f531b0723b0b6fb0721",
  "7f0e37f1487f595b0b0bb0b6fb0722", "7f0e397bd097c35b0b6fc9210c8dc2",
  "977837f0e37f14998082b0787b06bd", "7f07e7f0e47f531b0723b0b6fb0721",
  "7f0e27f1487f531b0b0bb0b6fb0722", "7f0e397bd097c35b0b6fc920fb0722",
  "977837f0e37f14998082b0787b06bd", "7f07e7f0e47f531b0723b0b6fb0721",
  "7f0e27f1487f531b0b0bb0b6fb0722", "7f0e397bd097c35b0b6fc920fb0722",
  "977837f0e37f14998082b0787b06bd", "7f07e7f0e47f531b0723b0b6fb0721",
  "7f0e27f1487f531b0b0bb0b6fb0722", "7f0e397bd07f595b0b0bc920fb0722",
  "977837f0e37f14998082b0787b06bd", "7f07e7f0e47f531b0723b0b6fb0721",
  "7f0e27f1487f531b0b0bb0b6fb0722", "7f0e397bd07f595b0b0bc920fb0722",
  "977837f0e37f14998082b0787b06bd", "7f07e7f0e47f149b0723b0787b0721",
  "7f0e27f0e47f531b0b0bb0b6fb0722", "7f0e397bd07f595b0b0bc920fb0722",
  "977837f0e37f14998082b0723b06bd", "7f07e7f0e37f149b0723b0787b0721",
  "7f0e27f0e47f531b0723b0b6fb0722", "7f0e397bd07f595b0b0bc920fb0722",
  "977837f0e37f14898082b0723b02d5", "7ec967f0e37f14998082b0787b0721",
  "7f07e7f0e47f531b0723b0b6fb0722", "7f0e37f1487f595b0b0bb0b6fb0722",
  "7f0e37f0e37f14898082b0723b02d5", "7ec967f0e37f14998082b0787b0721",
  "7f07e7f0e47f531b0723b0b6fb0722", "7f0e37f1487f531b0b0bb0b6fb0722",
  "7f0e37f0e37f14898082b0723b02d5", "7ec967f0e37f14998082b0787b06bd",
  "7f07e7f0e47f531b0723b0b6fb0721", "7f0e37f1487f531b0b0bb0b6fb0722",
  "7f0e37f0e37f14898082b072297c35", "7ec967f0e37f14998082b0787b06bd",
  "7f07e7f0e47f531b0723b0b6fb0721", "7f0e27f1487f531b0b0bb0b6fb0722",
  "7f0e37f0e37f14898082b072297c35", "7ec967f0e37f14998082b0787b06bd",
  "7f07e7f0e47f531b0723b0b6fb0721", "7f0e27f1487f531b0b0bb0b6fb0722",
  "7f0e37f0e366aa89801eb072297c35", "7ec967f0e37f14998082b0787b06bd",
  "7f07e7f0e47f149b0723b0787b0721", "7f0e27f1487f531b0b0bb0b6fb0722",
  "7f0e37f0e366aa89801eb072297c35", "7ec967f0e37f14998082b0723b06bd",
  "7f07e7f0e47f149b0723b0787b0721", "7f0e27f0e47f531b0723b0b6fb0722",
  "7f0e37f0e366aa89801eb072297c35", "7ec967f0e37f14998082b0723b06bd",
  "7f07e7f0e37f14998083b0787b0721", "7f0e27f0e47f531b0723b0b6fb0722",
  "7f0e37f0e366aa89801eb072297c35", "7ec967f0e37f14898082b0723b02d5",
  "7f07e7f0e37f14998082b0787b0721", "7f07e7f0e47f531b0723b0b6fb0722",
  "7f0e36665b66aa89801e9808297c35", "665f67f0e37f14898082b0723b02d5",
  "7ec967f0e37f14998082b0787b0721", "7f07e7f0e47f531b0723b0b6fb0722",
  "7f0e36665b66a449801e9808297c35", "665f67f0e37f14898082b0723b02d5",
  "7ec967f0e37f14998082b0787b06bd", "7f07e7f0e47f531b0723b0b6fb0721",
  "7f0e36665b66a449801e9808297c35", "665f67f0e37f14898082b072297c35",
  "7ec967f0e37f14998082b0787b06bd", "7f07e7f0e47f531b0723b0b6fb0721",
  "7f0e26665b66a449801e9808297c35", "665f67f0e37f1489801eb072297c35",
  "7ec967f0e37f14998082b0787b06bd", "7f07e7f0e47f531b0723b0b6fb0721",
  "7f0e27f1487f531b0b0bb0b6fb0722",
];

/** 公历节日表：key = month * 100 + day */
const SOLAR_FESTIVALS: Record<number, string> = {
  101: "元旦",
  214: "情人节",
  308: "妇女节",
  312: "植树节",
  401: "愚人节",
  501: "劳动节",
  504: "青年节",
  601: "儿童节",
  701: "建党节",
  801: "建军节",
  903: "抗战胜利",
  910: "教师节",
  918: "九一八",
  930: "烈士纪念日",
  1001: "国庆节",
  1213: "国家公祭日",
  1224: "平安夜",
  1225: "圣诞节",
};

/** 农历节日表：key = 农历月 * 100 + 农历日 */
const LUNAR_FESTIVALS: Record<number, string> = {
  101: "春节",
  115: "元宵节",
  202: "龙抬头",
  505: "端午节",
  707: "七夕节",
  715: "中元节",
  815: "中秋节",
  909: "重阳节",
  1208: "腊八节",
};

const LUNAR_MONTH_NAMES = [
  "正月", "二月", "三月", "四月", "五月", "六月",
  "七月", "八月", "九月", "十月", "冬月", "腊月",
];

const LUNAR_DAY_NAMES = [
  "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
  "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
  "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
];

/** 农历年月日（含闰月标记） */
export interface LunarYmd {
  year: number;
  month: number;
  day: number;
  isLeap: boolean;
}

function lunarInfo(y: number): number {
  return LUNAR_INFO[y - 1900];
}

function leapMonthOf(y: number): number {
  return lunarInfo(y) & 0xf;
}

function leapDaysOf(y: number): number {
  if (leapMonthOf(y) === 0) return 0;
  return (lunarInfo(y) & 0x10000) !== 0 ? 30 : 29;
}

function monthDaysOf(y: number, m: number): number {
  return (lunarInfo(y) & (0x10000 >> m)) !== 0 ? 30 : 29;
}

function yearDaysOf(y: number): number {
  let sum = 348;
  for (let mask = 0x8000; mask > 0x8; mask >>= 1) {
    if ((lunarInfo(y) & mask) !== 0) sum += 1;
  }
  return sum + leapDaysOf(y);
}

/** 计算 y 年第 n 个节气（n: 1..24）落在当月几号；越界返回 null */
function termDay(y: number, n: number): number | null {
  if (y < 1900 || y > 2100 || n < 1 || n > 24) return null;
  const table = S_TERM_INFO[y - 1900];
  const parts: string[] = [];
  for (let i = 0; i < 6; i++) {
    parts.push(parseInt(table.substring(i * 5, i * 5 + 5), 16).toString());
  }
  const calday: string[] = [];
  for (const p of parts) {
    calday.push(p.substring(0, 1));
    calday.push(p.substring(1, 3));
    calday.push(p.substring(3, 4));
    calday.push(p.substring(4, 6));
  }
  const v = Number.parseInt(calday[n - 1], 10);
  return Number.isFinite(v) ? v : null;
}

/** 若 date 恰为节气日，返回节气名；否则 null */
export function solarTermLabel(date: Date): string | null {
  const m = date.getMonth() + 1;
  for (const n of [m * 2 - 1, m * 2]) {
    const day = termDay(date.getFullYear(), n);
    if (day != null && day === date.getDate()) {
      return SOLAR_TERM_NAMES[n - 1];
    }
  }
  return null;
}

/** 公历节日名；非节日返回 null */
export function solarFestivalLabel(date: Date): string | null {
  return SOLAR_FESTIVALS[(date.getMonth() + 1) * 100 + date.getDate()] ?? null;
}

/** 农历节日名；非节日返回 null（除夕 = 腊月最后一天） */
export function lunarFestivalLabel(lunar: LunarYmd): string | null {
  const festival = LUNAR_FESTIVALS[lunar.month * 100 + lunar.day];
  if (festival != null) return festival;
  if (!lunar.isLeap && lunar.month === 12) {
    const maxDay = lunarToSolarDate(lunar.year, 12, 30) != null ? 30 : 29;
    if (lunar.day === maxDay) return "除夕";
  }
  return null;
}

/** 公历 → 农历（calendar.js 标准正向遍历，与 Dart/Rust 同表） */
export function solarToLunar(date: Date): LunarYmd | null {
  const BASE = Date.UTC(1900, 0, 31);
  const utc = Date.UTC(date.getFullYear(), date.getMonth(), date.getDate());
  let offset = Math.round((utc - BASE) / 86400000);
  if (offset < 0) return null;

  let year = 1900;
  let temp = 0;
  for (; year < 2101 && offset > 0; year++) {
    temp = yearDaysOf(year);
    offset -= temp;
  }
  if (offset < 0) {
    offset += temp;
    year--;
  }

  const leap = leapMonthOf(year);
  let isLeap = false;
  let month = 1;
  let temp2 = 0;
  for (; month < 13 && offset > 0; month++) {
    if (leap > 0 && month === leap + 1 && !isLeap) {
      --month;
      isLeap = true;
      temp2 = leapDaysOf(year);
    } else {
      temp2 = monthDaysOf(year, month);
    }
    if (isLeap && month === leap + 1) isLeap = false;
    offset -= temp2;
  }
  if (offset === 0 && leap > 0 && month === leap + 1) {
    if (isLeap) {
      isLeap = false;
    } else {
      isLeap = true;
      --month;
    }
  }
  if (offset < 0) {
    offset += temp2;
    --month;
  }
  return { year, month, day: offset + 1, isLeap };
}

/**
 * 每日副标签（日历视图用）
 *
 * 优先级：公历节日 > 农历节日 > 节气 > 农历日（初一显示月名，闰月显示"闰X月"）
 */
export function daySubLabel(date: Date): string | null {
  const solar = solarFestivalLabel(date);
  if (solar != null) return solar;
  const lunar = solarToLunar(date);
  if (lunar != null) {
    const lunarFestival = lunarFestivalLabel(lunar);
    if (lunarFestival != null) return lunarFestival;
  }
  const term = solarTermLabel(date);
  if (term != null) return term;
  if (lunar == null) return null;
  if (lunar.day === 1) {
    const leapPrefix = lunar.isLeap ? "闰" : "";
    return `${leapPrefix}${LUNAR_MONTH_NAMES[lunar.month - 1]}`;
  }
  return LUNAR_DAY_NAMES[lunar.day - 1];
}

/** 干支 / 生肖字符表（农历纪年） */
const GAN = "甲乙丙丁戊己庚辛壬癸";
const ZHI = "子丑寅卯辰巳午未申酉戌亥";
const ZODIAC = "鼠牛虎兔龙蛇马羊猴鸡狗猪";

/**
 * 公历年的农历干支生肖标签（如 2026 → 丙午马年、2025 → 乙巳蛇年）
 *
 * 以立春前的近似口径按公历年直推（与 Days Matter 年视图标题一致）：
 * 天干 = (year - 4) % 10，地支 = (year - 4) % 12。
 */
export function lunarYearLabel(year: number): string {
  const idx = year - 4;
  return `${GAN[idx % 10]}${ZHI[idx % 12]}${ZODIAC[idx % 12]}年`;
}