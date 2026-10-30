/**
 * 表格视图（B1：ViewMode 第四态）
 *
 * 七列概览：完成/标题/项目/标签/开始/截止/时长——批量整理与全字段一览刚需
 * （Vikunja 四视图口径）。数据/字段组件全部复用列表视图管线：
 * visibleTasks 注入 + LabelChips + dateText 同口径。
 * 行语言与列表视图对齐（2026-10-30）：行高 57、完成框 = 列表同款 4px 方角框
 * （未完成描边取优先级色，P0 中性灰）、标题 15px、其余列 12px muted、星标/
 * 我的一天收进行尾动作列（与列表行同位同序，标题左沿才能与表头对齐）。
 * **优先级不单设列**（2026-10-30 二次收口）——完成框描边即优先级色，「完成」
 * 列表头同时承接优先级排序（排序键 priority，箭头落在完成列）；多选态完成框
 * 变多选框后由行左缘竖条承接色。
 * 开始/截止双日期列（2026-10-30）：start_date 是纯日期（本地零点），与截止列
 * 共用 ±15 天相对文案；开始列**不参与逾期判定**（逾期固定取 due_date），
 * 两列均可点表头排序（start/due 与工具栏「开始时间/截止时间」同源）。
 * 多选批量语义与列表视图一致（selected Set + shift 区间 + runBatch）：
 * 入口为右键菜单「多选」或 x 键；进入多选后「完成」列方框就地变多选框
 * （2026-10-29，行首不再额外多一个勾选框），退出多选即恢复完成语义。
 * 列头排序（#107）：完成（按优先级）/标题/开始/截止四列可点，写回 task-panel
 * 的 sortKey/sortDir 单一口径（标题档自动回退万行全量，与列表视图同约束）；
 * 表内编辑仍不做（YAGNI）。manual 档不可拖（与看板一致）。
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useQueryClient } from "@tanstack/react-query";
import { formatDistanceToNow } from "date-fns";
import { zhCN } from "date-fns/locale";
import { ArrowDown, ArrowUp, CalendarDays, Clock, ListChecks, Star, Sunrise } from "lucide-react";

import { cn } from "@/lib/utils";
import {
  todoTaskUpdate,
  type ProjectedTaskLabel,
  type TodoProject,
  type TodoTaskListItem,
} from "@/lib/tauri";
import {
  batchMoveToProject,
  batchSetDueDate,
  batchUpdateFavorite,
  batchUpdateMyDay,
  batchUpdatePriority,
  batchUpdateStatus,
} from "../shared/batch-actions";
import { completeTask } from "../shared/task-actions";
import { useUndoableDeleteAction, hideManyFromQueries } from "@/hooks/use-undoable-delete";
import { listNavDirection, isListActivationKey } from "../shared/list-keyboard";
import {
  BASE_SORT_DIR,
  todayStartMs,
  toggleMyDayValue,
  type TaskSortDir,
  type TaskSortKey,
} from "../shared/task-filters";
import { EmptyState } from "@/components/business/empty-state";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { LabelChips } from "../shared/label-chips";
import { formatDuration } from "../shared/time";
import { ReminderChip } from "../shared/reminder-chip";
import { displayReminder } from "../shared/reminder-meta";
import {
  FAVORITE_COLOR,
  MY_DAY_COLOR,
  OVERDUE_COLOR_CLASS,
  PRIORITY_COLOR,
  TASK_PREFETCH_ROWS,
  TODO_ACCENT,
} from "../shared/constants";
import type { TaskReminderMeta } from "../shared/reminder-meta";
import { CheckSvg } from "./task-list-view";
import { TaskContextMenu } from "./task-context-menu";

export interface TaskTableViewProps {
  tasks: TodoTaskListItem[];
  projects: TodoProject[];
  labelsByTask: Map<number, ProjectedTaskLabel[]>;
  remindersByTask: Map<number, TaskReminderMeta[]>;
  onOpenDetail: (id: number) => void;
  /** 列表同款加载/错误态通道（H3：查询进行中不闪「暂无任务」空态） */
  loading?: boolean;
  error?: string | null;
  /** 滚动到底部附近时请求下一页（P1 窗口化）；调用方负责去重 */
  onLoadMore?: () => void;
  /** 是否还有下一页 */
  hasMore?: boolean;
  /** 当前排序档（与列表/工具栏同一口径；仅完成(优先级)/标题/开始/截止四列可点） */
  sortKey?: TaskSortKey;
  sortDir?: TaskSortDir;
  /** 点表头：同列切方向、换列用该列默认方向；缺省 = 表头只读 */
  onSortChange?: (key: TaskSortKey, dir: TaskSortDir) => void;
}

