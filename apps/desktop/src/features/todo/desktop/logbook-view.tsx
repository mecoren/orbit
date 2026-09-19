/**
 * Logbook 视图 —— 已完成任务的完成历史（对标 Things 3 Logbook）
 *
 * 选中侧栏「已完成」快捷视图（quickView=done）且处于列表档时接管渲染：
 * 按完成日（done_at 本地日）倒序分组、组内按完成时刻倒序——「最近的成就
 * 排最前」；行复用日历行 CalendarTaskRow（划线/优先级条/标签同口径）。
 *
 * 隐藏已完成开关（默认开）与 done 视图互不干扰：filterTasks 在 quickView=done
 * 时不剔除完成行，本视图的数据源即全量完成集（filterTasks 输出）。
 * 虚拟化：日历 VirtualGroupedList 同款打平 [日头+任务行] 序列 +
 * useVirtualizer 动态 measure（长年使用后完成集可达数千行）。
 */
import { useMemo, useRef } from "react";
import { format } from "date-fns";
import { zhCN } from "date-fns/locale";
import { useVirtualizer } from "@tanstack/react-virtual";
import { CheckCircle2, Inbox } from "lucide-react";

import { cn } from "@/lib/utils";
import { EmptyState } from "@/components/business/empty-state";
import { TaskContextMenu } from "./task-context-menu";
import { CalendarTaskRow } from "./calendar-view";
import { groupDoneByDay } from "../shared/task-filters";
import type { ProjectedTaskLabel, TodoProject, TodoTask } from "@/lib/tauri";

interface LogbookViewProps {
  /** filterTasks 输出的完成集（quickView=done 语义：全部 done 任务） */
  tasks: TodoTask[];
  projects: TodoProject[];
  projectById: Map<number, TodoProject>;
  labelsByTask: Map<number, ProjectedTaskLabel[]>;
  loading?: boolean;
  onOpenDetail: (id: number) => void;
}

/** 打平条目：完成日头 + 任务行 */
type FlatItem =
  | { kind: "day"; key: string; label: string; count: number; isToday: boolean }
  | { kind: "task"; key: string; task: TodoTask };

/** 完成日头标签："今天" / "M月d日 EEEE"（与统计热力图/日历日头同口径） */
function dayHeadLabel(date: Date, today: Date): string {
  if (
    date.getFullYear() === today.getFullYear() &&
    date.getMonth() === today.getMonth() &&
    date.getDate() === today.getDate()
  ) {
    return "今天";
  }
  return format(date, "M月d日 EEEE", { locale: zhCN });
}

export function LogbookView({
  tasks,
  projects,
  projectById,
  labelsByTask,
  loading,
  onOpenDetail,
}: LogbookViewProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const today = useMemo(() => new Date(), []);

  const groups = useMemo(() => groupDoneByDay(tasks, today), [tasks, today]);

  // 打平 [日头 + 任务行] 线性序列（日历 VirtualGroupedList 同款手法）
  const flat = useMemo<FlatItem[]>(() => {
    const out: FlatItem[] = [];
    for (const g of groups) {
      out.push({
        kind: "day",
        key: `d-${g.key}`,
        label: dayHeadLabel(g.date, today),
        count: g.tasks.length,
        isToday: g.key === format(today, "yyyy-MM-dd"),
      });
      for (const t of g.tasks) out.push({ kind: "task", key: `t-${t.id}`, task: t });
    }
    return out;
  }, [groups, today]);

  const virtualizer = useVirtualizer({
    count: flat.length,
    getScrollElement: () => scrollRef.current,
    // 初值仅影响首帧测量前估计（日头 ~33 + 任务行 48+间距）
    estimateSize: (i) => (flat[i].kind === "day" ? 33 : 56),
    overscan: 10,
    getItemKey: (i) => flat[i].key,
  });

  if (loading) {
    return (
      <div aria-busy className="flex min-h-0 flex-1 flex-col gap-2 p-4">
        {Array.from({ length: 6 }, (_, i) => (
          <div key={i} className="h-12 animate-pulse rounded bg-muted" />
        ))}
      </div>
    );
  }
  if (tasks.length === 0) {
    return (
      <div className="flex min-h-0 flex-1 items-center justify-center overflow-y-auto">
        <EmptyState
          icon={Inbox}
          title="还没有完成记录"
          hint="完成的任务会按完成日归档在这里，形成你的完成历史"
        />
      </div>
    );
  }

  return (
    <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto p-2">
      <div style={{ height: virtualizer.getTotalSize(), position: "relative", width: "100%" }}>
        {virtualizer.getVirtualItems().map((vi) => {
          const item = flat[vi.index];
          return (
            <div
              key={item.key}
              data-index={vi.index}
              ref={virtualizer.measureElement}
              style={{ position: "absolute", top: vi.start, left: 0, width: "100%" }}
            >
              {item.kind === "day" ? (
                <div className="mt-4 flex items-center gap-2 px-1 py-1.5 first:mt-0">
                  <CheckCircle2 className="size-3.5 text-emerald-500" aria-hidden />
                  <span
                    className={cn(
                      "rounded px-1.5 py-0.5 text-xs font-medium",
                      item.isToday ? "bg-primary text-primary-foreground" : "text-muted-foreground",
                    )}
                  >
                    {item.label}
                  </span>
                  <span className="text-xs text-muted-foreground/70 tabular-nums">
                    {item.count} 条
                  </span>
                  <span className="h-px flex-1 bg-border/40" />
                </div>
              ) : (
                <div className="py-0.5">
                  <TaskContextMenu
                    task={item.task}
                    projects={projects}
                    onOpenDetail={() => onOpenDetail(item.task.id)}
                  >
                    <CalendarTaskRow
                      task={item.task}
                      labels={labelsByTask.get(item.task.id) ?? []}
                      project={
                        item.task.project_id != null
                          ? projectById.get(item.task.project_id)
                          : undefined
                      }
                      onActivate={() => onOpenDetail(item.task.id)}
                      overdue={false}
                    />
                  </TaskContextMenu>
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
