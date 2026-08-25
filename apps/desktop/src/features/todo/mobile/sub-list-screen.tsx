/**
 * SubListScreen —— 任务子列表 /todo/tasks（05 §4.2 逐条复刻）
 *
 * 入口三参数互斥：projectId > ungrouped > view（04 §四 同款优先级）。
 * 列表消费共享 filterTasks/sortTasks；空态文案按入口八种映射；
 * FAB 右下 fixed（AboveBottomNavFab extraMargin=4 ≈ bottom-5 right-4）。
 * 表单抽屉（Task 15）：FAB 新建携 defaultProjectId=当前 projectId；
 * Tile 长按「编辑」携 editingTaskId——抽屉挂本屏层级。
 */
import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";

import { GlassFab } from "@/components/mobile/glass-fab";
import { LiquidGlassTitleBar } from "@/components/mobile/liquid-glass-title-bar";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { waitToast } from "@/components/mobile/wait-toast";
import {
  todoProjectList,
  todoTaskList,
  todoTaskUpdate,
  type TodoTask,
} from "@/lib/tauri";
import { QUICK_VIEWS, type QuickViewKey } from "../shared/constants";
import { applyDoneToggle } from "../shared/task-actions";
import { filterTasks, sortTasks } from "../shared/task-filters";
import { RecordFormBottomSheet } from "./form-bottom-sheet";
import { TodoTaskTile } from "./todo-task-tile";

/** 空态图标 + 文案八种映射（05 §4.2，按入口取值） */
function emptyMessage(target: { projectId: number | null; ungrouped: boolean; view: QuickViewKey | null }): string {
  if (target.projectId != null) return "该项目暂无任务";
  if (target.ungrouped) return "暂无未分组任务";
  switch (target.view) {
    case "undone":
      return "暂无未完成任务";
    case "done":
      return "暂无已完成任务";
    case "today":
      return "今天没有截止的任务";
    case "week":
      return "本周没有截止的任务";
    case "favorite":
      return "暂无收藏任务";
    default:
      return "暂无任务";
  }
}

