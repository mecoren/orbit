/**
 * 视图内新增自动带视图标记（#39，2026-09-09 用户需求）
 *
 * 口径：在快捷视图内新建任务时，提交自动携带该视图的过滤口径，
 * 防止任务创建后不满足过滤条件从当前视图「立刻消失」。
 * 注入优先级：NLP 显式值（明天/#项目）> 手动选择（Popover/表单）> 本视图默认。
 * 仅创建分支生效；编辑态不受影响。默认值在提交瞬间重算（跨零点不落昨天）。
 *
 * 截止时刻（2026-09-09 用户口径修订）：今日/本周视图内创建的截止一律落
 * 当日 18:00——日期由 NLP/手动/视图默认决定，时刻统一 18 点。
 * 我的一天标记保持当天零点：视图过滤按 my_day_date === 今天零点精确匹配。
 *
 * 与项目视图 defaultProjectId 的既有注入链路同构：
 * 有字段的标记（today/week → due_date）预填表单字段（可见可改），
 * 无字段的标记（my_day/favorite）静默附加在创建载荷。
 */
import type { QuickViewKey } from "./constants";

/** 视图默认截止时刻：18:00（用户口径；非零点） */
const VIEW_DUE_HOUR = 18;

/** 时间戳移到当日 18:00（保留日期、替换时刻；本地时区） */
export function atViewDueHour(ms: number): number {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), VIEW_DUE_HOUR).getTime();
}

/** 本周默认截止：当周周五 18:00；周末（周六/周日）→ 周日 18:00。
 * 周一起始周（与日历网格一致）。 */
export function weekDefaultDueMs(now = new Date()): number {
  const zero = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const monday = new Date(zero);
  monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7)); // 周一 = 本周起点
  // 周内（周一~周五）锚当周周五；周末锚周日
  const dayOffset = zero.getDay() >= 1 && zero.getDay() <= 5 ? 4 : 6;
  const anchor = new Date(monday);
  anchor.setDate(monday.getDate() + dayOffset);
  return atViewDueHour(anchor.getTime());
}

/** 视图创建默认值（null = 不注入；all/undone/done 等无标记视图返回空） */
export function quickViewCreateDefaults(
  view: QuickViewKey | null | undefined,
  now = new Date(),
): { dueMs?: number; myDayMs?: number; favorite?: number } {
  if (!view) return {};
  const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  switch (view) {
    case "my_day":
      return { myDayMs: midnight };
    case "today":
      return { dueMs: atViewDueHour(midnight) };
    case "week":
      return { dueMs: weekDefaultDueMs(now) };
    case "favorite":
      return { favorite: 1 };
    default:
      return {};
  }
}
