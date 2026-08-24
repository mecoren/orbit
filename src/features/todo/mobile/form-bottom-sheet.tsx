/**
 * RecordFormBottomSheet —— 新建/编辑表单底部抽屉（05 §4.4 十字段表逐条复刻；M4 Task 15）
 *
 * 容器 BottomSheet 默认档 [.35,.65,1]（initial .65 即表单档）；内容 ListView padding 16。
 * 字段顺序固定：标题* → 描述 → 项目 → 优先级 → 状态 → 截止日期 → 更多选项折叠
 * → 开始日期 → 结束日期 → 颜色，间距 12（space-y-3）。
 *
 * 数据层：todoTasksCreate/Get/Update + todoProjectList；UpdateInput 缺省键=跳过语义
 * （02 §三要点 3）——update 仅传与预填值有差异的字段。保存链：校验标题非空 →
 * create/update(payload 全字段) → 关闭抽屉 + invalidate ["todo_tasks"]（编辑态另失效详情 key）；
 * 失败 waitToast.destructive("保存失败")。提醒调度无需显式调用：轮询守护自动拾取
 * （notification_scheduler 前台轮询，R2 兜底基线）。
 */
import { useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";

import { BottomSheet } from "@/components/mobile/bottom-sheet";
import { EqSpinner } from "@/components/mobile/eq-spinner";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { SelectSheet } from "@/components/mobile/select-sheet";
import { WaitDatePickerSheet } from "@/components/mobile/wait-date-picker-sheet";
import { waitToast } from "@/components/mobile/wait-toast";
import {
  todoProjectCreate,
  todoProjectList,
  todoTaskCreate,
  todoTaskGet,
  todoTaskUpdate,
  type TodoTaskUpdateInput,
} from "@/lib/tauri";
import { TODO_ACCENT } from "../shared/constants";

/** cfg `todo_priority` 硬编码映射项 */
interface PriorityOption {
  value: number;
  label: string;
}
/**
 * cfg `todo_priority` 选项：lib 层无现成 cfgOptionItemsList 命令，按计划硬编码中文映射
 * （low=低/medium=中/high=高/urgent=紧急/immediate=立即处理，value 对齐桌面
 * PRIORITY_LABELS 下标语义）；加载失败回退 低/中/高（05 §4.4 字段 4）。
 */
const CFG_PRIORITY_OPTIONS: PriorityOption[] = [
  { value: 1, label: "低" },
  { value: 2, label: "中" },
  { value: 3, label: "高" },
  { value: 4, label: "紧急" },
  { value: 5, label: "立即处理" },
];
/**
 * 加载失败回退三项：低/中/高（05 §4.4 字段 4）。lib 层暂无 cfg 命令、硬编码路径恒成功，
 * 导出留作接入真实 cfgOptionItemsList 命令后的降级出口（loadPriorityOptions 失败分支）。
 */
export const PRIORITY_FALLBACK: PriorityOption[] = CFG_PRIORITY_OPTIONS.slice(0, 3);

/**
 * cfg 优先级选项加载出口：lib 层暂无 cfgOptionItemsList 命令 → 硬编码映射即视为加载成功；
 * 未来接入真实命令后，失败时改返回 PRIORITY_FALLBACK（低/中/高）即可。
 */
function loadPriorityOptions(): PriorityOption[] {
  return CFG_PRIORITY_OPTIONS;
}
/** 桌面同款优先级文案表（兜底项 label 取值用，含 P0「无」） */
const PRIORITY_LABELS = ["无", "低", "中", "高", "紧急", "立即处理"];
/** 桌面共享优先级色板（04 §5.2，index 0 为空不显点） */
const PRIORITY_COLOR = ["", "#6B7280", "#3B82F6", "#F59E0B", "#EF4444", "#DC2626"];

/** 状态三段（05 §4.4 字段 5） */
const STATUS_ITEMS = [
  { key: "pending", label: "待办" },
  { key: "doing", label: "进行中" },
  { key: "done", label: "已完成" },
] as const;

/** 表单色板七个 32×32 圆（首项 '' 透明 + block_rounded 占位）（05 §4.4 字段 10） */
const FORM_COLORS = ["", "#EF4444", "#F59E0B", "#22C55E", "#3B82F6", "#8B5CF6", "#EC4899"];
/** 快捷建项目六色 28 圆，默认蓝 #3B82F6（05 §4.4 字段 3） */
const PROJECT_COLORS = ["#EF4444", "#F59E0B", "#22C55E", "#3B82F6", "#8B5CF6", "#EC4899"];

/** yyyy-MM-dd 本地时区（日期盒展示口径，同 tile/detail formatDue） */
function formatYmd(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/**
 * 玻璃盒边框色：M3 outline #79747E @30%（亮）/ @50%（暗）（05 §4.4 字段 6
 * 「边框 outline@30%/0.5」）。inline style 写不了 media query，运行期跟随系统深浅取值
 * （与 sidebar-screen useSurfaceHighest 同手法）。
 */
function useOutlineBorder(): string {
  const [dark, setDark] = useState(
    () => window.matchMedia("(prefers-color-scheme: dark)").matches,
  );
  useEffect(() => {
    const mql = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = (e: MediaQueryListEvent) => setDark(e.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, []);
  return `rgba(121, 116, 126, ${dark ? 0.5 : 0.3})`;
}

/** 区块头（05 §4.4 字段 1）：3×16 强调竖条(r2) + w8 间距 + 标题 w600 */
function SectionBar({ text }: { text: string }) {
  return (
    <div className="flex items-center gap-2 pb-1.5">
      <span className="h-4 w-[3px] shrink-0 rounded-[2px]" style={{ background: TODO_ACCENT }} />
      <span className="text-sm font-semibold text-[var(--m-text)]">{text}</span>
      <span className="text-sm font-semibold" style={{ color: "#F44336" }}>
        *
      </span>
    </div>
  );
}

/** 独立小标签（状态/颜色等字段共用）：12px/sub/left4/bottom6（05 §4.4 字段 5/10） */
function FieldLabel({ text }: { text: string }) {
  return <div className="pb-1.5 pl-1 text-xs text-[var(--m-sub)]">{text}</div>;
}

/** 玻璃盒基底样式：blur10+surface@50%+r12+边框 outline@30%/0.5，padding h14/v12（05 §4.4 字段 6） */
function glassBoxStyle(border: string): React.CSSProperties {
  return {
    backdropFilter: "blur(10px)",
    WebkitBackdropFilter: "blur(10px)",
    background: "color-mix(in srgb, var(--m-surface) 50%, transparent)",
    borderRadius: 12,
    border: `1px solid ${border}`,
    padding: "12px 14px",
  };
}

/** 日期玻璃盒（截止/开始/结束三字段共用）：前缀 calendar_today_rounded18，有值时尾随 close_rounded18 清除 */
function DatePickerBox({
  ms,
  placeholder,
  outline,
  onOpen,
  onClear,
}: {
  ms: number | null;
  placeholder: string;
  outline: string;
  onOpen: () => void;
  onClear: () => void;
}) {
  return (
    <div className="relative">
      <button type="button" className="flex w-full items-center gap-2 text-left" style={glassBoxStyle(outline)} onClick={onOpen}>
        <MaterialIcon name="calendar_today_rounded" size={18} color="var(--m-sub)" />
        <span
          className={`min-w-0 flex-1 truncate text-[15px] ${ms != null ? "text-[var(--m-text)]" : ""}`}
          style={ms != null ? undefined : { color: "var(--m-sub)" }}
        >
          {ms != null ? formatYmd(ms) : placeholder}
        </span>
      </button>
      {ms != null && (
        <button
          type="button"
          aria-label="清除日期"
          className="absolute top-1/2 -translate-y-1/2 pr-1"
          style={{ right: 12 }}
          onClick={(e) => {
            e.stopPropagation();
            onClear();
          }}
        >
          <MaterialIcon name="close_rounded" size={18} color="var(--m-sub)" />
        </button>
      )}
    </div>
  );
}

export interface RecordFormBottomSheetProps {
  open: boolean;
  /** 有值=编辑态（异步预填 todoTaskGet）；缺省=新建态 */
  editingTaskId?: number | null;
  /** 新建态默认归属项目（子列表项目入口携入） */
  defaultProjectId?: number | null;
  onClose: () => void;
}

type SheetKind = "priority" | "project" | null;

export function RecordFormBottomSheet({
  open,
  editingTaskId = null,
  defaultProjectId = null,
  onClose,
}: RecordFormBottomSheetProps) {
  const qc = useQueryClient();
  const outline = useOutlineBorder();

  // ---- 十字段表单状态 ----
  const [title, setTitle] = useState("");
  const [titleError, setTitleError] = useState(false);
  const [description, setDescription] = useState("");
  const [projectId, setProjectId] = useState<number | null>(null);
  const [priority, setPriority] = useState<number>(1);
  const [status, setStatus] = useState<string>("pending");
  const [dueDate, setDueDate] = useState<number | null>(null);
  const [expanded, setExpanded] = useState(false);
  const [startDate, setStartDate] = useState<number | null>(null);
  const [endDate, setEndDate] = useState<number | null>(null);
  const [hexColor, setHexColor] = useState("");

  // ---- 弹层/对话框状态 ----
  const [sheet, setSheet] = useState<SheetKind>(null);
  const [pickerTarget, setPickerTarget] = useState<"due" | "start" | "end" | null>(null);
  const [creatingProject, setCreatingProject] = useState(false);

  // 编辑态异步预填（05 §4.4 保存链第 4 条）
  const taskQuery = useQuery({
    queryKey: ["todo-task-form-prefill", editingTaskId],
    queryFn: () => todoTaskGet(editingTaskId!),
    enabled: open && editingTaskId != null,
    staleTime: 0,
  });
  /** 预填快照：update 差量对比基准（缺省键=跳过语义） */
  const prefillRef = useRef<{ id: number; task: Awaited<ReturnType<typeof todoTaskGet>> } | null>(null);

  // 打开即重置：新建取默认值；编辑待数据到达后按预填快照填充
  useEffect(() => {
    if (!open) return;
    prefillRef.current = null;
    if (editingTaskId == null) {
      setTitle("");
      setTitleError(false);
      setDescription("");
      setProjectId(defaultProjectId ?? null);
      setPriority(1);
      setStatus("pending");
      setDueDate(null);
      setStartDate(null);
      setEndDate(null);
      setHexColor("");
      setExpanded(false); // 新建默认折叠（05 §4.4 字段 7）
      return;
    }
    const t = taskQuery.data;
    if (t && prefillRef.current == null) {
      prefillRef.current = { id: t.id, task: t };
      setTitle(t.title);
      setTitleError(false);
      setDescription(t.description ?? "");
      setProjectId(t.project_id ?? null);
      setPriority(t.priority);
      setStatus(t.status);
      setDueDate(t.due_date);
      setStartDate(t.start_date);
      setEndDate(t.end_date);
      setHexColor(t.hex_color ?? "");
      // 编辑态已有 start/end/hexColor 时默认展开（05 §4.4 字段 7）
      setExpanded(!!(t.start_date || t.end_date || t.hex_color));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, editingTaskId, taskQuery.data]);

  // 项目列表（SelectSheet 选项 + 尾部快捷创建后回填）
  const projectsQuery = useQuery({
    queryKey: ["todo-project", "list"],
    queryFn: () => todoProjectList({ page: 1, page_size: 1000 }),
    enabled: open,
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const projects = projectsQuery.data ?? [];

  /**
   * 优先级选项解析：lib 层无 cfg 命令可调 → 直接采用完整硬编码映射（等价加载成功，
   * 未来接入真实命令失败时降级为 PRIORITY_FALLBACK 低/中/高）；旧值不在选项中追加兜底项
   * （05 §4.4 字段 4）。
   */
  const priorityItems = (() => {
    const base = [...loadPriorityOptions()];
    if (!base.some((o) => o.value === priority)) {
      base.push({ value: priority, label: PRIORITY_LABELS[priority] ?? `优先级 ${priority}` });
    }
    return base;
  })();
  const priorityLabelOf = (v: number) =>
    [...CFG_PRIORITY_OPTIONS].find((o) => o.value === v)?.label ??
    PRIORITY_LABELS[v] ??
    `优先级 ${v}`;

  const projectTitle =
    projectId != null ? (projects.find((p) => p.id === projectId)?.title ?? "") : "";

  /** 状态↔完成标记配对（与 detail info-section handleStatusSelect 同源语义） */
  const statusPair = () =>
    status === "done"
      ? { status: "done", done: 1, done_at: Date.now() }
      : { status, done: 0, done_at: null };

  /** update 差量载荷：仅传与预填值不同的键（02 §三要点 3 三态语义） */
  const buildDiff = (): TodoTaskUpdateInput => {
    const p = prefillRef.current?.task;
    if (!p) return {};
    const diff: TodoTaskUpdateInput = {};
    const titleTrim = title.trim();
    if (titleTrim !== p.title) diff.title = titleTrim;
    const desc = description.trim() || null;
    if (desc !== p.description) diff.description = desc;
    if (projectId !== p.project_id) diff.project_id = projectId;
    if (priority !== p.priority) diff.priority = priority;
    if (status !== p.status) Object.assign(diff, statusPair());
    if (dueDate !== p.due_date) diff.due_date = dueDate;
    if (startDate !== p.start_date) diff.start_date = startDate;
    if (endDate !== p.end_date) diff.end_date = endDate;
    if (hexColor !== p.hex_color) diff.hex_color = hexColor;
    return diff;
  };

  // ---- 保存链（05 §4.4）：校验标题非空 → create/update 全字段 → 关闭+invalidate ----
  const [saving, setSaving] = useState(false);
  const save = async () => {
    if (saving) return;
    if (!title.trim()) {
      setTitleError(true);
      return;
    }
    setSaving(true);
    try {
      if (editingTaskId == null) {
        await todoTaskCreate({
          title: title.trim(),
          description: description.trim() || null,
          project_id: projectId,
          priority,
          ...statusPair(),
          due_date: dueDate,
          start_date: startDate,
          end_date: endDate,
          hex_color: hexColor,
        });
      } else {
        const diff = buildDiff();
        if (Object.keys(diff).length > 0) await todoTaskUpdate(editingTaskId, diff);
      }
      onClose(); // 关闭抽屉
      void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
      if (editingTaskId != null) {
        void qc.invalidateQueries({ queryKey: ["todo-task-detail", editingTaskId] });
      }
    } catch {
      waitToast.destructive("保存失败");
    } finally {
      setSaving(false);
    }
  };

  // 快捷建项目（05 §4.4 字段 3）：名称 + 六色 28 圆（默认蓝 #3B82F6），成功后回选
  const [newProjectTitle, setNewProjectTitle] = useState("");
  const [newProjectColor, setNewProjectColor] = useState("#3B82F6");
  const [creatingProjectBusy, setCreatingProjectBusy] = useState(false);
  const submitCreateProject = async () => {
    const name = newProjectTitle.trim();
    if (!name || creatingProjectBusy) return;
    setCreatingProjectBusy(true);
    try {
      const created = await todoProjectCreate({ title: name, hex_color: newProjectColor });
      void qc.invalidateQueries({ queryKey: ["todo-project", "list"] });
      setProjectId(created.id);
      setCreatingProject(false);
      setNewProjectTitle("");
      setNewProjectColor("#3B82F6"); // 复位默认蓝
    } catch {
      waitToast.destructive("创建失败");
    } finally {
      setCreatingProjectBusy(false);
    }
  };

  if (!open) return null;

  const isEdit = editingTaskId != null;
  const editingLoadFailed = isEdit && taskQuery.isError;

  return (
    <BottomSheet open={open} onClose={onClose}>
      {/* 标题行：添加待办/编辑待办 + 保存钮 check_rounded（保存中 EqSpinner 20）（05 §4.4 第 1 条） */}
      <div className="flex items-center justify-between pb-1 pl-4 pr-2 pt-1">
        <h2 className="text-base font-semibold text-[var(--m-text)]">
          {isEdit ? "编辑待办" : "添加待办"}
        </h2>
        <button
          type="button"
          aria-label="保存"
          disabled={saving}
          className="grid h-12 w-12 place-items-center disabled:opacity-60"
          onClick={() => void save()}
        >
          {saving ? <EqSpinner size={20} /> : <MaterialIcon name="check_rounded" size={24} color={TODO_ACCENT} />}
        </button>
      </div>

      {isEdit && taskQuery.isPending && !editingLoadFailed ? (
        /* 编辑态加载：EqSpinner 居中 48px（05 §4.4 第 4 条） */
        <div className="grid place-items-center py-24">
          <EqSpinner size={48} />
        </div>
      ) : editingLoadFailed ? (
        /* 编辑态失败：记录不存在或加载失败 + 返回钮 */
        <div className="flex flex-col items-center gap-4 py-24">
          <p className="text-sm text-[var(--m-sub)]">记录不存在或加载失败</p>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg px-4 py-2 text-sm font-medium active:bg-black/[.04] dark:active:bg-white/[.04]"
            style={{ color: TODO_ACCENT }}
          >
            返回
          </button>
        </div>
      ) : (
        /* 内容 ListView padding 16 + 字段间距 12（space-y-3）（05 §4.4） */
        <div className="space-y-3 px-4 pb-8 pt-1">
          {/* 字段 1：标题*（errorText 请输入标题） */}
          <div>
            <SectionBar text="标题" />
            <input
              value={title}
              maxLength={200}
              onChange={(e) => {
                setTitle(e.target.value);
                if (titleError) setTitleError(false);
              }}
              className={`w-full rounded-xl bg-black/[.05] px-3.5 py-3 text-[15px] text-[var(--m-text)] outline-none placeholder:text-[var(--m-sub)] focus:border-[#3B82F6] dark:bg-white/[.07] ${
                titleError ? "border" : "border border-transparent"
              }`}
              style={titleError ? { borderColor: "#F44336" } : undefined}
              placeholder="请输入标题"
            />
            {titleError && (
              <p className="pt-1 text-xs" style={{ color: "#F44336" }}>
                请输入标题
              </p>
            )}
          </div>

          {/* 字段 2：描述 multiline */}
          <div>
            <FieldLabel text="描述" />
            <textarea
              value={description}
              rows={3}
              maxLength={2000}
              onChange={(e) => setDescription(e.target.value)}
              className="w-full resize-none rounded-xl bg-black/[.05] px-3.5 py-3 text-[15px] leading-relaxed text-[var(--m-text)] outline-none placeholder:text-[var(--m-sub)] dark:bg-white/[.07]"
              placeholder="请输入描述"
            />
          </div>

          {/* 字段 3：项目（SelectField 等价 + 尾部 add_circle_outline_rounded28 快捷建项目） */}
          <div>
            <FieldLabel text="项目" />
            <div className="flex items-center gap-2">
              <button
                type="button"
                className="flex min-w-0 flex-1 items-center gap-2 text-left"
                style={glassBoxStyle(outline)}
                onClick={() => setSheet("project")}
              >
                {projectId != null && (
                  <span
                    className="h-3 w-3 shrink-0 rounded-[4px]"
                    style={{ background: projects.find((p) => p.id === projectId)?.hex_color || TODO_ACCENT }}
                  />
                )}
                <span
                  className="min-w-0 flex-1 truncate text-[15px]"
                  style={{ color: projectId != null ? "var(--m-text)" : "var(--m-sub)" }}
                >
                  {projectId != null ? projectTitle || "加载中…" : "无项目"}
                </span>
              </button>
              <button
                type="button"
                aria-label="新建项目"
                className="grid h-8 w-8 shrink-0 place-items-center text-[var(--m-sub)] active:opacity-60"
                onClick={() => setCreatingProject(true)}
              >
                <MaterialIcon name="add_circle_outline_rounded" size={28} />
              </button>
            </div>
          </div>

          {/* 字段 4：优先级（cfg 选项 SelectSheet；旧值不在选项中追加兜底项） */}
          <div>
            <FieldLabel text="优先级" />
            <button type="button" className="flex w-full items-center gap-2 text-left" style={glassBoxStyle(outline)} onClick={() => setSheet("priority")}>
              {PRIORITY_COLOR[priority] ? (
                <span className="h-2.5 w-2.5 shrink-0 rounded-full" style={{ background: PRIORITY_COLOR[priority] }} />
              ) : null}
              <span className="min-w-0 flex-1 truncate text-[15px] text-[var(--m-text)]">{priorityLabelOf(priority)}</span>
              <MaterialIcon name="keyboard_arrow_right_rounded" size={20} color="var(--m-sub)" />
            </button>
          </div>

          {/* 字段 5：状态 SegmentedButton 三段（选中底 accent@15% 前景 accent） */}
          <div>
            <FieldLabel text="状态" />
            <div className="flex overflow-hidden rounded-[20px]" style={{ border: `1px solid ${outline}` }}>
              {STATUS_ITEMS.map((s, i) => {
                const active = status === s.key;
                return (
                  <button
                    key={s.key}
                    type="button"
                    className={`h-10 flex-1 text-sm ${i > 0 ? "border-l" : ""}`}
                    style={{
                      borderColor: outline,
                      background: active ? "color-mix(in srgb, #3B82F6 15%, transparent)" : "transparent",
                      color: active ? TODO_ACCENT : "var(--m-sub)",
                      fontWeight: active ? 500 : 400,
                    }}
                    onClick={() => setStatus(s.key)}
                  >
                    {s.label}
                  </button>
                );
              })}
            </div>
          </div>

          {/* 字段 6：截止日期（WaitDatePicker 注入玻璃盒） */}
          <div>
            <FieldLabel text="截止日期" />
            <DatePickerBox
              ms={dueDate}
              placeholder="请选择日期"
              outline={outline}
              onOpen={() => setPickerTarget("due")}
              onClear={() => setDueDate(null)}
            />
          </div>

          {/* 字段 7：更多选项折叠行（编辑态已有 start/end/hexColor 时默认展开） */}
          <button
            type="button"
            className="flex w-full items-center gap-1 rounded-lg py-1 text-left active:opacity-70"
            onClick={() => setExpanded((v) => !v)}
          >
            <MaterialIcon name={expanded ? "expand_less_rounded" : "expand_more_rounded"} size={22} color={TODO_ACCENT} />
            <span className="text-sm text-[var(--m-text)]">更多选项</span>
          </button>

          {expanded && (
            <>
              {/* 字段 8：开始日期 */}
              <div>
                <FieldLabel text="开始日期" />
                <DatePickerBox
                  ms={startDate}
                  placeholder="请选择日期"
                  outline={outline}
                  onOpen={() => setPickerTarget("start")}
                  onClear={() => setStartDate(null)}
                />
              </div>

              {/* 字段 9：结束日期 */}
              <div>
                <FieldLabel text="结束日期" />
                <DatePickerBox
                  ms={endDate}
                  placeholder="请选择日期"
                  outline={outline}
                  onOpen={() => setPickerTarget("end")}
                  onClear={() => setEndDate(null)}
                />
              </div>

              {/* 字段 10：颜色（Wrap gap10 七个 32×32 圆；选中 border 3px accent 否则 1px outlineVariant） */}
              <div>
                <FieldLabel text="颜色" />
                <div className="flex flex-wrap gap-2.5">
                  {FORM_COLORS.map((c) => (
                    <button
                      key={c || "none"}
                      type="button"
                      aria-label={c ? `颜色 ${c}` : "无颜色"}
                      className="grid h-8 w-8 place-items-center rounded-full"
                      style={{
                        background: c || "transparent",
                        border: hexColor === c ? `3px solid ${TODO_ACCENT}` : `1px solid ${outline}`,
                      }}
                      onClick={() => setHexColor(c)}
                    >
                      {!c && <MaterialIcon name="block_rounded" size={16} color="var(--m-sub)" />}
                    </button>
                  ))}
                </div>
              </div>
            </>
          )}

          {/* 底部安全区 spacer */}
          <div className="m-safe-bottom" aria-hidden />
        </div>
      )}

      {/* 优先级选择弹层（cfg 硬编码映射 + 兜底项） */}
      <SelectSheet
        open={sheet === "priority"}
        title="优先级"
        items={priorityItems.map((o) => ({ value: o.value, label: o.label, colorDot: PRIORITY_COLOR[o.value] || undefined }))}
        current={priority}
        onSelect={(v) => setPriority(v)}
        onClose={() => setSheet(null)}
      />

      {/* 项目选择弹层：首项"无项目"(哨兵 "") + 全部项目 */}
      <SelectSheet
        open={sheet === "project"}
        title="项目"
        items={[
          { value: "", label: "无项目" },
          ...projects.map((p) => ({
            value: String(p.id),
            label: p.title,
            colorDot: p.hex_color || TODO_ACCENT,
          })),
        ]}
        current={projectId != null ? String(projectId) : ""}
        onSelect={(v) => setProjectId(v === "" ? null : Number(v))}
        onClose={() => setSheet(null)}
      />

      {/* 三个日期字段共用的 WaitDatePickerSheet */}
      <WaitDatePickerSheet
        open={pickerTarget != null}
        mode="date"
        initial={pickerTarget === "due" ? dueDate : pickerTarget === "start" ? startDate : endDate}
        onConfirm={(d) => {
          const ms = d ? d.getTime() : null;
          if (pickerTarget === "due") setDueDate(ms);
          else if (pickerTarget === "start") setStartDate(ms);
          else if (pickerTarget === "end") setEndDate(ms);
        }}
        onClose={() => setPickerTarget(null)}
      />

      {/* 快捷建项目对话框：名称 input + 六色 28 圆（默认蓝 #3B82F6）（05 §4.4 字段 3） */}
      {creatingProject && (
        <div
          className="fixed inset-0 z-[60] grid place-items-center bg-black/40 p-6"
          onClick={() => !creatingProjectBusy && setCreatingProject(false)}
        >
          <div
            className="w-full max-w-xs rounded-[20px] p-6"
            style={{ background: "var(--m-surface)" }}
            onClick={(e) => e.stopPropagation()}
          >
            <h3 className="text-base font-semibold text-[var(--m-text)]">新建项目</h3>
            <label htmlFor="form-new-project-title" className="mt-4 block text-xs text-[var(--m-sub)]">
              项目名称
            </label>
            <input
              id="form-new-project-title"
              autoFocus
              value={newProjectTitle}
              maxLength={50}
              onChange={(e) => setNewProjectTitle(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void submitCreateProject();
              }}
              className="mt-1 w-full rounded-lg border border-transparent bg-black/[.05] px-3 py-2 text-sm text-[var(--m-text)] outline-none placeholder:text-[var(--m-sub)] focus:border-[#3B82F6] dark:bg-white/[.07]"
              placeholder="请输入项目名称"
            />
            <div className="mt-4 flex flex-wrap gap-2.5">
              {PROJECT_COLORS.map((c) => (
                <button
                  key={c}
                  type="button"
                  aria-label={`颜色 ${c}`}
                  className="h-7 w-7 rounded-full"
                  style={{
                    background: c,
                    border: newProjectColor === c ? `3px solid ${TODO_ACCENT}` : "1px solid rgba(121,116,126,.3)",
                  }}
                  onClick={() => setNewProjectColor(c)}
                />
              ))}
            </div>
            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                className="rounded-lg px-4 py-2 text-sm text-[var(--m-sub)]"
                onClick={() => !creatingProjectBusy && setCreatingProject(false)}
              >
                取消
              </button>
              <button
                type="button"
                disabled={!newProjectTitle.trim() || creatingProjectBusy}
                className="rounded-lg px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
                style={{ background: TODO_ACCENT }}
                onClick={() => void submitCreateProject()}
              >
                创建
              </button>
            </div>
          </div>
        </div>
      )}
    </BottomSheet>
  );
}
