/**
 * 待办任务共享过滤/排序逻辑（M4 Task 10，从 desktop/list-page.tsx 原样搬移）
 *
 * 语义（04 §四）：互斥目标 ungrouped > projectId/projectIds > quickView；
 * 快捷视图与状态/优先级筛选仅在非项目目标下生效；
 * 排序默认 position 升序 → created_at 降序（sortKey 可切截止/优先级/标题/创建时间，
 * 07 backlog #26 双端排序选项；非默认档下手动拖拽排序把手由 UI 隐藏）。
 */
import { type ListFilter, type TaskListPredicate, type TodoTaskListItem } from "@/lib/tauri";
import { type QuickViewKey } from "./constants";
import { type SavedFilterConditions } from "./saved-filter";

export type TaskStatusFilter = "all" | "pending" | "doing" | "done" | "undone";

/** 状态多选档（工具栏「状态」筛选，2026-10-28 对齐 TickTick 多状态筛选）。
 *  空数组 = 全部状态；`undone` 是派生档（待办 + 进行中），不落进多选集合。 */
export type TaskStatusFilterSet = Exclude<TaskStatusFilter, "all" | "undone">[];

/** 多选集合 → 单档（旧单选语义的兼容出口：Logbook/看板列等按单档判断的地方用）。
 *  多于一档时回落 "all"（那些调用点只关心「是否明确只看已完成」这类判断）。 */
export function statusFilterOf(set: TaskStatusFilterSet): TaskStatusFilter {
  if (set.length === 0) return "all";
  if (set.length === 1) return set[0];
  // 待办 + 进行中 = 未完成档（语义等价，不是「混合档」）
  if (set.length === 2 && set.includes("pending") && set.includes("doing")) return "undone";
  return "all";
}

/** 排序档位（manual = position 拖拽顺序，唯一允许拖拽重排的档位） */
export type TaskSortKey = "manual" | "due" | "priority" | "title" | "created";

/** 排序方向（工具栏「↑↓ → 顺序」档；manual 无方向概念） */
export type TaskSortDir = "asc" | "desc";

/** 各档位现状默认方向：due/title 升序、priority/created 降序——
 *  用户未显式选方向时逐档回落到它，保证「入口收拢」前后可见顺序零变化 */
export const BASE_SORT_DIR: Record<Exclude<TaskSortKey, "manual">, TaskSortDir> = {
  due: "asc",
  priority: "desc",
  title: "asc",
  created: "desc",
};

export interface TaskFilterInput {
  quickView?: QuickViewKey | null;
  projectId?: number | null;
  /**
   * 清单聚合集合（M8+ 清单文件夹）= 选中项目 + 全部后代项目 id。
   *
   * 给出且非空时优先于 [projectId] 的等值匹配：父清单视图要连同子清单的
   * **直接**任务一起显示（TickTick List Folder 同款）。口径与壳层谓词下推
   * 的 `ListFilter.project_ids` 一致——两层必须同源，否则服务端取回了子清单
   * 任务、客户端这里又把它过滤掉，表现为「聚合不生效」。
   */
  projectIds?: number[] | null;
  ungrouped?: boolean;
  keyword?: string | null; // title+description 大小写不敏感包含
  /** 状态多选档（2026-10-28）：空数组 = 全部状态；多档之间是「或」 */
  statusFilters?: TaskStatusFilterSet;
  priorityFilter?: number | null;
  /** 隐藏已完成（Logbook 治理）：true 时剔除 done 任务；
   *  quickView=done / 明确只看完成集（只选了 done 档）时不生效——要看完成集
   *  就明确去 done 入口 */
  hideDone?: boolean;
}

/**
 * 状态多选匹配（派生状态口径，与 core `status_in` 同源）：
 * 脏 status 回落 pending（看板 status 列同口径），`done` 档兼容「勾选完成但
 * status 未改写」的老数据（done = 1 也算完成）。
 */
