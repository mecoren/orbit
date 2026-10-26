/**
 * TaskCreateDrawer — 新增任务抽屉（详情形态，2026-10-22）
 *
 * 背景：新增与编辑长期是两套语言——编辑走详情抽屉（属性网格 + 区块，即改即存），
 * 新增走 label 竖排的窄表单（448px）。本组件把新增也换成详情形态：同一套
 * InfoRow/SectionBlock 原语、同一宽度（max-w-xl）、同一套字段编辑器（开始日期 /
 * 截止日期 / 重复直接复用详情抽屉的受控组件）。
 *
 * 「让用户知道要填值」的三个落点：
 * - 标题常驻输入框 + placeholder「准备做什么？」+ autoFocus，空值点创建会聚焦并提示；
 * - 未填字段用虚线胶囊「+ 设置」呈现，与真值的实心文字拉开层级（详情沿用「设置」）；
 * - 描述/子任务/标签沿用详情既有空态（「+ 添加描述」「添加标签」…），新建可见。
 *
 * 数据语义仍是「草稿 + 一次性创建」，不退化为先落库：所有字段只写本地 state，
 * 点「创建」才走 todoTaskCreate + 标签/子任务/完成引擎；取消不产生任何行，
 * 因此不会在列表留下空任务、也不会污染活动历史。
 *
 * 区块范围：属性网格 / 描述 / 子任务 / 标签 / 提醒（单条 + 持续标记）。关联、
 * 评论、附件、历史留到创建后进详情补充——它们是 id 驱动的即改即存，草稿化成本
 * 高于收益；提醒必须留在新建态（「设个提醒再建」是常见动作，事后补要再点两次）。
 */
import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { format } from "date-fns";
import {
  AlignLeft,
  Bell,
  Calendar,
  Check,
  CircleStop,
  Flag,
  FolderOpen,
  ListChecks,
  Repeat,
  Tag as TagIcon,
  Timer,
  X,
} from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { NumberInput } from "@/components/ui/number-input";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { ErrorState } from "@/components/business/error-state";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { DateTimePicker } from "@/components/business/date-picker";
import { cn } from "@/lib/utils";
import { reminderEndMs } from "@/lib/quick-dates";
import {
  todoLabelCreate,
  todoLabelList,
  todoReminderCreate,
  todoSubtaskCreate,
  todoTaskComplete,
  todoTaskCreate,
  todoTaskLabelCreate,
  type TodoLabel,
  type TodoProject,
} from "@/lib/tauri";
import {
  PRIORITY_COLOR,
  PRIORITY_LABELS,
  PRESET_10,
  STATUS_COLOR,
  STATUS_LABELS,
  TODO_ACCENT,
  type QuickViewKey,
} from "../shared/constants";
import { formatCnDate, REPEAT_MODE } from "../shared/repeat";
import { renderMarkdown } from "../shared/markdown-lite";
import { atViewDueHour, quickViewCreateDefaults } from "../shared/view-create-defaults";
import { templateDueDate, type TemplatePayload } from "../shared/template-apply";
import {
  DueDateEditor,
  InfoRow,
  RepeatEditor,
  SectionBlock,
  StartDateEditor,
} from "./task-detail-drawer";

/** 新建态「未填」占位样式：虚线胶囊 + muted，与真值的实心文字拉开层级 */
const EMPTY_FIELD_CLASS =
  "rounded-md border border-dashed border-muted-foreground/40 px-1.5 py-0.5 text-[12px] text-muted-foreground transition-colors hover:border-primary/60 hover:text-primary";

/** 空值文案：前缀 + 号明示「这里可以点」 */
const EMPTY_LABEL = "+ 设置";

/** 状态三档（详情 PropertyGrid 同口径，STATUS_COLOR/LABELS 单源组装） */
const STATUS_ITEMS = [
  { key: "pending", label: STATUS_LABELS.pending, color: STATUS_COLOR.pending },
  { key: "doing", label: STATUS_LABELS.doing, color: STATUS_COLOR.doing },
  { key: "done", label: STATUS_LABELS.done, color: STATUS_COLOR.done },
] as const;

