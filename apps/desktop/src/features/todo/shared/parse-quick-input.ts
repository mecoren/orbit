// apps/desktop/src/features/todo/shared/parse-quick-input.ts
/**
 * NLP 快速输入规则解析器 v2（07 报告 §五-P1#7 日期/优先级/项目/标签；
 * docs/13 §五 F4 补时刻/时长/重复，双端共享向量见 parse-quick-input-vectors.json）
 *
 * 纯函数、零框架依赖。语法（中文优先，大小写敏感仅限拉丁 token）：
 *   日期：今天/明天/后天/大后天 | 今晚/明晚（=当天/次日零点，无显式时刻不猜）|
 *         周X·星期X·礼拜X（未来最近，含今天）|
 *         下周X·下星期X·下礼拜X（下周一为首周的对应日）|
 *         M月d日·M月d号（今年已过则顺延一年）
 *   时刻：HH:mm（含全角冒号）| 时段词+X点(半)（凌晨/清晨/早上/上午/中午/下午/
 *         傍晚/晚上；中午仅认 11/12/1/2 点的口语窗口）| X点半·X点钟（裸数字
 *         无「半/钟」后缀不识别，防「三点原因」枚举误伤）| 今晚/明晚X点（组合词，
 *         时段按晚上计）
 *   时长：N小时 / N分钟 / Nh·NH / N小时M分钟（组合）/ 半小时；
 *         「一个半小时」「30分钟后」这类歧义/相对语一律不识别保原文
 *   重复：每天 | 每周X | 每周 | 每月X号（X 号本月已过顺延下一有 X 号的月）| 每月
 *         —— 映射 repeat_mode/repeat_after/repeat_weekdays 三列，并给出锚点日
 *   优先级：!1 ~ !5（!6+ 不识别，原样保留）
 *   项目：#名称 —— 项目标题精确匹配优先，其次第一个前缀命中
 *   标签：@名称 —— 同上，可出现多个（去重）
 *
 * 组合规则：显式日期 token 与时刻组合；无日期时取重复锚点（每天=今天、
 * 每周X=未来最近该日、每月X号=未来最近该日号），再无则默认今天；纯时刻已过
 * 顺延明天（重复为按天档同样顺延；周/月锚点为保序列对齐不顺延，当天实例
 * 落为逾期）。重复不覆盖显式日期 token。
 *
 * 边界规则：长词优先、命中区间互斥、未匹配 token 原样保留（歧义不猜测）；
 * 时刻/时长对前后文做守卫（数字粘连、相对语后缀）。#/@ 名称以空白或中英文
 * 常用标点收尾。
 */
import { addDays, startOfDay } from "@/lib/date-utils";

export interface QuickInputContext {
  projects: { id: number; title: string }[];
  labels: { id: number; title: string }[];
  now: Date;
}

/** 重复规则解析结果（todo_tasks.repeat_* 三列的子集；结束条件/月高级语义不参与 NLP） */
export interface ParsedRepeat {
  /** 1 按天 2 按周 3 按月（与 repeat_mode 列同口径） */
  mode: number;
  /** 间隔数（NLP 恒 1） */
  after: number;
  /** 星期几位掩码 bit0=周一…bit6=周日（仅周档；0 = 按 due 的星期） */
  weekdays: number;
}

export interface ParsedQuickInput {
  /** 剥离全部命中 token 并收敛空白后的标题 */
  title: string;
  dueDate: Date | null;
  /** true = dueDate 时刻位来自显式时刻 token，消费端勿再归一零点/视图 18 点 */
  dueHasTime: boolean;
  /** 1-5；0 = 输入中未指定 */
  priority: number;
  projectId: number | null;
  labelIds: number[];
  /** 预计时长（分钟）；null = 未命中 */
  durationMinutes: number | null;
  /** 命中即非 null；dueDate 同时给出锚点日（无显式日期时） */
  repeat: ParsedRepeat | null;
}

const WEEKDAY_CN: Record<string, number> = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 0, 天: 0 };
const RELATIVE_DAYS: Record<string, number> = { 今天: 0, 明天: 1, 大后天: 3, 后天: 2 };
/** 时段词 → 是否午后（午后小时数 <12 时 +12；12 点恒 12 点口径） */
// bounded: 固定 3 元素源码字面量集（永不增长，无淘汰需求）
const PM_PARTS = new Set(["下午", "傍晚", "晚上"]);

