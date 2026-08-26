// apps/desktop/src/features/todo/shared/parse-quick-input.ts
/**
 * NLP 快速输入规则解析器 v1（07 报告 §五-P1#7）
 *
 * 纯函数、零框架依赖。语法（中文优先，大小写敏感仅限拉丁 token）：
 *   日期：今天/明天/后天/大后天 | 周X·星期X·礼拜X（未来最近，含今天）|
 *         下周X·下星期X·下礼拜X（下周一为首周的对应日）|
 *         M月d日·M月d号（今年已过则顺延一年）
 *   优先级：!1 ~ !5（!6+ 不识别，原样保留）
 *   项目：#名称 —— 项目标题精确匹配优先，其次第一个前缀命中
 *   标签：@名称 —— 同上，可出现多个（去重）
 *
 * 边界规则：日期/优先级为封闭词形，文本任意位置可命中；
 * #/@ 名称以空白或中英文常用标点收尾。所有命中区间互斥——先命中的
 * 长词保护内部短词不被二次解析（如下周三 中的 周三）。
 * 未匹配的 #/@ token 原样保留在标题中，避免误删用户文字。
 */

export interface QuickInputContext {
  projects: { id: number; title: string }[];
  labels: { id: number; title: string }[];
  now: Date;
}

export interface ParsedQuickInput {
  /** 剥离全部命中 token 并收敛空白后的标题 */
  title: string;
  dueDate: Date | null;
  /** 1-5；0 = 输入中未指定 */
  priority: number;
  projectId: number | null;
  labelIds: number[];
}

const WEEKDAY_CN: Record<string, number> = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 0, 天: 0 };
const RELATIVE_DAYS: Record<string, number> = { 今天: 0, 明天: 1, 大后天: 3, 后天: 2 };

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function addDays(d: Date, n: number): Date {
  const x = startOfDay(d);
  x.setDate(x.getDate() + n);
  return x;
}

/** 距下一个周一的天数（今天为周一也取下周一），与 quick-dates.nextMonday 同口径 */
function nextMondayDelta(now: Date): number {
  return ((8 - now.getDay()) % 7) || 7;
}

/** 下周的周 X（周一为首日；wd 为 JS 星期 0=周日） */
function nextWeekWeekday(now: Date, wd: number): Date {
  const posFromMonday = (wd + 6) % 7; // 周一=0 … 周日=6
  return addDays(now, nextMondayDelta(now) + posFromMonday);
}

export function parseQuickInput(raw: string, ctx: QuickInputContext): ParsedQuickInput {
  interface Strip { start: number; end: number }
  const strips: Strip[] = [];
  let dueDate: Date | null = null;
  let priority = 0;
  let projectId: number | null = null;
  const labelIds: number[] = [];

  let dueDateStart = -1;

  /** 多个日期 token 时靠文本位置后者覆盖（如「下周三复查 改明天」以 明天 为准） */
  const setDueDate = (start: number, d: Date): void => {
    if (start >= dueDateStart) {
      dueDate = d;
      dueDateStart = start;
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
    dueDate,
    priority,
    projectId,
    labelIds,
  };
}
