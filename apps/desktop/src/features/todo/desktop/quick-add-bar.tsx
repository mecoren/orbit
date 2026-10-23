/**
 * QuickAddBar — 底部常驻快速输入栏（04 文档 §3.5 复刻；背景与应用背景同色）
 *
 * 输入后浮现四个快捷 Popover（截止日期 / 提醒时间 / 优先级 / 项目）；
 * Enter 提交并保持焦点连续录入；Esc 重置。
 * 提醒时间为独立实体：任务创建成功后追加 todo_reminders_create。
 * NLP 命中（日期/时刻/时长/重复/优先级/项目/标签）以预览 chips 展示且
 * 可逐项取消（F4）；提交瞬间重算，NLP 显式值 > 手动 Popover 选择 > 视图默认。
 */
import { useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { format, parse } from "date-fns";
import { zhCN } from "date-fns/locale";
import { useQuery } from "@tanstack/react-query";
import {
  Calendar,
  CalendarPlus,
  Clock,
  Flag,
  Folder,
  Plus,
  Repeat as RepeatIcon,
  Tag,
  Timer,
  X,
} from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { PickerCalendar } from "@/components/business/picker-calendar";
import { TimeHMSelect } from "@/components/business/time-hm-select";
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
import { repeatLabel } from "../shared/repeat";
import {
  atViewDueHour,
  quickViewCreateDefaults,
} from "../shared/view-create-defaults";
import { PRIORITY_COLOR, TODO_ACCENT, type QuickViewKey, PRIORITY_LABELS } from "../shared/constants";
import { reminderEndMs } from "@/lib/quick-dates";

/** NLP 命中预览胶囊（F4：「用户可逐项取消」） */
function ParsedChip({
  icon,
  label,
  onDismiss,
  style,
}: {
  icon: ReactNode;
  label: string;
  onDismiss: () => void;
  style?: CSSProperties;
}) {
  return (
    <span
      className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-primary"
      style={style}
    >
      {icon}
      {label}
      <button
        type="button"
        aria-label={`取消：${label}`}
        onClick={onDismiss}
        className="ml-0.5 rounded-sm opacity-50 transition-opacity hover:opacity-100 focus-visible:opacity-100"
      >
        <X className="size-2.5" />
      </button>
    </span>
  );
}

/** chips 逐项取消状态：按解析值键控——token 改动后取消态自动失效，reset 清空 */
interface ParsedDismiss {
  dueMs: number | null;
  priority: number;
  projectId: number | null;
  labelIds: number[];
  duration: number | null;
  repeatKey: string | null;
}
const EMPTY_DISMISS: ParsedDismiss = {
  dueMs: null,
  priority: 0,
  projectId: null,
  labelIds: [],
  duration: null,
  repeatKey: null,
};

const repeatKeyOf = (r: { mode: number; after: number; weekdays: number }) =>
  `${r.mode}:${r.after}:${r.weekdays}`;

/** 时长 chip 文案：整小时收敛为「N 小时」 */
const durationLabel = (n: number) =>
  n >= 60 && n % 60 === 0 ? `${n / 60} 小时` : `${n} 分钟`;


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
  const [dismiss, setDismiss] = useState<ParsedDismiss>(EMPTY_DISMISS);

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
    parsed.labelIds.length > 0 ||
    parsed.durationMinutes != null ||
    parsed.repeat != null;

  const reset = () => {
    setTitle("");
    setPriority(0);
    setDueDate(null);
    setRemindDraft("");
    setProjectId("default");
    setDismiss(EMPTY_DISMISS);
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
    // chips 取消的维度回落到手动 Popover 选择（视图标记注入 #39 仍静默附加）
    const nlpDueMs =
      p.dueDate != null && p.dueDate.getTime() !== dismiss.dueMs
        ? p.dueDate.getTime()
        : null;
    const nlpPriority = p.priority !== dismiss.priority ? p.priority : 0;
    const nlpProjectId = p.projectId !== dismiss.projectId ? p.projectId : null;
    const nlpLabels = p.labelIds.filter((id) => !dismiss.labelIds.includes(id));
    // 视图标记注入（#39）：提交瞬间重算默认值（跨零点不落昨天）；
    // NLP 显式值 > 手动 Popover 选择 > 本视图默认。
    // 今日/本周视图内截止时刻归一 18:00（用户口径）：手动 Popover 与视图默认
    // 仍只表达日期；NLP 显式时刻（F4）跳过归一原样落库
    const viewDefaults = quickViewCreateDefaults(quickView);
    const inDueView = quickView === "today" || quickView === "week";
    const resolvedDue = nlpDueMs ?? dueDate?.getTime() ?? viewDefaults.dueMs ?? null;
    const skipViewHour = nlpDueMs != null && p.dueHasTime;
    try {
      const created = await todoTaskCreate({
        title: t,
        priority: nlpPriority || priority,
        due_date:
          inDueView && resolvedDue != null && !skipViewHour
            ? atViewDueHour(resolvedDue)
            : resolvedDue,
        project_id: nlpProjectId ?? effectiveProjectId,
        ...(viewDefaults.myDayMs != null && { my_day_date: viewDefaults.myDayMs }),
        ...(viewDefaults.favorite != null && { is_favorite: viewDefaults.favorite }),
        ...(p.durationMinutes != null &&
          p.durationMinutes !== dismiss.duration && { duration_minutes: p.durationMinutes }),
        ...(p.repeat != null &&
          repeatKeyOf(p.repeat) !== dismiss.repeatKey && {
            repeat_mode: p.repeat.mode,
            repeat_after: p.repeat.after,
            repeat_weekdays: p.repeat.weekdays,
          }),
      });
      // 标签挂载：单个失败不阻断任务本身
      for (const labelId of nlpLabels) {
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
      {/* NLP 解析预览 chips（07 §五-P1#7 + F4 时刻/时长/重复）：仅展示命中项，可逐项取消 */}
      {hasInput && hasHits && (
        <div
          role="status"
          aria-live="polite"
          className="mb-1.5 flex flex-wrap items-center gap-1.5 px-1 text-xs text-muted-foreground"
        >
          {parsed.dueDate && parsed.dueDate.getTime() !== dismiss.dueMs && (
            <ParsedChip
              icon={<Calendar className="size-3" />}
              label={`${format(parsed.dueDate, "M月d日 EEEE", { locale: zhCN })}${
                parsed.dueHasTime ? format(parsed.dueDate, " HH:mm") : ""
              }`}
              onDismiss={() => setDismiss((d) => ({ ...d, dueMs: parsed.dueDate!.getTime() }))}
            />
          )}
          {parsed.priority > 0 && parsed.priority !== dismiss.priority && (
            <ParsedChip
              icon={<Flag className="size-3" />}
              label={PRIORITY_LABELS[parsed.priority]}
              onDismiss={() => setDismiss((d) => ({ ...d, priority: parsed.priority }))}
            />
          )}
          {parsed.projectId != null && parsed.projectId !== dismiss.projectId && (
            <ParsedChip
              icon={<Folder className="size-3" />}
              label={projects.find((pr) => pr.id === parsed.projectId)?.title ?? ""}
              style={{
                color: projects.find((pr) => pr.id === parsed.projectId)?.hex_color || TODO_ACCENT,
              }}
              onDismiss={() => setDismiss((d) => ({ ...d, projectId: parsed.projectId }))}
            />
          )}
          {parsed.labelIds
            .filter((id) => !dismiss.labelIds.includes(id))
            .map((id) => (
              <ParsedChip
                key={id}
                icon={<Tag className="size-3" />}
                label={(labelsQuery.data ?? []).find((l) => l.id === id)?.title ?? ""}
                onDismiss={() =>
                  setDismiss((d) => ({ ...d, labelIds: [...d.labelIds, id] }))
                }
              />
            ))}
          {parsed.durationMinutes != null && parsed.durationMinutes !== dismiss.duration && (
            <ParsedChip
              icon={<Timer className="size-3" />}
              label={`时长 ${durationLabel(parsed.durationMinutes)}`}
              onDismiss={() => setDismiss((d) => ({ ...d, duration: parsed.durationMinutes }))}
            />
          )}
          {parsed.repeat && repeatKeyOf(parsed.repeat) !== dismiss.repeatKey && (
            <ParsedChip
              icon={<RepeatIcon className="size-3" />}
              label={repeatLabel(parsed.repeat.mode, parsed.repeat.after, {
                weekdays: parsed.repeat.weekdays,
              })}
              onDismiss={() => setDismiss((d) => ({ ...d, repeatKey: repeatKeyOf(parsed.repeat!) }))}
            />
          )}
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
          placeholder="添加任务…支持「明天下午3点 每天 30分钟 #项目 @标签 !3」"
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
              {/* 宽度交给内容：选择器月历固定 368px（农历副标签需 ~49px 格宽不截断） */}
              <PopoverContent align="end" className="w-auto p-0">
                {dueCalendar ? (
                  <div className="p-3">
                    <PickerCalendar
                      selected={dueDate ?? undefined}
                      onSelect={(d) => {
                        setDueDate(d);
                        // 选中具体日期后自动收起（清除按钮保持弹层打开）
                        setDueOpen(false);
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
                      aria-label="提醒时间"
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
              <PopoverContent align="end" className="w-auto p-3">
                {remindCalendar ? (
                  <div>
                    <p className="mb-2 text-sm font-medium">提醒时间</p>
                    <PickerCalendar
                      selected={
                        remindDraft
                          ? parse(remindDraft.slice(0, 10), "yyyy-MM-dd", new Date())
                          : undefined
                      }
                      onSelect={(d) => {
                        const datePart = format(d, "yyyy-MM-dd");
                        const prev = remindDraft || format(new Date(), "yyyy-MM-dd'T'HH:mm");
                        const timePart = prev.slice(11) || "09:00";
                        setRemindDraft(`${datePart}T${timePart}`);
                      }}
                    />
                    <div className="mt-2 flex items-center gap-2 border-t pt-2">
                      <span className="text-xs text-muted-foreground">时间</span>
                      {/* 手输 + 下拉二合一（内联列表无 portal，可驻 PopoverContent 内） */}
                      <TimeHMSelect
                        hour={(remindDraft ? remindDraft.slice(11, 13) : "09").padStart(2, "0")}
                        minute={(remindDraft ? remindDraft.slice(14, 16) : "00").padStart(2, "0")}
                        onHourChange={(h) => {
                          const datePart =
                            remindDraft?.slice(0, 10) || format(new Date(), "yyyy-MM-dd");
                          const m = remindDraft?.slice(14, 16) || "00";
                          setRemindDraft(`${datePart}T${h}:${m}`);
                        }}
                        onMinuteChange={(m) => {
                          const datePart =
                            remindDraft?.slice(0, 10) || format(new Date(), "yyyy-MM-dd");
                          const h = remindDraft?.slice(11, 13) || "09";
                          setRemindDraft(`${datePart}T${h}:${m}`);
                        }}
                      />
                    </div>
                  </div>
                ) : (
                  <QuickDateMenu
                    kind="datetime"
                    value={remindDraft}
                    // 已选截止 → 多一组「相对截止」档（对齐移动端 #53 口径）；
                    // 快加无开始/时长输入，「结束时」仅在截止本身带时刻时出现
                    dueDateMs={dueDate ? dueDate.getTime() : null}
                    endMs={
                      reminderEndMs({
                        due_date: dueDate ? dueDate.getTime() : null,
                      })
                    }
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