/** 距下一个周一的天数（今天为周一也取下周一），与 quick-dates.nextMonday 同口径 */
function nextMondayDelta(now: Date): number {
  return ((8 - now.getDay()) % 7) || 7;
}

/** 下周的周 X（周一为首日；wd 为 JS 星期 0=周日） */
function nextWeekWeekday(now: Date, wd: number): Date {
  const posFromMonday = (wd + 6) % 7; // 周一=0 … 周日=6
  return addDays(now, nextMondayDelta(now) + posFromMonday);
}

/** 未来最近的 X 号（含今天；目标月无该日号则顺延，如 31 号跳过小月）；无效返回 null */
function nextMonthlyAnchor(now: Date, dayOfMonth: number): Date | null {
  for (let add = 0; add < 12; add++) {
    const cand = new Date(now.getFullYear(), now.getMonth() + add, dayOfMonth);
    // JS Date 会把「31 号」在小月静默滚到下月 —— getDate 不符即该月无此日号
    if (cand.getDate() !== dayOfMonth) continue;
    if (cand.getTime() >= startOfDay(now).getTime()) return cand;
  }
  return null;
}

export function parseQuickInput(raw: string, ctx: QuickInputContext): ParsedQuickInput {
  interface Strip { start: number; end: number }
  const strips: Strip[] = [];
  let dueDate: Date | null = null;
  let priority = 0;
  let projectId: number | null = null;
  const labelIds: number[] = [];
  let durationMinutes: number | null = null;
  let repeat: ParsedRepeat | null = null;
  /** 重复 token 给出的锚点日（无显式日期 token 时的 due 起点） */
  let repeatAnchor: Date | null = null;
  /** 显式时刻 token（位置后者覆盖，与日期 token 同口径） */
  let timeToken: { h: number; m: number } | null = null;

  let dueDateStart = -1;
  let timeStart = -1;

  /** 多个日期 token 时靠文本位置后者覆盖（如「下周三复查 改明天」以 明天 为准） */
  const setDueDate = (start: number, d: Date): void => {
    if (start >= dueDateStart) {
      dueDate = d;
      dueDateStart = start;
    }
  };

  const setTime = (start: number, h: number, m: number): void => {
    if (start >= timeStart) {
      timeToken = { h, m };
      timeStart = start;
    }
  };

  const overlaps = (start: number, end: number) =>
    strips.some((s) => start < s.end && s.start < end);

  /** 依次消费 re 的每个匹配：consume 返回 true 才剥离该区间 */
  const take = (re: RegExp, consume: (m: RegExpExecArray) => boolean): void => {
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(raw)) !== null) {
      const end = m.index + m[0].length;
      if (overlaps(m.index, end)) continue;
      if (!consume(m)) continue;
      strips.push({ start: m.index, end });
      if (m[0].length === 0) re.lastIndex++; // 防空匹配死循环
    }
  };

  // ---- 重复（先于 周X/M月d日：每周X 内含 周X，先到先得防拆词）----
  take(/每月(\d{1,2})[日号]/g, (m) => {
    const anchor = nextMonthlyAnchor(ctx.now, Number(m[1]));
    if (anchor == null) return false; // 每月0号/32号 —— 无效保留原文
    repeat = { mode: 3, after: 1, weekdays: 0 };
    repeatAnchor = anchor;
    return true;
  });
  take(/每周([一二三四五六日天])/g, (m) => {
    const wd = WEEKDAY_CN[m[1]];
    repeat = { mode: 2, after: 1, weekdays: 1 << ((wd + 6) % 7) };
    repeatAnchor = addDays(ctx.now, (wd - ctx.now.getDay() + 7) % 7); // 未来最近，含今天
    return true;
  });
  take(/(每天|每周|每月)/g, (m) => {
    // 「每月32号」整词已被上方 X号 形态拒绝时，裸词不得再吃掉 每月 前缀
    if (m[1] === "每月" && /^\s*\d{1,2}\s*[日号]/.test(raw.slice(m.index + m[0].length))) {
      return false;
    }
    repeat = {
      mode: m[1] === "每天" ? 1 : m[1] === "每周" ? 2 : 3,
      after: 1,
      weekdays: 0,
    };
    repeatAnchor = addDays(ctx.now, 0);
    return true;
  });

  // ---- 今晚/明晚X点（组合词：日期 + 晚间 12 小时制时刻），先于裸 今晚/明晚 ----
  take(/(今晚|明晚)\s*(\d{1,2})\s*点(?:钟)?(半)?/g, (m) => {
    const h = Number(m[2]);
    if (h < 1 || h > 12) return false;
    setDueDate(m.index, addDays(ctx.now, m[1] === "明晚" ? 1 : 0));
    setTime(m.index, h < 12 ? h + 12 : 12, m[3] != null ? 30 : 0);
    return true;
  });
  take(/(今晚|明晚)/g, (m) => {
    setDueDate(m.index, addDays(ctx.now, m[1] === "明晚" ? 1 : 0));
    return true;
  });

  // ---- 相对日词（大后天 必须列在 后天 前，保证长词优先）----
  take(/(大后天|后天|明天|今天)/g, (m) => {
    setDueDate(m.index, addDays(ctx.now, RELATIVE_DAYS[m[1]]));
    return true;
  });
  // ---- 下周X ----
  take(/(?:下周|下星期|下礼拜)([一二三四五六日天])/g, (m) => {
    setDueDate(m.index, nextWeekWeekday(ctx.now, WEEKDAY_CN[m[1]]));
    return true;
  });
  // ---- 周X（未来最近，含今天）----
  take(/(?:周|星期|礼拜)([一二三四五六日天])/g, (m) => {
    const delta = (WEEKDAY_CN[m[1]] - ctx.now.getDay() + 7) % 7;
    setDueDate(m.index, addDays(ctx.now, delta));
    return true;
  });
  // ---- M月d日 / M月d号 ----
  take(/(\d{1,2})月(\d{1,2})[日号]/g, (m) => {
    const month = Number(m[1]) - 1;
    const dayOfMonth = Number(m[2]);
    if (month < 0 || month > 11 || dayOfMonth < 1 || dayOfMonth > 31) return false;
    const cand = new Date(ctx.now.getFullYear(), month, dayOfMonth);
    // JS Date 会把 2月29日(平年)/2月30日 静默滚动到 3 月 —— 视为无效日期保留原文
    if (cand.getDate() !== dayOfMonth) return false;
    if (cand.getTime() < startOfDay(ctx.now).getTime()) {
      cand.setFullYear(cand.getFullYear() + 1);
    }
    setDueDate(m.index, cand);
    return true;
  });

  // ---- 时刻：时段词 + X点(半)（上午13点 / 中午3点 这类越界词不识别保原文）----
  take(/(凌晨|清晨|早上|上午|中午|下午|傍晚|晚上)\s*(\d{1,2})\s*点(?:钟)?(半)?/g, (m) => {
    const part = m[1];
    const h = Number(m[2]);
    if (part === "中午") {
      // 口语窗口约 11:00–14:00：11 点按上午、12 点恒正午、1/2 点按午后
      if (h === 12) setTime(m.index, 12, m[3] != null ? 30 : 0);
      else if (h === 1 || h === 2) setTime(m.index, h + 12, m[3] != null ? 30 : 0);
      else if (h === 11) setTime(m.index, 11, m[3] != null ? 30 : 0);
      else return false;
      return true;
    }
    if (h > 12) return false;
    if (PM_PARTS.has(part)) setTime(m.index, h < 12 ? h + 12 : 12, m[3] != null ? 30 : 0);
    else setTime(m.index, h, m[3] != null ? 30 : 0);
    return true;
  });
  // ---- 时刻：X点半 / X点钟（裸数字必须带 半/钟 后缀，防「三点原因」枚举误伤）----
  take(/(\d{1,2})\s*点(?:钟|半)/g, (m) => {
    const h = Number(m[1]);
    if (h > 23) return false;
    setTime(m.index, h, m[0].endsWith("半") ? 30 : 0);
    return true;
  });
  // ---- 时刻：HH:mm（前后不得粘连数字，防「比分2:10」「13:45:22」误伤）----
  take(/(\d{1,2})[:：](\d{2})/g, (m) => {
    const s = m.index;
    const e = s + m[0].length;
    if (s > 0 && /[0-9]/.test(raw[s - 1]!)) return false;
    const next = raw[e];
    if (next != null && /[0-9:：]/.test(next)) return false;
    const h = Number(m[1]);
    const min = Number(m[2]);
    if (h > 23 || min > 59) return false;
    setTime(s, h, min);
    return true;
  });

  // ---- 优先级 !1-!5（负向先行排除 !12 这类多位数的前缀误命中）----
  take(/!([1-5])(?!\d)/g, (m) => {
    priority = Number(m[1]);
    return true;
  });
  // ---- 项目 #名称（名称不含空白、#@! 与常用标点）----
  take(/#([^\s#!@，。；、！？,.;;!?()（）[\]【】""''"]+)/g, (m) => {
    const name = m[1];
    const hit =
      ctx.projects.find((p) => p.title === name) ??
      ctx.projects.find((p) => p.title.startsWith(name));
    if (!hit) return false; // 未匹配：保留原文
    projectId = hit.id;
    return true;
  });
  // ---- 标签 @名称（可多个）----
  take(/@([^\s#!@，。；、！？,.;;!?()（）[\]【】""''"]+)/g, (m) => {
    const name = m[1];
    const hit =
      ctx.labels.find((l) => l.title === name) ??
      ctx.labels.find((l) => l.title.startsWith(name));
    if (!hit) return false;
    if (!labelIds.includes(hit.id)) labelIds.push(hit.id);
    return true;
  });

  // ---- 时长（多 token 后者覆盖，与日期同口径）----
  take(/(\d+)\s*个?小时\s*(\d{1,2})\s*分钟/g, (m) => {
    durationMinutes = Number(m[1]) * 60 + Number(m[2]);
    return true;
  });
  take(/半\s*个?小时/g, (m) => {
    if (m.index > 0 && /[0-9一两几个]/.test(raw[m.index - 1]!)) return false; // 一个半小时
    const next = raw[m.index + m[0].length];
    if (next != null && /[后之以内]/.test(next)) return false; // 半小时后（相对语）
    durationMinutes = 30;
    return true;
  });
  take(/(\d+(?:\.\d+)?)\s*(?:个?小时|分钟|[hH])/g, (m) => {
    const e = m.index + m[0].length;
    const next = raw[e];
    if (next != null && /[0-9a-zA-Z]/.test(next)) return false; // 2https 这类粘连
    if (next != null && /[后之以内]/.test(next)) return false; // 30分钟后 / 2小时内
    const n = Number(m[1]);
    durationMinutes = /[hH]|小时/.test(m[0]) ? Math.round(n * 60) : n;
    return true;
  });

  // ---- 时刻与日期/重复锚点组合 ----
  // 闭包内赋值的外层变量在读取点被 TS 流分析收窄为 null，用 as 恢复声明类型
  const dateToken = dueDate as Date | null;
  const repRule = repeat as ParsedRepeat | null;
  const repAnchorDay = repeatAnchor as Date | null;
  const timeTok = timeToken as { h: number; m: number } | null;

  let finalDue = dateToken; // 显式日期 token（含 今晚/明晚）
  if (finalDue == null && repAnchorDay != null) finalDue = repAnchorDay;
  let dueHasTime = false;
  if (timeTok != null) {
    if (finalDue == null) finalDue = startOfDay(ctx.now); // 纯时刻：默认今天
    const combined = new Date(
      finalDue.getFullYear(),
      finalDue.getMonth(),
      finalDue.getDate(),
      timeTok.h,
      timeTok.m,
    );
    // 已过顺延明天：仅无显式日期时；重复为按天档同样顺延，周/月锚点保
    // 序列对齐不顺延（当天实例落为逾期，完成引擎仍正确推进）
    if (
      dateToken == null &&
      combined.getTime() < ctx.now.getTime() &&
      (repRule == null || repRule.mode === 1)
    ) {
      combined.setDate(combined.getDate() + 1);
    }
    finalDue = combined;
    dueHasTime = true;
  }

  // ---- 剥离命中区间并收敛空白 ----
  let title = "";
  let cursor = 0;
  for (const s of [...strips].sort((a, b) => a.start - b.start)) {
    title += raw.slice(cursor, s.start);
    cursor = s.end;
  }
  title += raw.slice(cursor);

  return {
    title: title.replace(/\s{2,}/g, " ").trim(),
    dueDate: finalDue,
    dueHasTime,
    priority,
    projectId,
    labelIds,
    durationMinutes,
    repeat: repRule,
  };
}