/**
 * 表头排序键映射（项目/标签/时长不参与排序；manual 档也不会由表头产生）。
 * 「完成」列表头没有独立的优先级列可挂，排序键落 priority——点完成列表头即
 * 按优先级排序，箭头也显示在完成列（2026-10-30）。
 */
type TableSortKey = "title" | "start" | "due" | "priority";
export const COLUMN_SORT_KEY: Partial<Record<TableColumn["key"], TableSortKey>> = {
  done: "priority",
  title: "title",
  start: "start",
  due: "due",
};

export interface TableColumn {
  key: "done" | "title" | "project" | "labels" | "start" | "due" | "duration";
  label: string;
  weight: number;
}

export const TABLE_COLUMNS: TableColumn[] = [
  { key: "done", label: "完成", weight: 0.6 },
  { key: "title", label: "标题", weight: 2.4 },
  { key: "project", label: "项目", weight: 1 },
  { key: "labels", label: "标签", weight: 1 },
  { key: "start", label: "开始", weight: 1 },
  { key: "due", label: "截止", weight: 1 },
  { key: "duration", label: "时长", weight: 0.8 },
];

/** 表头排序的语义文案：完成列按优先级、日期列带「时间」后缀，其余与列名一致 */
function sortLabelOf(c: TableColumn): string {
  if (c.key === "done") return "优先级";
  if (c.key === "start") return "开始时间";
  if (c.key === "due") return "截止时间";
  return c.label;
}

/** 权重 → grid 模板列（表头与数据行共享同一模板保证列对齐；首列给 minmax 保完成钮不挤没） */
export function gridTemplateOf(columns: TableColumn[]): string {
  return columns
    .map((c) => (c.key === "title" ? `minmax(10rem,${c.weight}fr)` : `minmax(2.5rem,${c.weight}fr)`))
    .join(" ");
}

/**
 * 固定行高（列表行同口径 57px）：虚拟化 estimateSize 与 CSS `h-[57px]` 必须一致，
 * 否则滚动时行矩形与内容错位。
 */
const ROW_HEIGHT = 57;

/** 行尾动作列（我的一天/星标，与列表行同位同序）：固定宽，表头留同宽空占位 */
const ACTIONS_COLUMN_WIDTH = "3rem";