export function SubListScreen() {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const scrollRef = useRef<HTMLDivElement>(null);
  const [searchParams] = useSearchParams();

  // ---- 表单抽屉状态（Task 15）：新建携 defaultProjectId / 编辑携 editingTaskId ----
  const [formOpen, setFormOpen] = useState(false);
  const [editingTaskId, setEditingTaskId] = useState<number | null>(null);
  const openForm = (taskId?: number | null) => {
    setEditingTaskId(taskId ?? null);
    setFormOpen(true);
  };

  // ---- searchParams 解析：三参数互斥，projectId 优先 > ungrouped > view ----
  const projectIdRaw = searchParams.get("projectId");
  const ungrouped = searchParams.get("ungrouped") != null;
  // 合法 projectId 须为正整数（空串 Number("")=0、非数字串在此一并拦截）
  const projectId =
    projectIdRaw != null && /^\d+$/.test(projectIdRaw) && Number(projectIdRaw) > 0 ? Number(projectIdRaw) : null;
  const view: QuickViewKey | null =
    !projectIdRaw && !ungrouped ? (QUICK_VIEWS.find((v) => v.key === searchParams.get("view"))?.key ?? null) : null;

  // ---- 数据查询（queryKey 复用桌面/侧栏同款；db-change 自动失效由 ReadyShell 统一处理）----
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

  // 动态标题（05 §4.2）：项目名 / 未分组 / 快捷视图 label
  const title = useMemo(() => {
    if (projectId != null) return projects.find((p) => p.id === projectId)?.title ?? "项目";
    if (ungrouped) return "未分组";
    return QUICK_VIEWS.find((v) => v.key === view)?.label ?? "任务";
  }, [projectId, ungrouped, view, projects]);

  // 过滤语义照抄桌面（04 §四）：filterTasks 内部即 ungrouped > projectId > quickView 互斥
  const visible = useMemo(
    () =>
      sortTasks(
        filterTasks(tasks, {
          quickView: view,
          projectId,
          ungrouped,
        }),
      ),
    [tasks, projectId, ungrouped, view],
  );

  const projectTitleById = useMemo(() => new Map(projects.map((p) => [p.id, p.title])), [projects]);

  // P0 虚拟化：scrollRef 同时是 LiquidGlassTitleBar 的滚动契约，复用为虚拟滚动容器；
  // 列表区在 AppBar 之下，offsetTop 作为 scrollMargin 换算坐标系（官方模式）
  const listRef = useRef<HTMLDivElement | null>(null);
  const [listOffset, setListOffset] = useState(0);
  // useLayoutEffect：首帧即取准 offsetTop，可视窗口计算不偏差
  useLayoutEffect(() => {
    if (listRef.current) setListOffset(listRef.current.offsetTop);
  }, []);
  const virtualizer = useVirtualizer({
    count: visible.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 76,
    overscan: 6,
    getItemKey: (i) => visible[i].id,
    scrollMargin: listOffset,
  });

  // 勾选/星标变更：todoTaskUpdate 落库后失效任务列表
  const patchTask = async (id: number, input: Record<string, unknown>, failMsg: string) => {
    try {
      await todoTaskUpdate(id, input);
      void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
    } catch {
      waitToast.destructive(failMsg);
    }
  };
  const toggleDone = (t: TodoTask) => void patchTask(t.id, applyDoneToggle(t), "更新失败");
  const toggleFavorite = (t: TodoTask) =>
    void patchTask(t.id, { is_favorite: t.is_favorite ? 0 : 1 }, "更新失败");

  // 项目入口 FAB 携 defaultProjectId=当前 projectId（05 §4.2/Task 15）
  const handleFabClick = () => openForm(null);

  return (
    <div className="h-dvh bg-[var(--m-bg)] text-[var(--m-text)]">
      {/* 主体滚动容器：ref 与标题栏同 commit 赋值（LiquidGlassTitleBar scrollRef 契约） */}
      <div ref={scrollRef} className="h-full overflow-y-auto overscroll-y-contain">
        {/* 标准 AppBar：arrow_back 返回 + 动态标题 + more_vert_rounded（MVP 无动作，禁用态） */}
        <LiquidGlassTitleBar
          title={title}
          scrollRef={scrollRef}
          onBack={() => navigate(-1)}
          actions={
            <button
              type="button"
              aria-label="更多"
              disabled
              className="grid h-12 w-12 place-items-center text-[var(--m-text)] opacity-50"
            >
              <MaterialIcon name="more_vert_rounded" size={24} />
            </button>
          }
        />

        {/* ListView padding top8/bottom48（05 §4.2）+ 底部安全区 */}
        <div className="flex min-h-full flex-col pt-2 pb-12">
            <div ref={listRef} className="flex-1">
              {visible.length > 0 && (
                <div style={{ height: virtualizer.getTotalSize(), position: "relative" }}>
                  {virtualizer.getVirtualItems().map((vi) => {
                    const t = visible[vi.index];
                    return (
                      <div
                        key={vi.key}
                        data-index={vi.index}
                        ref={virtualizer.measureElement}
                        style={{
                          // top 而非 transform：行内长按 BottomSheet / WaitAlertDialog
                          // 均为无 portal 的 fixed，transform 会把定位压进单行盒子
                          position: "absolute",
                          top: vi.start - virtualizer.options.scrollMargin,
                          left: 0,
                          width: "100%",
                        }}
                      >
                        <TodoTaskTile
                          task={t}
                          projectTitle={t.project_id != null ? (projectTitleById.get(t.project_id) ?? null) : null}
                          onToggleDone={() => toggleDone(t)}
                          onToggleFavorite={() => toggleFavorite(t)}
                          onEdit={() => openForm(t.id)}
                        />
                      </div>
                    );
                  })}
                </div>
              )}
              {visible.length === 0 && (
                /* 空态 EmptyState（05 §4.2）：checklist 大图标 + 八种映射文案 */
                <div className="flex flex-col items-center gap-3 pt-24 text-[var(--m-sub)]">
                  <MaterialIcon name="checklist" size={56} className="opacity-40" />
                  <p className="text-sm">{emptyMessage({ projectId, ungrouped, view })}</p>
                </div>
              )}
            </div>
          {/* 底部安全区 spacer（space48 预留由 .m-safe-bottom 覆盖） */}
          <div className="m-safe-bottom" aria-hidden />
        </div>
      </div>

      {/* FAB：右下 fixed（AboveBottomNavFab extraMargin=4 ≈ bottom-5 right-4）；accent=themeAccent #4E8CFF（GlassFab 默认值，05 §2.1/§4.2） */}
      <div className="fixed right-4 bottom-5 z-40">
        <GlassFab ariaLabel="新建待办" onClick={handleFabClick}>
          <MaterialIcon name="add_rounded" size={24} />
        </GlassFab>
      </div>

      {/* 表单抽屉（Task 15）：新建携当前 projectId，编辑携任务 id（挂本屏层级） */}
      <RecordFormBottomSheet
        open={formOpen}
        editingTaskId={editingTaskId}
        defaultProjectId={projectId}
        onClose={() => setFormOpen(false)}
      />
    </div>
  );
}
