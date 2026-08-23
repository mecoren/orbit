/**
 * TaskDetailDrawer — 任务详情抽屉（04 文档 §3.4 复刻）
 *
 * 八区块顺序：标题行 / 属性网格 / 描述 / 子任务 / 标签 / 提醒 / 关联任务 / 评论。
 * 数据源 todo_tasks_get_detail 五合一；变更即改即存，
 * 列表刷新依赖 db-change 全局失效；本抽屉内部经局部 refetch 同步。
 */
import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { format } from "date-fns";
import {
  AlignLeft,
  Bell,
  Calendar,
  Check,
  Flag,
  FolderOpen,
  Link2,
  ListChecks,
  Send,
  Star,
  Tag as TagIcon,
  Trash2,
  X,
} from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
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
import { DateTimePicker } from "@/components/business/date-picker";
import { WaitCalendar } from "@/components/ui/wait-calendar";
import { useTodoStore } from "@/features/todo/store";
import { PRIORITY_COLOR, TODO_ACCENT } from "../shared/constants";
import {
  todoCommentCreate,
  todoCommentDelete,
  todoLabelCreate,
  todoLabelList,
  todoSubtaskCreate,
  todoSubtaskDelete,
  todoSubtaskToggleDone,
  todoTaskDelete,
  todoTaskGetDetail,
  todoTaskLabelCreate,
  todoTaskLabelDelete,
  todoReminderCreate,
  todoReminderDelete,
  todoTaskUpdate,
} from "@/lib/tauri";

/** 关联类型中文标签（只读展示） */
const RELATION_TYPE_LABEL: Record<string, string> = {
  subtask: "子任务",
  blocks: "阻塞",
  blocked_by: "被阻塞",
  relates_to: "关联",
  duplicates: "重复于",
  duplicated_by: "重复项",
};

/** LabelAdder 新建随机色池（04 §3.8） */
const RANDOM_COLORS = [
  "#ef4444", "#f97316", "#eab308", "#22c55e",
  "#06b6d4", "#3b82f6", "#8b5cf6", "#ec4899",
];

const PRIORITY_LABELS = ["无", "低", "中", "高", "紧急", "立即处理"];
const STATUS_ITEMS = [
  { key: "pending", label: "待办", color: "#6B7280" },
  { key: "doing", label: "进行中", color: "#3B82F6" },
  { key: "done", label: "已完成", color: "#22C55E" },
];

interface ProjectOption {
  id: number;
  title: string;
  hex_color: string;
}

interface TaskDetailDrawerProps {
  projects: ProjectOption[];
}

export function TaskDetailDrawer({ projects }: TaskDetailDrawerProps) {
  const selectedTaskId = useTodoStore((s) => s.selectedTaskId);
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const qc = useQueryClient();
  const open = selectedTaskId != null;

  const detailQuery = useQuery({
    queryKey: ["todo-task-detail", selectedTaskId],
    queryFn: () => todoTaskGetDetail(selectedTaskId!),
    enabled: open,
  });
  const t = detailQuery.data;

  // 切换任务时重置查询缓存键由 key 承担；关闭时清空输入态在子组件内各自处理

  const refetchDetail = () => {
    if (selectedTaskId != null) {
      void qc.invalidateQueries({ queryKey: ["todo-task-detail", selectedTaskId] });
    }
  };

  const updateTask = async (patch: Parameters<typeof todoTaskUpdate>[1]) => {
    if (selectedTaskId == null) return;
    await todoTaskUpdate(selectedTaskId, patch);
    refetchDetail();
  };

  return (
    <Sheet open={open} onOpenChange={(o) => !o && setSelectedTaskId(null)}>
      <SheetContent className="w-full max-w-xl overflow-y-auto sm:max-w-xl">
        {t ? (
          <div className="flex flex-col gap-4 px-6 pb-8 pt-2">
            {/* 1. 标题行 */}
            <TitleRow task={t} onPatch={updateTask} />
            {/* 2. 属性网格 */}
            <PropertyGrid task={t} projects={projects} onPatch={updateTask} />
            {/* 3. 描述 */}
            {t.description && <SectionBlock icon={AlignLeft} title="描述">
              <p className="whitespace-pre-wrap text-[13px]">{t.description}</p>
            </SectionBlock>}
            {/* 4. 子任务 */}
            <SubtasksSection taskId={t.id} subtasks={t.subtasks} percentDone={t.percent_done} onChanged={refetchDetail} />
            {/* 5. 标签 */}
            <LabelsSection taskId={t.id} labels={t.labels} onChanged={refetchDetail} />
            {/* 6. 提醒 */}
            <RemindersSection taskId={t.id} reminders={t.reminders} onChanged={refetchDetail} />
            {/* 7. 关联任务 */}
            {t.relations.length > 0 && (
              <SectionBlock icon={Link2} title="关联任务">
                <div className="flex flex-wrap gap-x-3 gap-y-1">
                  {t.relations.map((r) => (
                    <span key={r.id} className="rounded-md bg-accent px-2 py-0.5 text-[11px] text-accent-foreground">
                      {RELATION_TYPE_LABEL[r.relation_type] ?? r.relation_type} · 任务 #{r.other_task_id}
                    </span>
                  ))}
                </div>
              </SectionBlock>
            )}
            {/* 8. 评论 */}
            <CommentsSection taskId={t.id} comments={t.comments} onChanged={refetchDetail} />
          </div>
        ) : (
          <div className="px-6 py-10 text-sm text-muted-foreground">加载中…</div>
        )}
      </SheetContent>
    </Sheet>
  );
}

