/**
 * TaskDetailDrawer — 任务详情抽屉（04 文档 §3.4 复刻）
 *
 * 八区块顺序：标题行 / 属性网格 / 描述 / 子任务 / 标签 / 提醒 / 关联任务 / 评论。
 * 数据源 todo_tasks_get_detail 五合一；变更即改即存，
 * 列表刷新依赖 db-change 全局失效；本抽屉内部经局部 refetch 同步。
 */
import { useEffect, useRef, useState } from "react";
import { useQueries, useQuery, useQueryClient } from "@tanstack/react-query";
import { format } from "date-fns";
import {
  Copy,
  AlignLeft,
  Bell,
  Calendar,
  Check,
  CircleStop,
  CornerUpRight,
  ExternalLink,
  File as FileIcon,
  Flag,
  FolderOpen,
  History,
  Link2,
  ListChecks,
  Loader2,
  Paperclip,
  Plus,
  Repeat,
  Send,
  Star,
  Sunrise,
  Tag as TagIcon,
  Trash2,
  X,
  BellRing,
} from "lucide-react";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import {
  getDescPreviewDelayMs,
  getDescPreviewEnabled,
} from "../shared/desc-preview-pref";
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
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { DateTimePicker } from "@/components/business/date-picker";
import { QuickDateMenu } from "@/components/business/quick-date-options";
import { WaitCalendar } from "@/components/ui/wait-calendar";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useTodoStore } from "@/features/todo/store";
import { hideFromQueries, useUndoableDeleteAction } from "@/hooks/use-undoable-delete";
import { usePasteAttachment } from "@/hooks/use-paste-attachment";
import { PRIORITY_COLOR, TODO_ACCENT, PRIORITY_LABELS, STATUS_COLOR, MY_DAY_COLOR, PRESET_10 } from "../shared/constants";
import { todayStartMs, toggleMyDayValue } from "../shared/task-filters";
import { ConfirmPopover } from "../shared/confirm-popover";
import { renderMarkdown } from "../shared/markdown-lite";
import { REPEAT_MODE, REPEAT_PRESETS, WEEKDAY_CHIPS, repeatLabel } from "../shared/repeat";
import { completeTask } from "@/features/todo/shared/task-actions";
import {
  todoTaskDuplicate,
  globalSearch,
  taskAttachmentAdd,
  taskAttachmentRemove,
  taskAttachmentsList,
  type TaskAttachmentView,
  todoCommentCreate,
  todoCommentDelete,
  todoLabelCreate,
  todoLabelList,
  todoSubtaskCreate,
  todoSubtaskDelete,
  todoSubtaskPromote,
  todoSubtaskToggleDone,
  todoTaskDelete,
  todoTaskGet,
  todoTaskGetDetail,
  todoTaskLabelCreate,
  todoTaskLabelDelete,
  todoTaskRelationCreate,
  todoTaskRelationDelete,
  todoReminderCreate,
  todoReminderDelete,
  todoTaskUpdate,
  taskActivityList,
  type TodoComment,
  type TodoSubtask,
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

// 状态三档从 STATUS_COLOR 组装（单口径；此前值与 constants 重复两份）
const STATUS_ITEMS = [
  { key: "pending", label: "待办", color: STATUS_COLOR.pending },
  { key: "doing", label: "进行中", color: STATUS_COLOR.doing },
  { key: "done", label: "已完成", color: STATUS_COLOR.done },
] as const;

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
    // 缓存分层（F5）：详情单条查询 5min 未观察即卸载——全局 gcTime 10min
    // 面向列表级 key，抽屉逐条打开过的历史详情无理由驻留到 10 分钟
    gcTime: 5 * 60_000,
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
      {/* 头部固定 + 内容区独立滚动：SheetContent 去 overflow-y-auto，
          标题行（完成钮/标题/日出/星标/删除）常驻不随内容滚走 */}
      <SheetContent className="flex w-full max-w-xl flex-col gap-0 p-0 sm:max-w-xl">
        {t ? (
          <>
            {/* 1. 标题行（固定头部；右侧留出关闭钮 44px 防遮挡） */}
            <div className="shrink-0 px-6 pt-8">
              <TitleRow task={t} onPatch={updateTask} />
            </div>
            {/* 2-9. 其余区块：独立滚动 */}
            <div className="min-h-0 flex-1 overflow-y-auto">
              <div className="flex flex-col gap-4 px-6 pb-8 pt-4">
                <PropertyGrid task={t} projects={projects} onPatch={updateTask} />
                <DescriptionSection task={t} onPatch={updateTask} />
                <SubtasksSection taskId={t.id} subtasks={t.subtasks} percentDone={t.percent_done} onChanged={refetchDetail} />
                <LabelsSection taskId={t.id} labels={t.labels} onChanged={refetchDetail} />
                <RemindersSection
                  taskId={t.id}
                  reminders={t.reminders}
                  taskDone={!!t.done}
                  repeatMode={t.repeat_mode}
                  repeatAfter={t.repeat_after}
                  repeatWeekdays={t.repeat_weekdays}
                  repeatEndType={t.repeat_end_type}
                  repeatEndParam={t.repeat_end_param}
                  repeatFromDone={t.repeat_from_done}
                  onChanged={refetchDetail}
                />
                <RelationsSection
                  taskId={t.id}
                  relations={t.relations}
                  onChanged={refetchDetail}
                />
                <CommentsSection taskId={t.id} comments={t.comments} onChanged={refetchDetail} />
                <AttachmentsSection taskId={t.id} />
                <ActivitySection taskId={t.id} />
              </div>
            </div>
          </>
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
  const inMyDay = task.my_day_date === todayStartMs();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(task.title);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const undoableDelete = useUndoableDeleteAction();

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
    <div className="flex items-center gap-3 border-b pb-4">
      <button
        type="button"
        aria-label={task.done ? "标记未完成" : "标记完成"}
        className={cn(
          "h-5 w-5 shrink-0 rounded-full border-2 transition-colors",
          task.done ? "border-primary bg-primary" : "border-muted-foreground/30 hover:border-primary",
        )}
        onClick={() => void completeTask(task)}
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

      <Button
        variant="ghost"
        size="icon"
        className="h-8 w-8"
        aria-label={inMyDay ? "移出我的一天" : "加入我的一天"}
        style={{ color: inMyDay ? MY_DAY_COLOR : undefined }}
        onClick={() => {
          void onPatch({ my_day_date: toggleMyDayValue(task.my_day_date) });
        }}
      >
        <Sunrise size={16} fill={inMyDay ? "currentColor" : "none"} />
      </Button>
      <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="收藏"
        style={{ color: task.is_favorite ? "#FACC15" : undefined }}
        onClick={() => void onPatch({ is_favorite: task.is_favorite ? 0 : 1 })}
      >
        <Star size={16} fill={task.is_favorite ? "currentColor" : "none"} />
      </Button>
      <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="复制任务"
        title="复制任务（克隆字段与子任务）"
        onClick={() => {
          void (async () => {
            try {
              const copy = await todoTaskDuplicate(task.id);
              toast.success(`已复制为「${copy.title}」`);
              setSelectedTaskId(copy.id);
            } catch (e) {
              toast.error(`复制失败：${e}`);
            }
          })();
        }}
      >
        <Copy size={16} />
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
            <AlertDialogDescription className="break-words">
              确定要删除「{task.title}」吗？删除后 5 秒内可撤销，之后将移入回收站。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => {
                setConfirmDelete(false);
                setSelectedTaskId(null);
                // Provider 在 ListPage 层：抽屉关闭卸载不丢撤销窗口
                undoableDelete({
                  entityLabel: "任务",
                  recordName: task.title,
                  commit: () => todoTaskDelete(task.id),
                  hide: (qc) => hideFromQueries(qc, ["todo_tasks"], task.id),
                });
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
    // 评审 I2：对已完成任务再点「已完成」是幂等动作，不得经 completeTask 翻回待办
    if (key === "done") {
      if (!task.done) void completeTask(task);
    } else void onPatch({ status: key, done: 0, done_at: null });
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
                <span className="size-2 rounded-full" style={{ background: PRIORITY_COLOR[i] }} />
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
            {/* #36：项目名按项目色着字（未分组保持默认前景色） */}
            <button
              type="button"
              className="truncate font-medium hover:text-primary"
              style={project ? { color: project.hex_color || TODO_ACCENT } : undefined}
            >
              {project?.title ?? "未分组"}
            </button>
          </PopoverTrigger>
          <PopoverContent align="start" className="w-56 p-1">
            <button
              type="button"
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
                <span className="truncate" style={{ color: p.hex_color || TODO_ACCENT }}>{p.title}</span>
              </button>
            ))}
          </PopoverContent>
        </Popover>
      </InfoRow>

      {/* 截止日期 */}
      <InfoRow icon={Calendar} label="截止日期">
        <DueDateEditor value={task.due_date} onChange={(ms) => void onPatch({ due_date: ms })} />
      </InfoRow>

      {/* 开始日期（纯日期，零点语义；与移动端详情「截止→开始」相邻同款） */}
      <InfoRow icon={CircleStop} label="开始日期">
        <StartDateEditor value={task.start_date} onChange={(ms) => void onPatch({ start_date: ms })} />
      </InfoRow>

      {/* 完成进度：仅 >0 显示，占位保持对齐（04 §3.4） */}
      <InfoRow icon={ListChecks} label="进度">
        {task.percent_done > 0 ? `${Math.round(task.percent_done)}%` : null}
      </InfoRow>

      {/* 完成时间：done_at 仅完成任务可见（未完成为空占位保持对齐） */}
      <InfoRow icon={Check} label="完成时间">
        {task.done_at != null ? format(task.done_at, "yyyy-MM-dd HH:mm") : null}
      </InfoRow>

      {/* 重复规则（repeat_after/repeat_mode；提醒触发后前端排下一次） */}
      <InfoRow icon={Repeat} label="重复">
        <RepeatEditor
          mode={task.repeat_mode}
          after={task.repeat_after}
          weekdays={task.repeat_weekdays}
          endType={task.repeat_end_type}
          endParam={task.repeat_end_param}
          fromDone={task.repeat_from_done}
          onChange={(v) =>
            void onPatch({
              repeat_mode: v.mode,
              repeat_after: v.after,
              repeat_weekdays: v.mode === REPEAT_MODE.WEEKLY ? v.weekdays : 0,
              repeat_end_type: v.endType,
              repeat_end_param: v.endParam,
              repeat_from_done: v.fromDone,
            })
          }
        />
      </InfoRow>
    </div>
  );
}

