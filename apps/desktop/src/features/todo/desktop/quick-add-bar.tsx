/**
 * QuickAddBar — 底部常驻快速输入栏（04 文档 §3.5 复刻；背景与应用背景同色）
 *
 * 输入后浮现四个快捷 Popover（截止日期 / 提醒时间 / 优先级 / 项目）；
 * Enter 提交并保持焦点连续录入；Esc 重置。
 * 提醒时间为独立实体：任务创建成功后追加 todo_reminders_create。
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { format, parse } from "date-fns";
import { zhCN } from "date-fns/locale";
import { useQuery } from "@tanstack/react-query";
import { Calendar, CalendarPlus, Clock, Flag, Folder, Plus, Tag } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { WaitCalendar } from "@/components/ui/wait-calendar";
import { QuickDateMenu } from "@/components/business/quick-date-options";
import {
  todoLabelList,
  todoReminderCreate,
  todoTaskCreate,
  todoTaskLabelCreate,
  type TodoProject,
} from "@/lib/tauri";
import { useAppStore } from "@/stores/app-store";
import { parseQuickInput } from "../shared/parse-quick-input";
import {
  atViewDueHour,
  quickViewCreateDefaults,
} from "../shared/view-create-defaults";
import { PRIORITY_COLOR, TODO_ACCENT, type QuickViewKey, PRIORITY_LABELS } from "../shared/constants";


interface QuickAddBarProps {
  projects: TodoProject[];
  /** 当前选中项目（新建任务默认归属；快捷视图下为 undefined） */
  defaultProjectId?: number | null;
  /** 当前选中的快捷视图（#39：视图内新建自动带本视图标记；项目/未分组/筛选器下为 null） */
  quickView?: QuickViewKey | null;
}