/** 日期列文案（开始/截止共用，与列表视图同口径）：±15 天相对时间，否则 MM-dd */
export function dateTextOf(ms: number | null): string | null {
  if (!ms) return null;
  const diff = Math.abs(ms - Date.now());
  if (diff <= 15 * 24 * 3600 * 1000) {
    return formatDistanceToNow(new Date(ms), { addSuffix: true, locale: zhCN });
  }
  const d = new Date(ms);
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** 截止文案别名（矩阵视图沿用既有导出名，避免跨文件改名） */
export const dueTextOf = dateTextOf;

export default function TaskTableView({
  tasks,
  projects,
  labelsByTask,
  remindersByTask,
  onOpenDetail,
  loading,
  error,
  onLoadMore,
  hasMore = false,
  sortKey,
  sortDir,
  onSortChange,
}: TaskTableViewProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const qc = useQueryClient();

  // 键盘导航：行 DOM 注册表（j/k 移焦点，Enter/Space 打开）
  const rowRefs = useRef(new Map<number, HTMLDivElement>());
  // 读屏位置播报（D13）：与列表视图同口径，只在焦点变化时更新 live 节点
  const [livePos, setLivePos] = useState("");
  const announcePos = (index: number) => {
    if (index < 0 || index >= tasks.length) return;
    setLivePos(`第 ${index + 1} 项，共 ${tasks.length} 项`);
  };
  const focusRow = (index: number) => {
    if (index < 0 || index >= tasks.length) return;
    announcePos(index);
    virtualizer.scrollToIndex(index, { align: "auto" });
    rowRefs.current.get(tasks[index]?.id)?.focus();
  };

  const virtualizer = useVirtualizer({
    count: tasks.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => ROW_HEIGHT,
    overscan: 8,
    getItemKey: (i) => tasks[i].id,
  });

  // 触底预取（P1 窗口化）：与列表视图同口径（末尾 TASK_PREFETCH_ROWS 行内请求下一页）
  const virtualItems = virtualizer.getVirtualItems();
  const lastVirtualIndex =
    virtualItems.length > 0 ? virtualItems[virtualItems.length - 1].index : -1;
  const loadMoreLock = useRef(false);
  useEffect(() => {
    loadMoreLock.current = false;
  }, [tasks.length]);
  useEffect(() => {
    if (!hasMore || !onLoadMore || lastVirtualIndex < 0) return;
    if (lastVirtualIndex < tasks.length - TASK_PREFETCH_ROWS) return;
    if (loadMoreLock.current) return;
    loadMoreLock.current = true;
    onLoadMore();
  }, [lastVirtualIndex, tasks.length, hasMore, onLoadMore]);

  // ---- 多选批量（与列表视图同语义）----
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [anchorId, setAnchorId] = useState<number | null>(null);
  const [batchBusy, setBatchBusy] = useState(false);
  const [confirmBatchDelete, setConfirmBatchDelete] = useState(false);
  const undoableDelete = useUndoableDeleteAction();

  const selectedTasks = useMemo(
    () => tasks.filter((t) => selected.has(t.id)),
    [tasks, selected],
  );
  const allDoneSelected =
    selectedTasks.length > 0 && selectedTasks.every((t) => t.done);

  const toggleSelect = (id: number, shift: boolean) => {
    if (shift && anchorId != null) {
      const a = tasks.findIndex((t) => t.id === anchorId);
      const b = tasks.findIndex((t) => t.id === id);
      if (a >= 0 && b >= 0) {
        const [lo, hi] = a < b ? [a, b] : [b, a];
        setSelected(new Set(tasks.slice(lo, hi + 1).map((t) => t.id)));
        return;
      }
    }
    setAnchorId(id);
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const clearSelection = () => {
    setSelected(new Set());
    setAnchorId(null);
  };

  const runBatch = async (_label: string, action: (sel: TodoTaskListItem[]) => Promise<unknown>) => {
    const sel = selectedTasks;
    if (sel.length === 0 || batchBusy) return;
    setBatchBusy(true);
    try {
      await action(sel);
      void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
    } finally {
      setBatchBusy(false);
      clearSelection();
    }
  };

  const batchDelete = (sel: TodoTaskListItem[]) => {
    if (sel.length === 0) return;
    const ids = sel.map((t) => t.id);
    undoableDelete({
      entityLabel: "任务",
      count: ids.length,
      hide: (q) => hideManyFromQueries<TodoTaskListItem>(q, ["todo_tasks"], ids),
      commit: async () => {
        const { todoTaskDelete } = await import("@/lib/tauri");
        await Promise.all(ids.map((id) => todoTaskDelete(id)));
      },
    });
    clearSelection();
  };

  // 加载/错误/空态与列表视图同口径（骨架行 + EmptyState，不闪「暂无任务」）
  if (loading && tasks.length === 0) {
    return (
      <div aria-busy className="flex min-h-0 flex-1 flex-col" data-testid="table-loading">
        {Array.from({ length: 8 }, (_, i) => (
          <div key={i} className="flex h-[57px] items-center gap-3 border-b border-border/30 px-4">
            <Skeleton className="h-5 w-5 shrink-0 rounded-[4px]" />
            <Skeleton className="h-4 w-1/4" />
            <Skeleton className="ml-auto h-3 w-1/5" />
          </div>
        ))}
      </div>
    );
  }
  if (error && tasks.length === 0) {
    return (
      <div className="flex flex-1 items-center justify-center p-8 text-sm text-destructive">
        {error}
      </div>
    );
  }
  if (tasks.length === 0) {
    return <EmptyState title="暂无任务" className="flex-1" />;
  }

  // 七列模板 + 行尾动作列（表头同模板，末尾留空占位保持逐列对齐）
  const gridStyle = {
    gridTemplateColumns: `${gridTemplateOf(TABLE_COLUMNS)} ${ACTIONS_COLUMN_WIDTH}`,
  };

  return (
    // #107 窄窗（900–1023px）：七列 grid 在 680px 内容区里会被压到不可读，
    // 低于最小可读宽度时整表横向滚动（表头与数据行同一滚动容器，滚动同步）。
    <div className="flex min-h-0 flex-1 flex-col overflow-x-auto">
      {/* 批量工具条（与列表视图同款；Button/Select 原语保证主题与焦点环一致） */}
      {selected.size > 0 && (
        <div className="flex flex-wrap items-center gap-1 border-b bg-primary/5 px-4 py-2 text-sm">
          <span className="mr-1 text-muted-foreground">已选 {selected.size} 项</span>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 px-2"
            disabled={batchBusy}
            onClick={() =>
              void runBatch("标记完成", (sel) =>
                batchUpdateStatus(sel, { done: 1, done_at: Date.now(), status: "done" }, qc),
              )
            }
          >
            标记完成
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 px-2"
            disabled={batchBusy}
            onClick={() =>
              void runBatch("移回待办", (sel) =>
                batchUpdateStatus(sel, { done: 0, done_at: null, status: "pending" }, qc),
              )
            }
          >
            移回待办
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 px-2"
            disabled={batchBusy}
            onClick={() =>
              void runBatch("设为高优先级", (sel) => batchUpdatePriority(sel, 3, qc))
            }
          >
            设为高优先级
          </Button>
          <Select
            value=""
            onValueChange={(v) => {
              const preset = v as "today" | "tomorrow" | "next_monday" | "clear";
              if (!preset) return;
              void runBatch("批量改期", (sel) => batchSetDueDate(sel, preset, qc));
            }}
          >
            <SelectTrigger
              size="sm"
              aria-label="批量改期"
              className="h-7 border-transparent bg-transparent px-2 shadow-none hover:bg-accent"
            >
              <SelectValue placeholder="改期…" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="today">改到今天</SelectItem>
              <SelectItem value="tomorrow">改到明天</SelectItem>
              <SelectItem value="next_monday">改到下周一</SelectItem>
              <SelectItem value="clear">清除截止</SelectItem>
            </SelectContent>
          </Select>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 px-2"
            disabled={batchBusy}
            onClick={() =>
              void runBatch("加入我的一天", (sel) => batchUpdateMyDay(sel, true, qc))
            }
          >
            加入我的一天
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 px-2"
            disabled={batchBusy}
            onClick={() =>
              void runBatch("移入未分组", (sel) => batchMoveToProject(sel, null, tasks))
            }
          >
            移入未分组
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 px-2"
            disabled={batchBusy}
            onClick={() =>
              void runBatch(allDoneSelected ? "取消收藏" : "收藏", (sel) =>
                batchUpdateFavorite(sel, !allDoneSelected, qc),
              )
            }
          >
            {allDoneSelected ? "取消收藏" : "收藏"}
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 px-2 text-destructive hover:text-destructive"
            disabled={batchBusy}
            onClick={() => setConfirmBatchDelete(true)}
          >
            删除
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="ml-auto h-7 px-2"
            onClick={clearSelection}
          >
            取消选择
          </Button>
        </div>
      )}

      {/* 表头 */}
      <div
        className="grid min-w-[860px] items-center gap-3 border-b bg-muted/40 px-4 text-xs font-medium text-muted-foreground"
        style={{ ...gridStyle, height: 36 }}
      >
        {TABLE_COLUMNS.map((c) => {
          const key = COLUMN_SORT_KEY[c.key];
          const active = key != null && sortKey === key;
          const sortLabel = sortLabelOf(c);
          const sortButton =
            key == null || onSortChange == null ? null : (
              <button
                type="button"
                className={cn(
                  "-mx-1 inline-flex items-center gap-1 rounded px-1 py-0.5 hover:text-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring",
                  active && "text-foreground",
                )}
                aria-label={`按${sortLabel}排序`}
                onClick={() =>
                  onSortChange(
                    key,
                    active
                      ? sortDir === "asc"
                        ? "desc"
                        : "asc"
                      : BASE_SORT_DIR[key],
                  )
                }
              >
                {c.label}
                {active ? (
                  sortDir === "asc" ? (
                    <ArrowUp className="size-3" aria-hidden />
                  ) : (
                    <ArrowDown className="size-3" aria-hidden />
                  )
                ) : null}
              </button>
            );
          return (
            // 完成列表头不加固定窄宽（w-5 会把「完成」挤成两行）；一律单行防折行。
            // 完成列的排序键是 priority，按钮文字仍是「完成」——用 tooltip 说明口径。
            <span key={c.key} className="min-w-0 whitespace-nowrap">
              {sortButton == null ? (
                c.label
              ) : c.key === "done" ? (
                <Tooltip>
                  <TooltipTrigger asChild>{sortButton}</TooltipTrigger>
                  <TooltipContent side="bottom">按优先级排序</TooltipContent>
                </Tooltip>
              ) : (
                sortButton
              )}
            </span>
          );
        })}
        {/* 行尾动作列占位：数据行此处是「我的一天 / 星标」hover 动作 */}
        <span aria-hidden />
      </div>

      {/* 数据行（虚拟化）：min-w 与表头一致，横向滚动由外层容器统一承担 */}
      <div ref={scrollRef} className="min-h-0 min-w-[860px] flex-1 overflow-y-auto">
        {/* 读屏位置播报（D13）：焦点变化时更新，滚动/渲染不碰 */}
        <div role="status" aria-live="polite" data-testid="task-pos-live" className="sr-only">
          {livePos}
        </div>
        <div style={{ height: virtualizer.getTotalSize(), position: "relative" }}>
          {virtualItems.map((vi) => {
            const t = tasks[vi.index];
            const labels = labelsByTask.get(t.id) ?? [];
            const project = projects.find((p) => p.id === t.project_id) ?? null;
            const startText = dateTextOf(t.start_date);
            const due = dateTextOf(t.due_date);
            // 逾期只看截止（开始日期不参与逾期判定，与日历「按开始日期」口径一致）
            const overdue =
              t.due_date != null && !t.done && t.due_date < Date.now();
            const reminder = displayReminder(
              remindersByTask.get(t.id) ?? [],
              Date.now(),
              !!t.done,
            );
            const inMyDay = t.my_day_date === todayStartMs();
            return (
              <div
                key={t.id}
                data-index={vi.index}
                // 固定行高（ROW_HEIGHT，与列表 57 同口径）不挂 measureElement：
                // 逐行 ResizeObserver 在滚动中只会反复触发重测（2026-10-30）
                style={{ position: "absolute", top: vi.start, left: 0, width: "100%" }}
              >
                {/* 右键菜单与列表/看板同口径：hover 多选框移除后，这里是鼠标进入
                    多选态的唯一入口（x 键仍可直接选中焦点行） */}
                <TaskContextMenu
                  task={t}
                  projects={projects}
                  onOpenDetail={() => onOpenDetail(t.id)}
                  onStartSelect={() => toggleSelect(t.id, false)}
                >
                  <div
                    ref={(el) => {
                      if (el) rowRefs.current.set(t.id, el);
                      else rowRefs.current.delete(t.id);
                    }}
                    role="button"
                    tabIndex={0}
                    aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
                    onFocus={() => announcePos(vi.index)}
                    className={cn(
                      "group relative grid h-[57px] cursor-default items-center gap-3 border-b border-border/30 px-4 hover:bg-accent/30",
                      "focus-visible:bg-accent/40 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring",
                      selected.has(t.id) && "bg-primary/5 ring-1 ring-inset ring-primary/30",
                    )}
                    style={gridStyle}
                    onClick={() => {
                      // 多选态下点击行 = 切换勾选（与列表视图一致），否则打开详情
                      if (selected.size > 0) toggleSelect(t.id, false);
                      else onOpenDetail(t.id);
                    }}
                    onKeyDown={(e) => {
                      if (e.nativeEvent.isComposing) return;
                      // x 键切选中（Linear 同款，三视图一致）；Esc 选中态退选全部
                      if (e.target === e.currentTarget && (e.key === "x" || e.key === "X")) {
                        e.preventDefault();
                        toggleSelect(t.id, false);
                        return;
                      }
                      if (e.target === e.currentTarget && e.key === "Escape" && selected.size > 0) {
                        e.preventDefault();
                        clearSelection();
                        return;
                      }
                      if (e.target === e.currentTarget && isListActivationKey(e.key)) {
                        e.preventDefault();
                        onOpenDetail(t.id);
                        return;
                      }
                      const dir = listNavDirection(e.key);
                      if (!dir) return;
                      if (vi.index === 0 && dir === "up") return;
                      if (vi.index === tasks.length - 1 && dir === "down") return;
                      e.preventDefault();
                      focusRow(dir === "up" ? vi.index - 1 : vi.index + 1);
                    }}
                  >
                    {/* 优先级左缘竖条：与列表行同口径，**仅多选态渲染**——默认态优先级
                        在完成框描边上（优先级列另有显式色点，同色不上三处） */}
                    {selected.size > 0 && (
                      <span
                        aria-hidden
                        className="pointer-events-none absolute inset-y-1.5 left-0 w-1 rounded-full"
                        style={{ background: PRIORITY_COLOR[t.priority] }}
                      />
                    )}

                    {/* 完成列：完成钮与多选勾选框共用同一位置——进入多选态后
                        完成钮直接变多选框，行首不再多出一个框（2026-10-29）；
                        hover 多选框已移除，多选入口 = 右键菜单「多选」/ x 键 */}
                    <div className="flex items-center">
                      {selected.size > 0 ? (
                        <button
                          type="button"
                          aria-label={selected.has(t.id) ? "取消选中" : "选中"}
                          aria-pressed={selected.has(t.id)}
                          className={cn(
                            "flex h-5 w-5 shrink-0 items-center justify-center rounded-[4px] border transition-colors",
                            selected.has(t.id)
                              ? "border-primary bg-primary text-primary-foreground"
                              : "border-muted-foreground/30 hover:border-primary",
                          )}
                          onClick={(e) => {
                            e.stopPropagation();
                            toggleSelect(t.id, e.shiftKey);
                          }}
                        >
                          {selected.has(t.id) ? (
                            <CheckSvg className="size-3.5" stroke={3} />
                          ) : null}
                        </button>
                      ) : (
                        <button
                          type="button"
                          aria-label={t.done ? "标记未完成" : "标记完成"}
                          className={cn(
                            // 与列表/看板/四象限/详情同款方角框（04 §3.2），
                            // 未完成描边 = 优先级色（P0「无」回落中性灰）
                            "h-5 w-5 shrink-0 rounded-[4px] border-2 transition-colors",
                            t.done
                              ? "border-muted-foreground bg-muted-foreground"
                              : "border-muted-foreground/30 hover:border-primary",
                          )}
                          style={
                            !t.done && t.priority > 0
                              ? { borderColor: PRIORITY_COLOR[t.priority] }
                              : undefined
                          }
                          onClick={(e) => {
                            e.stopPropagation();
                            void completeTask(t, qc);
                          }}
                        >
                          {t.done ? <CheckSvg /> : null}
                        </button>
                      )}
                    </div>

                    {/* 标题列：标题 + 子任务进度（星标/我的一天移到行尾动作列——
                        原先两枚图标顶在标题前，把标题顶出 40px、与表头错位） */}
                    <div className="flex min-w-0 items-center gap-1.5">
                      <span
                        className={cn(
                          "truncate text-[15px] leading-5",
                          t.done && "text-muted-foreground line-through",
                        )}
                      >
                        {t.title}
                      </span>
                      {t.percent_done > 0 && t.percent_done < 100 && (
                        <span className="inline-flex shrink-0 items-center gap-0.5 text-xs text-muted-foreground tabular-nums">
                          <ListChecks size={11} />
                          {Math.round(t.percent_done)}%
                        </span>
                      )}
                    </div>

                    {/* 项目列 */}
                    <span
                      className="min-w-0 truncate text-xs"
                      style={{ color: project?.hex_color || TODO_ACCENT }}
                    >
                      {project ? project.title : "—"}
                    </span>

                    {/* 标签列：格子必须 min-w-0 + overflow-hidden，否则两枚长标签
                        会溢出轨道压到截止列（LabelChips 自身可收缩省略） */}
                    <div className="min-w-0 overflow-hidden">
                      {labels.length > 0 ? (
                        <LabelChips labels={labels} max={2} />
                      ) : (
                        <span className="text-xs text-muted-foreground">—</span>
                      )}
                    </div>

                    {/* 开始列（start_date 纯日期/本地零点）：中性色，不参与逾期红标 */}
                    <span className="flex min-w-0 items-center gap-0.5 text-xs text-muted-foreground">
                      {startText ? (
                        <>
                          <CalendarDays size={11} className="shrink-0" />
                          <span className="truncate">{startText}</span>
                        </>
                      ) : (
                        "—"
                      )}
                    </span>

                    {/* 截止列 */}
                    <span
                      className={cn(
                        "flex min-w-0 items-center gap-0.5 text-xs text-muted-foreground",
                        overdue && OVERDUE_COLOR_CLASS,
                      )}
                    >
                      {due ? (
                        <>
                          <Clock size={11} className="shrink-0" />
                          <span className="truncate">{due}</span>
                        </>
                      ) : (
                        "—"
                      )}
                      <ReminderChip reminder={reminder} />
                    </span>

                    {/* 时长列（M9 阶段一；未设置显示占位保持列对齐） */}
                    <span className="min-w-0 truncate text-xs text-muted-foreground tabular-nums">
                      {formatDuration(t.duration_minutes) ?? "—"}
                    </span>

                    {/* 行尾动作列：我的一天 → 星标（与列表行同序），hover/focus 显现；
                        列宽固定，不可见时仍占位，不随 hover 抖动/挤压标题 */}
                    <div className="flex items-center justify-end gap-1">
                      <button
                        type="button"
                        aria-label={inMyDay ? "移出我的一天" : "加入我的一天"}
                        className={cn(
                          "shrink-0",
                          inMyDay
                            ? "opacity-100"
                            : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
                        )}
                        style={inMyDay ? { color: MY_DAY_COLOR } : undefined}
                        onClick={(e) => {
                          e.stopPropagation();
                          // 写入口径与列表/详情/右键菜单一致：本地零点（toggleMyDayValue 单口径）
                          void todoTaskUpdate(t.id, {
                            my_day_date: toggleMyDayValue(t.my_day_date),
                          });
                        }}
                      >
                        <Sunrise size={16} fill={inMyDay ? "currentColor" : "none"} />
                      </button>
                      <button
                        type="button"
                        aria-label={t.is_favorite ? "取消收藏" : "收藏"}
                        className={cn(
                          "shrink-0",
                          t.is_favorite
                            ? "opacity-100"
                            : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
                        )}
                        style={{ color: FAVORITE_COLOR }}
                        onClick={(e) => {
                          e.stopPropagation();
                          void todoTaskUpdate(t.id, {
                            is_favorite: t.is_favorite ? 0 : 1,
                          });
                        }}
                      >
                        <Star size={16} fill={t.is_favorite ? "currentColor" : "none"} />
                      </button>
                    </div>
                  </div>
                </TaskContextMenu>
              </div>
            );
          })}
        </div>
      </div>

      {/* 批量删除确认（与列表视图同款口径） */}
      {confirmBatchDelete && (
        <div className="border-t bg-muted/30 px-4 py-2 text-sm">
          <span>
            确认删除已选 {selected.size} 项？删除后 5 秒内可撤销。
          </span>
          <button
            type="button"
            className="ml-2 rounded bg-destructive px-2 py-1 text-destructive-foreground"
            onClick={() => {
              setConfirmBatchDelete(false);
              batchDelete(selectedTasks);
            }}
          >
            确认删除
          </button>
          <button
            type="button"
            className="ml-2 rounded px-2 py-1 hover:bg-accent"
            onClick={() => setConfirmBatchDelete(false)}
          >
            取消
          </button>
        </div>
      )}
    </div>
  );
}
