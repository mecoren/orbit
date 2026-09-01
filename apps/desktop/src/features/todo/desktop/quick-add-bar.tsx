/**
 * QuickAddBar — 底部常驻快速输入栏（04 文档 §3.5 复刻；背景与应用背景同色）
 *
 * 输入后浮现四个快捷 Popover（截止日期 / 提醒时间 / 优先级 / 项目）；
 * Enter 提交并保持焦点连续录入；Esc 重置。
 * 提醒时间为独立实体：任务创建成功后追加 todo_reminders_create。
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { format } from "date-fns";
import { zhCN } from "date-fns/locale";
import { useQuery } from "@tanstack/react-query";
import { Calendar, CalendarPlus, Clock, Flag, Folder, Plus, Tag } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { WaitCalendar } from "@/components/ui/wait-calendar";
import { DateTimePicker } from "@/components/business/date-picker";
import { QuickDateMenu } from "@/components/business/quick-date-options";
import {
  todoLabelList,
  todoReminderCreate,
  todoTaskCreate,
  todoTaskLabelCreate,
  type TodoProject,
} from "@/lib/tauri";
import { parseQuickInput } from "../shared/parse-quick-input";
import { PRIORITY_COLOR, TODO_ACCENT } from "../shared/constants";

const PRIORITY_LABELS = ["无", "低", "中", "高", "紧急", "立即处理"];

interface QuickAddBarProps {
  projects: TodoProject[];
  /** 当前选中项目（新建任务默认归属；快捷视图下为 undefined） */
  defaultProjectId?: number | null;
}