/** 标签选择：id 存在 = 关联已有标签；否则 = 提交时新建标签再关联 */
interface TagSelection {
  id?: number;
  title: string;
  hex_color: string;
}

/** 提醒草稿：单条提醒（详情 RemindersSection 支持多条，新建态一条足够；
 *  isConstant = G2 持续提醒「响到完成为止」） */
interface ReminderDraft {
  remindMs: number;
  isConstant: boolean;
}

/** 重复规则草稿（与详情 RepeatEditor 的 onChange 载荷同形） */
interface RepeatDraft {
  mode: number;
  after: number;
  weekdays: number;
  endType: number;
  endParam: number;
  fromDone: number;
  monthMode: number;
  nthWeek: number;
}

const REPEAT_DEFAULT: RepeatDraft = {
  mode: REPEAT_MODE.NONE,
  after: 0,
  weekdays: 0,
  endType: 0,
  endParam: 0,
  fromDone: 0,
  monthMode: 0,
  nthWeek: 0,
};

interface DraftState {
  title: string;
  description: string;
  projectId: string;
  priority: number;
  status: string;
  dueMs: number | null;
  startMs: number | null;
  /** 预计时长的原始输入串（空串 = 未设，落库口径见 parseDurationMinutes） */
  durationText: string;
  repeat: RepeatDraft;
  /** 提醒（单条；null = 不提醒——沿用「新增默认不提醒，曾默认一小时后被反馈打扰」口径） */
  reminder: ReminderDraft | null;
  tags: TagSelection[];
  subtasks: string[];
}

const EMPTY_DRAFT: DraftState = {
  title: "",
  description: "",
  projectId: "",
  priority: 0,
  status: "pending",
  dueMs: null,
  startMs: null,
  durationText: "",
  repeat: REPEAT_DEFAULT,
  reminder: null,
  tags: [],
  subtasks: [],
};

/** 今日本地零点（start_date 的既有默认：新增即从今天开始） */
function todayStartMs(now = new Date()): number {
  return new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
}

/** 截止日期初始值：模板 > 日历右键 > 视图默认 > 无（与旧表单同优先级） */
function initialDueMs(args: {
  presetDueDate?: string | null;
  templateOffsetDays?: number;
  viewDueMs?: number;
}): number | null {
  if (args.templateOffsetDays != null) {
    const ms = new Date(`${templateDueDate(args.templateOffsetDays)}T00:00:00`).getTime();
    return Number.isNaN(ms) ? null : ms;
  }
  if (args.presetDueDate) {
    const ms = new Date(`${args.presetDueDate}T00:00:00`).getTime();
    return Number.isNaN(ms) ? null : ms;
  }
  return args.viewDueMs ?? null;
}

/** 开始日期初始值：日历「按开始日期」口径右键注入 > 今天零点 */
function initialStartMs(presetStartDate?: string | null): number {
  if (presetStartDate) {
    const ms = new Date(`${presetStartDate}T00:00:00`).getTime();
    if (!Number.isNaN(ms)) return ms;
  }
  return todayStartMs();
}

/** 预计时长输入串 → 分钟数（空/非正数 = 未设置，与 core 下限口径一致） */
function parseDurationMinutes(text: string): number | null {
  const n = Number.parseInt(text, 10);
  return Number.isFinite(n) && n > 0 ? n : null;
}

interface TaskCreateDrawerProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  projects: TodoProject[];
  /** 新增时的默认项目（当前选中项目） */
  defaultProjectId?: number | null;
  /** 日历视图右键日格注入的截止日期（YYYY-MM-DD） */
  presetDueDate?: string | null;
  /** 日历「按开始日期」口径下右键日格注入的开始日期（YYYY-MM-DD） */
  presetStartDate?: string | null;
  /** 当前快捷视图（今日/本周/我的一天/收藏 → 创建载荷自动带视图标记） */
  quickView?: QuickViewKey | null;
  /** 任务模板预填（优先级：模板 > 日历右键 > 视图默认） */
  presetTemplate?: TemplatePayload | null;
}