/**
 * 开始日期编辑器：快捷项（今天/明天/下周）⇄ 纯日历，即改即存。
 * 与 DueDateEditor 的差异：start_date 是日期级字段（惯例存本地零点，
 * 无时刻语义）——无时分输入行，选中即提交零点 ms，显示 yyyy-MM-dd。
 * 清除为二次确认（与截止日期同款交互）。
 */
function StartDateEditor({
  value,
  onChange,
}: {
  value: number | null;
  onChange: (ms: number | null) => void;
}) {
  const [open, setOpen] = useState(false);
  const [draft, setOpenDraft] = useState("");
  const [confirmClear, setConfirmClear] = useState(false);

  const toYm = (ms: number) => format(new Date(ms), "yyyy-MM-dd");

  useEffect(() => {
    if (open) setConfirmClear(false);
  }, [open]);

  useEffect(() => {
    if (!confirmClear || !open) return;
    const id = setTimeout(() => setConfirmClear(false), 3000);
    return () => clearTimeout(id);
  }, [confirmClear, open]);

  const commit = (ymd: string) => {
    if (!ymd) onChange(null);
    else {
      const ms = new Date(`${ymd}T00:00:00`).getTime();
      if (!Number.isNaN(ms)) onChange(ms);
    }
    setOpen(false);
  };

  const clearStart = () => {
    if (!confirmClear) {
      setConfirmClear(true);
      return;
    }
    onChange(null);
    setOpen(false);
    setConfirmClear(false);
    toast.success("已清除开始日期");
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button type="button" className="truncate font-medium hover:text-primary">
          {value ? toYm(value) : "设置"}
        </button>
      </PopoverTrigger>
      {/* 弹层宽度对齐 DueDateEditor 的 w-72（288px）：日历 caption 行
          （月份 72px + 年份 112px 下拉 + 两侧翻月钮与 px-9 让位）内容宽
          ~286px，w-64 装不下导致日历向右溢出弹层边界。 */}
      <PopoverContent align="end" className="w-72 space-y-2 p-3">
        {draft ? (
          <>
            <WaitCalendar
              mode="single"
              selected={draft ? new Date(`${draft}T00:00:00`) : undefined}
              onSelect={(d) => setOpenDraft(d ? format(d, "yyyy-MM-dd") : "")}
            />
            <div className="flex justify-end gap-2 border-t pt-2">
              <Button size="sm" variant="outline" onClick={() => setOpenDraft("")}>
                返回
              </Button>
              <Button size="sm" onClick={() => commit(draft)}>确定</Button>
            </div>
          </>
        ) : (
          <QuickDateMenu
            kind="date"
            value={value ? toYm(value) : undefined}
            onSelect={(d) => {
              onChange(new Date(`${format(d, "yyyy-MM-dd")}T00:00:00`).getTime());
              setOpen(false);
            }}
            customLabel="选择日期"
            onCustom={() => setOpenDraft(value ? toYm(value) : format(Date.now(), "yyyy-MM-dd"))}
          />
        )}
        {draft ? null : (
          <div className="flex justify-end gap-2 border-t pt-2">
            {value != null && (
              <Button
                size="sm"
                variant={confirmClear ? "destructive" : "link"}
                onClick={clearStart}
              >
                {confirmClear ? "确认清除？" : "清除"}
              </Button>
            )}
            <Button size="sm" variant="outline" onClick={() => setOpen(false)}>取消</Button>
          </div>
        )}
      </PopoverContent>
    </Popover>
  );
}