/* ================= 区块 1：标题行 ================= */

function TitleRow({
  task,
  onPatch,
}: {
  task: Awaited<ReturnType<typeof todoTaskGetDetail>>;
  onPatch: (patch: Record<string, unknown>) => Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(task.title);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);

  useEffect(() => {
    setDraft(task.title);
    setEditing(false);
  }, [task.id, task.title]);

  const commit = async () => {
    const v = draft.trim();
    if (v && v !== task.title) await onPatch({ title: v });
    setEditing(false);
  };

  return (
    <div className="flex items-start gap-3 border-b pb-4">
      <button
        type="button"
        aria-label={task.done ? "标记未完成" : "标记完成"}
        className={cn(
          "mt-1 h-5 w-5 shrink-0 rounded-full border-2 transition-colors",
          task.done ? "border-primary bg-primary" : "border-muted-foreground/30 hover:border-primary",
        )}
        onClick={() =>
          onPatch(
            task.done
              ? { done: 0, done_at: null, status: "pending" }
              : { done: 1, done_at: Date.now(), status: "done" },
          )
        }
      >
        {task.done ? <Check className="m-auto size-3 text-white" /> : null}
      </button>

      <div className="min-w-0 flex-1">
        {editing ? (
          <Input
            autoFocus
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={() => void commit()}
            onKeyDown={(e) => {
              if (e.key === "Enter") void commit();
              if (e.key === "Escape") {
                setDraft(task.title);
                setEditing(false);
              }
            }}
            className="h-8 text-xl font-semibold"
          />
        ) : (
          <h2
            className={cn(
              "cursor-text truncate text-xl font-semibold leading-8",
              task.done && "text-muted-foreground line-through",
            )}
            onClick={() => setEditing(true)}
          >
            {task.title}
          </h2>
        )}
      </div>

      <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="收藏"
        style={{ color: task.is_favorite ? "#FACC15" : undefined }}
        onClick={() => void onPatch({ is_favorite: task.is_favorite ? 0 : 1 })}
      >
        <Star size={16} fill={task.is_favorite ? "currentColor" : "none"} />
      </Button>
      <Button variant="ghost" size="icon" className="text-destructive h-8 w-8" aria-label="删除"
        onClick={() => setConfirmDelete(true)}
      >
        <Trash2 size={16} />
      </Button>

      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>删除待办</AlertDialogTitle>
            <AlertDialogDescription>
              确定要删除「{task.title}」吗？此操作无法撤销。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={async () => {
                await todoTaskDelete(task.id);
                setSelectedTaskId(null);
              }}
            >
              删除
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/* ================= 区块 2：属性网格 ================= */

function InfoRow({
  icon: Icon,
  label,
  children,
}: {
  icon: typeof Flag;
  label: string;
  children?: React.ReactNode;
}) {
  return (
    <div className="flex items-center gap-2 overflow-hidden">
      <Icon size={14} className="shrink-0 text-muted-foreground" />
      <span className="shrink-0 text-[13px] text-muted-foreground">{label}</span>
      <div className="min-w-0 flex-1 truncate text-right text-[13px] font-medium">{children ?? "\u00A0"}</div>
    </div>
  );
}

function PropertyGrid({
  task,
  projects,
  onPatch,
}: {
  task: Awaited<ReturnType<typeof todoTaskGetDetail>>;
  projects: ProjectOption[];
  onPatch: (patch: Record<string, unknown>) => Promise<void>;
}) {
  const project = projects.find((p) => p.id === task.project_id);
  const statusDef = STATUS_ITEMS.find((s) => s.key === task.status);

  const setStatus = (key: string) => {
    if (key === "done") void onPatch({ status: "done", done: 1, done_at: Date.now() });
    else void onPatch({ status: key, done: 0, done_at: null });
  };

  return (
    <div className="grid grid-cols-2 gap-x-6 gap-y-3 rounded-xl bg-muted/40 p-3.5 text-sm">
      {/* 优先级 */}
      <InfoRow icon={Flag} label="优先级">
        <Popover>
          <PopoverTrigger asChild>
            <button type="button" className="font-medium hover:text-primary">
              {PRIORITY_LABELS[task.priority] || "无"}
            </button>
          </PopoverTrigger>
          <PopoverContent align="end" className="w-36 p-1">
            {PRIORITY_LABELS.map((label, i) => (
              <button key={i} type="button"
                className={cn("flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent",
                  task.priority === i && "bg-accent font-medium")}
                onClick={() => void onPatch({ priority: i })}
              >
                <span className="size-2 rounded-full" style={{ background: i === 0 ? "#D1D5DB" : PRIORITY_COLOR[i] }} />
                {label}
              </button>
            ))}
          </PopoverContent>
        </Popover>
      </InfoRow>

      {/* 状态 */}
      <InfoRow icon={Check} label="状态">
        <Popover>
          <PopoverTrigger asChild>
            <button type="button" className="font-medium hover:text-primary">
              {statusDef?.label ?? task.status}
            </button>
          </PopoverTrigger>
          <PopoverContent align="end" className="w-32 p-1">
            {STATUS_ITEMS.map((s) => (
              <button key={s.key} type="button"
                className={cn("flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent")}
                onClick={() => setStatus(s.key)}
              >
                <span
                  className={cn("size-2.5 rounded-full", task.status === s.key && "ring-2 ring-offset-1")}
                  style={{ background: s.color }}
                />
                {s.label}
              </button>
            ))}
          </PopoverContent>
        </Popover>
      </InfoRow>

      {/* 项目 */}
      <InfoRow icon={FolderOpen} label="项目">
        <Popover>
          <PopoverTrigger asChild>
            <button type="button" className="truncate font-medium hover:text-primary">
              {project?.title ?? "未分组"}
            </button>
          </PopoverTrigger>
          <PopoverContent align="start" className="w-56 p-1">
            <button type="button"
              className="flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent"
              onClick={() => void onPatch({ project_id: null })}
            >
              <span className="h-3 w-3 rounded-sm border border-dashed border-muted-foreground/50" />
              未分组
            </button>
            <div className="my-1 border-t" />
            {projects.map((p) => (
              <button key={p.id} type="button"
                className={cn("flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent",
                  task.project_id === p.id && "bg-accent font-medium")}
                onClick={() => void onPatch({ project_id: p.id })}
              >
                <span className="h-3 w-3 shrink-0 rounded-sm" style={{ background: p.hex_color || TODO_ACCENT }} />
                <span className="truncate">{p.title}</span>
              </button>
            ))}
          </PopoverContent>
        </Popover>
      </InfoRow>

      {/* 截止日期 */}
      <InfoRow icon={Calendar} label="截止日期">
        <DueDateEditor value={task.due_date} onChange={(ms) => void onPatch({ due_date: ms })} />
      </InfoRow>

      {/* 完成进度：仅 >0 显示，占位保持对齐（04 §3.4） */}
      <InfoRow icon={ListChecks} label="进度">
        {task.percent_done > 0 ? `${Math.round(task.percent_done)}%` : null}
      </InfoRow>
    </div>
  );
}

/** 截止日期编辑器：DateTimePicker + 清除（04 §3.4 即改即存） */
function DueDateEditor({
  value,
  onChange,
}: {
  value: number | null;
  onChange: (ms: number | null) => void;
}) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState("");

  useEffect(() => {
    if (open) {
      setDraft(value ? format(new Date(value), "yyyy-MM-dd'T'HH:mm") : "");
    }
  }, [open, value]);

  const commit = () => {
    if (!draft) onChange(null);
    else {
      const ms = new Date(draft.replace(" ", "T")).getTime();
      if (!Number.isNaN(ms)) onChange(ms);
    }
    setOpen(false);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button type="button" className="truncate font-medium hover:text-primary">
          {value ? format(new Date(value), "yyyy-MM-dd HH:mm") : "设置"}
        </button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-auto space-y-2 p-3">
        <WaitCalendar
          mode="single"
          selected={draft ? new Date(draft.replace(" ", "T")) : undefined}
          onSelect={(d) => {
            const prevTime = draft.split("T")[1] ?? "09:00";
            setDraft(d ? `${format(d, "yyyy-MM-dd")}T${prevTime}` : "");
          }}
        />
        <DateTimePicker value={draft} onChange={setDraft} />
        <div className="flex justify-end gap-2 border-t pt-2">
          {value != null && (
            <Button size="sm" variant="link" onClick={() => { onChange(null); setOpen(false); }}>
              清除
            </Button>
          )}
          <Button size="sm" variant="outline" onClick={() => setOpen(false)}>取消</Button>
          <Button size="sm" onClick={commit}>确定</Button>
        </div>
      </PopoverContent>
    </Popover>
  );
}

/* ================= 通用区块容器 ================= */

function SectionBlock({
  icon: Icon,
  title,
  trailing,
  children,
}: {
  icon: typeof Flag;
  title: string;
  trailing?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div>
      <div className="mb-2 flex items-center gap-2">
        <Icon size={14} className="text-muted-foreground" />
        <span className="text-[13px] font-medium text-muted-foreground">{title}</span>
        {trailing}
      </div>
      {children}
    </div>
  );
}

/* ================= 区块 4：子任务 ================= */

function SubtasksSection({
  taskId,
  subtasks,
  percentDone,
  onChanged,
}: {
  taskId: number;
  subtasks: Awaited<ReturnType<typeof todoTaskGetDetail>>["subtasks"];
  percentDone: number;
  onChanged: () => void;
}) {
  const [newTitle, setNewTitle] = useState("");
  const doneCount = subtasks.filter((s) => s.done).length;

  const add = async () => {
    const v = newTitle.trim();
    if (!v) return;
    await todoSubtaskCreate({ task_id: taskId, title: v });
    setNewTitle("");
    onChanged();
  };

  return (
    <SectionBlock
      icon={ListChecks}
      title="子任务"
      trailing={
        <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] text-muted-foreground">
          {doneCount}/{subtasks.length}
        </span>
      }
    >
      <div className="space-y-1">
        {subtasks.map((s) => (
          <div key={s.id} className="group flex items-center gap-2 rounded-md px-1 py-1 hover:bg-accent/30">
            <button
              type="button"
              aria-label={s.done ? "标记未完成" : "标记完成"}
              className={cn(
                "flex h-4 w-4 shrink-0 items-center justify-center rounded-sm border-2",
                s.done ? "border-primary bg-primary text-white" : "border-muted-foreground/40",
              )}
              onClick={async () => {
                await todoSubtaskToggleDone(s.id, !s.done);
                onChanged();
              }}
            >
              {s.done ? <Check className="size-2.5" /> : null}
            </button>
            <span className={cn("flex-1 truncate text-[13px]", s.done && "text-muted-foreground line-through")}>
              {s.title}
            </span>
            <button type="button" aria-label="删除子任务"
              className="opacity-0 group-hover:opacity-100"
              onClick={async () => { await todoSubtaskDelete(s.id); onChanged(); }}
            >
              <X size={14} className="text-muted-foreground hover:text-destructive" />
            </button>
          </div>
        ))}

        {/* 内联添加框 */}
        <div className="flex items-center gap-2 pt-1">
          <Input
            value={newTitle}
            placeholder="添加子任务"
            className="h-7 flex-1 text-[13px]"
            onChange={(e) => setNewTitle(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") void add(); }}
          />
          <Button size="sm" variant="ghost" className="h-7" disabled={!newTitle.trim()} onClick={() => void add()}>
            添加
          </Button>
        </div>

        {percentDone > 0 && (
          <p className="pt-1 text-[11px] text-muted-foreground">完成度自动回算：{Math.round(percentDone)}%</p>
        )}
      </div>
    </SectionBlock>
  );
}

/* ================= 区块 5：标签 ================= */

function LabelsSection({
  taskId,
  labels,
  onChanged,
}: {
  taskId: number;
  labels: Awaited<ReturnType<typeof todoTaskGetDetail>>["labels"];
  onChanged: () => void;
}) {
  const allLabelsQuery = useQuery({
    queryKey: ["todo-label", "list"],
    queryFn: () => todoLabelList({ page: 1, page_size: 1000 }),
    staleTime: 60_000,
  });
  const allLabels = allLabelsQuery.data ?? [];
  const mountedIds = new Set(labels.map((l) => l.id));
  const [popoverOpen, setPopoverOpen] = useState(false);
  const [newTitle, setNewTitle] = useState("");

  const toggleMount = async (labelId: number) => {
    const existing = labels.find((l) => l.id === labelId);
    if (existing) await todoTaskLabelDelete(existing.task_label_id);
    else await todoTaskLabelCreate({ task_id: taskId, label_id: labelId });
    onChanged();
    void allLabelsQuery.refetch();
  };

  const createAndMount = async () => {
    const v = newTitle.trim();
    if (!v) return;
    const color = RANDOM_COLORS[Math.floor(Math.random() * RANDOM_COLORS.length)];
    const created = await todoLabelCreate({ title: v, hex_color: color });
    await todoTaskLabelCreate({ task_id: taskId, label_id: created.id });
    setNewTitle("");
    setPopoverOpen(false);
    onChanged();
    void allLabelsQuery.refetch();
  };

  return (
    <SectionBlock icon={TagIcon} title="标签">
      <div className="flex flex-wrap items-center gap-1.5">
        {labels.map((l) => (
          <span key={l.task_label_id}
            className="inline-flex items-center gap-1 rounded-md px-2.5 py-0.5 text-xs font-medium text-white shadow-sm"
            style={{ background: l.hex_color }}
          >
            {l.title}
            <button type="button" aria-label={`移除标签 ${l.title}`}
              onClick={async () => { await todoTaskLabelDelete(l.task_label_id); onChanged(); }}
            >
              <X size={12} />
            </button>
          </span>
        ))}

        <Popover open={popoverOpen} onOpenChange={setPopoverOpen}>
          <PopoverTrigger asChild>
            <Button variant="outline" size="sm" className="h-7">添加标签</Button>
          </PopoverTrigger>
          <PopoverContent align="start" className="w-64 p-0">
            <div className="max-h-60 overflow-y-auto p-1">
              {allLabels.map((l) => (
                <label key={l.id} className="flex cursor-pointer items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent">
                  <input
                    type="checkbox"
                    checked={mountedIds.has(l.id)}
                    onChange={() => void toggleMount(l.id)}
                    className="accent-primary"
                  />
                  <span className="size-2.5 rounded-sm" style={{ background: l.hex_color }} />
                  <span className="truncate">{l.title}</span>
                </label>
              ))}
            </div>
            <div className="border-t p-2">
              <Input
                value={newTitle}
                placeholder="新建标签，Enter 创建"
                className="h-7 text-[13px]"
                onChange={(e) => setNewTitle(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Enter") void createAndMount(); }}
              />
            </div>
          </PopoverContent>
        </Popover>
      </div>
    </SectionBlock>
  );
}

/* ================= 区块 6：提醒 ================= */

function RemindersSection({
  taskId,
  reminders,
  onChanged,
}: {
  taskId: number;
  reminders: Awaited<ReturnType<typeof todoTaskGetDetail>>["reminders"];
  onChanged: () => void;
}) {
  // 编辑态：{reminderId, draft}——编辑=删旧建新（04 §3.4）
  const [editing, setEditing] = useState<{ id: number | null; draft: string } | null>(null);

  const commitNew = async () => {
    if (!editing?.draft) { setEditing(null); return; }
    const ms = new Date(editing.draft.replace(" ", "T")).getTime();
    if (!Number.isNaN(ms)) {
      if (editing.id != null) await todoReminderDelete(editing.id);
      await todoReminderCreate({ task_id: taskId, remind_at: ms });
      onChanged();
    }
    setEditing(null);
  };

  const fmt = (ms: number) => format(new Date(ms), "yyyy-MM-dd HH:mm");

  return (
    <SectionBlock
      icon={Bell}
      title="提醒"
      trailing={
        editing == null ? (
          <Button variant="link" size="sm" className="h-6 px-1 text-xs"
            onClick={() => setEditing({ id: null, draft: format(new Date(Date.now() + 3600_000), "yyyy-MM-dd'T'HH:mm") })}
          >
            添加提醒
          </Button>
        ) : undefined
      }
    >
      <div className="space-y-1.5">
        {reminders.map((r) =>
          editing?.id === r.id ? (
            <div key={r.id} className="space-y-1.5 rounded-lg bg-muted/40 p-2">
              <DateTimePicker value={editing.draft} onChange={(v) => setEditing({ ...editing, draft: v })} />
              <div className="flex justify-end gap-1">
                <Button size="sm" variant="ghost" onClick={() => setEditing(null)}>取消</Button>
                <Button size="sm" onClick={() => void commitNew()}>保存</Button>
              </div>
            </div>
          ) : (
            <div key={r.id} className="group flex items-center gap-2 rounded-lg bg-muted/40 px-3 py-2 text-[13px]">
              <Bell size={13} className="text-muted-foreground" />
              <button type="button" className="flex-1 text-left hover:text-primary"
                onClick={() => setEditing({ id: r.id, draft: fmt(r.remind_at) })}
              >
                {fmt(r.remind_at)}
              </button>
              <button type="button" aria-label="删除提醒" className="opacity-0 group-hover:opacity-100"
                onClick={async () => { await todoReminderDelete(r.id); onChanged(); }}
              >
                <X size={13} className="text-muted-foreground hover:text-destructive" />
              </button>
            </div>
          ),
        )}

        {editing?.id === null && (
          <div className="space-y-1.5 rounded-lg bg-muted/40 p-2">
            <DateTimePicker value={editing.draft} onChange={(v) => setEditing({ ...editing, draft: v })} />
            <div className="flex justify-end gap-1">
              <Button size="sm" variant="ghost" onClick={() => setEditing(null)}>取消</Button>
              <Button size="sm" onClick={() => void commitNew()}>添加</Button>
            </div>
          </div>
        )}
      </div>
    </SectionBlock>
  );
}

/* ================= 区块 8：评论 ================= */

function CommentsSection({
  taskId,
  comments,
  onChanged,
}: {
  taskId: number;
  comments: Awaited<ReturnType<typeof todoTaskGetDetail>>["comments"];
  onChanged: () => void;
}) {
  const [draft, setDraft] = useState("");

  const submit = async () => {
    const v = draft.trim();
    if (!v) return;
    await todoCommentCreate({ task_id: taskId, content: v });
    setDraft("");
    onChanged();
  };

  const relative = (ms: number) => {
    const diff = Date.now() - ms;
    if (diff < 60_000) return "刚刚";
    if (diff < 3600_000) return `${Math.floor(diff / 60_000)}分钟前`;
    if (diff < 86_400_000) return `${Math.floor(diff / 3600_000)}小时前`;
    if (diff < 7 * 86_400_000) return `${Math.floor(diff / 86_400_000)}天前`;
    return format(new Date(ms), "yyyy-MM-dd");
  };

  return (
    <SectionBlock icon={Send} title="评论">
      <div className="space-y-2">
        {comments.map((c) => (
          <div key={c.id} className="group rounded-lg bg-muted/40 px-3 py-2">
            <div className="flex items-start gap-2">
              <p className="whitespace-pre-wrap text-[13px]">{c.content}</p>
              <span className="ml-auto shrink-0 text-[11px] text-muted-foreground">{relative(c.created_at)}</span>
              <button type="button" aria-label="删除评论" className="opacity-0 group-hover:opacity-100"
                onClick={async () => { await todoCommentDelete(c.id); onChanged(); }}
              >
                <Trash2 size={12} className="text-muted-foreground hover:text-destructive" />
              </button>
            </div>
          </div>
        ))}

        <div className="flex items-center gap-2 pt-1">
          <Input
            value={draft}
            placeholder="输入评论..."
            className="h-8 flex-1 text-[13px]"
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") void submit(); }}
          />
          <Button size="icon" variant="ghost" className="h-8 w-8" disabled={!draft.trim()} onClick={() => void submit()}>
            <Send size={14} className="text-primary" />
          </Button>
        </div>
      </div>
    </SectionBlock>
  );
}
