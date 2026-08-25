/**
 * ProjectSidebar — 项目侧栏（04 文档 §3.1 复刻）
 *
 * 结构：快捷入口区（6 视图，选中才显示语义色图标）+ 项目列表区
 * （色块 + 名称 + 拖拽手柄，内联新增在列表尾部，右键删除，删除保护双 AlertDialog）。
 * 未分组为虚拟项（id=-1），可拖拽参与项目排序，默认项目第一位，
 * 位置持久化为「前驱项目 id」存 localStorage（LS_UNGROUPED_AFTER）。
 */
import { useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router";
import { useSortable } from "@dnd-kit/sortable";
import { closestCenter, DndContext, type DragEndEvent } from "@dnd-kit/core";
import {
  SortableContext,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable";
import { GripVertical, Inbox, Plus } from "lucide-react";

import { cn } from "@/lib/utils";
import { hideFromQueries, useUndoableDeleteAction } from "@/hooks/use-undoable-delete";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
  todoProjectCreate,
  todoProjectDelete,
  todoProjectUpdateSortOrder,
  type TodoProject,
} from "@/lib/tauri";
import { LS_UNGROUPED_AFTER, QUICK_VIEWS, TODO_ACCENT, type QuickViewKey } from "../shared/constants";
import { ProjectContextMenu } from "./task-context-menu";

/** 未分组虚拟 id */
export const UNGROUPED_ID = -1;

interface ProjectSidebarProps {
  projects: TodoProject[];
  /** 项目 id → 未完成任务数（由父级从任务全量数据聚合，删除保护判定用） */
  undoneCounts: Record<number, number>;
  activeQuickView: QuickViewKey | null;
  activeProjectId: number | null;
  ungroupedActive: boolean;
  onSelectQuickView: (key: QuickViewKey) => void;
  onSelectProject: (id: number) => void;
  onSelectUngrouped: () => void;
}

export function ProjectSidebar({
  projects,
  undoneCounts,
  activeQuickView,
  activeProjectId,
  ungroupedActive,
  onSelectQuickView,
  onSelectProject,
  onSelectUngrouped,
}: ProjectSidebarProps) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const [adding, setAdding] = useState(false);
  const [newTitle, setNewTitle] = useState("");

  // 删除保护对话框状态：null 关闭；{project, hasUndone} 决定弹哪种
  const [deleteTarget, setDeleteTarget] = useState<{
    project: TodoProject;
    hasUndone: boolean;
    undoneCount?: number;
  } | null>(null);

  const refetchProjects = () => qc.invalidateQueries({ queryKey: ["todo-project", "list"] });

  // ---- 组合排序：未分组（UNGROUPED_ID 占位）+ 项目 ----
  // 未分组位置持久化为「前驱项目 id」（空 = 最前，默认项目第一位）
  const projectById = useMemo(() => new Map(projects.map((p) => [p.id, p])), [projects]);
  const orderedIds = useMemo(() => {
    const ids = projects.map((p) => p.id);
    const raw = localStorage.getItem(LS_UNGROUPED_AFTER);
    const afterId = raw ? Number(raw) : null;
    let idx = 0; // 默认最前
    if (afterId != null && !Number.isNaN(afterId)) {
      const at = ids.indexOf(afterId);
      if (at >= 0) idx = at + 1;
    }
    const combined = [...ids];
    combined.splice(idx, 0, UNGROUPED_ID);
    return combined;
  }, [projects]);

  const submitNew = async () => {
    const title = newTitle.trim();
    if (!title) {
      setAdding(false);
      return;
    }
    try {
      await todoProjectCreate({ title });
      await refetchProjects();
    } finally {
      setNewTitle("");
      setAdding(false);
    }
  };

  // 删除项目：项目下有未完成任务 → 拒绝；无任务 → 确认后进入撤销窗口软删
  const undoableDelete = useUndoableDeleteAction();
  const confirmDelete = (project: TodoProject) => {
    setDeleteTarget(null);
    if (activeProjectId === project.id) navigate("/todo");
    undoableDelete({
      entityLabel: "项目",
      recordName: project.title,
      commit: async () => {
        await todoProjectDelete(project.id);
        await refetchProjects();
      },
      hide: (qc) => hideFromQueries(qc, ["todo-project"], project.id),
    });
  };

  // 拖拽结束：组合列表 arraymove；未分组位置存 localStorage，
  // 项目逐条 sortOrder=i+1 重编号落库（04 §3.1）
  const handleDragEnd = async (event: DragEndEvent) => {
    const { active, over } = event;
    if (!over || active.id === over.id) return;
    const oldIndex = orderedIds.indexOf(active.id as number);
    const newIndex = orderedIds.indexOf(over.id as number);
    if (oldIndex < 0 || newIndex < 0) return;
    const reordered = [...orderedIds];
    const [moved] = reordered.splice(oldIndex, 1);
    reordered.splice(newIndex, 0, moved);

    // 未分组新位置：记录前驱项目 id（无前驱 = 最前）
    const ugIdx = reordered.indexOf(UNGROUPED_ID);
    const prevId = ugIdx > 0 ? reordered[ugIdx - 1] : null;
    localStorage.setItem(LS_UNGROUPED_AFTER, prevId == null ? "" : String(prevId));

    // 乐观更新项目缓存，再逐条落库（跳过未分组占位）
    const reorderedProjects = reordered
      .filter((id) => id !== UNGROUPED_ID)
      .map((id) => projectById.get(id))
      .filter((p): p is TodoProject => p != null);
    qc.setQueryData(["todo-project", "list"], reorderedProjects);
    for (let i = 0; i < reorderedProjects.length; i++) {
      await todoProjectUpdateSortOrder(reorderedProjects[i].id, i + 1);
    }
    void refetchProjects();
  };

  return (
    <div className="flex h-full w-56 shrink-0 flex-col border-r border-border bg-card/30">
      {/* 快捷入口区 */}
      <div className="space-y-1 p-3">
        {QUICK_VIEWS.map((v) => {
          const active = activeQuickView === v.key && !ungroupedActive;
          return (
            <button
              key={v.key}
              type="button"
              onClick={() => onSelectQuickView(v.key)}
              className={cn(
                "flex w-full items-center gap-2 rounded-md px-3 py-2 text-sm",
                active ? "bg-primary/10 font-medium text-primary" : "hover:bg-accent/50",
              )}
            >
              {/* 未选中与未分组图标同款（继承前景色），选中才显示语义色 */}
              <v.icon className="size-4" style={active ? { color: v.color } : undefined} />
              <span>{v.label}</span>
            </button>
          );
        })}
      </div>

      {/* 项目列表区 */}
      <div className="flex min-h-0 flex-1 flex-col px-3 pb-3">
        <div className="flex items-center justify-between py-1">
          <span className="text-xs uppercase tracking-wide text-muted-foreground">项目</span>
          <Button variant="ghost" size="icon" className="h-6 w-6" onClick={() => setAdding(true)}>
            <Plus className="size-3.5" />
          </Button>
        </div>

        <ScrollArea className="min-h-0 flex-1">
          <DndContext collisionDetection={closestCenter} onDragEnd={handleDragEnd}>
            <SortableContext
              items={orderedIds}
              strategy={verticalListSortingStrategy}
            >
              <div className="space-y-0.5">
                {orderedIds.map((id) =>
                  id === UNGROUPED_ID ? (
                    <SortableUngroupedRow
                      key={id}
                      active={ungroupedActive}
                      onSelect={onSelectUngrouped}
                    />
                  ) : (
                    <SortableProjectRow
                      key={id}
                      project={projectById.get(id)!}
                      undoneCount={undoneCounts[id] ?? 0}
                      active={activeProjectId === id && !ungroupedActive}
                      onSelect={() => onSelectProject(id)}
                      onRequestDelete={(hasUndone, undoneCount) => {
                        const project = projectById.get(id);
                        if (project) setDeleteTarget({ project, hasUndone, undoneCount });
                      }}
                    />
                  ),
                )}

                {/* 内联新增：输入框固定在已有项目之后 */}
                {adding && (
                  <Input
                    className="mt-0.5 h-8"
                    autoFocus
                    value={newTitle}
                    placeholder="项目名称"
                    onChange={(e) => setNewTitle(e.target.value)}
                    onBlur={submitNew}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") void submitNew();
                      if (e.key === "Escape") {
                        setNewTitle("");
                        setAdding(false);
                      }
                    }}
                  />
                )}
              </div>
            </SortableContext>
          </DndContext>
        </ScrollArea>
      </div>

      {/* 删除保护双弹窗（04 §3.1） */}
      <AlertDialog
        open={deleteTarget?.hasUndone === true}
        onOpenChange={(o) => !o && setDeleteTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>无法删除</AlertDialogTitle>
            <AlertDialogDescription>
              该项目下还有未完成任务，请先清空或移走任务后再删除。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogAction>我知道了</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog
        open={deleteTarget != null && deleteTarget.hasUndone === false}
        onOpenChange={(o) => !o && setDeleteTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>删除项目</AlertDialogTitle>
            <AlertDialogDescription>
              确定要删除项目「{deleteTarget?.project.title}」吗？删除后 5 秒内可撤销。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => deleteTarget && confirmDelete(deleteTarget.project)}
            >
              删除
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/** 未分组虚拟项（id=-1，可拖拽参与项目排序） */
function SortableUngroupedRow({
  active,
  onSelect,
}: {
  active: boolean;
  onSelect: () => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition } = useSortable({
    id: UNGROUPED_ID,
  });

  return (
    <div
      ref={setNodeRef}
      style={{ transform: transform ? `translateY(${transform.y}px)` : undefined, transition }}
      className={cn(
        "group flex items-center gap-2 rounded-md px-2 py-1.5 text-sm",
        active
          ? "bg-primary/10 font-medium text-primary"
          : "text-sidebar-foreground hover:bg-sidebar-accent/50",
      )}
    >
      <GripVertical
        {...attributes}
        {...listeners}
        className="w-3 cursor-grab text-muted-foreground/30 opacity-0 group-hover:opacity-100"
      />
      <button
        type="button"
        onClick={onSelect}
        className="flex min-w-0 flex-1 items-center gap-2 text-left"
      >
        <Inbox className="size-4 shrink-0" />
        <span className="truncate">未分组</span>
      </button>
    </div>
  );
}

/** 单行可拖拽项目项 */
function SortableProjectRow({
  project,
  undoneCount,
  active,
  onSelect,
  onRequestDelete,
}: {
  project: TodoProject;
  undoneCount: number;
  active: boolean;
  onSelect: () => void;
  /** 上报删除请求；hasUndone 决定弹窗类型（保护 / 确认） */
  onRequestDelete: (hasUndone: boolean, undoneCount: number) => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition } = useSortable({
    id: project.id,
  });

  return (
    <div
      ref={setNodeRef}
      style={{ transform: transform ? `translateY(${transform.y}px)` : undefined, transition }}
      className={cn(
        "group flex items-center gap-2 rounded-md px-2 py-1.5 text-sm",
        active ? "bg-primary/10 font-medium text-primary" : "hover:bg-sidebar-accent/50",
      )}
    >
      <GripVertical
        {...attributes}
        {...listeners}
        className="w-3 cursor-grab text-muted-foreground/30 opacity-0 group-hover:opacity-100"
      />
      {/* 右键菜单：标题头 + 删除项目（保护弹窗由父级处理） */}
      <ProjectContextMenu
        projectTitle={project.title}
        onRequestDelete={() => onRequestDelete(undoneCount > 0, undoneCount)}
      >
        <button
          type="button"
          onClick={onSelect}
          className="flex min-w-0 flex-1 items-center gap-2 text-left"
        >
          <span
            className="h-2.5 w-2.5 shrink-0 rounded-sm"
            style={{ background: project.hex_color || TODO_ACCENT }}
          />
          <span className="truncate">{project.title}</span>
        </button>
      </ProjectContextMenu>
    </div>
  );
}