/** 重复规则选择器：预设（每天/周/月/年）+ 自定义 N 天（04 §3.4 即改即存） */
function RepeatEditor({
  mode,
  after,
  weekdays,
  endType,
  endParam,
  fromDone,
  onChange,
}: {
  mode: number;
  after: number;
  weekdays: number;
  endType: number;
  endParam: number;
  fromDone: number;
  onChange: (v: {
    mode: number;
    after: number;
    weekdays: number;
    endType: number;
    endParam: number;
    fromDone: number;
  }) => void;
}) {
  const [open, setOpen] = useState(false);
  const [customDays, setCustomDays] = useState("3");
  // 扩展规则编辑态（打开时从任务初始化）
  const [weekdayMask, setWeekdayMask] = useState(weekdays);
  const [endOption, setEndOption] = useState(endType);
  const [endText, setEndText] = useState(
    endType === 2 ? String(Math.max(1, endParam || 1)) : "",
  );
  const [endDate, setEndDate] = useState(
    endType === 1 && endParam > 0 ? new Date(endParam).toISOString().slice(0, 10) : "",
  );
  const [whenDone, setWhenDone] = useState(fromDone);
  // 结束=日期档的内联日历开关：Popover 内禁嵌自带 Popover 的 DatePicker
  //（portal 套 portal 布局测量异常，同 DueDateEditor 的教训），此处
  // 内联项目日历 WaitCalendar 两段式切换
  const [endDateCalendar, setEndDateCalendar] = useState(false);

  // 打开时同步外部值（外部 task 切换场景）
  useEffect(() => {
    if (open) return;
    setWeekdayMask(weekdays);
    setEndOption(endType);
    setEndText(endType === 2 ? String(Math.max(1, endParam || 1)) : "");
    setEndDate(endType === 1 && endParam > 0 ? new Date(endParam).toISOString().slice(0, 10) : "");
    setWhenDone(fromDone);
    setEndDateCalendar(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, after, weekdays, endType, endParam, fromDone, open]);

  const applyExt = (m: number, a: number) => {
    let param = 0;
    if (endOption === 2) param = Math.max(1, Number(endText) || 1);
    if (endOption === 1 && endDate) param = new Date(`${endDate}T23:59:59`).getTime();
    onChange({
      mode: m,
      after: a,
      weekdays: m === REPEAT_MODE.WEEKLY ? weekdayMask : 0,
      endType: endOption,
      endParam: param,
      fromDone: whenDone,
    });
    setOpen(false);
  };

  const pick = (m: number, a: number) => {
    // 预设 = 基础语义：清扩展态并应用
    setWeekdayMask(0);
    setEndOption(0);
    setEndText("");
    setEndDate("");
    setWhenDone(0);
    onChange({ mode: m, after: a, weekdays: 0, endType: 0, endParam: 0, fromDone: 0 });
    setOpen(false);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button type="button" className="truncate font-medium hover:text-primary">
          {mode === REPEAT_MODE.NONE
            ? "不重复"
            : repeatLabel(mode, after, { weekdays, endType, endParam, fromDone })}
        </button>
      </PopoverTrigger>
      {/* 日历展开态独占弹层（w-72=288px 容纳日历 ~286px）：只渲染日历 +
          返回钮——原面板内容全高 675px，弹层 bottom 出视口（800px）100px；
          隐藏其余内容后日历态 ~330px 内敛，且横向 286>254 的溢出同步消除 */}
      <PopoverContent align="end" className="w-72 p-1">
        {endDateCalendar ? (
          <>
            <div className="p-1">
              <WaitCalendar
                mode="single"
                selected={endDate ? new Date(`${endDate}T00:00:00`) : undefined}
                onSelect={(d) => {
                  setEndDate(d ? format(d, "yyyy-MM-dd") : "");
                  setEndDateCalendar(false);
                }}
              />
            </div>
            <Button
              size="sm"
              variant="outline"
              className="h-6 w-full text-xs"
              onClick={() => setEndDateCalendar(false)}
            >
              返回
            </Button>
          </>
        ) : (
          <>
            {REPEAT_PRESETS.map((p) => (
              <button key={p.mode} type="button"
                className={cn("flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent",
                  mode === p.mode && after === p.after && "bg-accent font-medium")}
                onClick={() => pick(p.mode, p.after)}
              >
                {p.label}
                {mode === p.mode && after === p.after && <Check size={13} className="ml-auto text-primary" />}
              </button>
            ))}
            <div className="my-1 border-t" />
            <button type="button"
              className={cn("flex w-full items-center rounded-sm px-2 py-1.5 text-sm hover:bg-accent",
                mode === REPEAT_MODE.NONE && "bg-accent font-medium")}
              onClick={() => pick(REPEAT_MODE.NONE, 0)}
            >
              不重复
              {mode === REPEAT_MODE.NONE && <Check size={13} className="ml-auto text-primary" />}
            </button>
            <div className="flex items-center gap-1.5 px-2 py-1.5">
              <span className="shrink-0 text-xs text-muted-foreground">每</span>
              <Input
                type="number"
                min={1}
                value={customDays}
                onChange={(e) => setCustomDays(e.target.value)}
                className="h-6 w-14 px-1.5 text-xs"
                onKeyDown={(e) => {
                  if (e.key === "Enter") applyExt(REPEAT_MODE.DAILY, Math.max(1, Number(customDays) || 1));
                }}
              />
              <span className="shrink-0 text-xs text-muted-foreground">天</span>
              <Button size="sm" variant="ghost" className="ml-auto h-6 px-2 text-xs"
                onClick={() => applyExt(REPEAT_MODE.DAILY, Math.max(1, Number(customDays) || 1))}
              >
                确定
              </Button>
            </div>

        {/* #34 扩展规则：星期几 / 结束条件 / when done */}
        <div className="mt-1 space-y-1.5 border-t px-2 py-1.5">
          <div className="flex flex-wrap items-center gap-1">
            <span className="text-[11px] text-muted-foreground">星期几</span>
            {WEEKDAY_CHIPS.map((d) => (
              <button
                key={d.bit}
                type="button"
                aria-label={`星期${d.label}`}
                onClick={() => setWeekdayMask((m) => m ^ d.bit)}
                className={cn(
                  "size-6 rounded-md border text-[11px]",
                  (weekdayMask & d.bit) !== 0
                    ? "border-primary bg-primary/10 font-medium text-primary"
                    : "text-muted-foreground hover:bg-accent",
                )}
              >
                {d.label}
              </button>
            ))}
          </div>
          <div className="flex flex-wrap items-center gap-1.5">
            <span className="text-[11px] text-muted-foreground">结束</span>
            {[{ t: 0, l: "永不" }, { t: 2, l: "次数" }, { t: 1, l: "日期" }].map((o) => (
              <button key={o.t} type="button"
                onClick={() => setEndOption(o.t)}
                className={cn(
                  "rounded-md border px-2 py-0.5 text-[11px]",
                  endOption === o.t
                    ? "border-primary bg-primary/10 font-medium text-primary"
                    : "text-muted-foreground hover:bg-accent",
                )}
              >
                {o.l}
              </button>
            ))}
            {endOption === 2 && (
              <Input value={endText} inputMode="numeric" placeholder="次数"
                className="h-6 w-14 px-1.5 text-xs"
                onChange={(e) => setEndText(e.target.value)} />
            )}
            {endOption === 1 && (
              <button
                type="button"
                onClick={() => setEndDateCalendar(true)}
                className={cn(
                  "flex items-center gap-1 rounded-md border px-2 py-0.5 text-[11px]",
                  endDate
                    ? "text-foreground"
                    : "text-muted-foreground hover:bg-accent",
                )}
              >
                <Calendar className="size-3" />
                {endDate || "选择日期"}
              </button>
            )}
          </div>
          <div className="flex items-center gap-1.5">
            <button type="button"
              onClick={() => setWhenDone((v) => (v ? 0 : 1))}
              className={cn(
                "rounded-md border px-2 py-0.5 text-[11px]",
                whenDone
                  ? "border-primary bg-primary/10 font-medium text-primary"
                  : "text-muted-foreground hover:bg-accent",
              )}
              title="默认按原定日期推进（节奏恒定）；勾选后按实际完成日推进（迟到完成，下次顺延一个完整周期）"
            >
              按完成日推进
            </button>
          </div>
          <Button size="sm" variant="outline" className="h-6 w-full text-xs"
            disabled={mode === REPEAT_MODE.NONE}
            onClick={() => applyExt(mode, Math.max(1, after || 1))}
          >
            应用扩展规则
          </Button>
          </div>
          </>
        )}
      </PopoverContent>
    </Popover>
  );
}

/** 截止日期编辑器：快捷选项 ⇄ 日历+时间，即改即存（04 §3.4；快捷项与表单/快捷新增同口径） */
function DueDateEditor({
  value,
  onChange,
}: {
  value: number | null;
  onChange: (ms: number | null) => void;
}) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState("");
  // 快捷菜单 ⇄ 完整日历+时间视图；关闭弹层时复位
  const [showPicker, setShowPicker] = useState(false);
  // 清除二次确认（Popover 内不宜再套 Popover——qraft 同款嵌套测量异常；
  // 首点「清除」变红显示「确认清除？」，3 秒内再点执行，超时/关闭弹层复位）
  const [confirmClear, setConfirmClear] = useState(false);

  useEffect(() => {
    if (open) {
      setDraft(value ? format(new Date(value), "yyyy-MM-dd'T'HH:mm") : "");
      setShowPicker(false);
      setConfirmClear(false);
    }
  }, [open, value]);

  // 弹层开着时保持确认窗口的 3 秒超时复位
  useEffect(() => {
    if (!confirmClear || !open) return;
    const id = setTimeout(() => setConfirmClear(false), 3000);
    return () => clearTimeout(id);
  }, [confirmClear, open]);

  const commit = () => {
    if (!draft) onChange(null);
    else {
      const ms = new Date(draft.replace(" ", "T")).getTime();
      if (!Number.isNaN(ms)) onChange(ms);
    }
    setOpen(false);
  };

  const clearDue = () => {
    if (!confirmClear) {
      setConfirmClear(true);
      return;
    }
    onChange(null);
    setOpen(false);
    setConfirmClear(false);
    toast.success("已清除截止日期");
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button type="button" className="truncate font-medium hover:text-primary">
          {value ? format(new Date(value), "yyyy-MM-dd HH:mm") : "设置"}
        </button>
      </PopoverTrigger>
      {/* 弹层宽度固定 w-72：原实现内嵌自带 Popover 的 DateTimePicker——
          Popover 套 Popover 的 portal 布局测量异常把弹层撑到接近视口宽
          （实测 1159px），且其 w-full 触发钮在深色主题下是一整条白底
          描边块（"显示全白"）；改为内联日历 + 时间数字输入行（与右键
          菜单设置截止的 Dialog 内同款行）。 */}
      <PopoverContent align="end" className="w-72 space-y-2 p-3">
        {showPicker ? (
          <>
            <WaitCalendar
              mode="single"
              selected={draft ? new Date(draft.replace(" ", "T")) : undefined}
              onSelect={(d) => {
                const prevTime = draft.split("T")[1] ?? "09:00";
                setDraft(d ? `${format(d, "yyyy-MM-dd")}T${prevTime}` : "");
              }}
            />
            <div className="flex items-center gap-2 border-t p-3">
              <span className="text-xs text-muted-foreground">时间</span>
              <Input
                type="number"
                min={0}
                max={23}
                value={draft ? draft.split("T")[1]?.split(":")[0] ?? "09" : "09"}
                onChange={(e) => {
                  const v = Math.min(23, Math.max(0, Number(e.target.value) || 0));
                  const date = draft.split("T")[0] || format(Date.now(), "yyyy-MM-dd");
                  const m = draft.split("T")[1]?.split(":")[1] ?? "00";
                  setDraft(`${date}T${String(v).padStart(2, "0")}:${m}`);
                }}
                className="h-8 w-16"
              />
              <span>:</span>
              <Input
                type="number"
                min={0}
                max={59}
                value={draft ? draft.split("T")[1]?.split(":")[1] ?? "00" : "00"}
                onChange={(e) => {
                  const v = Math.min(59, Math.max(0, Number(e.target.value) || 0));
                  const date = draft.split("T")[0] || format(Date.now(), "yyyy-MM-dd");
                  const h = draft.split("T")[1]?.split(":")[0] ?? "09";
                  setDraft(`${date}T${h}:${String(v).padStart(2, "0")}`);
                }}
                className="h-8 w-16"
              />
            </div>
          </>
        ) : (
          <QuickDateMenu
            kind="datetime"
            value={draft}
            onSelect={(d) => {
              const ms = d.getTime();
              setDraft(format(ms, "yyyy-MM-dd'T'HH:mm"));
              onChange(ms);
              setOpen(false);
            }}
            customLabel="选择日期和时间"
            onCustom={() => setShowPicker(true)}
          />
        )}
        <div className="flex justify-end gap-2 border-t pt-2">
          {value != null && (
            <Button
              size="sm"
              variant={confirmClear ? "destructive" : "link"}
              onClick={clearDue}
            >
              {confirmClear ? "确认清除？" : "清除"}
            </Button>
          )}
          <Button size="sm" variant="outline" onClick={() => setOpen(false)}>取消</Button>
          {showPicker && <Button size="sm" onClick={commit}>确定</Button>}
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

/* ================= 区块 3：描述（行内编辑） ================= */

/** 展示态点击进入编辑（textarea 自适应高度）；保存语义与表单一致：
 *  trim 空写 null（清空描述）；Esc 取消还原。原实现为条件渲染的只读 <p>，
 *  空描述时区块整体消失——详情页无任何描述编辑入口，只能绕道表单。 */
function DescriptionSection({
  task,
  onPatch,
}: {
  task: Awaited<ReturnType<typeof todoTaskGetDetail>>;
  onPatch: (patch: Record<string, unknown>) => Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(task.description ?? "");

  useEffect(() => {
    setDraft(task.description ?? "");
    setEditing(false);
  }, [task.id, task.description]);

  const commit = async () => {
    const v = draft.trim();
    if (v !== (task.description?.trim() ?? "")) {
      await onPatch({ description: v || null });
    }
    setEditing(false);
  };

  if (editing) {
    return (
      <SectionBlock icon={AlignLeft} title="描述">
        <Textarea
          autoFocus
          value={draft}
          maxLength={5000}
          onChange={(e) => setDraft(e.target.value)}
          // 桌面多行文本惯例：Enter 换行、Ctrl/Cmd+Enter 提交；失焦兜底保存
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              e.preventDefault();
              setDraft(task.description ?? "");
              setEditing(false);
            } else if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
              e.preventDefault();
              void commit();
            }
          }}
          onBlur={() => void commit()}
          className="min-h-[80px] max-h-64 field-sizing-content text-[13px]"
        />
        <div className="mt-1 flex items-center justify-between">
          <span className="text-[11px] text-muted-foreground">Ctrl+Enter 保存 · Esc 取消</span>
          <span className="text-[11px] tabular-nums text-muted-foreground/70">{draft.length}/5000</span>
        </div>
      </SectionBlock>
    );
  }

  return (
    <SectionBlock icon={AlignLeft} title="描述">
      {task.description ? (
        <DescriptionPreviewHover content={renderMarkdown(task.description)}>
          <div
            role="button"
            tabIndex={0}
            aria-label="点击编辑描述"
            title="点击编辑（支持 Markdown：# 标题 / **粗体** / *斜体* / `代码` / [链接](url) / - 列表）"
            className="max-h-64 space-y-0.5 overflow-y-auto break-words rounded-md text-[13px] transition-colors hover:bg-accent/40 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring"
            onClick={() => setEditing(true)}
            onKeyDown={(e) => {
              if (e.key === "Enter" || e.key === " ") {
                e.preventDefault();
                setEditing(true);
              }
            }}
          >
            {renderMarkdown(task.description)}
          </div>
        </DescriptionPreviewHover>
      ) : (
        <button
          type="button"
          onClick={() => setEditing(true)}
          className="text-[13px] text-muted-foreground/50 transition-colors hover:text-muted-foreground"
        >
          + 添加描述
        </button>
      )}
    </SectionBlock>
  );
}

