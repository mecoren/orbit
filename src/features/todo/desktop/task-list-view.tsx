/**
 * TaskListView — 任务列表行（04 文档 §3.2 复刻）
 *
 * 行规格：圆形 checkbox（done 联动 status/done_at）+ 标题（划线）+
 * 元信息行（优先级色点/项目名/截止时间，逾期整段红）+ hover 星标。
 */
import { useRef } from "react";
import { formatDistanceToNow } from "date-fns";
import { zhCN } from "date-fns/locale";
import { Clock, Inbox, Plus, Star } from "lucide-react";
import { useVirtualizer } from "@tanstack/react-virtual";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorState } from "@/components/business/error-state";
import { EmptyState } from "@/components/business/empty-state";
import { todoTaskUpdate, type TodoProject, type TodoTask } from "@/lib/tauri";
import { FAVORITE_COLOR, OVERDUE_COLOR_CLASS, PRIORITY_COLOR } from "../shared/constants";
import { TaskContextMenu } from "./task-context-menu";

interface TaskListViewProps {
  tasks: TodoTask[];
  projects: TodoProject[];
  loading?: boolean;
  /** 列表查询错误文案；非空时整块渲染 ErrorState */
  error?: string | null;
  /** 空态"新建任务"动作回调（由 list-page 注入打开表单） */
  onCreateClick?: () => void;
  onOpenDetail: (id: number) => void;
}

/** 截止文案：±15 天内相对时间，否则 MM-dd（04 §3.2） */
function dueText(dueDate: number | null): string | null {
  if (!dueDate) return null;
  const ms = dueDate;
  const diff = Math.abs(ms - Date.now());
  if (diff <= 15 * 24 * 3600 * 1000) {
    return formatDistanceToNow(new Date(ms), { addSuffix: true, locale: zhCN });
  }
  const d = new Date(ms);
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

export function TaskListView({ tasks, projects, loading, error, onCreateClick, onOpenDetail }: TaskListViewProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  // P0 虚拟化：仅渲染可视窗 ± overscan（page_size=10000 全量拉取下的 DOM 治理）。
  // 行高估算 57（py-3×2 + 标题20 + meta16 + 边框），measureElement 动态校正两态行高差。
  const virtualizer = useVirtualizer({
    count: tasks.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 57,
    overscan: 8,
    getItemKey: (i) => tasks[i].id,
  });

  if (loading) {
    return (
      <div className="flex-1 divide-y divide-border/30 overflow-y-auto" aria-busy="true">
        {Array.from({ length: 8 }, (_, i) => (
          <div key={i} className="flex items-center gap-3 px-4 py-3">
            <Skeleton className="h-5 w-5 shrink-0 rounded-full" />
            <div className="min-w-0 flex-1 space-y-2">
              <Skeleton className="h-4 w-2/5" />
              <Skeleton className="h-3 w-1/5" />
            </div>
          </div>
        ))}
      </div>
    );
  }
  if (error) {
    return (
      <div className="flex-1 overflow-y-auto p-4">
        <ErrorState message={error} />
      </div>
    );
  }
  if (tasks.length === 0) {
    return (
      <div className="flex flex-1 items-center justify-center overflow-y-auto">
        <EmptyState
          icon={Inbox}
          title="暂无任务"
          hint="用底部输入栏快速记录，或点击下方按钮"
          action={
            onCreateClick ? (
              <Button size="sm" variant="outline" onClick={onCreateClick}>
                <Plus size={14} className="mr-1" />
                新建任务
              </Button>
            ) : undefined
          }
        />
      </div>
    );
  }

  const projectById = new Map(projects.map((p) => [p.id, p]));

  const toggleDone = (t: TodoTask) => {
    const done = t.done ? 0 : 1;
    void todoTaskUpdate(t.id, {
      done,
      done_at: done ? Date.now() : null,
      status: done ? "done" : "pending",
    });
  };

  const toggleFavorite = (t: TodoTask) => {
    void todoTaskUpdate(t.id, { is_favorite: t.is_favorite ? 0 : 1 });
  };

  return (
    <div ref={scrollRef} className="flex-1 overflow-y-auto">
      <div style={{ height: virtualizer.getTotalSize(), position: "relative" }}>
        {virtualizer.getVirtualItems().map((vi) => {
          const t = tasks[vi.index];
          const overdue = !!t.due_date && !t.done && t.due_date < Date.now();
          const due = dueText(t.due_date);
          const projectName = t.project_id != null ? projectById.get(t.project_id)?.title : undefined;
          return (
            // 绝对定位行容器：divide-y 在脱离文档流的兄弟间不生效，改每行自带 border-b
            <div
              key={t.id}
              data-index={vi.index}
              ref={virtualizer.measureElement}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                transform: `translateY(${vi.start}px)`,
              }}
            >
              <TaskContextMenu
                task={t}
                projects={projects}
                onOpenDetail={() => onOpenDetail(t.id)}
              >
                <div
                  className="group flex items-center gap-3 border-b border-border/30 px-4 py-3 hover:bg-accent/30"
                  onClick={() => onOpenDetail(t.id)}
                >
            {/* 完成 checkbox：圆环 */}
            <button
              type="button"
              aria-label={t.done ? "标记未完成" : "标记完成"}
              className={cn(
                "h-5 w-5 shrink-0 rounded-full border-2 transition-colors",
                t.done
                  ? "border-primary bg-primary"
                  : "border-muted-foreground/30 hover:border-primary",
              )}
              onClick={(e) => {
                e.stopPropagation();
                toggleDone(t);
              }}
            >
              {t.done ? <CheckSvg /> : null}
            </button>

            {/* 标题 + 元信息 */}
            <div className="min-w-0 flex-1">
              <div
                className={cn(
                  "truncate text-[15px] leading-5",
                  t.done && "text-muted-foreground line-through",
                )}
              >
                {t.title}
              </div>
              {(t.priority > 0 || projectName || due) && (
                <div
                  className={cn(
                    "mt-0.5 flex items-center gap-1.5 text-xs text-muted-foreground",
                    overdue && OVERDUE_COLOR_CLASS,
                  )}
                >
                  {t.priority > 0 && (
                    <span
                      className="h-1.5 w-1.5 rounded-full"
                      style={{ background: PRIORITY_COLOR[t.priority] }}
                    />
                  )}
                  {projectName && <span>{projectName}</span>}
                  {due && (
                    <span className="inline-flex items-center gap-0.5">
                      <Clock size={11} />
                      {due}
                    </span>
                  )}
                </div>
              )}
            </div>

            {/* 星标：hover 显现 */}
            <button
              type="button"
              aria-label={t.is_favorite ? "取消收藏" : "收藏"}
              className={cn(
                "shrink-0",
                t.is_favorite
                  ? "opacity-100"
                  : "opacity-0 group-hover:opacity-100",
              )}
              style={{ color: FAVORITE_COLOR }}
              onClick={(e) => {
                e.stopPropagation();
                toggleFavorite(t);
              }}
            >
              <Star size={16} fill={t.is_favorite ? "currentColor" : "none"} />
            </button>
                </div>
              </TaskContextMenu>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** 完成态白色对勾（04 §3.2：白勾 SVG） */
function CheckSvg() {
  return (
    <svg
      viewBox="0 0 24 24"
      className="m-auto size-3 text-white"
      fill="none"
      stroke="currentColor"
      strokeWidth={3}
    >
      <path d="M20 6L9 17l-5-5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
