/**
 * TaskFormSheet — 新增/编辑任务表单（04 文档 §3.6 复刻）
 *
 * 包装通用 EntityFormSheet；九字段规格照抄 + 虚拟字段 remind_at + 重复规则：
 * title(必填) / description(5000) / project_id / priority(0–5, 语义色点) / status(pending|doing|done)
 * / due_date / start_date（提交转毫秒时间戳）
 * / repeat_mode / repeat_after（footerContent 预设 + 自定义 N×单位，与移动端同语义）。
 * remind_at 不是任务列：新增默认一小时后；编辑载入既有提醒回填，
 * 提交时按"清除删 / 变更删旧建新"同步。
 * 新增模式（footerContent）支持标签选择/新建与子任务草稿，创建任务后统一落库关联；
 * 编辑模式的标签与子任务仍走详情抽屉（task-detail-drawer）。
 */
import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { format } from "date-fns";
import { Tag as TagIcon, X } from "lucide-react";

import { EntityFormSheet } from "@/components/business/entity-form-sheet";
import { DatePicker } from "@/components/business/date-picker";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import type { FieldDef } from "@/lib/form-types";
import { cn } from "@/lib/utils";
import {
  todoLabelCreate,
  todoLabelList,
  todoReminderCreate,
  todoReminderDelete,
  todoReminderList,
  todoSubtaskCreate,
  todoTaskCreate,
  todoTaskLabelCreate,
  todoTaskUpdate,
  type TodoLabel,
  type TodoProject,
  type TodoReminder,
  type TodoTask,
} from "@/lib/tauri";
import {
  REPEAT_MODE,
  REPEAT_PRESETS,
  WEEKDAY_CHIPS,
  repeatLabel,
} from "../shared/repeat";
import { formatYmd } from "../shared/lunar";
import { templateDueDate } from "../shared/template-apply";
import { atViewDueHour, quickViewCreateDefaults } from "../shared/view-create-defaults";
import { PRIORITY_COLOR, TODO_ACCENT } from "../shared/constants";

const PRIORITY_LABELS = ["无", "低", "中", "高", "紧急", "立即处理"];

/** ms → DateTimePicker 值格式（YYYY-MM-DDTHH:MM） */
const tsToInputValue = (ms: number) => format(new Date(ms), "yyyy-MM-dd'T'HH:mm");

export function buildTaskFields(projects: TodoProject[]): FieldDef[] {
  return [
    { name: "title", label: "标题", type: "text", required: true, placeholder: "输入任务标题" },
    { name: "description", label: "描述", type: "textarea", maxLength: 5000 },
    {
      name: "project_id",
      label: "所属项目",
      type: "select",
      options: [
        { label: "未分组", value: "" },
        // 项目名按项目色直接着色（#36；侧边栏圆点口径外的展示位）
        ...projects.map((p) => ({
          label: p.title,
          value: String(p.id),
          textColor: p.hex_color || TODO_ACCENT,
        })),
      ],
    },
    {
      name: "priority",
      label: "优先级",
      type: "select",
      defaultValue: 0,
      options: PRIORITY_LABELS.map((label, value) => ({
        label,
        value,
        color: PRIORITY_COLOR[value],
      })),
    },
    {
      name: "status",
      label: "状态",
      type: "select",
      defaultValue: "pending",
      options: [
        { label: "待办", value: "pending" },
        { label: "进行中", value: "doing" },
        { label: "已完成", value: "done" },
      ],
    },
    { name: "due_date", label: "截止日期", type: "date" },
    { name: "remind_at", label: "提醒时间", type: "datetime" },
    { name: "start_date", label: "开始日期", type: "date" },
  ];
}

/** 日期字符串 → 毫秒时间戳；空值转 null */
function toDateMs(v: unknown): number | null {
  if (typeof v !== "string" || !v) return null;
  const ms = new Date(`${v}T00:00:00`).getTime();
  return Number.isNaN(ms) ? null : ms;
}

/* ================= 新增模式：标签选择 ================= */