export function QuickAddBar({ projects, defaultProjectId, quickView }: QuickAddBarProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [title, setTitle] = useState("");
  const [priority, setPriority] = useState(0);
  const [dueDate, setDueDate] = useState<Date | null>(null);
  /** 截止日期弹层：快捷菜单 ⇄ 完整日历视图（关闭时复位，与表单 DatePicker 同口径） */
  const [dueOpen, setDueOpen] = useState(false);
  const [dueCalendar, setDueCalendar] = useState(false);
  /** 提醒弹层同款两段式（quick 菜单 ⇄ 日历+时分）——PopoverContent 内
   *  禁嵌自带 Popover 控件（Radix 焦点陷阱，drawer 已踩过 portal 套
   *  portal 测量异常），故不用 DateTimePicker 而是内联同款结构 */
  const [remindOpen, setRemindOpen] = useState(false);
  const [remindCalendar, setRemindCalendar] = useState(false);
  // 优先级/项目弹层受控：选项点选后自动关闭
  const [priorityOpen, setPriorityOpen] = useState(false);
  const [projectOpen, setProjectOpen] = useState(false);
  useEffect(() => {
    if (!dueOpen) setDueCalendar(false);
    if (!remindOpen) setRemindCalendar(false);
  }, [dueOpen, remindOpen]);
  /** 提醒时间草稿（DateTimePicker 值格式 YYYY-MM-DDTHH:MM；空 = 不提醒） */
  const [remindDraft, setRemindDraft] = useState("");
  const [projectId, setProjectId] = useState<number | null | "default">("default");

  // 托盘「快速新建」意图（07 #16）：壳层 bump → 此处消费聚焦；
  // 归零防重放（机制同 list-page 的 taskFormIntent 消费）
  const quickAddIntent = useAppStore((s) => s.quickAddIntent);
  const consumeQuickAddIntent = useAppStore((s) => s.consumeQuickAddIntent);
  useEffect(() => {
    if (quickAddIntent === 0) return;
    consumeQuickAddIntent();
    requestAnimationFrame(() => inputRef.current?.focus());
  }, [quickAddIntent, consumeQuickAddIntent]);

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
    // 视图标记注入（#39）：提交瞬间重算默认值（跨零点不落昨天）；
    // NLP 显式值 > 手动 Popover 选择 > 本视图默认。
    // 今日/本周视图内截止时刻归一 18:00（用户口径）：三个日期来源
    // （NLP 词/Popover/视图默认）均只表达日期、无时刻位，统一落 18 点
    const viewDefaults = quickViewCreateDefaults(quickView);
    const inDueView = quickView === "today" || quickView === "week";
    const resolvedDue =
      p.dueDate?.getTime() ?? dueDate?.getTime() ?? viewDefaults.dueMs ?? null;
    try {
      const created = await todoTaskCreate({
        title: t,
        priority: p.priority || priority,
        due_date:
          inDueView && resolvedDue != null ? atViewDueHour(resolvedDue) : resolvedDue,
        project_id: p.projectId ?? effectiveProjectId,
        ...(viewDefaults.myDayMs != null && { my_day_date: viewDefaults.myDayMs }),
        ...(viewDefaults.favorite != null && { is_favorite: viewDefaults.favorite }),
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
            <span
              className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5"
              style={{ color: projects.find((pr) => pr.id === parsed.projectId)?.hex_color || TODO_ACCENT }}
            >
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
            <Popover open={remindOpen} onOpenChange={setRemindOpen}>
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
                {remindCalendar ? (
                  <div>
                    <p className="mb-2 text-sm font-medium">提醒时间</p>
                    <WaitCalendar
                      mode="single"
                      selected={
                        remindDraft
                          ? parse(remindDraft.slice(0, 10), "yyyy-MM-dd", new Date())
                          : undefined
                      }
                      onSelect={(d) => {
                        if (d) {
                          const datePart = format(d, "yyyy-MM-dd");
                          const prev = remindDraft || format(new Date(), "yyyy-MM-dd'T'HH:mm");
                          const timePart = prev.slice(11) || "09:00";
                          setRemindDraft(`${datePart}T${timePart}`);
                        }
                      }}
                    />
                    <div className="mt-2 flex items-center gap-2 border-t pt-2">
                      <span className="text-xs text-muted-foreground">时间</span>
                      <Input
                        type="number"
                        min={0}
                        max={23}
                        value={remindDraft ? remindDraft.slice(11, 13) : "9"}
                        onChange={(e) => {
                          const v = Math.min(23, Math.max(0, Number(e.target.value) || 0));
                          const datePart = remindDraft?.slice(0, 10) || format(new Date(), "yyyy-MM-dd");
                          const m = remindDraft?.slice(14, 16) || "00";
                          setRemindDraft(`${datePart}T${String(v).padStart(2, "0")}:${m}`);
                        }}
                        className="h-8 w-16"
                      />
                      <span>:</span>
                      <Input
                        type="number"
                        min={0}
                        max={59}
                        value={remindDraft ? remindDraft.slice(14, 16) : "00"}
                        onChange={(e) => {
                          const v = Math.min(59, Math.max(0, Number(e.target.value) || 0));
                          const datePart = remindDraft?.slice(0, 10) || format(new Date(), "yyyy-MM-dd");
                          const h = remindDraft?.slice(11, 13) || "09";
                          setRemindDraft(`${datePart}T${h}:${String(v).padStart(2, "0")}`);
                        }}
                        className="h-8 w-16"
                      />
                    </div>
                  </div>
                ) : (
                  <QuickDateMenu
                    kind="datetime"
                    value={remindDraft}
                    onSelect={(d) => {
                      setRemindDraft(format(d, "yyyy-MM-dd'T'HH:mm"));
                      setRemindOpen(false);
                    }}
                    customLabel="选择日期和时间"
                    onCustom={() => setRemindCalendar(true)}
                  />
                )}
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
                      style={{ color: PRIORITY_COLOR[parsed.priority || priority] }}
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
                      style={{ background: PRIORITY_COLOR[i] }}
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
                    {/* #36：项目名按项目色着字（与其他展示位统一），去色点 */}
                    <span className="truncate" style={{ color: p.hex_color || TODO_ACCENT }}>
                      {p.title}
                    </span>
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