export function QuickAddBar({ projects, defaultProjectId }: QuickAddBarProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [title, setTitle] = useState("");
  const [priority, setPriority] = useState(0);
  const [dueDate, setDueDate] = useState<Date | null>(null);
  /** 截止日期弹层：快捷菜单 ⇄ 完整日历视图（关闭时复位，与表单 DatePicker 同口径） */
  const [dueOpen, setDueOpen] = useState(false);
  const [dueCalendar, setDueCalendar] = useState(false);
  // 优先级/项目弹层受控：选项点选后自动关闭
  const [priorityOpen, setPriorityOpen] = useState(false);
  const [projectOpen, setProjectOpen] = useState(false);
  useEffect(() => {
    if (!dueOpen) setDueCalendar(false);
  }, [dueOpen]);
  /** 提醒时间草稿（DateTimePicker 值格式 YYYY-MM-DDTHH:MM；空 = 不提醒） */
  const [remindDraft, setRemindDraft] = useState("");
  const [projectId, setProjectId] = useState<number | null | "default">("default");

  const hasInput = title.trim().length > 0;
  const effectiveProjectId =
    projectId === "default" ? (defaultProjectId ?? null) : projectId;

  // 标签清单：有输入才拉取（@标签 解析与预览需要）
  const labelsQuery = useQuery({
    queryKey: ["todo-label", "list"],
    queryFn: () => todoLabelList({ page: 1, page_size: 1000 }),
    enabled: hasInput,
    staleTime: 60_000,
  });

  // 实时解析结果（预览 chips 与提示用；提交时以最新输入重算一次为准）
  const parsed = useMemo(
    () =>
      parseQuickInput(title, {
        projects: projects.map((p) => ({ id: p.id, title: p.title })),
        labels: (labelsQuery.data ?? []).map((l) => ({ id: l.id, title: l.title })),
        now: new Date(),
      }),
    [title, projects, labelsQuery.data],
  );
  const hasHits =
    parsed.dueDate != null ||
    parsed.priority > 0 ||
    parsed.projectId != null ||
    parsed.labelIds.length > 0;

  const reset = () => {
    setTitle("");
    setPriority(0);
    setDueDate(null);
    setRemindDraft("");
    setProjectId("default");
  };

  const submit = async () => {
    // 用提交瞬间最新输入重算（避免 memo 时差）；token 显式值优先于手动 Popover 选择
    const p = parseQuickInput(title, {
      projects: projects.map((pr) => ({ id: pr.id, title: pr.title })),
      labels: (labelsQuery.data ?? []).map((l) => ({ id: l.id, title: l.title })),
      now: new Date(),
    });
    const t = p.title.trim();
    if (!t) return;
    try {
      const created = await todoTaskCreate({
        title: t,
        priority: p.priority || priority,
        due_date: p.dueDate ? p.dueDate.getTime() : dueDate ? dueDate.getTime() : null,
        project_id: p.projectId ?? effectiveProjectId,
      });
      // 标签挂载：单个失败不阻断任务本身
      for (const labelId of p.labelIds) {
        try {
          await todoTaskLabelCreate({ task_id: created.id, label_id: labelId });
        } catch {
          /* 忽略单个标签失败 */
        }
      }
      // 提醒为独立实体：任务创建成功后追加；失败不影响任务本身
      if (remindDraft) {
        const ms = new Date(remindDraft).getTime();
        if (!Number.isNaN(ms)) {
          await todoReminderCreate({ task_id: created.id, remind_at: ms });
        }
      }
      // 连续录入：清空并保持焦点（04 §3.5）
      reset();
      requestAnimationFrame(() => inputRef.current?.focus());
    } catch (err) {
      console.error("创建任务失败:", err);
    }
  };

  // 背景保持透明：壳层 main 为 bg-background/60 半透明底（透出 Mica），
  // 此处再叠任何不透明底都会与周围所见背景产生色差
  return (
    <div className="border-t border-border px-4 py-2.5">
      {/* NLP 解析预览 chips（07 §五-P1#7）：仅展示命中项 */}
      {hasInput && hasHits && (
        <div
          role="status"
          aria-live="polite"
          className="mb-1.5 flex flex-wrap items-center gap-1.5 px-1 text-xs text-muted-foreground"
        >
          {parsed.dueDate && (
            <span className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-primary">
              <Calendar className="size-3" />
              {format(parsed.dueDate, "M月d日 EEEE", { locale: zhCN })}
            </span>
          )}
          {parsed.priority > 0 && (
            <span className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-primary">
              <Flag className="size-3" />
              {PRIORITY_LABELS[parsed.priority]}
            </span>
          )}
          {parsed.projectId != null && (
            <span className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-primary">
              <Folder className="size-3" />
              {projects.find((pr) => pr.id === parsed.projectId)?.title}
            </span>
          )}
          {parsed.labelIds.map((id) => (
            <span
              key={id}
              className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-primary"
            >
              <Tag className="size-3" />
              {(labelsQuery.data ?? []).find((l) => l.id === id)?.title}
            </span>
          ))}
        </div>
      )}
      <div className="flex items-center gap-2 rounded-md border border-border px-2 py-1.5 shadow-sm">
        <span
          className={cn(
            "flex h-5 w-5 items-center justify-center rounded-full border-2",
            hasInput ? "border-primary text-primary" : "border-muted-foreground/30",
          )}
        >
          <Plus className="size-3" />
        </span>

        <Input
          ref={inputRef}
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => {
            if (e.nativeEvent.isComposing) return; // IME 组合期：选词 Enter 不提交（评审修复）
            if (e.key === "Enter") void submit();
            if (e.key === "Escape") reset();
          }}
          placeholder="添加任务…支持「明天 #项目 @标签 !3」"
          className="h-7 min-w-0 flex-1 border-0 bg-transparent px-1 shadow-none focus-visible:ring-0"
        />

        {/* 有输入后才浮现的快捷区（shrink-0 防止被输入框挤压变形） */}
        {hasInput && (
          <div className="flex shrink-0 items-center gap-0.5">
            {/* 截止日期：快捷选项（今天/明天/下周）⇄ 完整日历，与表单 DatePicker 同构 */}
            <Popover open={dueOpen} onOpenChange={setDueOpen}>
              <Tooltip>
                <TooltipTrigger asChild>
                  <PopoverTrigger asChild>
                    <Button
                      variant="ghost"
                      size="icon"
                      className={cn(
                        "h-7 w-7",
                        dueDate && "bg-primary/10 text-primary",
                      )}
                    >
                      <Calendar className="size-4" />
                    </Button>
                  </PopoverTrigger>
                </TooltipTrigger>
                <TooltipContent>
                  {dueDate ? `截止日期：${formatDue(dueDate)}` : "截止日期"}
                </TooltipContent>
              </Tooltip>
              {/* 宽度需设上限：DayPicker 表格 w-full+aspect-square 在无界 w-auto 下无法收敛 */}
              <PopoverContent align="end" className="w-auto min-w-[280px] max-w-[320px] p-0">
                {dueCalendar ? (
                  <div className="p-3">
                    <WaitCalendar
                      mode="single"
                      selected={dueDate ?? undefined}
                      onSelect={(d) => {
                        setDueDate(d ?? null);
                        // 选中具体日期后自动收起（清除按钮保持弹层打开）
                        if (d) setDueOpen(false);
                      }}
                    />
                    <div className="mt-2 flex justify-end gap-2 border-t pt-2">
                      {dueDate && (
                        <Button variant="link" size="sm" onClick={() => setDueDate(null)}>
                          清除
                        </Button>
                      )}
                    </div>
                  </div>
                ) : (
                  <QuickDateMenu
                    kind="date"
                    value={dueDate ? format(dueDate, "yyyy-MM-dd") : ""}
                    onSelect={(d) => {
                      setDueDate(d);
                      setDueOpen(false);
                    }}
                    customLabel="选择日期"
                    onCustom={() => setDueCalendar(true)}
                  />
                )}
              </PopoverContent>
            </Popover>

            {/* 提醒时间 */}
            <Popover>
              <Tooltip>
                <TooltipTrigger asChild>
                  <PopoverTrigger asChild>
                    <Button
                      variant="ghost"
                      size="icon"
                      className={cn(
                        "h-7 w-7",
                        remindDraft && "bg-primary/10 text-primary",
                      )}
                    >
                      <Clock className="size-4" />
                    </Button>
                  </PopoverTrigger>
                </TooltipTrigger>
                <TooltipContent>
                  {remindDraft
                    ? `提醒时间：${format(new Date(remindDraft), "M月d日 HH:mm", { locale: zhCN })}`
                    : "提醒时间"}
                </TooltipContent>
              </Tooltip>
              <PopoverContent align="end" className="w-[320px] p-3">
                <p className="mb-2 text-sm font-medium">提醒时间</p>
                <DateTimePicker value={remindDraft} onChange={setRemindDraft} />
                <div className="mt-2 flex justify-end gap-2 border-t pt-2">
                  {remindDraft && (
                    <Button variant="link" size="sm" onClick={() => setRemindDraft("")}>
                      清除
                    </Button>
                  )}
                </div>
              </PopoverContent>
            </Popover>

            {/* 优先级 */}
            <Popover open={priorityOpen} onOpenChange={setPriorityOpen}>
              <Tooltip>
                <TooltipTrigger asChild>
                  <PopoverTrigger asChild>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-7 w-7"
                      style={{ color: PRIORITY_COLOR[parsed.priority || priority] || undefined }}
                    >
                      <Flag className="size-4" />
                    </Button>
                  </PopoverTrigger>
                </TooltipTrigger>
                <TooltipContent>
                  优先级：{PRIORITY_LABELS[parsed.priority || priority]}
                </TooltipContent>
              </Tooltip>
              <PopoverContent align="end" className="w-40 p-1">
                {PRIORITY_LABELS.map((label, i) => (
                  <button
                    key={i}
                    type="button"
                    onClick={() => {
                      setPriority(i);
                      setPriorityOpen(false);
                    }}
                    className={cn(
                      "flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent",
                      priority === i && "bg-accent font-medium",
                    )}
                  >
                    <span
                      className="size-2 rounded-full"
                      style={{ background: i === 0 ? "#D1D5DB" : PRIORITY_COLOR[i] }}
                    />
                    {label}
                  </button>
                ))}
              </PopoverContent>
            </Popover>

            {/* 项目 */}
            <Popover open={projectOpen} onOpenChange={setProjectOpen}>
              <Tooltip>
                <TooltipTrigger asChild>
                  <PopoverTrigger asChild>
                    <Button variant="ghost" size="icon" className="h-7 w-7">
                      <Folder className="size-4" />
                    </Button>
                  </PopoverTrigger>
                </TooltipTrigger>
                <TooltipContent>
                  项目：
                  {effectiveProjectId != null
                    ? (projects.find((p) => p.id === effectiveProjectId)?.title ?? "未分组")
                    : "未分组"}
                </TooltipContent>
              </Tooltip>
              <PopoverContent align="end" className="w-56 p-1">
                <button
                  type="button"
                  onClick={() => {
                    setProjectId(null);
                    setProjectOpen(false);
                  }}
                  className={cn(
                    "flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent",
                    effectiveProjectId === null && "bg-accent font-medium",
                  )}
                >
                  <span className="h-3 w-3 rounded-sm border border-dashed border-muted-foreground/50" />
                  未分组
                </button>
                <div className="my-1 border-t" />
                {projects.map((p) => (
                  <button
                    key={p.id}
                    type="button"
                    onClick={() => {
                      setProjectId(p.id);
                      setProjectOpen(false);
                    }}
                    className={cn(
                      "flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent",
                      effectiveProjectId === p.id && "bg-accent font-medium",
                    )}
                  >
                    <span
                      className="h-3 w-3 shrink-0 rounded-sm"
                      style={{ background: p.hex_color || TODO_ACCENT }}
                    />
                    <span className="truncate">{p.title}</span>
                  </button>
                ))}
              </PopoverContent>
            </Popover>

            {/* 提交 */}
            <Button size="sm" className="h-7 px-3" onClick={() => void submit()}>
              <CalendarPlus className="mr-1 size-3.5" />
              添加
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}

/** 已选日期展示辅助（供触发钮 title 提示） */
export function formatDue(d: Date): string {
  return format(d, "M月d日 EEEE", { locale: zhCN });
}