/** 标签选择状态：id 存在 = 关联已有标签；否则 = 提交时新建标签再关联 */
interface TagSelection {
  id?: number;
  title: string;
  hex_color: string;
}

const LABEL_RANDOM_COLORS = [
  "#3B82F6",
  "#8B5CF6",
  "#EC4899",
  "#F59E0B",
  "#10B981",
  "#EF4444",
  "#06B6D4",
  "#F97316",
];

function TagsField({
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
  const pendingTitles = new Set(
    value.filter((t) => t.id == null).map((t) => t.title),
  );

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
          {
            id: existing.id,
            title: existing.title,
            hex_color: existing.hex_color,
          },
        ]);
      }
    } else if (!pendingTitles.has(title)) {
      onChange([
        ...value,
        {
          title,
          hex_color:
            LABEL_RANDOM_COLORS[
              Math.floor(Math.random() * LABEL_RANDOM_COLORS.length)
            ],
        },
      ]);
    }
    setNewTitle("");
  };

  return (
    <div className="flex flex-col gap-1.5">
      <Label>
        <TagIcon className="mr-1.5 inline size-3.5 text-muted-foreground" />
        标签
      </Label>
      <div className="flex flex-wrap items-center gap-1.5">
        {value.map((t, i) => (
          <span
            key={t.id ?? `pending-${t.title}`}
            className="inline-flex items-center gap-1.5 rounded-md border px-2 py-0.5 text-xs text-muted-foreground"
          >
            {/* 色点+标签名：与列表行 LabelChips 同形制（点=颜色信号） */}
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
                    className="accent-primary"
                  />
                  <span
                    className="size-2.5 rounded-sm"
                    style={{ background: l.hex_color }}
                  />
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
    </div>
  );
}

/* ================= 新增模式：子任务 ================= */

function SubtasksField({
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
    <div className="flex flex-col gap-1.5">
      <Label>子任务</Label>
      <div className="space-y-1">
        {value.map((title, i) => (
          <div
            key={`${title}-${i}`}
            className="group flex items-center gap-2 rounded-md px-1 py-1 hover:bg-accent/30"
          >
            <span className="h-4 w-4 shrink-0 rounded-sm border-2 border-muted-foreground/40" />
            <span className="flex-1 truncate text-[13px]">{title}</span>
            <button
              type="button"
              aria-label="移除子任务"
              onClick={() => onChange(value.filter((_, idx) => idx !== i))}
            >
              <X size={14} className="text-muted-foreground hover:text-destructive" />
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
    </div>
  );
}

/* ================= 新增/编辑模式：重复规则 ================= */

/** 自定义间隔单位（值对应 repeat_mode 1–4，与移动端 RepeatUnit 同语义） */
const REPEAT_UNITS = [
  { mode: REPEAT_MODE.DAILY, label: "天" },
  { mode: REPEAT_MODE.WEEKLY, label: "周" },
  { mode: REPEAT_MODE.MONTHLY, label: "月" },
  { mode: REPEAT_MODE.YEARLY, label: "年" },
] as const;

/** 结束条件选项（与 Rust REPEAT_END_* 常量对齐） */
const REPEAT_END_OPTIONS = [
  { type: 0, label: "永不" },
  { type: 2, label: "次数" },
  { type: 1, label: "日期" },
] as const;

/**
 * 重复规则选择：预设 chips 即点即存；「自定义」展开 间隔 N × 单位 面板
 * （周档可勾选星期几、结束条件 永不/次数/日期、when done 推进口径），
 * 确定 后派生 repeat_mode/repeat_after/扩展字段（#34 重复规则升级）。
 */
function RepeatField({
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
  const [intervalText, setIntervalText] = useState(
    String(Math.max(1, after || 1)),
  );
  const [unit, setUnit] = useState(
    mode === REPEAT_MODE.NONE ? REPEAT_MODE.DAILY : mode,
  );
  const [customOpen, setCustomOpen] = useState(false);
  // 扩展规则的编辑态（customOpen 展开面板时初始化一次；预设路径不触碰）
  const [weekdayMask, setWeekdayMask] = useState(weekdays);
  const [endOption, setEndOption] = useState(endType);
  const [endText, setEndText] = useState(
    endType === 2 ? String(Math.max(1, endParam || 1)) : "",
  );
  const [endDate, setEndDate] = useState(
    endType === 1 && endParam > 0
      ? new Date(endParam).toISOString().slice(0, 10)
      : "",
  );
  const [whenDone, setWhenDone] = useState(fromDone);

  const isPreset =
    REPEAT_PRESETS.some((p) => p.mode === mode && p.after === after) &&
    weekdays === 0 &&
    endType === 0 &&
    fromDone === 0;
  const custom = mode !== REPEAT_MODE.NONE && !isPreset;

  const pick = (m: number, a: number) => {
    setIntervalText(String(Math.max(1, a)));
    setUnit(m === REPEAT_MODE.NONE ? REPEAT_MODE.DAILY : m);
    setCustomOpen(false);
    // 预设 = 基础语义：清扩展字段
    setWeekdayMask(0);
    setEndOption(0);
    setEndText("");
    setEndDate("");
    setWhenDone(0);
    onChange({ mode: m, after: a, weekdays: 0, endType: 0, endParam: 0, fromDone: 0 });
  };

  const applyCustom = () => {
    const n = Math.max(1, Number(intervalText) || 1);
    let param = 0;
    if (endOption === 2) param = Math.max(1, Number(endText) || 1);
    if (endOption === 1 && endDate) {
      param = new Date(`${endDate}T23:59:59`).getTime();
    }
    onChange({
      mode: unit,
      after: n,
      weekdays: unit === REPEAT_MODE.WEEKLY ? weekdayMask : 0,
      endType: endOption,
      endParam: param,
      fromDone: whenDone,
    });
    setCustomOpen(false);
  };

  const toggleWeekday = (bit: number) => {
    setWeekdayMask((m) => m ^ bit);
  };

  return (
    <div className="flex flex-col gap-1.5">
      <Label>重复</Label>
      <div className="flex flex-wrap items-center gap-1.5">
        {REPEAT_PRESETS.map((p) => (
          <button
            key={p.mode}
            type="button"
            onClick={() => pick(p.mode, p.after)}
            className={cn(
              "rounded-md border px-2.5 py-1 text-xs",
              !custom && !customOpen && mode === p.mode
                ? "border-primary bg-primary/10 font-medium text-primary"
                : "text-muted-foreground hover:bg-accent",
            )}
          >
            {p.label}
          </button>
        ))}
        <button
          type="button"
          onClick={() => setCustomOpen((v) => !v)}
          className={cn(
            "rounded-md border px-2.5 py-1 text-xs",
            custom || customOpen
              ? "border-primary bg-primary/10 font-medium text-primary"
              : "text-muted-foreground hover:bg-accent",
          )}
        >
          {custom ? repeatLabel(mode, after) : "自定义"}
        </button>
      </div>
      {customOpen && (
        <div className="flex flex-col gap-1.5 rounded-md border border-border/60 bg-muted/20 p-2">
          <div className="flex flex-wrap items-center gap-1.5">
            <Input
              value={intervalText}
              inputMode="numeric"
              placeholder="间隔"
              className="h-7 w-16 text-[13px]"
              onChange={(e) => setIntervalText(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                }
              }}
            />
            {REPEAT_UNITS.map((u) => (
              <button
                key={u.mode}
                type="button"
                onClick={() => setUnit(u.mode)}
                className={cn(
                  "rounded-md border px-2.5 py-1 text-xs",
                  unit === u.mode
                    ? "border-primary bg-primary/10 font-medium text-primary"
                    : "text-muted-foreground hover:bg-accent",
                )}
              >
                {u.label}
              </button>
            ))}
          </div>
          {unit === REPEAT_MODE.WEEKLY && (
            <div className="flex flex-wrap items-center gap-1">
              <span className="text-[11px] text-muted-foreground">星期几</span>
              {WEEKDAY_CHIPS.map((d) => (
                <button
                  key={d.bit}
                  type="button"
                  aria-label={`星期${d.label}`}
                  onClick={() => toggleWeekday(d.bit)}
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
              {weekdayMask !== 0 && (
                <span className="text-[11px] text-muted-foreground">
                  （周档 N 周 + 多选星期几）
                </span>
              )}
            </div>
          )}
          <div className="flex flex-wrap items-center gap-1.5">
            <span className="text-[11px] text-muted-foreground">结束</span>
            {REPEAT_END_OPTIONS.map((o) => (
              <button
                key={o.type}
                type="button"
                onClick={() => setEndOption(o.type)}
                className={cn(
                  "rounded-md border px-2 py-0.5 text-[11px]",
                  endOption === o.type
                    ? "border-primary bg-primary/10 font-medium text-primary"
                    : "text-muted-foreground hover:bg-accent",
                )}
              >
                {o.label}
              </button>
            ))}
            {endOption === 2 && (
              <Input
                value={endText}
                inputMode="numeric"
                placeholder="次数"
                className="h-7 w-16 text-xs"
                onChange={(e) => setEndText(e.target.value)}
              />
            )}
            {endOption === 1 && (
              // 日期档独占一行：弹出的日历层较宽，128px 触发钮夹在
              // chips 行内会让弹层定位局促（上弹横跨面板），全宽行更稳
              <div className="w-full">
                <DatePicker
                  value={endDate}
                  onChange={setEndDate}
                  placeholder="结束日期"
                  quick={false}
                  className="h-7 px-2 text-xs"
                />
              </div>
            )}
          </div>
          <div className="flex items-center gap-1.5">
            <span className="text-[11px] text-muted-foreground">完成后</span>
            <button
              type="button"
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
            <span className="text-[11px] text-muted-foreground">
              {whenDone ? "下次 = 完成后一个完整周期" : "下次 = 按原排程节奏"}
            </span>
          </div>
          <Button
            type="button"
            size="sm"
            variant="ghost"
            className="h-7 self-start"
            onClick={applyCustom}
          >
            确定
          </Button>
        </div>
      )}
    </div>
  );
}

interface TaskFormSheetProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 编辑模式传入任务；null/undefined 为新增 */
  task?: TodoTask | null;
  projects: TodoProject[];
  /** 新增时的默认项目（当前选中项目，04 §3.6） */
  defaultProjectId?: number | null;
  /** 新增时预填的截止日期（YYYY-MM-DD；日历视图右键日格快捷新增用） */
  presetDueDate?: string | null;
  /** 当前选中的快捷视图（#39：视图内新建自动带本视图标记；仅新增模式消费，编辑不受影响） */
  quickView?: import("../shared/constants").QuickViewKey | null;
  /** 任务模板预填（套用模板时传入；优先级：模板 > 日历右键 > 视图默认） */
  presetTemplate?: import("../shared/template-apply").TemplatePayload | null;
}

export function TaskFormSheet({
  open,
  onOpenChange,
  task,
  projects,
  defaultProjectId,
  presetDueDate,
  quickView,
  presetTemplate,
}: TaskFormSheetProps) {
  // 编辑模式载入该任务既有提醒（取第一条未删除），用于回填与变更比对
  const [existingReminder, setExistingReminder] = useState<TodoReminder | null>(null);
  // 新增模式：标签选择 / 子任务草稿（编辑模式的标签与子任务走详情抽屉）
  const [tagSelections, setTagSelections] = useState<TagSelection[]>([]);
  const [subtaskTitles, setSubtaskTitles] = useState<string[]>([]);
  // 重复规则（新增/编辑共用 footerContent 编辑；#34 扩展字段）
  const [repeatMode, setRepeatMode] = useState<number>(REPEAT_MODE.NONE);
  const [repeatAfter, setRepeatAfter] = useState<number>(0);
  const [repeatWeekdays, setRepeatWeekdays] = useState<number>(0);
  const [repeatEndType, setRepeatEndType] = useState<number>(0);
  const [repeatEndParam, setRepeatEndParam] = useState<number>(0);
  const [repeatFromDone, setRepeatFromDone] = useState<number>(0);

  // 打开时初始化：编辑载入既有规则，新增重置为不重复
  useEffect(() => {
    if (!open) return;
    if (task) {
      setRepeatMode(task.repeat_mode);
      setRepeatAfter(task.repeat_after);
      setRepeatWeekdays(task.repeat_weekdays ?? 0);
      setRepeatEndType(task.repeat_end_type ?? 0);
      setRepeatEndParam(task.repeat_end_param ?? 0);
      setRepeatFromDone(task.repeat_from_done ?? 0);
    } else {
      setRepeatMode(REPEAT_MODE.NONE);
      setRepeatAfter(0);
      setRepeatWeekdays(0);
      setRepeatEndType(0);
      setRepeatEndParam(0);
      setRepeatFromDone(0);
      setTagSelections([]);
      // 模板子任务预填（套用模板 > 空白新建）；标题留空由用户补
      setSubtaskTitles(presetTemplate?.subtasks ?? []);
    }
  }, [open, task, presetTemplate]);

  useEffect(() => {
    if (!open || !task) {
      setExistingReminder(null);
      return;
    }
    let cancelled = false;
    todoReminderList({ page: 1, page_size: 1000 })
      .then((rows) => {
        if (!cancelled) {
          setExistingReminder(
            rows.find((r) => r.task_id === task.id && !r.is_deleted) ?? null,
          );
        }
      })
      .catch(() => {
        /* 载入失败按无提醒处理 */
      });
    return () => {
      cancelled = true;
    };
  }, [open, task]);

  // 稳定引用：避免父级重渲染（后台 refetch 等）触发 EntityFormSheet 重置表单
  const fields = useMemo(() => buildTaskFields(projects), [projects]);

  const initialRecord = useMemo(() => {
    if (task) {
      return {
        ...task,
        // select 组件以字符串值工作，数字键需字符串化
        project_id: task.project_id != null ? String(task.project_id) : "",
        priority: String(task.priority),
        status: task.status,
        remind_at: existingReminder ? tsToInputValue(existingReminder.remind_at) : "",
      };
    }
    // 视图默认截止（#39）：今日/本周视图预填表单字段（可见可改；依赖 open 每次打开重算）
    const viewDefaults = quickViewCreateDefaults(quickView);
    // 模板预填（套用模板）：显式选择语义最强，优先级 模板 > 日历右键 > 视图默认
    const tpl = presetTemplate ?? null;
    return {
      ...(defaultProjectId != null ? { project_id: String(defaultProjectId) } : {}),
      ...(tpl?.title ? { title: tpl.title } : {}),
      ...(tpl?.notes != null ? { description: tpl.notes } : {}),
      priority: tpl?.priority != null ? String(tpl.priority) : "0",
      status: "pending",
      // 新增默认开始日期：今天（跨零点打开也正确，依赖 open 重算）
      start_date: formatYmd(new Date()),
      // 截止日期预填优先级：模板 > 日历右键 > 视图默认（today/week）> 无
      ...(tpl?.due_offset_days != null
        ? { due_date: templateDueDate(tpl.due_offset_days) }
        : presetDueDate
          ? { due_date: presetDueDate }
          : viewDefaults.dueMs != null
            ? { due_date: formatYmd(new Date(viewDefaults.dueMs)) }
            : {}),
      // 新增默认提醒：一小时后（依赖 open，每次打开重新计算）
      remind_at: tsToInputValue(Date.now() + 60 * 60 * 1000),
    };
  }, [task, defaultProjectId, existingReminder, open, presetDueDate, quickView, presetTemplate]);

  const handleSubmit = async (values: Record<string, unknown>) => {
    const payload = {
      title: String(values.title ?? "").trim(),
      description: (values.description as string) || null,
      project_id:
        values.project_id === "" || values.project_id == null
          ? null
          : Number(values.project_id),
      priority: Number(values.priority ?? 0),
      status: String(values.status ?? "pending"),
      due_date: toDateMs(values.due_date),
      start_date: toDateMs(values.start_date),
      repeat_mode: repeatMode,
      repeat_after: repeatAfter,
      repeat_weekdays: repeatMode === REPEAT_MODE.WEEKLY ? repeatWeekdays : 0,
      repeat_end_type: repeatEndType,
      repeat_end_param: repeatEndParam,
      repeat_from_done: repeatFromDone,
    };

    // 提醒时间（values 已过滤 null：undefined = 用户清空或未填）
    const remindRaw = typeof values.remind_at === "string" ? values.remind_at : "";
    const remindMs = remindRaw ? new Date(remindRaw).getTime() : null;

    if (task) {
      await todoTaskUpdate(task.id, payload);
      // 同步提醒实体：清空→删；变更→删旧建新；未动→跳过
      const old = existingReminder;
      if (remindMs == null || Number.isNaN(remindMs)) {
        if (old) await todoReminderDelete(old.id);
      } else if (!old || tsToInputValue(old.remind_at) !== remindRaw) {
        if (old) await todoReminderDelete(old.id);
        await todoReminderCreate({ task_id: task.id, remind_at: remindMs });
      }
    } else {
      // 视图标记静默附加（#39）：我的一天/收藏视图下新建自动带标记
      //（表单无对应字段，用户取消可在列表行 Sunrise/星标一键解除）；
      // 提交瞬间重算（表单跨零点长开时 my_day_date 不落昨天）。
      // 今日/本周视图内截止时刻归一 18:00（用户口径）：表单日期字段为
      // 纯日期型（落零点），视图内填的日期统一挪到 18 点
      const viewDefaults = quickViewCreateDefaults(quickView);
      const inDueView = quickView === "today" || quickView === "week";
      const created = await todoTaskCreate({
        ...payload,
        ...(inDueView &&
          payload.due_date != null && { due_date: atViewDueHour(payload.due_date) }),
        ...(viewDefaults.myDayMs != null && { my_day_date: viewDefaults.myDayMs }),
        ...(viewDefaults.favorite != null && { is_favorite: viewDefaults.favorite }),
      });
      if (remindMs != null && !Number.isNaN(remindMs)) {
        await todoReminderCreate({ task_id: created.id, remind_at: remindMs });
      }
      // 标签：已有标签直接关联；待新建标签先落库再关联
      for (const t of tagSelections) {
        let labelId: number;
        if (t.id != null) {
          labelId = t.id;
        } else {
          const newLabel = await todoLabelCreate({
            title: t.title,
            hex_color: t.hex_color,
          });
          labelId = newLabel.id;
        }
        await todoTaskLabelCreate({ task_id: created.id, label_id: labelId });
      }
      // 子任务：逐条创建（percent_done 由后端按完成度回算）
      for (const title of subtaskTitles) {
        await todoSubtaskCreate({ task_id: created.id, title });
      }
    }
  };

  return (
    <EntityFormSheet
      open={open}
      onOpenChange={onOpenChange}
      title={task ? "编辑待办" : "新增待办"}
      fields={fields}
      accent={TODO_ACCENT}
      initialRecord={initialRecord}
      onSubmit={handleSubmit}
      footerContent={
        <>
          <RepeatField
            mode={repeatMode}
            after={repeatAfter}
            weekdays={repeatWeekdays}
            endType={repeatEndType}
            endParam={repeatEndParam}
            fromDone={repeatFromDone}
            onChange={(v) => {
              setRepeatMode(v.mode);
              setRepeatAfter(v.after);
              setRepeatWeekdays(v.weekdays);
              setRepeatEndType(v.endType);
              setRepeatEndParam(v.endParam);
              setRepeatFromDone(v.fromDone);
            }}
          />
          {!task && (
            <>
              <TagsField value={tagSelections} onChange={setTagSelections} />
              <SubtasksField value={subtaskTitles} onChange={setSubtaskTitles} />
            </>
          )}
        </>
      }
      submitText={task ? "保存" : "创建"}
    />
  );
}

