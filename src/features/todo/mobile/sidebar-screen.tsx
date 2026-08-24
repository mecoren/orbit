/**
 * SidebarScreen —— 侧栏首屏 /todo（05 文档 §4.1 逐条复刻）
 *
 * 三段结构：快捷视图六行 / 项目（拖拽把手重排 + 行体长按删除双流）/ 未分组行。
 * 长按 vs 拖拽分离：dnd-kit TouchSensor 只绑 drag_handle 元素（delay 250ms /
 * tolerance 8），行体左区 pointer 长按 500ms 进删除流程，互不误触。
 */
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { MouseEvent as ReactMouseEvent, PointerEvent as ReactPointerEvent } from "react";
import { useNavigate } from "react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  closestCenter,
  DndContext,
  DragOverlay,
  MouseSensor,
  TouchSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import {
  arrayMove,
  SortableContext,
  useSortable,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable";

import { LiquidGlassTitleBar } from "@/components/mobile/liquid-glass-title-bar";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { WaitAlertDialog } from "@/components/mobile/wait-alert-dialog";
import { waitToast } from "@/components/mobile/wait-toast";
import {
  todoProjectCreate,
  todoProjectDelete,
  todoProjectList,
  todoProjectUpdateSortOrder,
  todoTaskList,
  type TodoProject,
  type TodoTask,
} from "@/lib/tauri";
import { QUICK_VIEWS, TODO_ACCENT, type QuickViewKey } from "../shared/constants";
import { filterTasks } from "../shared/task-filters";

/** 移动端快捷视图 Material 图标映射（05 §4.1；QUICK_VIEWS.icon 是 lucide 组件，移动端不用 lucide） */
const QUICK_VIEW_ICON: Record<QuickViewKey, string> = {
  all: "list_alt_rounded",
  undone: "radio_button_unchecked_rounded",
  done: "check_circle_outline_rounded",
  today: "calendar_today_rounded",
  week: "date_range_rounded",
  favorite: "star_border_rounded",
};

/** surfaceContainerHighest 内联近似（05 §4.1 badge/拖拽代理底色；M4 token 命名空间未含此项，亮暗双值自定） */
const SC_HIGHEST = { light: "#EDEDED", dark: "#23252E" } as const;

/** inline style 写不了 media query，运行期跟随系统深浅取值（与 index.css 移动 token 段同用 prefers-color-scheme） */
function useSurfaceHighest(): string {
  const [dark, setDark] = useState(
    () => window.matchMedia("(prefers-color-scheme: dark)").matches,
  );
  useEffect(() => {
    const mql = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = (e: MediaQueryListEvent) => setDark(e.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, []);
  return dark ? SC_HIGHEST.dark : SC_HIGHEST.light;
}

/** 长按 500ms 触发回调（05 §4.1 长按行=删除流程）；位移 >10px 或抬起/取消即中止 */
function useLongPress(onLongPress: () => void, enabled = true) {
  const timer = useRef<number | null>(null);
  const origin = useRef<{ x: number; y: number } | null>(null);
  // 长按已触发标记：抬指后的合成 click 必须吞掉，否则导航卸载当前屏、删除流程被打断
  const firedRef = useRef(false);
  const clear = () => {
    if (timer.current != null) {
      window.clearTimeout(timer.current);
      timer.current = null;
    }
    origin.current = null;
  };
  useEffect(() => clear, []); // 卸载兜底清计时器

  return {
    onPointerDown: (e: ReactPointerEvent) => {
      if (!enabled || e.button !== 0 || !e.isPrimary) return;
      origin.current = { x: e.clientX, y: e.clientY };
      firedRef.current = false;
      timer.current = window.setTimeout(() => {
        clear();
        firedRef.current = true;
        onLongPress();
      }, 500);
    },
    onPointerMove: (e: ReactPointerEvent) => {
      const o = origin.current;
      if (o && Math.hypot(e.clientX - o.x, e.clientY - o.y) > 10) clear();
    },
    onPointerUp: clear,
    onPointerCancel: clear,
    /** 抑制长按弹出的系统右键菜单 */
    onContextMenu: (e: ReactMouseEvent) => e.preventDefault(),
    /** 长按触发后吞掉同元素的合成 click（capture 先于 bubble，stopPropagation 拦截同元素 onClick） */
    onClickCapture: (e: ReactMouseEvent) => {
      if (firedRef.current) {
        firedRef.current = false;
        e.stopPropagation();
      }
    },
  };
}

/** 分区头（05 §4.1）：padding L16/R8/T12/B4、12px/sub/w600、可选尾部节点 */
function SectionHeader({ label, trailing }: { label: string; trailing?: ReactNode }) {
  return (
    <div className="flex items-center pb-1 pl-4 pr-2 pt-3">
      <span className="flex-1 text-xs font-semibold text-[var(--m-sub)]">{label}</span>
      {trailing}
    </div>
  );
}

/** 未完成计数 badge（05 §4.1）：surfaceContainerHighest 底、radius 8、padding h8/v2、字 12，仅 >0 显示 */
function CountBadge({ n, bg }: { n: number; bg: string }) {
  return (
    <span
      className="shrink-0 rounded-[8px] px-2 py-0.5 text-xs tabular-nums text-[var(--m-sub)]"
      style={{ background: bg }}
    >
      {n}
    </span>
  );
}

/** 可拖拽项目行：左区（色块+名称+badge）承载导航与长按删除，右侧把手独占拖拽监听 */
function SortableProjectRow({
  project,
  undoneCount,
  surfaceHighest,
  onRequestDelete,
}: {
  project: TodoProject;
  undoneCount: number;
  surfaceHighest: string;
  onRequestDelete: (project: TodoProject, undone: number) => void;
}) {
  const navigate = useNavigate();
  const { attributes, listeners, setNodeRef, setActivatorNodeRef, transform, transition, isDragging } =
    useSortable({ id: project.id });
  const longPress = useLongPress(
    () => onRequestDelete(project, undoneCount),
    !isDragging,
  );

  return (
    <div
      ref={setNodeRef}
      style={{
        transform: transform ? `translateY(${transform.y}px)` : undefined,
        transition,
        // 拖拽中的原行隐藏，由 DragOverlay 代理呈现
        opacity: isDragging ? 0.4 : undefined,
      }}
      className="flex items-center select-none"
    >
      {/* 左区：点击导航 + 长按删除（不含把手，避免与 TouchSensor 冲突） */}
      <div
        role="button"
        tabIndex={0}
        aria-label={`项目 ${project.title}`}
        onClick={() => navigate(`/todo/tasks?projectId=${project.id}`)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") navigate(`/todo/tasks?projectId=${project.id}`);
        }}
        className="flex min-w-0 flex-1 cursor-pointer items-center gap-3 rounded-lg py-2.5 pl-4 text-left active:bg-black/[.06] dark:active:bg-white/[.06]"
        {...longPress}
      >
        {/* 12×12 圆角色块（hex_color||强调色） */}
        <span
          className="size-3 shrink-0 rounded-[4px]"
          style={{ background: project.hex_color || TODO_ACCENT }}
        />
        <span className="min-w-0 flex-1 truncate text-base font-medium text-[var(--m-text)]">
          {project.title}
        </span>
        {undoneCount > 0 && <CountBadge n={undoneCount} bg={surfaceHighest} />}
      </div>
      {/* 拖拽把手：dnd-kit 监听只绑此处（05 §4.1 把手 onSurfaceVariant@50%） */}
      <button
        ref={setActivatorNodeRef}
        type="button"
        aria-label={`拖拽排序 ${project.title}`}
        className="grid touch-none place-items-center px-2 py-2.5 text-[var(--m-sub)] opacity-50"
        {...attributes}
        {...listeners}
      >
        <MaterialIcon name="drag_handle_rounded" size={22} />
      </button>
    </div>
  );
}

export function SidebarScreen() {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const scrollRef = useRef<HTMLDivElement>(null);
  const surfaceHighest = useSurfaceHighest();

  // ---- 数据查询（queryKey 复用桌面同款；db-change 自动失效由 App ReadyShell 统一处理）----
  const projectsQuery = useQuery({
    queryKey: ["todo-project", "list"],
    queryFn: () => todoProjectList({ page: 1, page_size: 1000 }),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const tasksQuery = useQuery({
    queryKey: ["todo_tasks", ""],
    queryFn: () => todoTaskList({ keyword: "", page: 1, page_size: 10000 }),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });

  const projects = projectsQuery.data ?? [];
  const tasks = tasksQuery.data ?? [];

  // 项目未完成计数聚合（同 desktop/list-page undoneCounts 手法：全量任务单遍聚合）
  const undoneCounts = useMemo(() => {
    const map: Record<number, number> = {};
    for (const t of tasks as TodoTask[]) {
      if (!t.done && t.project_id != null) {
        map[t.project_id] = (map[t.project_id] ?? 0) + 1;
      }
    }
    return map;
  }, [tasks]);

  // 未分组未完成计数（filterTasks ungrouped 过滤后统计）
  const ungroupedUndone = useMemo(
    () => filterTasks(tasks, { ungrouped: true }).filter((t) => !t.done).length,
    [tasks],
  );

  // ---- 拖拽：传感器只挂把手（TouchSensor delay 250/tolerance 8；MouseSensor 便于桌面调试同约束）----
  const sensors = useSensors(
    useSensor(TouchSensor, { activationConstraint: { delay: 250, tolerance: 8 } }),
    useSensor(MouseSensor, { activationConstraint: { delay: 250, tolerance: 8 } }),
  );
  const [activeId, setActiveId] = useState<number | null>(null);
  const activeProject = activeId != null ? projects.find((p) => p.id === activeId) : undefined;

  // ---- 删除保护双流 / 新建项目对话框状态 ----
  const [deleteTarget, setDeleteTarget] = useState<{
    project: TodoProject;
    undone: number;
  } | null>(null);
  const [creating, setCreating] = useState(false);
  const [newTitle, setNewTitle] = useState("");
  const [creatingBusy, setCreatingBusy] = useState(false);
  const createInputRef = useRef<HTMLInputElement>(null);

  // 新建项目（05 §4.1）：默认色 #3B82F6；成功 toast「项目已创建」
  const submitCreate = async () => {
    const title = newTitle.trim();
    if (!title || creatingBusy) return;
    setCreatingBusy(true);
    try {
      await todoProjectCreate({ title, hex_color: TODO_ACCENT });
      waitToast.message("项目已创建");
      setCreating(false);
      setNewTitle("");
      void qc.invalidateQueries({ queryKey: ["todo-project", "list"] });
    } catch {
      waitToast.destructive("创建失败");
    } finally {
      setCreatingBusy(false);
    }
  };

  // 确认删除（保护流已在前置对话框拦截 N>0）
  const confirmDelete = async (project: TodoProject) => {
    try {
      await todoProjectDelete(project.id);
      void qc.invalidateQueries({ queryKey: ["todo-project", "list"] });
    } catch {
      waitToast.destructive("删除失败");
    }
  };

  // 拖拽结束（05 §4.1）：本地乐观重排先行渲染 → 逐条落库 sortOrder=i+1；
  // 失败 toast「排序失败」并失效重拉（finally 对账成功结果亦无害）
  const handleDragStart = (e: DragStartEvent) => setActiveId(Number(e.active.id));
  const handleDragEnd = async (e: DragEndEvent) => {
    setActiveId(null);
    const { active, over } = e;
    if (!over || active.id === over.id) return;
    const ids = projects.map((p) => p.id);
    const oldIndex = ids.indexOf(active.id as number);
    const newIndex = ids.indexOf(over.id as number);
    if (oldIndex < 0 || newIndex < 0) return;
    const byId = new Map(projects.map((p) => [p.id, p]));
    const reordered = arrayMove(ids, oldIndex, newIndex)
      .map((id) => byId.get(id))
      .filter((p): p is TodoProject => p != null);

    qc.setQueryData<TodoProject[]>(["todo-project", "list"], reordered);
    // 逐条落库不中断：中途 break 会留下新旧混杂的撞号 sort_order（比拖拽前更乱），
    // 收集失败项、循环到底，最后统一 toast 一次并失效重拉对账
    let failed = false;
    try {
      for (let i = 0; i < reordered.length; i++) {
        try {
          await todoProjectUpdateSortOrder(reordered[i].id, i + 1);
        } catch {
          failed = true;
        }
      }
    } finally {
      if (failed) waitToast.destructive("排序失败");
      void qc.invalidateQueries({ queryKey: ["todo-project", "list"] });
    }
  };

  return (
    <div className="h-dvh bg-[var(--m-bg)] text-[var(--m-text)]">
      {/* 主体滚动容器：ref 与标题栏同 commit 赋值（LiquidGlassTitleBar scrollRef 契约） */}
      <div ref={scrollRef} className="h-full overflow-y-auto overscroll-y-contain">
        <LiquidGlassTitleBar
          title="待办"
          scrollRef={scrollRef}
          actions={
            <button
              type="button"
              aria-label="搜索"
              onClick={() => navigate("/todo/tasks?view=all")}
              className="grid h-12 w-12 place-items-center text-[var(--m-text)]"
            >
              <MaterialIcon name="search_rounded" size={24} />
            </button>
          }
        />

        {/* 一、快捷视图（05 §4.1 第 1 条）：六行 ListTile，icon 22 quickView 色 + 16/w500 标题 + chevron */}
        <section>
          <SectionHeader label="快捷视图" />
          <div className="pb-1">
            {QUICK_VIEWS.map((v) => (
              <button
                key={v.key}
                type="button"
                onClick={() => navigate(`/todo/tasks?view=${v.key}`)}
                className="flex w-full select-none items-center gap-3 px-4 py-2.5 text-left active:bg-black/[.06] dark:active:bg-white/[.06]"
              >
                <MaterialIcon name={QUICK_VIEW_ICON[v.key]} size={22} color={v.color} />
                <span className="min-w-0 flex-1 truncate text-base font-medium">{v.label}</span>
                <MaterialIcon name="chevron_right_rounded" size={22} color="var(--m-sub)" />
              </button>
            ))}
          </div>
        </section>

        {/* 二、项目（05 §4.1 第 2 条）：可拖拽重排；长按行体=删除流程 */}
        <section>
          <SectionHeader
            label="项目"
            trailing={
              <button
                type="button"
                aria-label="新建项目"
                onClick={() => setCreating(true)}
                className="grid h-9 w-9 shrink-0 place-items-center text-[var(--m-text)]"
              >
                <MaterialIcon name="add_rounded" size={22} />
              </button>
            }
          />
          <DndContext
            sensors={sensors}
            collisionDetection={closestCenter}
            onDragStart={handleDragStart}
            onDragEnd={handleDragEnd}
            onDragCancel={() => setActiveId(null)}
          >
            <SortableContext items={projects.map((p) => p.id)} strategy={verticalListSortingStrategy}>
              <div className="pb-1">
                {projects.map((p) => (
                  <SortableProjectRow
                    key={p.id}
                    project={p}
                    undoneCount={undoneCounts[p.id] ?? 0}
                    surfaceHighest={surfaceHighest}
                    onRequestDelete={(project, undone) => setDeleteTarget({ project, undone })}
                  />
                ))}
              </div>
            </SortableContext>
            {/* 拖拽代理：surfaceContainerHighest 底色浮层（05 §4.1） */}
            <DragOverlay>
              {activeProject && (
                <div
                  className="flex items-center gap-3 rounded-xl px-4 py-2.5 shadow-md"
                  style={{ background: surfaceHighest }}
                >
                  <span
                    className="size-3 shrink-0 rounded-[4px]"
                    style={{ background: activeProject.hex_color || TODO_ACCENT }}
                  />
                  <span className="min-w-0 flex-1 truncate text-base font-medium text-[var(--m-text)]">
                    {activeProject.title}
                  </span>
                  {(undoneCounts[activeProject.id] ?? 0) > 0 && (
                    /* 代理底色与 badge 同为 surfaceHighest 会吞掉 badge 形状，改用页面 surface 底+描边区分 */
                    <CountBadge n={undoneCounts[activeProject.id]} bg="var(--m-surface)" />
                  )}
                </div>
              )}
            </DragOverlay>
          </DndContext>
        </section>

        {/* 三、未分组（05 §4.1 第 3 条）：inbox(sub 色) + 计数 badge + chevron */}
        <section className="pb-1">
          <button
            type="button"
            onClick={() => navigate("/todo/tasks?ungrouped=1")}
            className="flex w-full select-none items-center gap-3 px-4 py-2.5 text-left active:bg-black/[.06] dark:active:bg-white/[.06]"
          >
            <MaterialIcon name="inbox_rounded" size={22} color="var(--m-sub)" />
            <span className="min-w-0 flex-1 truncate text-base font-medium">未分组</span>
            {ungroupedUndone > 0 && <CountBadge n={ungroupedUndone} bg={surfaceHighest} />}
            <MaterialIcon name="chevron_right_rounded" size={22} color="var(--m-sub)" />
          </button>
        </section>

        {/* 底部安全区 spacer（space48 预留由 .m-safe-bottom 覆盖） */}
        <div className="m-safe-bottom" aria-hidden />
      </div>

      {/* 新建项目对话框（05 §4.1）：label 项目名称 + autofocus 输入 + 取消/创建(FilledButton 蓝) */}
      {creating && (
        <div
          className="fixed inset-0 z-[60] grid place-items-center bg-black/40 p-6"
          onClick={() => !creatingBusy && setCreating(false)}
        >
          <div
            className="w-full max-w-xs rounded-[20px] p-6"
            style={{ background: "var(--m-surface)" }}
            onClick={(e) => e.stopPropagation()}
          >
            <h3 className="text-base font-semibold text-[var(--m-text)]">新建项目</h3>
            <label htmlFor="new-project-title" className="mt-4 block text-xs text-[var(--m-sub)]">
              项目名称
            </label>
            <input
              id="new-project-title"
              ref={createInputRef}
              autoFocus
              value={newTitle}
              onChange={(e) => setNewTitle(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void submitCreate();
              }}
              maxLength={50}
              className="mt-1 w-full rounded-lg border border-transparent bg-black/[.05] px-3 py-2 text-sm text-[var(--m-text)] outline-none placeholder:text-[var(--m-sub)] focus:border-[#3B82F6] dark:bg-white/[.07]"
            />
            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                className="rounded-lg px-4 py-2 text-sm text-[var(--m-sub)]"
                onClick={() => !creatingBusy && setCreating(false)}
              >
                取消
              </button>
              <button
                type="button"
                disabled={!newTitle.trim() || creatingBusy}
                className="rounded-lg px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
                style={{ background: TODO_ACCENT }}
                onClick={() => void submitCreate()}
              >
                创建
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 删除保护双流（05 §4.1 第 4 条逐字文案）：有未完成任务 → 拒绝；否则 destructive 确认 */}
      <WaitAlertDialog
        open={deleteTarget != null && deleteTarget.undone > 0}
        title="无法删除"
        message={`该项目下还有 ${deleteTarget?.undone ?? 0} 条未完成任务，请先清空或移走任务后再删除。`}
        onClose={() => setDeleteTarget(null)}
      />
      <WaitAlertDialog
        open={deleteTarget != null && deleteTarget.undone === 0}
        title="删除项目"
        message={`确定要删除项目「${deleteTarget?.project.title ?? ""}」吗？该操作不可撤销。`}
        onClose={() => setDeleteTarget(null)}
        destructiveLabel="删除"
        onConfirm={() => deleteTarget && void confirmDelete(deleteTarget.project)}
      />
    </div>
  );
}