export function TaskCreateDrawer({
  open,
  onOpenChange,
  projects,
  defaultProjectId,
  presetDueDate,
  presetStartDate,
  quickView,
  presetTemplate,
}: TaskCreateDrawerProps) {
  const [draft, setDraft] = useState<DraftState>(EMPTY_DRAFT);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const titleRef = useRef<HTMLInputElement>(null);

  // 每次打开重算默认值（跨零点打开也正确）；关闭不清空，避免关闭动画期间闪空
  useEffect(() => {
    if (!open) return;
    const viewDefaults = quickViewCreateDefaults(quickView);
    const tpl = presetTemplate ?? null;
    setDraft({
      ...EMPTY_DRAFT,
      title: tpl?.title ?? "",
      description: tpl?.notes ?? "",
      projectId: defaultProjectId != null ? String(defaultProjectId) : "",
      priority: tpl?.priority ?? 0,
      startMs: initialStartMs(presetStartDate),
      dueMs: initialDueMs({
        presetDueDate,
        templateOffsetDays: tpl?.due_offset_days,
        viewDueMs: viewDefaults.dueMs,
      }),
      repeat: { ...REPEAT_DEFAULT },
      subtasks: tpl?.subtasks ?? [],
    });
    setError(null);
    // Radix 打开后会把焦点交给内容区，下一帧再聚焦标题才稳
    const raf = requestAnimationFrame(() => titleRef.current?.focus());
    return () => cancelAnimationFrame(raf);
  }, [open, defaultProjectId, presetDueDate, presetStartDate, quickView, presetTemplate]);

  const patch = (next: Partial<DraftState>) =>
    setDraft((prev) => ({ ...prev, ...next }));

  const handleCreate = async () => {
    if (submitting) return; // 双击/回车连发防重（按钮 disable 是异步态，挡不住同一帧）
    const title = draft.title.trim();
    if (!title) {
      setError("请先填写标题，再创建任务");
      titleRef.current?.focus();
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      // 视图标记在提交瞬间重算（表单跨零点长开时不落昨天）
      const viewDefaults = quickViewCreateDefaults(quickView);
      const inDueView = quickView === "today" || quickView === "week";
      const duration = parseDurationMinutes(draft.durationText);
      const repeat = draft.repeat;

      // 新建即完成：先落非完成态再走完成引擎——直接写 status=done 只会得到
      // done=0 的不一致行，且重复任务不会推进下一期
      const created = await todoTaskCreate({
        title,
        description: draft.description.trim() || null,
        project_id: draft.projectId === "" ? null : Number(draft.projectId),
        priority: draft.priority,
        status: draft.status === "done" ? "pending" : draft.status,
        due_date:
          inDueView && draft.dueMs != null ? atViewDueHour(draft.dueMs) : draft.dueMs,
        start_date: draft.startMs,
        repeat_mode: repeat.mode,
        repeat_after: repeat.after,
        repeat_weekdays: repeat.mode === REPEAT_MODE.WEEKLY ? repeat.weekdays : 0,
        repeat_end_type: repeat.endType,
        repeat_end_param: repeat.endParam,
        repeat_from_done: repeat.fromDone,
        // 月高级语义只在月档落库（与详情/重复引擎同口径）
        repeat_month_mode: repeat.mode === REPEAT_MODE.MONTHLY ? repeat.monthMode : 0,
        repeat_nth_week: repeat.mode === REPEAT_MODE.MONTHLY ? repeat.nthWeek : 0,
        duration_minutes: duration,
        ...(viewDefaults.myDayMs != null && { my_day_date: viewDefaults.myDayMs }),
        ...(viewDefaults.favorite != null && { is_favorite: viewDefaults.favorite }),
      });

      // 标签：已有标签直接关联；待新建标签先落库再关联
      for (const t of draft.tags) {
        const labelId =
          t.id ?? (await todoLabelCreate({ title: t.title, hex_color: t.hex_color })).id;
        await todoTaskLabelCreate({ task_id: created.id, label_id: labelId });
      }
      // 子任务：逐条创建（percent_done 由后端按完成度回算）
      for (const subtaskTitle of draft.subtasks) {
        await todoSubtaskCreate({ task_id: created.id, title: subtaskTitle });
      }
      // 提醒：新建态单条；持续标记（G2）随行落库
      if (draft.reminder) {
        await todoReminderCreate({
          task_id: created.id,
          remind_at: draft.reminder.remindMs,
          is_constant: draft.reminder.isConstant ? 1 : 0,
        });
      }
      // 新建即完成：子任务/标签挂载完再走完成引擎（重复任务的下一期才能承接）
      if (draft.status === "done") {
        try {
          const res = await todoTaskComplete(created.id);
          const nextDue = res.next_instance?.due_date;
          if (nextDue != null) {
            toast.success(`已完成，已生成下一期：${formatCnDate(nextDue)}`);
          }
        } catch {
          toast.error("任务已创建，但标记完成失败，请手动勾选完成");
        }
      }
      onOpenChange(false);
    } catch (e) {
      setError(`创建失败：${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Sheet open={open} onOpenChange={(o) => !submitting && onOpenChange(o)}>
      <SheetContent className="flex w-full max-w-xl flex-col gap-0 p-0 sm:max-w-xl">
        {/* 标题行：与详情头部同位同阶（pt-8 / border-b），但始终是输入框 */}
        <div className="shrink-0 border-b px-6 pt-8 pb-4">
          <div className="flex items-center gap-3 pr-10">
            <span
              aria-hidden
              className="h-5 w-5 shrink-0 rounded-[4px] border-2 border-muted-foreground/30"
            />
            <Input
              ref={titleRef}
              value={draft.title}
              placeholder="准备做什么？"
              maxLength={200}
              onChange={(e) => {
                patch({ title: e.target.value });
                if (error) setError(null);
              }}
              onKeyDown={(e) => {
                if (e.nativeEvent.isComposing) return; // IME 组合期回车不提交
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  void handleCreate();
                }
              }}
              className="h-8 flex-1 border-0 bg-transparent px-0 text-xl font-semibold shadow-none focus-visible:ring-0 dark:bg-transparent"
            />
          </div>
          <p className="mt-2 pl-8 text-[11px] text-muted-foreground">
            填写标题即可创建；日期、标签等其余字段可按需补充
          </p>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto">
          <div className="flex flex-col gap-4 px-6 pb-6 pt-4">
            <div className="grid grid-cols-2 gap-x-6 gap-y-3 rounded-xl bg-muted/40 p-3.5 text-sm">
              {/* 优先级 */}
              <InfoRow icon={Flag} label="优先级">
                <Popover>
                  <PopoverTrigger asChild>
                    <button type="button" className="font-medium hover:text-primary">
                      {PRIORITY_LABELS[draft.priority] || "无"}
                    </button>
                  </PopoverTrigger>
                  <PopoverContent align="end" className="w-36 p-1">
                    {PRIORITY_LABELS.map((label, i) => (
                      <button
                        key={i}
                        type="button"
                        className={cn(
                          "flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent",
                          draft.priority === i && "bg-accent font-medium",
                        )}
                        onClick={() => patch({ priority: i })}
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
              </InfoRow>

              {/* 状态 */}
              <InfoRow icon={Check} label="状态">
                <Popover>
                  <PopoverTrigger asChild>
                    <button type="button" className="font-medium hover:text-primary">
                      {STATUS_ITEMS.find((s) => s.key === draft.status)?.label ??
                        draft.status}
                    </button>
                  </PopoverTrigger>
                  <PopoverContent align="end" className="w-32 p-1">
                    {STATUS_ITEMS.map((s) => (
                      <button
                        key={s.key}
                        type="button"
                        className="flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent"
                        onClick={() => patch({ status: s.key })}
                      >
                        <span
                          className={cn(
                            "size-2.5 rounded-full",
                            draft.status === s.key && "ring-2 ring-offset-1",
                          )}
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
                    <button
                      type="button"
                      className="truncate font-medium hover:text-primary"
                      style={
                        draft.projectId === ""
                          ? undefined
                          : {
                              color:
                                projects.find((p) => String(p.id) === draft.projectId)
                                  ?.hex_color || TODO_ACCENT,
                            }
                      }
                    >
                      {projects.find((p) => String(p.id) === draft.projectId)?.title ??
                        "未分组"}
                    </button>
                  </PopoverTrigger>
                  <PopoverContent align="start" className="w-56 p-1">
                    <button
                      type="button"
                      className="flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent"
                      onClick={() => patch({ projectId: "" })}
                    >
                      <span className="h-3 w-3 rounded-sm border border-dashed border-muted-foreground/50" />
                      未分组
                    </button>
                    <div className="my-1 border-t" />
                    {projects.map((p) => (
                      <button
                        key={p.id}
                        type="button"
                        className={cn(
                          "flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent",
                          draft.projectId === String(p.id) && "bg-accent font-medium",
                        )}
                        onClick={() => patch({ projectId: String(p.id) })}
                      >
                        <span
                          className="truncate"
                          style={{ color: p.hex_color || TODO_ACCENT }}
                        >
                          {p.title}
                        </span>
                      </button>
                    ))}
                  </PopoverContent>
                </Popover>
              </InfoRow>

              {/* 截止日期（未填 → 虚线「+ 设置」） */}
              <InfoRow icon={Calendar} label="截止日期">
                <DueDateEditor
                  value={draft.dueMs}
                  onChange={(ms) => patch({ dueMs: ms })}
                  emptyLabel={EMPTY_LABEL}
                  emptyClassName={EMPTY_FIELD_CLASS}
                />
              </InfoRow>

              {/* 开始日期 */}
              <InfoRow icon={CircleStop} label="开始日期">
                <StartDateEditor
                  value={draft.startMs}
                  onChange={(ms) => patch({ startMs: ms })}
                  emptyLabel={EMPTY_LABEL}
                  emptyClassName={EMPTY_FIELD_CLASS}
                />
              </InfoRow>

              {/* 预计时长（详情是只读展示，新建态必须可填，否则创建后无入口） */}
              <InfoRow icon={Timer} label="预计时长">
                <span className="flex items-center justify-end gap-1">
                  <NumberInput
                    value={draft.durationText}
                    onValueChange={(v) => patch({ durationText: v })}
                    min={1}
                    step={5}
                    placeholder="未设置"
                    ariaLabel="预计时长（分钟）"
                    className={cn("h-6 w-20", draft.durationText === "" && "border-dashed")}
                  />
                  <span className="text-[12px] text-muted-foreground">分钟</span>
                </span>
              </InfoRow>

              {/* 重复（「不重复」本身即有效默认值，不做空态虚化） */}
              <InfoRow icon={Repeat} label="重复">
                <RepeatEditor
                  mode={draft.repeat.mode}
                  after={draft.repeat.after}
                  weekdays={draft.repeat.weekdays}
                  endType={draft.repeat.endType}
                  endParam={draft.repeat.endParam}
                  fromDone={draft.repeat.fromDone}
                  monthMode={draft.repeat.monthMode}
                  nthWeek={draft.repeat.nthWeek}
                  dueMs={draft.dueMs}
                  onChange={(v) => patch({ repeat: v })}
                />
              </InfoRow>
            </div>

            <DescriptionDraft
              value={draft.description}
              onChange={(v) => patch({ description: v })}
            />

            <SubtasksDraft
              value={draft.subtasks}
              onChange={(v) => patch({ subtasks: v })}
            />

            <TagsDraft value={draft.tags} onChange={(v) => patch({ tags: v })} />

            <ReminderDraft
              value={draft.reminder}
              onChange={(v) => patch({ reminder: v })}
              dueDateMs={draft.dueMs}
              endMs={reminderEndMs({
                start_date: draft.startMs,
                due_date: draft.dueMs,
                duration_minutes: parseDurationMinutes(draft.durationText),
              })}
            />
          </div>
        </div>

        {/* 底部操作：标题为空时不 disable（点了才给聚焦提示，避免「按钮灰着不知道为什么」） */}
        <div className="flex shrink-0 flex-col gap-2 border-t px-6 py-3">
          {error && (
            <div role="alert">
              <ErrorState message={error} className="text-[12px]" />
            </div>
          )}
          <div className="flex items-center justify-end gap-2">
            <Button
              variant="outline"
              onClick={() => onOpenChange(false)}
              disabled={submitting}
            >
              取消
            </Button>
            <Button onClick={() => void handleCreate()} disabled={submitting}>
              {submitting ? (
                <>
                  <EqualizerLoader size={16} inline />
                  创建中…
                </>
              ) : (
                "创建"
              )}
            </Button>
          </div>
        </div>
      </SheetContent>
    </Sheet>
  );
}

/* ================= 区块：描述（空态即「+ 添加描述」） ================= */

function DescriptionDraft({
  value,
  onChange,
}: {
  value: string;
  onChange: (v: string) => void;
}) {
  const [editing, setEditing] = useState(false);

  if (editing) {
    return (
      <SectionBlock icon={AlignLeft} title="描述">
        <Textarea
          autoFocus
          value={value}
          maxLength={5000}
          placeholder="补充背景、验收标准或参考链接…"
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              e.preventDefault();
              setEditing(false);
            } else if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
              e.preventDefault();
              setEditing(false);
            }
          }}
          className="min-h-[80px] max-h-64 field-sizing-content text-[13px]"
        />
        <div className="mt-1 flex items-center justify-between">
          <span className="text-[11px] text-muted-foreground">
            Ctrl+Enter 完成 · Esc 收起
          </span>
          <span className="text-[11px] tabular-nums text-muted-foreground/70">
            {value.length}/5000
          </span>
        </div>
      </SectionBlock>
    );
  }

  return (
    <SectionBlock icon={AlignLeft} title="描述">
      {value.trim() ? (
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
          {renderMarkdown(value)}
        </div>
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

/* ================= 区块：子任务（草稿标题列表） ================= */

function SubtasksDraft({
  value,
  onChange,
}: {
  value: string[];
  onChange: (v: string[]) => void;
}) {
  const [newTitle, setNewTitle] = useState("");

  const add = () => {
    const title = newTitle.trim();
    if (!title || value.includes(title)) return;
    onChange([...value, title]);
    setNewTitle("");
  };

  return (
    <SectionBlock
      icon={ListChecks}
      title="子任务"
      trailing={
        // 与详情同形制：恒显 0/N（草稿态可勾选数为 0），空态也保留徽标占位
        <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] text-muted-foreground">
          0/{value.length}
        </span>
      }
    >
      <div className="space-y-1">
        {value.map((title, i) => (
          <div
            key={`${title}-${i}`}
            className="group flex items-center gap-2 rounded-md px-1 py-1 hover:bg-accent/30"
          >
            {/* 草稿态未落库：方框仅作形制占位，创建后进详情勾选 */}
            <span
              aria-hidden
              className="h-4 w-4 shrink-0 rounded-sm border-2 border-muted-foreground/30"
            />
            <span className="flex-1 truncate text-[13px]">{title}</span>
            <button
              type="button"
              aria-label={`移除子任务 ${title}`}
              className="text-muted-foreground/60 hover:text-destructive"
              onClick={() => onChange(value.filter((_, idx) => idx !== i))}
            >
              <X size={14} />
            </button>
          </div>
        ))}

        <div className="flex items-center gap-2 pt-1">
          <Input
            value={newTitle}
            placeholder="添加子任务"
            className="h-7 flex-1 text-[13px]"
            onChange={(e) => setNewTitle(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                add();
              }
            }}
          />
          <Button
            type="button"
            size="sm"
            variant="ghost"
            className="h-7"
            disabled={!newTitle.trim()}
            onClick={add}
          >
            添加
          </Button>
        </div>
      </div>
    </SectionBlock>
  );
}

/* ================= 区块：提醒（草稿单条 + 持续标记） ================= */

function ReminderDraft({
  value,
  onChange,
  dueDateMs,
  endMs,
}: {
  value: ReminderDraft | null;
  onChange: (v: ReminderDraft | null) => void;
  /** 截止日期（ms）：提醒选择器据此给「相对截止」档 */
  dueDateMs: number | null;
  /** 结束时刻（ms）：选择器组首给「结束时」项（start/due + 时长派生） */
  endMs: number | null;
}) {
  const [editing, setEditing] = useState<{ draft: string; isConstant: boolean } | null>(
    null,
  );

  const commit = () => {
    if (!editing) return;
    const ms = new Date(editing.draft.replace(" ", "T")).getTime();
    if (!Number.isNaN(ms)) onChange({ remindMs: ms, isConstant: editing.isConstant });
    setEditing(null);
  };

  return (
    <SectionBlock
      icon={Bell}
      title="提醒"
      trailing={
        value == null && editing == null ? (
          // 空态用「+ 添加提醒」与「+ 添加描述」同一套语言（详情是主色 link，
          // 新建态统一 muted + 号，弱化但不隐藏）
          <button
            type="button"
            className="text-[12px] font-medium text-primary transition-opacity hover:opacity-80"
            onClick={() =>
              setEditing({
                draft: format(new Date(Date.now() + 3600_000), "yyyy-MM-dd'T'HH:mm"),
                isConstant: false,
              })
            }
          >
            + 添加提醒
          </button>
        ) : undefined
      }
    >
      <div className="space-y-1.5">
        {value && editing == null && (
          <div className="group flex items-center gap-2 rounded-lg bg-muted/40 px-3 py-2 text-[13px]">
            <Bell size={13} className="shrink-0 text-muted-foreground" aria-hidden />
            <button
              type="button"
              className="flex-1 truncate text-left hover:text-primary"
              onClick={() =>
                setEditing({
                  draft: format(new Date(value.remindMs), "yyyy-MM-dd'T'HH:mm"),
                  isConstant: value.isConstant,
                })
              }
            >
              {format(new Date(value.remindMs), "yyyy-MM-dd HH:mm")}
            </button>
            {value.isConstant && (
              <button
                type="button"
                title="持续提醒：未完成则每 5 分钟再提醒，点击关闭"
                onClick={() => onChange({ ...value, isConstant: false })}
                className="shrink-0 rounded-full bg-orange-500/15 px-1.5 py-0.5 text-[10px] font-medium text-orange-600 hover:bg-orange-500/25 dark:text-orange-400"
              >
                持续
              </button>
            )}
            <button
              type="button"
              aria-label="删除提醒"
              className="shrink-0 text-muted-foreground/60 opacity-0 transition-opacity hover:text-destructive group-hover:opacity-100 group-focus-within:opacity-100"
              onClick={() => onChange(null)}
            >
              <X size={13} />
            </button>
          </div>
        )}

        {editing && (
          <div className="max-w-xs space-y-1.5 rounded-lg bg-muted/40 p-2">
            <DateTimePicker
              value={editing.draft}
              dueDateMs={dueDateMs}
              endMs={endMs}
              onChange={(v) => setEditing({ ...editing, draft: v })}
            />
            <label className="flex cursor-pointer items-center justify-between gap-2 text-xs text-muted-foreground">
              <span>持续提醒（响到完成为止）</span>
              <Switch
                checked={editing.isConstant}
                onCheckedChange={(v) => setEditing({ ...editing, isConstant: v })}
                aria-label="持续提醒"
              />
            </label>
            <div className="flex justify-end gap-1">
              <Button size="sm" variant="ghost" onClick={() => setEditing(null)}>
                取消
              </Button>
              <Button size="sm" onClick={commit}>
                确定
              </Button>
            </div>
          </div>
        )}
      </div>
    </SectionBlock>
  );
}

/* ================= 区块：标签（草稿选择 / 新建） ================= */

function TagsDraft({
  value,
  onChange,
}: {
  value: TagSelection[];
  onChange: (v: TagSelection[]) => void;
}) {
  const labelsQuery = useQuery({
    queryKey: ["todo-label", "list"],
    queryFn: () => todoLabelList({ page: 1, page_size: 1000 }),
    staleTime: 60_000,
  });
  const allLabels = labelsQuery.data ?? [];
  const [popoverOpen, setPopoverOpen] = useState(false);
  const [newTitle, setNewTitle] = useState("");

  const selectedIds = new Set(
    value.map((t) => t.id).filter((id): id is number => id != null),
  );
  const pendingTitles = new Set(value.filter((t) => t.id == null).map((t) => t.title));

  const toggleExisting = (label: TodoLabel) => {
    if (selectedIds.has(label.id)) {
      onChange(value.filter((t) => t.id !== label.id));
    } else {
      onChange([
        ...value,
        { id: label.id, title: label.title, hex_color: label.hex_color },
      ]);
    }
  };

  // Enter 新建：重名自动归到已有标签；否则作为待创建标签（提交时落库）
  const addPending = () => {
    const title = newTitle.trim();
    if (!title) return;
    const existing = allLabels.find((l) => l.title === title);
    if (existing) {
      if (!selectedIds.has(existing.id)) {
        onChange([
          ...value,
          { id: existing.id, title: existing.title, hex_color: existing.hex_color },
        ]);
      }
    } else if (!pendingTitles.has(title)) {
      onChange([
        ...value,
        {
          title,
          hex_color: PRESET_10[Math.floor(Math.random() * PRESET_10.length)],
        },
      ]);
    }
    setNewTitle("");
  };

  return (
    <SectionBlock icon={TagIcon} title="标签">
      <div className="flex flex-wrap items-center gap-1.5">
        {value.map((t, i) => (
          <span
            key={t.id ?? `pending-${t.title}`}
            className="inline-flex items-center gap-1.5 rounded-md border px-2 py-0.5 text-xs text-muted-foreground"
          >
            <span
              aria-hidden
              className="size-2 shrink-0 rounded-full"
              style={{ background: t.hex_color }}
            />
            {t.title}
            <button
              type="button"
              aria-label={`移除标签 ${t.title}`}
              className="text-muted-foreground/60 hover:text-foreground"
              onClick={() => onChange(value.filter((_, idx) => idx !== i))}
            >
              <X size={12} />
            </button>
          </span>
        ))}

        <Popover open={popoverOpen} onOpenChange={setPopoverOpen}>
          <PopoverTrigger asChild>
            <Button type="button" variant="outline" size="sm" className="h-7">
              添加标签
            </Button>
          </PopoverTrigger>
          <PopoverContent align="start" className="w-64 p-0">
            <div className="max-h-60 overflow-y-auto p-1">
              {allLabels.length === 0 && (
                <p className="px-2 py-1.5 text-xs text-muted-foreground">
                  暂无标签，可在下方输入新建
                </p>
              )}
              {allLabels.map((l) => (
                <label
                  key={l.id}
                  className="flex cursor-pointer items-center gap-2 rounded-sm px-2 py-1.5 text-sm hover:bg-accent"
                >
                  <input
                    type="checkbox"
                    checked={selectedIds.has(l.id)}
                    onChange={() => toggleExisting(l)}
                    className="size-4 shrink-0 accent-primary"
                  />
                  <span className="size-2.5 rounded-sm" style={{ background: l.hex_color }} />
                  <span className="truncate">{l.title}</span>
                </label>
              ))}
            </div>
            <div className="border-t p-2">
              <Input
                value={newTitle}
                placeholder="新建标签，Enter 添加"
                className="h-7 text-[13px]"
                onChange={(e) => setNewTitle(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    addPending();
                  }
                }}
              />
            </div>
          </PopoverContent>
        </Popover>
      </div>
    </SectionBlock>
  );
}