function statusMatches(t: TodoTaskListItem, filters: TaskStatusFilterSet): boolean {
  if (t.done || t.status === "done") return filters.includes("done");
  return filters.includes(t.status === "doing" ? "doing" : "pending");
}

/** 是否「只看完成集」：多选里只有 done 一档时，hideDone 不剔除 */
function isDoneOnly(filters: TaskStatusFilterSet): boolean {
  return filters.length === 1 && filters[0] === "done";
}

/** 「今天」本地零点毫秒（我的一天判定/写入单一口径：
 *  列表/表格/详情/右键菜单/本文件过滤共五处，收编防口径漂移） */
export function todayStartMs(now = new Date()): number {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 我的一天切换写值：在「我的一天」→ 移出（null），否则 → 加入（今天零点）。
 *  判定基准与写入值同口径，杜绝「写入 Date.now() 当天即失效且无法移出」类 bug */
export function toggleMyDayValue(myDayDate: number | null, now = new Date()): number | null {
  const today = todayStartMs(now);
  return myDayDate === today ? null : today;
}

export function filterTasks(tasks: TodoTaskListItem[], input: TaskFilterInput): TodoTaskListItem[] {
  const {
    quickView = null,
    projectId = null,
    projectIds = null,
    ungrouped = false,
    keyword = null,
    statusFilters = [],
    priorityFilter = null,
    hideDone = false,
  } = input;

  let list = tasks;

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const todayEnd = todayStart.getTime() + 24 * 3600 * 1000;
  const weekEnd = todayEnd + 6 * 24 * 3600 * 1000;

  // 清单聚合集合优先于等值：集合可能只含选中项目本身（无子清单），
  // 此时与等值等价，无需分叉
  const aggregated = projectIds != null && projectIds.length > 0 ? new Set(projectIds) : null;

  if (ungrouped) {
    list = list.filter((t) => t.project_id == null);
  } else if (aggregated != null) {
    list = list.filter((t) => t.project_id != null && aggregated.has(t.project_id));
  } else if (projectId != null) {
    list = list.filter((t) => t.project_id === projectId);
  } else {
    switch (quickView) {
      case "undone":
        list = list.filter((t) => !t.done);
        break;
      case "done":
        list = list.filter((t) => !!t.done);
        break;
      case "today":
        // 今天 = 逾期 + 今日到期（截止 < 明日零点即命中）：逾期未完成仍是
        // 「今天要做的事」，与移动端 today 视图同口径；task-list-view 的
        // 逾期置顶段自然承接渲染
        list = list.filter((t) => t.due_date != null && t.due_date < todayEnd);
        break;
      case "week":
        // 近 7 天 = 逾期 + 未来 7 天到期（同口径去掉下界）
        list = list.filter((t) => t.due_date != null && t.due_date < weekEnd);
        break;
      case "favorite":
        list = list.filter((t) => !!t.is_favorite);
        break;
      case "my_day":
        // 我的一天：只显示「今天」加入的（my_day_date == 今天零点）。
        // 昨天加入未完成的任务自动退出视图（回到原项目可再次加入）——
        // 与微软 To Do 的 My Day 语义一致，数据不删。
        list = list.filter((t) => t.my_day_date === todayStart.getTime());
        break;
      default:
        break;
    }

    // 快捷视图下的状态筛选仍生效；项目视图沿用现版无工具栏语义
    if (statusFilters.length > 0) {
      list = list.filter((t) => statusMatches(t, statusFilters));
    }
    if (priorityFilter != null) {
      list = list.filter((t) => t.priority === priorityFilter);
    }
  }

  // 隐藏已完成（Logbook 治理）：done 快捷视图 / 明确只看完成集时不剔除
  if (hideDone && quickView !== "done" && !isDoneOnly(statusFilters)) {
    list = list.filter((t) => !t.done);
  }

  const kw = keyword?.trim().toLowerCase() ?? "";
  if (kw) {
    list = list.filter(
      (t) =>
        t.title.toLowerCase().includes(kw) ||
        (t.description ?? "").toLowerCase().includes(kw),
    );
  }

  return list;
}

/**
 * 排序（工具栏「↑↓」菜单数据源）。
 *
 * dir 语义：只翻转**主键**比较方向，回落键方向不随 dir 变（保平局稳定性）；
 * due 档无截止恒沉底（升/降序都不翻到顶）；manual 档忽略 dir（拖拽序无方向）。
 * dir 缺省 = BASE_SORT_DIR[sortKey]（收拢前现状）。
 */
export function sortTasks(
  tasks: TodoTaskListItem[],
  sortKey: TaskSortKey = "manual",
  dir?: TaskSortDir,
): TodoTaskListItem[] {
  const list = [...tasks];
  switch (sortKey) {
    case "due": {
      // 无截止排最后（方向无关），有截止按方向排，同值落回创建时间降序
      const sign = (dir ?? BASE_SORT_DIR.due) === "asc" ? 1 : -1;
      return list.sort((a, b) => {
        if (a.due_date == null && b.due_date == null) return b.created_at - a.created_at;
        if (a.due_date == null) return 1;
        if (b.due_date == null) return -1;
        if (a.due_date !== b.due_date) return sign * (a.due_date - b.due_date);
        return b.created_at - a.created_at;
      });
    }
    case "priority": {
      // 主键按方向排（desc = 大者在前 = 现状），同值落回拖拽顺序
      const sign = (dir ?? BASE_SORT_DIR.priority) === "asc" ? 1 : -1;
      return list.sort((a, b) => {
        if (a.priority !== b.priority) return sign * (a.priority - b.priority);
        const pa = a.position ?? 0;
        const pb = b.position ?? 0;
        return pa !== pb ? pa - pb : b.created_at - a.created_at;
      });
    }
    case "title": {
      // localeCompare 按方向排（asc = 中文拼音序 = 现状）
      const sign = (dir ?? BASE_SORT_DIR.title) === "asc" ? 1 : -1;
      return list.sort((a, b) => sign * a.title.localeCompare(b.title, "zh-Hans-CN"));
    }
    case "created": {
      // 创建时间按方向排（desc = 最新在前 = 现状；asc = 从旧到新）
      const sign = (dir ?? BASE_SORT_DIR.created) === "asc" ? 1 : -1;
      return list.sort((a, b) => sign * (a.created_at - b.created_at));
    }
    default:
      // manual：dir 不生效（拖拽顺序唯一语义就是 position 升序）
      return list.sort((a, b) => {
        const pa = a.position ?? 0;
        const pb = b.position ?? 0;
        if (pa !== pb) return pa - pb;
        return b.created_at - a.created_at;
      });
  }
}

/**
 * 逾期置顶分组（性能批次 UX 优化）：未完成且截止时间已过的任务
 * 划入「逾期」区置顶展示，其余落「其余任务」区——Todoist/MS To Do
 * 同款信息层级，逾期项永远先被看见。
 *
 * 判定口径与 task-list-view 行内 overdue 一致：due_date < now 且 !done。
 * 仅在存在逾期任务时分组（无逾期时 second 为全量、避免空区块噪音）；
 * 拖拽重排语义不受影响（逾期区/普通区各自内部维持原顺序，跨区拖拽
 * 依旧按 position 中值落位——dnd 事件照常走 tasks 原数组索引）。
 */
export function groupOverdueFirst(
  tasks: TodoTaskListItem[],
  now = Date.now(),
): { overdue: TodoTaskListItem[]; rest: TodoTaskListItem[] } {
  const overdue: TodoTaskListItem[] = [];
  const rest: TodoTaskListItem[] = [];
  for (const t of tasks) {
    if (!t.done && t.due_date != null && t.due_date < now) overdue.push(t);
    else rest.push(t);
  }
  return { overdue, rest };
}

// =============================================================================
// 键集分页通道的过滤条件下推（P1 50k 规模档）
// =============================================================================

/** 可分页的排序档：`title` 需要 localeCompare 的中文拼音序，SQL 侧复刻不了 */
export type PagedSortKey = Exclude<TaskSortKey, "title">;

export interface PagedFilterInput {
  keyword: string;
  /** 壳层已下推的视图谓词（快捷视图/项目集合/我的一天/收藏） */
  predicate: TaskListPredicate;
  ungrouped: boolean;
  /** 是否处于项目视图（含清单聚合）：工具栏状态/优先级在其中不生效（04 §四） */
  hasProjectView: boolean;
  quickView: QuickViewKey | null;
  /** 状态多选档（2026-10-28）：空数组 = 全部状态；多档之间是「或」 */
  statusFilters: TaskStatusFilterSet;
  priorityFilter: number | null;
  hideDone: boolean;
  sortKey: PagedSortKey;
  sortDir?: TaskSortDir | null;
  /** 主列表排除逾期行的时刻（毫秒）；null = 不排除（表格视图无逾期置顶段） */
  excludeOverdueBefore?: number | null;
  /**
   * 当前生效的保存筛选器条件 JSON（null = 未选）。
   *
   * #107：条件里的 14 键全部能在 SQL 侧表达，选中筛选器后仍走键集分页；
   * 合并规则见 [mergeSavedFilterConditions]（与移动端
   * `mergeSavedFilterConditions` 逐字同义，两端只允许一份语义）。
   */
  savedConditions?: string | null;
  now?: Date;
}

/**
 * 把「视图谓词 + 工具栏筛选 + 排序」组装成一条分页查询的 ListFilter。
 *
 * 这是 `filterTasks` 的 SQL 版：两者必须同语义——分页通道不再对结果做内存
 * `filterTasks`/`sortTasks`，任何一处漏下推都会表现为「筛选后条数不对」或
 * 「翻页顺序与视觉顺序不一致」。
 *
 * 优先级链与 `filterTasks` 一致：predicate（项目/未分组/快捷视图）优先，
 * 工具栏状态/优先级只在非项目目标下叠加；`hideDone` 最后施加，但
 * `done` 快捷视图与 `done` 状态筛选不剔除（明确要看完成集的入口）。
 */
export function buildPagedFilter(input: PagedFilterInput): ListFilter {
  const now = input.now ?? new Date();
  const dayStart = new Date(now);
  dayStart.setHours(0, 0, 0, 0);
  const todayEnd = dayStart.getTime() + 86_400_000;
  const weekEnd = todayEnd + 6 * 86_400_000;

  const toolbarApplies = !input.ungrouped && !input.hasProjectView;

  let done = input.predicate.done ?? null;
  let status: string | null = null;
  let dueTo: number | null = null;

  if (toolbarApplies) {
    if (input.quickView === "today") dueTo = todayEnd;
    if (input.quickView === "week") dueTo = weekEnd;
  }

  // 状态多选档下推（2026-10-28）：单档且非 done 仍走原有 status 等值谓词
  // （SQL 更省、与旧路径逐字一致）；其余情况交给 status_in 集合。
  //
  // 集合档**不**同时给 done=true：status_in 的 done 项已含「done = 1 或
  // status = 'done'」，再叠 done=true 会把「勾选完成但 status 未改写」的
  // 老数据漏掉（与本地 statusMatches 同口径）。
  const statusSet = input.statusFilters;
  let statusIn: string[] | null = null;
  if (toolbarApplies && statusSet.length > 0) {
    if (statusSet.length === 1 && statusSet[0] !== "done") {
      status = statusSet[0];
    } else {
      done = null; // 完成态由 status_in 判（见上）
      statusIn = [...statusSet];
    }
  }

  if (
    input.hideDone &&
    input.quickView !== "done" &&
    !isDoneOnly(statusSet) &&
    statusSet.length === 0
  ) {
    done = false;
  }

  const filter: ListFilter = {
    keyword: input.keyword.trim() || null,
    page: 1,
    page_size: 0,
    ...input.predicate,
    ungrouped: input.ungrouped ? true : null,
    priority_eq: toolbarApplies ? (input.priorityFilter ?? null) : null,
    done,
    status,
    status_in: statusIn,
    due_to: dueTo,
    exclude_due_before: input.excludeOverdueBefore ?? null,
    sort_key: input.sortKey,
    sort_dir: input.sortDir ?? null,
  };

  return input.savedConditions != null
    ? mergeSavedFilterConditions(filter, input.savedConditions, now)
    : filter;
}

/**
 * 保存筛选器条件 → `ListFilter`（**与当前列表范围取交集**，#107）。
 *
 * 语义与本地过滤 [applySavedFilter] 逐键对齐（#35/#71 的 14 键），区别只在
 * 「在哪算」：条件全部能表达成 core 谓词后改为 SQL 下推，键集分页通道不再
 * 因选中筛选器而回退万行全量。合并规则与移动端
 * `mergeSavedFilterConditions`（`logic/paged_query.dart`）逐字同义：
 *
 * - 项目：两侧 `project_ids` 求交；与 `ungrouped` 冲突或交集为空 → 空结果。
 * - 标签：`label_ids` 也是「任一命中」，两侧求交；交集为空 → 空结果
 *   （注意 core 侧空 `label_ids` 语义是「不过滤」，故空交集必须用恒假集合表达）。
 * - 优先级：`priority_min` 取 max、`priority_eq` 原样保留（SQL 天然 AND）。
 * - 区间：截止/创建/完成的下界取 max、上界取 min（半开区间，右端不含）。
 * - 完成态：`done_from` 隐含只看已完成；与 `done = false` 冲突 → 空结果。
 * - 条件 JSON 损坏：忽略条件（与本地过滤同口径，不静默清空列表）。
 */
export function mergeSavedFilterConditions(
  base: ListFilter,
  rawConditions: string,
  now = new Date(),
): ListFilter {
  let c: SavedFilterConditions;
  try {
    const parsed = JSON.parse(rawConditions) as unknown;
    if (parsed == null || typeof parsed !== "object" || Array.isArray(parsed)) return base;
    c = parsed as SavedFilterConditions;
  } catch {
    return base;
  }

  const dayStart = new Date(now);
  dayStart.setHours(0, 0, 0, 0);
  const todayZero = dayStart.getTime();

  let dueFrom = base.due_from ?? null;
  let dueTo = base.due_to ?? null;
  const raiseFrom = (v: number | null | undefined) => {
    if (v == null) return;
    dueFrom = dueFrom == null ? v : Math.max(dueFrom, v);
  };
  const lowerTo = (v: number | null | undefined) => {
    if (v == null) return;
    dueTo = dueTo == null ? v : Math.min(dueTo, v);
  };

  let impossible = false;

  // ── 项目：交集 ──
  let projectId = base.project_id ?? null;
  let projectIds = base.project_ids ?? null;
  const condProjects = Array.isArray(c.project_ids) ? c.project_ids : null;
  if (condProjects != null) {
    if (condProjects.length === 0) {
      // 空数组 = 匹配不到任何项目（与 applySavedFilter 的 `includes` 恒 false 同义）。
      // 表单不选项目时根本不写这个键（见 buildConditions），故空数组只可能来自
      // 导入/手改的脏条件——按「恒假」处理才能与本地过滤逐键对齐。
      impossible = true;
    } else if (base.ungrouped === true) {
      impossible = true; // 未分组任务不可能属于某个具体项目
    } else if (projectIds != null) {
      const allowed = new Set(condProjects);
      projectIds = projectIds.filter((id) => allowed.has(id));
    } else if (projectId != null) {
      projectIds = condProjects.includes(projectId) ? [projectId] : [];
      projectId = null;
    } else {
      projectIds = [...condProjects];
    }
  }

  // ── 标签：两侧都是「任一命中」，求交 ──
  let labelIds = base.label_ids ?? null;
  const condLabels = Array.isArray(c.label_ids) ? c.label_ids : null;
  if (condLabels != null && condLabels.length > 0) {
    if (labelIds == null || labelIds.length === 0) {
      labelIds = [...condLabels];
    } else {
      const wanted = new Set(condLabels);
      labelIds = labelIds.filter((id) => wanted.has(id));
      // 空交集 ≠ 不过滤：core 里 `label_ids: []` 是「没限制」，必须显式落空结果
      if (labelIds.length === 0) impossible = true;
    }
  }

  // ── 状态 / 完成态 ──
  let status = base.status ?? null;
  if (typeof c.status === "string") {
    if (status != null && status !== c.status) impossible = true;
    status = c.status;
  }
  let done = base.done ?? null;
  if (c.due_overdue === true) {
    // 逾期 = 未完成且截止早于今日零点（与本地过滤同口径，不是 now）
    lowerTo(todayZero);
    if (done === true) impossible = true;
    done = false;
  }
  if (typeof c.done_from === "number") {
    if (done === false) impossible = true;
    done = true;
  }

  // ── 优先级 ──
  const priorityMin =
    typeof c.priority_min === "number"
      ? Math.max(c.priority_min, base.priority_min ?? c.priority_min)
      : (base.priority_min ?? null);

  // ── 截止区间 ──
  if (typeof c.due_within_days === "number") {
    raiseFrom(todayZero);
    lowerTo(todayZero + c.due_within_days * 86_400_000);
  }
  raiseFrom(typeof c.due_from === "number" ? c.due_from : null);
  lowerTo(typeof c.due_until === "number" ? c.due_until : null);

  const createdFrom =
    typeof c.created_from === "number"
      ? Math.max(c.created_from, base.created_from ?? c.created_from)
      : (base.created_from ?? null);
  const doneFrom =
    typeof c.done_from === "number"
      ? Math.max(c.done_from, base.done_from ?? c.done_from)
      : (base.done_from ?? null);

  if (impossible) {
    // 恒假子句：`project_ids: []` 在 core 侧生成 `AND 1 = 0`
    return { ...base, project_id: null, project_ids: [], ungrouped: null };
  }

  return {
    ...base,
    done,
    status,
    priority_min: priorityMin,
    project_id: projectId,
    project_ids: projectIds,
    favorite_only: base.favorite_only === true || c.favorite_only === true ? true : null,
    due_from: dueFrom,
    due_to: dueTo,
    label_ids: labelIds,
    has_reminder:
      typeof c.has_reminder === "boolean" ? c.has_reminder : (base.has_reminder ?? null),
    has_attachment:
      typeof c.has_attachment === "boolean" ? c.has_attachment : (base.has_attachment ?? null),
    has_open_subtask:
      typeof c.has_open_subtask === "boolean"
        ? c.has_open_subtask
        : (base.has_open_subtask ?? null),
    created_from: createdFrom,
    done_from: doneFrom,
  };
}

/** Logbook 按完成日分组单元（Things Logbook：完成历史按日聚合回看） */
export interface DoneDayGroup {
  /** 本地 YYYY-MM-DD */
  key: string;
  date: Date;
  tasks: TodoTaskListItem[];
}

/**
 * 已完成任务按完成日（done_at 本地日）倒序分组——Logbook 视图数据源
 * （Things Logbook 同款「完成历史」语义：最近的成就排最前）。
 *
 * 分组口径：done_at 归本地自然日（本地时区日界，与统计热力图一致）；
 * done_at 缺失的脏行兜底落 created_at 日、再缺失落传入的 fallbackToday。
 * 组间倒序（今天在最上）；组内按 done_at 倒序（同日晚完成的排前）。
 */
export function groupDoneByDay(
  tasks: TodoTaskListItem[],
  fallbackToday = new Date(),
): DoneDayGroup[] {
  const byKey = new Map<string, DoneDayGroup>();
  for (const t of tasks) {
    const ts = t.done_at ?? t.created_at ?? fallbackToday.getTime();
    const d = new Date(ts);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    let g = byKey.get(key);
    if (!g) {
      g = { key, date: new Date(d.getFullYear(), d.getMonth(), d.getDate()), tasks: [] };
      byKey.set(key, g);
    }
    g.tasks.push(t);
  }
  const groups = [...byKey.values()];
  groups.sort((a, b) => b.date.getTime() - a.date.getTime());
  for (const g of groups) {
    g.tasks.sort((a, b) => (b.done_at ?? b.created_at ?? 0) - (a.done_at ?? a.created_at ?? 0));
  }
  return groups;
}

// ---------- 四象限分组（Eisenhower Matrix，对标 TickTick 矩阵视图） ----------

/** 四象限桶位（展示顺序即枚举序：先重要后次要，先紧急后不紧急） */
export type EisenhowerQuadrant =
  | "urgentImportant"
  | "importantNotUrgent"
  | "urgentNotImportant"
  | "neither";

/** 四象限展示名（对齐竞品：重要且紧急 / 重要不紧急 / 不重要但紧急 /
 *  不重要不紧急；罗马徽标Ⅰ-Ⅳ在格头承载象限序号） */
export const EISENHOWER_META: Record<EisenhowerQuadrant, { action: string }> = {
  urgentImportant: { action: "重要且紧急" },
  importantNotUrgent: { action: "重要不紧急" },
  urgentNotImportant: { action: "不重要但紧急" },
  neither: { action: "不重要不紧急" },
};

/** 四象限识别色（格头罗马徽标/名称着色 + 顶缘色带；与移动端矩阵格 tint
 *  同源：逾期红 / 我的一天琥珀 / 待办强调蓝 / 完成绿） */
export const QUADRANT_COLOR: Record<EisenhowerQuadrant, string> = {
  urgentImportant: "#F44336",
  importantNotUrgent: "#F59E0B",
  urgentNotImportant: "#3B82F6",
  neither: "#22C55E",
};

/** 四象限分组结果（四键恒在，空桶也要渲染格） */
export type EisenhowerBuckets = Record<EisenhowerQuadrant, TodoTaskListItem[]>;

/**
 * 四象限分组纯函数：已完成不入桶（矩阵只承载未完成工作集，完成历史
 * 交给侧栏「已完成」入口）。轴口径与移动端 groupEisenhower 逐字对齐——
 * 重要 = 优先级 ≥ 高(3)；紧急 = 截止在今天 24:00 之前（含逾期，本地时区
 * 日界）。[now] 供测试注入固定时间。组内保持入参顺序（排序在调用方做）。
 */
export function groupEisenhower(
  tasks: TodoTaskListItem[],
  now = new Date(),
): EisenhowerBuckets {
  const dayEnd = new Date(now);
  dayEnd.setHours(24, 0, 0, 0);
  const buckets: EisenhowerBuckets = {
    urgentImportant: [],
    importantNotUrgent: [],
    urgentNotImportant: [],
    neither: [],
  };
  for (const t of tasks) {
    if (t.done) continue;
    const urgent = t.due_date != null && t.due_date < dayEnd.getTime();
    const important = t.priority >= 3;
    const q: EisenhowerQuadrant = urgent
      ? important
        ? "urgentImportant"
        : "urgentNotImportant"
      : important
        ? "importantNotUrgent"
        : "neither";
    buckets[q].push(t);
  }
  return buckets;
}