/**
 * 描述展示态悬浮预览：内容被 max-h 截断（scrollHeight > clientHeight）且
 * 设置开启时，鼠标停留满设定时长弹全量预览浮层（防呆延迟避免滑过即闪）。
 * 浮层高度也封顶（视口 60%），超长仍可滚动读全。延迟内移开即取消。
 *
 * 悬浮探测用 pointerover/pointerout（React 委托链上比 mouseenter/leave
 * 更先派发、且 mouseenter 不冒泡在部分嵌入视图收不到——IAB 实测坑）；
 * pointerout 后浮层仍开着时由 Popover 自身交互区维持，移出即关。
 */
function DescriptionPreviewHover({ children, content }: { children: React.ReactNode; content: React.ReactNode }) {
  const boxRef = useRef<HTMLDivElement>(null);
  const [previewOpen, setPreviewOpen] = useState(false);
  const timerRef = useRef<number | null>(null);

  // 内容/尺寸变化后重判是否溢出（描述变化由子树重渲驱动本 effect）。
  // 溢出发生在带 max-h 的内层描述节点上——wrapper 自身不滚，须量 firstChild。
  const previewable = useRef(false);
  useEffect(() => {
    const el = boxRef.current?.firstElementChild as HTMLElement | null | undefined;
    previewable.current = !!el && el.scrollHeight > el.clientHeight + 1;
  });

  const openTimer = () => {
    if (!previewable.current || !getDescPreviewEnabled()) return;
    timerRef.current = window.setTimeout(() => setPreviewOpen(true), getDescPreviewDelayMs());
  };
  const closeTimer = () => {
    if (timerRef.current != null) {
      window.clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  };
  useEffect(() => closeTimer, []);

  return (
    <Popover open={previewOpen} onOpenChange={setPreviewOpen}>
      <PopoverTrigger asChild>
        <div
          ref={boxRef}
          onPointerOver={openTimer}
          onPointerOut={() => {
            closeTimer();
            setPreviewOpen(false);
          }}
        >
          {children}
        </div>
      </PopoverTrigger>
      <PopoverContent
        side="right"
        align="start"
        // 预览浮层与描述区留距，避免盖住原文导致阅读错位
        sideOffset={8}
        onOpenAutoFocus={(e) => e.preventDefault()}
        className="max-h-[60vh] w-100 overflow-y-auto p-3 text-[13px] leading-relaxed"
      >
        <div className="space-y-0.5 break-words">{content}</div>
      </PopoverContent>
    </Popover>
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
  // 待删子任务（null = 关闭）：删除前确认弹窗，防误触（与任务/评论删除同惯例）
  const [confirmDelete, setConfirmDelete] = useState<TodoSubtask | null>(null);
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
          <ConfirmPopover
            key={s.id}
            open={confirmDelete?.id === s.id}
            onOpenChange={(o) => { if (!o) setConfirmDelete(null); }}
            title="删除子任务"
            description={`确定要删除「${s.title}」吗？删除后无法恢复。`}
            onConfirm={() => {
              const target = s;
              void (async () => {
                await todoSubtaskDelete(target.id);
                onChanged();
                toast.success("已删除子任务");
              })();
            }}
          >
            {/* 触发行（确认框锚定行下方，qraft tab 删除同款） */}
            <div className="group flex items-center gap-2 rounded-md px-1 py-1 hover:bg-accent/30">
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
              <span
                className={cn("flex-1 truncate text-[13px]", s.done && "text-muted-foreground line-through")}
                title={s.title}
              >
                {s.title}
              </span>
              {/* 转独立任务（MS To Do Steps→Task 同款；承接父任务项目/
                  优先级/截止上下文，详见 todo_api::promote_todo_subtask） */}
              <Tooltip>
                <TooltipTrigger asChild>
                  <button
                    type="button"
                    aria-label={`转为独立任务 ${s.title}`}
                    className="opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
                    onClick={() => {
                      void (async () => {
                        try {
                          await todoSubtaskPromote(s.id);
                          onChanged();
                          toast.success("已转为独立任务", {
                            description: "承接了本任务的项目/优先级/截止日期",
                          });
                        } catch {
                          toast.error("转换失败");
                        }
                      })();
                    }}
                  >
                    <CornerUpRight size={14} className="text-muted-foreground hover:text-foreground" />
                  </button>
                </TooltipTrigger>
                <TooltipContent>转为独立任务</TooltipContent>
              </Tooltip>
              <button type="button" aria-label="删除子任务"
                className="opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
                onClick={() => setConfirmDelete(s)}
              >
                <X size={14} className="text-muted-foreground hover:text-destructive" />
              </button>
            </div>
          </ConfirmPopover>
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
    const color = PRESET_10[Math.floor(Math.random() * PRESET_10.length)];
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
            className="inline-flex items-center gap-1.5 rounded-md border px-2 py-0.5 text-xs text-muted-foreground"
          >
            {/* 色点+标签名：与列表行 LabelChips 同形制（点=颜色信号） */}
            <span
              aria-hidden
              className="size-2 shrink-0 rounded-full"
              style={{ background: l.hex_color }}
            />
            {l.title}
            <button type="button" aria-label={`移除标签 ${l.title}`}
              className="text-muted-foreground/60 hover:text-foreground"
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
  taskDone,
  repeatMode,
  repeatAfter,
  repeatWeekdays,
  repeatEndType,
  repeatEndParam,
  repeatFromDone,
  onChanged,
}: {
  taskId: number;
  reminders: Awaited<ReturnType<typeof todoTaskGetDetail>>["reminders"];
  /** 完成实例不再红警（与行内徽标同口径；过期提醒按普通 muted 展示） */
  taskDone: boolean;
  /** 任务重复规则（>0 时提醒行显示徽标；触发后由监听器自动排下一次） */
  repeatMode: number;
  repeatAfter: number;
  /** #34 重复规则扩展（徽标完整显示用） */
  repeatWeekdays: number;
  repeatEndType: number;
  repeatEndParam: number;
  repeatFromDone: number;
  onChanged: () => void;
}) {
  // 编辑态：{reminderId, draft}——编辑=删旧建新（04 §3.4）
  const [editing, setEditing] = useState<{ id: number | null; draft: string } | null>(null);
  // 待删提醒（null = 关闭）：行内确认弹框（qraft tab 删除同款）
  const [confirmDelete, setConfirmDelete] = useState<Awaited<ReturnType<typeof todoTaskGetDetail>>["reminders"][number] | null>(null);

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
            <div key={r.id} className="max-w-xs space-y-1.5 rounded-lg bg-muted/40 p-2">
              <DateTimePicker value={editing.draft} onChange={(v) => setEditing({ ...editing, draft: v })} />
              <div className="flex justify-end gap-1">
                <Button size="sm" variant="ghost" onClick={() => setEditing(null)}>取消</Button>
                <Button size="sm" onClick={() => void commitNew()}>保存</Button>
              </div>
            </div>
          ) : (
            <ConfirmPopover
              open={confirmDelete?.id === r.id}
              onOpenChange={(o) => { if (!o) setConfirmDelete(null); }}
              title="删除提醒"
              description={`确定要删除 ${fmt(r.remind_at)} 的提醒吗？删除后该时间不再通知。`}
              onConfirm={() => {
                const target = r;
                void (async () => {
                  await todoReminderDelete(target.id);
                  onChanged();
                  toast.success("已删除提醒");
                })();
              }}
            >
              <div className="group flex items-center gap-2 rounded-lg bg-muted/40 px-3 py-2 text-[13px]">
                {(() => {
                  // 双态图标：未来=Bell muted；到期且任务未完成=BellRing 红色警示
                  // （与列表行/看板卡/日历行的 ReminderChip 同口径）
                  const fired = !taskDone && r.remind_at <= Date.now();
                  return fired ? (
                    <BellRing size={13} className="shrink-0 animate-pulse text-destructive" aria-label="提醒已到期" />
                  ) : (
                    <Bell size={13} className="shrink-0 text-muted-foreground" aria-hidden />
                  );
                })()}
                <button
                  type="button"
                  className={cn(
                    "flex-1 truncate text-left hover:text-primary",
                    !taskDone && r.remind_at <= Date.now() && "text-destructive",
                  )}
                  onClick={() => setEditing({ id: r.id, draft: fmt(r.remind_at) })}
                >
                  {fmt(r.remind_at)}
                </button>
                {repeatMode > 0 && (
                  <span className="shrink-0 rounded-full bg-primary/10 px-1.5 py-0.5 text-[10px] text-primary">
                    {repeatLabel(repeatMode, repeatAfter, {
                      weekdays: repeatWeekdays,
                      endType: repeatEndType,
                      endParam: repeatEndParam,
                      fromDone: repeatFromDone,
                    })}
                  </span>
                )}
                <button type="button" aria-label="删除提醒" className="shrink-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
                  onClick={() => setConfirmDelete(r)}
                >
                  <X size={13} className="text-muted-foreground hover:text-destructive" />
                </button>
              </div>
            </ConfirmPopover>
          ),
        )}

        {editing?.id === null && (
          <div className="max-w-xs space-y-1.5 rounded-lg bg-muted/40 p-2">
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

/* ================= 区块 7：关联任务（#28：完整交互） ================= */

function RelationsSection({
  taskId,
  relations,
  onChanged,
}: {
  taskId: number;
  relations: Awaited<ReturnType<typeof todoTaskGetDetail>>["relations"];
  onChanged: () => void;
}) {
  const [keyword, setKeyword] = useState("");
  const [popoverOpen, setPopoverOpen] = useState(false);
  // 待删关联（null = 关闭）：行内确认弹框（qraft tab 删除同款）
  const [confirmDelete, setConfirmDelete] = useState<Awaited<ReturnType<typeof todoTaskGetDetail>>["relations"][number] | null>(null);

  // 对方任务标题解析：relations 只有 other_task_id，标题经 globalSearch 拿不到
  // 全量映射，直接 todoTaskGet 单查（行数通常个位数，逐行 useQuery 足够）
  const titlesQuery = useQueries({
    queries: relations.map((r) => ({
      queryKey: ["todo_tasks", "get", r.other_task_id],
      queryFn: () => todoTaskGet(r.other_task_id),
      staleTime: 60_000,
    })),
  });

  // 添加候选：300ms 防抖搜索；排除自身与已关联
  const [debounced, setDebounced] = useState("");
  useEffect(() => {
    const id = setTimeout(() => setDebounced(keyword.trim()), 300);
    return () => clearTimeout(id);
  }, [keyword]);
  const searchQuery = useQuery({
    queryKey: ["global-search", debounced],
    queryFn: () => globalSearch(debounced, 8),
    enabled: popoverOpen && debounced.length > 0,
    staleTime: 10_000,
  });
  const linkedIds = new Set(relations.map((r) => r.other_task_id));
  const candidates = (searchQuery.data?.tasks ?? []).filter(
    (t) => t.id !== taskId && !linkedIds.has(t.id),
  );

  const addRelation = async (otherId: number) => {
    await todoTaskRelationCreate({ task_id: taskId, other_task_id: otherId, relation_type: "relates_to" });
    setPopoverOpen(false);
    setKeyword("");
    onChanged();
  };

  return (
    <SectionBlock
      icon={Link2}
      title="关联任务"
      trailing={
        <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] text-muted-foreground">
          {relations.length}
        </span>
      }
    >
      <div className="space-y-1">
        {relations.map((r, i) => {
          const other = titlesQuery[i]?.data;
          return (
            <ConfirmPopover
              key={r.id}
              open={confirmDelete?.id === r.id}
              onOpenChange={(o) => { if (!o) setConfirmDelete(null); }}
              title="删除关联"
              description={`确定要移除与「${other ? other.title : `任务 #${r.other_task_id}`}」的关联吗？双方都会解除。`}
              onConfirm={() => {
                const target = r;
                void (async () => {
                  await todoTaskRelationDelete(target.id);
                  onChanged();
                })();
              }}
            >
              <div className="group flex items-center gap-2 rounded-md px-1 py-1 hover:bg-accent/30">
                <Link2 size={12} className="shrink-0 text-muted-foreground" />
                <button
                  type="button"
                  className="min-w-0 flex-1 truncate text-left text-[13px] hover:text-primary"
                  title={other ? `打开「${other.title}」` : `任务 #${r.other_task_id}`}
                  onClick={() => useTodoStore.getState().setSelectedTaskId(r.other_task_id)}
                >
                  {other ? other.title : `任务 #${r.other_task_id}`}
                  {other?.done ? "（已完成）" : ""}
                </button>
                <span className="shrink-0 text-[11px] text-muted-foreground">
                  {RELATION_TYPE_LABEL[r.relation_type] ?? r.relation_type}
                </span>
                <button
                  type="button"
                  aria-label="删除关联"
                  className="shrink-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
                  onClick={() => setConfirmDelete(r)}
                >
                <Trash2 size={12} className="text-muted-foreground hover:text-destructive" />
              </button>
              </div>
            </ConfirmPopover>
          );
        })}

        {/* 添加关联：Popover 搜索选择器（复用 globalSearch；空态提示） */}
        <Popover open={popoverOpen} onOpenChange={setPopoverOpen}>
          <PopoverTrigger asChild>
            <button
              type="button"
              className="flex w-full items-center gap-2 rounded-md px-1 py-1 text-[13px] text-muted-foreground hover:bg-accent/30 hover:text-foreground"
            >
              {/* SVG 图标替代文本 +（字符在行框内天然不居中，且比基线偏高）；size-3=12px 居中于 size-5 虚线圈 */}
              <span className="grid size-5 shrink-0 place-items-center rounded-full border border-dashed border-muted-foreground/40">
                <Plus className="size-3" />
              </span>
              添加关联
            </button>
          </PopoverTrigger>
          <PopoverContent align="start" className="w-72 p-2">
            <Input
              value={keyword}
              autoFocus
              placeholder="搜索任务标题…"
              className="h-7 text-[13px]"
              onChange={(e) => setKeyword(e.target.value)}
            />
            <div className="mt-1 max-h-56 space-y-0.5 overflow-y-auto">
              {debounced.length === 0 && (
                <p className="px-2 py-1.5 text-[12px] text-muted-foreground">输入关键词搜索任务</p>
              )}
              {debounced.length > 0 && candidates.length === 0 && !searchQuery.isFetching && (
                <p className="px-2 py-1.5 text-[12px] text-muted-foreground">没有可关联的任务</p>
              )}
              {candidates.map((t) => (
                <button
                  key={t.id}
                  type="button"
                  className="flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-left text-[13px] hover:bg-accent/50"
                  onClick={() => void addRelation(t.id)}
                >
                  <span className="truncate">{t.title}</span>
                  {t.done ? <span className="ml-auto shrink-0 text-[11px] text-muted-foreground">已完成</span> : null}
                </button>
              ))}
            </div>
          </PopoverContent>
        </Popover>
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
  // 待删评论（null = 关闭）：行内确认弹框（qraft tab 删除同款）
  const [confirmDelete, setConfirmDelete] = useState<TodoComment | null>(null);

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
          <ConfirmPopover
            key={c.id}
            open={confirmDelete?.id === c.id}
            onOpenChange={(o) => { if (!o) setConfirmDelete(null); }}
            title="删除评论"
            description={`确定要删除「${c.content.slice(0, 20)}${c.content.length > 20 ? "…" : ""}」吗？删除后无法恢复。`}
            onConfirm={() => {
              const target = c;
              void (async () => {
                await todoCommentDelete(target.id);
                onChanged();
                toast.success("已删除评论");
              })();
            }}
          >
            <div className="group rounded-lg bg-muted/40 px-3 py-2">
              <div className="flex items-start gap-2">
                <p className="min-w-0 flex-1 break-words whitespace-pre-wrap text-[13px]">{c.content}</p>
                <span className="ml-auto shrink-0 text-[11px] text-muted-foreground">{relative(c.created_at)}</span>
                <button type="button" aria-label="删除评论" className="opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
                  onClick={() => setConfirmDelete(c)}
                >
                  <Trash2 size={12} className="text-muted-foreground hover:text-destructive" />
                </button>
              </div>
            </div>
          </ConfirmPopover>
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

/* ================= 区块 9：附件 ================= */

/** 常见扩展名 → mime 映射（fs 插件不返回 mime，按扩展名推断；未知回落 octet-stream） */
const MIME_BY_EXT: Record<string, string> = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif",
  webp: "image/webp", svg: "image/svg+xml", bmp: "image/bmp", ico: "image/x-icon",
  pdf: "application/pdf", txt: "text/plain", md: "text/markdown", csv: "text/csv",
  json: "application/json", xml: "application/xml", zip: "application/zip",
  mp3: "audio/mpeg", wav: "audio/wav", mp4: "video/mp4", webm: "video/webm",
  doc: "application/msword", docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel", xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
};

function mimeFromFileName(name: string): string {
  const ext = name.split(".").pop()?.toLowerCase() ?? "";
  return MIME_BY_EXT[ext] ?? "application/octet-stream";
}

function humanSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function AttachmentsSection({ taskId }: { taskId: number }) {
  // B3：剪贴板截图 Ctrl+V 直粘为附件（零依赖，DOM paste 读 clipboardData.files）
  usePasteAttachment(taskId);
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<TaskAttachmentView | null>(null);
  // 图片附件应用内预览（F4 lightbox）：url 为 blob 引用，关闭时 revoke 防字节泄漏
  const [lightbox, setLightbox] = useState<{ url: string; name: string } | null>(null);
  // 走 react-query：db-change 全局失效后自动重拉（与其他区块同通道；
  // 局部 useState + useEffect 不吃失效事件，mock 直改/真实跨设备同步后不刷新）
  const { data: attachments = [], refetch } = useQuery({
    queryKey: ["task-attachments", taskId],
    queryFn: () => taskAttachmentsList(taskId),
  });

  const handleAdd = async () => {
    if (busy) return;
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({ multiple: false });
    if (!selected || typeof selected !== "string") return;

    setBusy(true);
    try {
      const { readFile } = await import("@tauri-apps/plugin-fs");
      const data = Array.from(await readFile(selected));
      const fileName = selected.split(/[\/]/).pop() ?? "附件";
      await taskAttachmentAdd(taskId, fileName, mimeFromFileName(fileName), data);
      await refetch();
      toast.success(`已添加附件「${fileName}」`);
    } catch (e) {
      toast.error(`附件上传失败：${e}`);
    } finally {
      setBusy(false);
    }
  };

  const handleOpen = async (att: TaskAttachmentView) => {
    if (att.is_local_cached === 0) {
      toast.info("附件尚未从云端同步到本机，稍后自动拉取");
      return;
    }
    try {
      const { taskAttachmentRead } = await import("@/lib/tauri");
      const bytes = await taskAttachmentRead(att.hash);
      // 图片：应用内 lightbox 预览（2026-09-12 F4——新窗口裸图体验断裂，
      //  且 blob 新窗被弹窗拦截时静默失败）；其他类型：落临时文件走系统默认程序
      if (att.mime_type.startsWith("image/")) {
        const buf = new Uint8Array(bytes);
        const blob = new Blob([buf], { type: att.mime_type });
        setLightbox({ url: URL.createObjectURL(blob), name: att.original_name });
      } else {
        const { writeFile } = await import("@tauri-apps/plugin-fs");
        const ext = att.original_name.split(".").pop() ?? "";
        const { appCacheDir, join } = await import("@tauri-apps/api/path");
        const dir = await appCacheDir();
        const target = await join(dir, `orbit-preview-${att.hash.slice(0, 12)}${ext ? "." + ext : ""}`);
        await writeFile(target, new Uint8Array(bytes));
        const { open: openPath } = await import("@tauri-apps/plugin-shell");
        await openPath(target);
      }
    } catch (e) {
      toast.error(`打开附件失败：${e}`);
    }
  };

  return (
    <SectionBlock
      icon={Paperclip}
      title="附件"
      trailing={
        <button
          type="button"
          aria-label="添加附件"
          disabled={busy}
          className="text-muted-foreground hover:text-foreground disabled:opacity-50"
          onClick={() => void handleAdd()}
        >
          {busy ? <Loader2 size={13} className="animate-spin" /> : <Plus size={13} />}
        </button>
      }
    >
      <div className="space-y-2">
        {attachments.map((a) => (
          <ConfirmPopover
            key={a.link_id}
            open={confirmDelete?.link_id === a.link_id}
            onOpenChange={(o) => { if (!o) setConfirmDelete(null); }}
            title="移除附件"
            description={`确定要移除「${a.original_name}」吗？仅解除与任务的关联。`}
            onConfirm={() => {
              const target = a;
              void (async () => {
                await taskAttachmentRemove(target.link_id);
                await refetch();
                toast.success("已移除附件");
              })();
            }}
          >
            <div
              className="group flex cursor-pointer items-center gap-2 rounded-lg bg-muted/40 px-3 py-2"
              onClick={() => void handleOpen(a)}
            >
              <AttachmentThumb attachment={a} />
              <span className="min-w-0 flex-1 truncate text-[13px]">{a.original_name}</span>
              <span className="shrink-0 text-[11px] text-muted-foreground">
                {a.is_local_cached === 0 ? "待同步" : humanSize(a.size_bytes)}
              </span>
              <button
                type="button"
                aria-label="移除附件"
                className="opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
                onClick={(e) => { e.stopPropagation(); setConfirmDelete(a); }}
              >
                <Trash2 size={12} className="text-muted-foreground hover:text-destructive" />
              </button>
              <ExternalLink size={12} className="shrink-0 text-muted-foreground opacity-0 group-hover:opacity-100 group-focus-within:opacity-100" />
            </div>
          </ConfirmPopover>
        ))}
        {attachments.length === 0 && (
          <p className="text-[12px] text-muted-foreground">点击 + 选择文件添加附件（单任务 20 个，单文件 50MB）。</p>
        )}
        <p className="text-[11px] text-muted-foreground/60">支持 Ctrl+V 直接粘贴截图</p>
      </div>

      {/* 图片附件应用内预览（F4 lightbox）：点图片行触发；Esc/点遮罩关闭。
          blob URL 关闭即 revoke（不 revoke 则整份图片字节驻留内存）。 */}
      <Dialog
        open={lightbox != null}
        onOpenChange={(o) => {
          if (o) return;
          if (lightbox) URL.revokeObjectURL(lightbox.url);
          setLightbox(null);
        }}
      >
        <DialogContent
          className="max-w-fit border-none bg-black/90 p-0 sm:max-w-fit [&>button]:text-white/70 [&>button]:hover:text-white"
          aria-describedby={undefined}
        >
          <DialogHeader className="sr-only">
            <DialogTitle>图片预览：{lightbox?.name}</DialogTitle>
          </DialogHeader>
          {lightbox && (
            <figure className="max-h-[85vh] max-w-[90vw]">
              <img
                src={lightbox.url}
                alt={lightbox.name}
                className="max-h-[78vh] max-w-[90vw] rounded-lg object-contain"
              />
              <figcaption className="mt-2 truncate text-center text-xs text-white/70">
                {lightbox.name}
              </figcaption>
            </figure>
          )}
        </DialogContent>
      </Dialog>
    </SectionBlock>
  );
}

// ============================================================================
// 活动历史区块（F6，2026-09-12）：任务操作轨迹回看（Todoist Activity log）
// ============================================================================

/** action → 中文动作文案（update 的 detail.fields 附加在括号里） */
const ACTIVITY_ACTION_LABELS: Record<string, string> = {
  create: "创建了任务",
  update: "更新",
  complete: "标记为完成",
  uncomplete: "恢复为未完成",
  delete: "移入回收站",
  restore: "从回收站恢复",
};

/** update detail 里的字段名 → 中文（与属性行文案对齐；未映射字段原样展示） */
const ACTIVITY_FIELD_LABELS: Record<string, string> = {
  title: "标题",
  description: "描述",
  project_id: "所属项目",
  priority: "优先级",
  status: "状态",
  done: "完成标记",
  done_at: "完成时间",
  due_date: "截止日期",
  start_date: "开始日期",
  percent_done: "进度",
  position: "顺序",
  is_favorite: "收藏",
  my_day_date: "我的一天",
};

function ActivitySection({ taskId }: { taskId: number }) {
  const { data: rows = [] } = useQuery({
    queryKey: ["task-activity", taskId],
    queryFn: () => taskActivityList(taskId, 30),
    staleTime: 30_000,
  });

  const describe = (action: string, detail: string): string => {
    const base = ACTIVITY_ACTION_LABELS[action] ?? action;
    if (action !== "update") return base;
    try {
      const fields = (JSON.parse(detail) as { fields?: string[] }).fields ?? [];
      if (fields.length === 0) return base;
      const names = fields.map((f) => ACTIVITY_FIELD_LABELS[f] ?? f).join("、");
      return `${base}（${names}）`;
    } catch {
      return base;
    }
  };

  return (
    <SectionBlock icon={History} title="历史">
      <div className="space-y-1.5">
        {rows.map((r) => (
          <div key={r.id} className="flex items-baseline gap-2 text-[12px]">
            <span className="shrink-0 tabular-nums text-muted-foreground/70">
              {format(new Date(r.created_at), "MM-dd HH:mm")}
            </span>
            <span className="text-muted-foreground">{describe(r.action, r.detail)}</span>
          </div>
        ))}
        {rows.length === 0 && (
          <p className="text-[12px] text-muted-foreground">暂无操作记录。</p>
        )}
      </div>
    </SectionBlock>
  );
}

// ============================================================================
// 附件行缩略图（批7b 轻量版）：图片附件行内 32px 预览
// ============================================================================

/**
 * 图片附件行内缩略图——行级 32px 预览替代纯文件图标（非图片附件仍图标）。
 * 解码内存由浏览器按渲染尺寸管理（24px 渲染需求远小于原图，Chromium
 * 自动降采样解码）；blob URL 卸载即 revoke 防字节驻留。
 */
function AttachmentThumb({ attachment }: { attachment: TaskAttachmentView }) {
  const [url, setUrl] = useState<string | null>(null);
  const isImage = attachment.mime_type.startsWith("image/") && attachment.is_local_cached === 1;

  useEffect(() => {
    if (!isImage) return;
    let alive = true;
    let created: string | null = null;
    void (async () => {
      try {
        const { taskAttachmentRead } = await import("@/lib/tauri");
        const bytes = await taskAttachmentRead(attachment.hash);
        created = URL.createObjectURL(new Blob([new Uint8Array(bytes)], { type: attachment.mime_type }));
        if (alive) setUrl(created);
        else if (created) URL.revokeObjectURL(created);
      } catch {
        // 读取失败退回图标（缩略图是增强不是关键路径）
      }
    })();
    return () => {
      alive = false;
      if (created) URL.revokeObjectURL(created);
    };
  }, [isImage, attachment.hash, attachment.mime_type]);

  if (!isImage) {
    return <FileIcon size={14} className="shrink-0 text-muted-foreground" />;
  }
  if (url) {
    return (
      <img
        src={url}
        alt=""
        aria-hidden
        className="h-8 w-8 shrink-0 rounded object-cover"
      />
    );
  }
  return <FileIcon size={14} className="h-8 w-8 shrink-0 text-muted-foreground" />;
}
