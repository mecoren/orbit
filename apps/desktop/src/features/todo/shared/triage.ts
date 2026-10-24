/**
 * 收件箱分诊（F2，docs/13 §五 F2 / §八 U2）共享纯函数——队列归集与快捷键映射。
 *
 * 分诊口径（双端一致，移动端 `logic/triage.dart` 逐字镜像）：
 * - **队列** = 未分组（project_id 为空）且未完成的活动任务；排序对齐未分组
 *   列表的 manual 档（position 升序 → created_at 降序），捕获顺序处理；
 * - **归属动作**（移入项目 / 排今天 / 排明天 / 删除 / 跳过）完成即出队；
 * - **字段修正**（清日期 / 改优先级）不出队——它们是「决定归属过程中」的
 *   就地编辑，卡片留到用户给出归属（或跳过）才走；
 * - 队列在弹层打开时**快照**（按 id）：写操作经 db-change 失效全量缓存会
 *   引发重拉，队列若跟着缓存走会在 50 条连击时抖动。
 */
import type { TodoProject, TodoTaskListItem } from "@/lib/tauri";

/** 键盘 1-9 可直选的项目数上限（超出的项目走鼠标下拉） */
export const TRIAGE_PROJECT_KEYS = 9;

/** 优先级循环档：无 → 高 → 紧急 → 无（分诊场景的三档高频选择；
 * 低/中/立即处理走表单或详情的六档编辑，不进循环） */
export const TRIAGE_PRIORITY_CYCLE = [0, 3, 4] as const;

/** 键盘 P 的优先级循环推进 */
export function nextTriagePriority(current: number): number {
  const idx = TRIAGE_PRIORITY_CYCLE.indexOf(current as (typeof TRIAGE_PRIORITY_CYCLE)[number]);
  return TRIAGE_PRIORITY_CYCLE[(idx + 1) % TRIAGE_PRIORITY_CYCLE.length];
}

/** 归集分诊队列（纯函数：过滤 + 排序，不触库） */
export function collectTriageQueue(tasks: TodoTaskListItem[]): TodoTaskListItem[] {
  return tasks
    .filter((t) => t.project_id == null && !t.done)
    .sort((a, b) => a.position - b.position || b.created_at - a.created_at || a.id - b.id);
}

/** 数字键 1-9 → 项目映射（取列表序前 9 个活跃项目；sort_order 与侧栏一致） */
export function projectKeyMap(projects: TodoProject[]): Map<number, TodoProject> {
  const map = new Map<number, TodoProject>();
  projects
    .filter((p) => !p.is_archived)
    .slice(0, TRIAGE_PROJECT_KEYS)
    .forEach((p, i) => map.set(i + 1, p));
  return map;
}

/** 汇总文案：「已分诊 X · 跳过 Y · 删除 Z」（X = 归属+排期合计） */
export function formatTriageSummary(moved: number, scheduled: number, skipped: number, deleted: number): string {
  return `已分诊 ${moved + scheduled} · 跳过 ${skipped}${deleted > 0 ? ` · 删除 ${deleted}` : ""}`;
}
