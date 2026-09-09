/**
 * 视图内新增自动带视图标记（#39，2026-09-09 用户需求）
 *
 * 口径：在快捷视图内新建任务时，提交自动携带该视图的过滤口径，
 * 防止任务创建后不满足过滤条件从当前视图「立刻消失」。
 * 注入优先级：NLP 显式值（明天/#项目）> 手动选择（Popover/表单）> 本视图默认。
 * 仅创建分支生效；编辑态不受影响。默认值在提交瞬间重算（跨零点不落昨天）。
 *
 * 与项目视图 defaultProjectId 的既有注入链路同构：
 * 有字段的标记（today/week → due_date）预填表单字段（可见可改），
 * 无字段的标记（my_day/favorite）静默附加在创建载荷。
 */
import type { QuickViewKey } from "./constants";

/** 本周默认截止：当周周五零点；今天已过周五（周六/周日）→ 周日零点。
 * 周一起始周（与日历网格一致）。 */
export function weekDefaultDueMs(now = new Date()): number {
  const zero = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const monday = new Date(zero);
  monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7)); // 周一 = 本周起点
  const friday = new Date(monday);
  friday.setDate(monday.getDate() + 4);
  if (zero.getTime() <= friday.getTime()) return friday.getTime();
  const sunday = new Date(monday);
  sunday.setDate(monday.getDate() + 6);
  return sunday.getTime();
}

/** 视图创建默认值（null = 不注入；all/undone/done/nodate 等无标记视图返回空） */
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
      return { dueMs: midnight };
    case "week":
      return { dueMs: weekDefaultDueMs(now) };
    case "favorite":
      return { favorite: 1 };
    default:
      return {};
  }
}
