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
import { isListActivationKey, listNavDirection } from "../shared/list-keyboard";
import { completeTask } from "../shared/task-actions";
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

  // 键盘导航（P1#8）：行 DOM 注册表（task id → 元素）；j/k 移动焦点并由
  // scrollToIndex 让可视窗跟随，避免焦点行滚出屏幕丢失
  const rowRefs = useRef(new Map<number, HTMLDivElement>());
  const focusRow = (index: number) => {
    if (index < 0 || index >= tasks.length) return;
    virtualizer.scrollToIndex(index, { align: "auto" });
    // 动态 measureElement 下，目标行可能晚一帧才挂载：rAF 重试至多 5 帧
    // （评审 I2：快速连按 j/k + 行高校正时单次 rAF 会静默丢焦点）
    let tries = 0;
    const tryFocus = () => {
      const el = rowRefs.current.get(tasks[index]?.id);
      if (el) {
        el.focus();
      } else if (++tries < 5) {
        requestAnimationFrame(tryFocus);
      }
    };
    requestAnimationFrame(tryFocus);
  };

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
    void completeTask(t);
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
            // 绝对定位行容器：divide-y 在脱离文档流的兄弟间不生效，改每行自带 border-b。
            // 用 top 而非 transform 定位——transform 会让本行成为 fixed 后代
            // （ContextMenuBase 的哨兵锚点）的 containing block，滚动后菜单错位飞出
            <div
              key={t.id}
              data-index={vi.index}
              ref={virtualizer.measureElement}
              style={{
                position: "absolute",
                top: vi.start,
                left: 0,
                width: "100%",
              }}
            >
              <TaskContextMenu
                task={t}
                projects={projects}
                onOpenDetail={() => onOpenDetail(t.id)}
              >
                <div
                  ref={(el) => {
                    if (el) rowRefs.current.set(t.id, el);
                    else rowRefs.current.delete(t.id);
                  }}
                  role="button"
                  tabIndex={0}
                  aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
                  className="group flex cursor-default items-center gap-3 border-b border-border/30 px-4 py-3 hover:bg-accent/30 focus-visible:bg-accent/40 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring"
                  onClick={() => onOpenDetail(t.id)}
                  onKeyDown={(e) => {
                    if (e.nativeEvent.isComposing) return; // IME 组合期不响应
                    // 评审 C1：焦点在内层 checkbox/星标上时保留其原生 Enter/Space
                    // 点击（keydown 冒泡至此会劫持并 preventDefault 掉原生 click）；
                    // 仅当焦点在本行容器时才拦截为"打开详情"。j/k 导航保持冒泡可用。
                    if (e.target === e.currentTarget && isListActivationKey(e.key)) {
                      e.preventDefault();
                      onOpenDetail(t.id);
                      return;
                    }
                    const dir = listNavDirection(e.key);
                    if (!dir) return;
                    e.preventDefault();
                    focusRow(vi.index + (dir === "down" ? 1 : -1));
                  }}
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
              : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
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
