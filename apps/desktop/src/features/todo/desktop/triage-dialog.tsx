/**
 * TriageDialog — 收件箱分诊（F2，docs/13 §五 F2 / §八 U2）
 *
 * Things/OmniFocus Inbox「捕获→澄清」的产品化：未分组任务一次一张卡逐条
 * 决定归属——归入项目（1-9 键或下拉）/ 排今天·明天（T/M，18 点口径同
 * 视图创建默认）/ 清日期（N）/ 优先级循环（P：无→高→紧急）/ 软删（D，
 * 5 秒撤销窗）/ 跳过（Enter/S）。字段修正（N/P）不出队，归属动作出队。
 *
 * - 队列打开时快照（shared/triage 口径）：写操作经 db-change 失效全量缓存，
 *   队列跟着缓存走会在连击时抖动；
 * - Backspace 撤销最近一次**字段动作**（移项目/排期/清日期/优先级）并把该卡
 *   拉回；删除的撤销走 use-undoable-delete 的 5 秒延迟提交通道（独立于本栈，
 *   且删除后**不**手动失效 todo_tasks——延迟提交前重拉会把行从后端带回来）；
 * - 结束给「已分诊 X · 跳过 Y · 删除 Z」汇总 + 「收件箱已清空」正反馈。
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { CalendarX2, CheckCircle2, Flag, Sun, Sunrise, Trash2, Undo2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { hideFromQueries, useUndoableDeleteAction } from "@/hooks/use-undoable-delete";
import {
  todoTaskDelete,
  todoTaskUpdate,
  type TodoProject,
  type TodoTaskListItem,
} from "@/lib/tauri";
import { PRIORITY_LABELS, TODO_ACCENT } from "../shared/constants";
import {
  collectTriageQueue,
  formatTriageSummary,
  nextTriagePriority,
  projectKeyMap,
} from "../shared/triage";
import { atViewDueHour } from "../shared/view-create-defaults";

/** 「今天/明天」排期目标毫秒（当日 18:00，与视图创建默认同口径） */
function triageDueMs(dayOffset: 0 | 1): number {
  const now = new Date();
  const day = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  day.setDate(day.getDate() + dayOffset);
  return atViewDueHour(day.getTime());
}

/** 字段动作分类：归属动作（出队）撤销时回退对应计数并拉回卡片 */
type TriageActionKind = "move" | "schedule" | "edit";

/** 字段动作的撤销记录（删除不进此栈，走延迟提交通道） */
interface TriageHistoryEntry {
  taskId: number;
  /** 动作发生时该卡在快照队列里的位置（撤销后拉回） */
  queueIndex: number;
  kind: TriageActionKind;
  before: { project_id?: number | null; due_date?: number | null; priority?: number };
  label: string;
}

interface TriageDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 全量任务集（壳层单份缓存；队列在其上归集） */
  tasks: TodoTaskListItem[];
  projects: TodoProject[];
}

export function TriageDialog({ open, onOpenChange, tasks, projects }: TriageDialogProps) {
  const qc = useQueryClient();
  const undoableDelete = useUndoableDeleteAction();

  const [queue, setQueue] = useState<TodoTaskListItem[]>([]);
  const [idx, setIdx] = useState(0);
  const [moved, setMoved] = useState(0);
  const [scheduled, setScheduled] = useState(0);
  const [skipped, setSkipped] = useState(0);
  const [deleted, setDeleted] = useState(0);
  const [history, setHistory] = useState<TriageHistoryEntry[]>([]);
  const [busy, setBusy] = useState(false);

  // 打开即快照队列（关闭再打开重算——期间可能有新捕获）。
  // 只依赖 open：写库后的 refetch 会换 tasks 引用，跟着重置会把进行中的
  // 队列/撤销栈整个清掉（分诊到一半被拉回起点）——tasks 经 ref 取当帧值
  const tasksRef = useRef(tasks);
  tasksRef.current = tasks;
  useEffect(() => {
    if (open) {
      setQueue(collectTriageQueue(tasksRef.current));
      setIdx(0);
      setMoved(0);
      setScheduled(0);
      setSkipped(0);
      setDeleted(0);
      setHistory([]);
    }
  }, [open]);

  const current = queue[idx];
  const finished = idx >= queue.length;
  const keyMap = useMemo(() => projectKeyMap(projects), [projects]);
  const activeProjects = useMemo(() => projects.filter((p) => !p.is_archived), [projects]);
  const keyIds = useMemo(() => new Set([...keyMap.values()].map((p) => p.id)), [keyMap]);
  const overflowProjects = activeProjects.filter((p) => !keyIds.has(p.id));

  /** 立即提交类写动作后的缓存刷新（未分组计数随之收敛） */
  const refreshTasks = () => void qc.invalidateQueries({ queryKey: ["todo_tasks"] });

  const pushHistory = (entry: TriageHistoryEntry) => setHistory((h) => [...h, entry]);

  /** 归入项目：归属动作（出队）。数字键 1-9 与鼠标下拉同路。 */
  const assign = async (project: TodoProject) => {
    if (busy || current == null) return;
    setBusy(true);
    try {
      await todoTaskUpdate(current.id, { project_id: project.id });
      pushHistory({
        taskId: current.id,
        queueIndex: idx,
        kind: "move",
        before: { project_id: null },
        label: `已归入「${project.title}」`,
      });
      setMoved((n) => n + 1);
      setIdx((i) => i + 1);
      refreshTasks();
    } finally {
      setBusy(false);
    }
  };

  /** 排今天/明天（18 点）：归属动作（出队——已排期的未分组任务会进今天/明天视图） */
  const schedule = async (dayOffset: 0 | 1) => {
    if (busy || current == null) return;
    setBusy(true);
    try {
      const before = { due_date: current.due_date };
      await todoTaskUpdate(current.id, { due_date: triageDueMs(dayOffset) });
      pushHistory({
        taskId: current.id,
        queueIndex: idx,
        kind: "schedule",
        before,
        label: dayOffset === 0 ? "已排到今天" : "已排到明天",
      });
      setScheduled((n) => n + 1);
      setIdx((i) => i + 1);
      refreshTasks();
    } finally {
      setBusy(false);
    }
  };

  /** 清日期：字段修正（不出队——去掉过期日期后仍需决定归属） */
  const clearDue = async () => {
    if (busy || current == null || current.due_date == null) return;
    setBusy(true);
    try {
      const before = { due_date: current.due_date };
      await todoTaskUpdate(current.id, { due_date: null });
      pushHistory({ taskId: current.id, queueIndex: idx, kind: "edit", before, label: "已清除日期" });
      setQueue((q) => q.map((t) => (t.id === current.id ? { ...t, due_date: null } : t)));
      refreshTasks();
    } finally {
      setBusy(false);
    }
  };

  /** 优先级循环（无→高→紧急）：字段修正（不出队） */
  const bumpPriority = async () => {
    if (busy || current == null) return;
    const next = nextTriagePriority(current.priority);
    if (next === current.priority) return;
    setBusy(true);
    try {
      const before = { priority: current.priority };
      await todoTaskUpdate(current.id, { priority: next });
      pushHistory({
        taskId: current.id,
        queueIndex: idx,
        kind: "edit",
        before,
        label: `优先级 → ${PRIORITY_LABELS[next]}`,
      });
      setQueue((q) => q.map((t) => (t.id === current.id ? { ...t, priority: next } : t)));
      refreshTasks();
    } finally {
      setBusy(false);
    }
  };

  /** 软删：延迟提交（5 秒撤销窗，撤销走 toast 按钮）。不进 Backspace 栈、
   *  不手动失效 todo_tasks——延迟提交前重拉会把行从后端带回来 */
  const remove = () => {
    if (busy || current == null) return;
    const task = current;
    undoableDelete({
      entityLabel: "任务",
      recordName: task.title,
      commit: () => todoTaskDelete(task.id),
      hide: (client) => hideFromQueries(client, ["todo_tasks"], task.id),
    });
    setDeleted((n) => n + 1);
    setIdx((i) => i + 1);
  };

  const skip = () => {
    if (current == null) return;
    setSkipped((n) => n + 1);
    setIdx((i) => i + 1);
  };

  /** Backspace：回滚最近一次字段动作；归属动作的撤销把卡片拉回队首 */
  const undoLast = async () => {
    if (busy || history.length === 0) return;
    setBusy(true);
    try {
      const entry = history[history.length - 1];
      await todoTaskUpdate(entry.taskId, entry.before);
      setHistory((h) => h.slice(0, -1));
      if (entry.kind === "move") setMoved((n) => Math.max(0, n - 1));
      if (entry.kind === "schedule") setScheduled((n) => Math.max(0, n - 1));
      if (entry.kind !== "edit") setIdx(entry.queueIndex);
      setQueue((q) =>
        q.map((t) => (t.id === entry.taskId ? { ...t, ...entry.before } : t)),
      );
      refreshTasks();
    } finally {
      setBusy(false);
    }
  };

  // ---- 键盘流（仅弹窗打开期间挂；修饰键/输入控件/Radix 弹层内不抢键。
  // 无依赖数组：每次渲染重挂，处理器闭包始终是最新状态（弹窗期渲染频率极低） ----
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      const el = e.target as HTMLElement | null;
      if (el?.closest('input, textarea, [contenteditable="true"], [role="listbox"]')) return;
      const k = e.key.toLowerCase();
      if (/^[1-9]$/.test(e.key)) {
        const p = keyMap.get(Number(e.key));
        if (p) void assign(p);
        return;
      }
      switch (k) {
        case "enter":
        case "s":
          e.preventDefault();
          skip();
          break;
        case "backspace":
          e.preventDefault();
          void undoLast();
          break;
        case "t":
          void schedule(0);
          break;
        case "m":
          void schedule(1);
          break;
        case "n":
          void clearDue();
          break;
        case "p":
          void bumpPriority();
          break;
        case "d":
        case "delete":
          remove();
          break;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const dueLabel = (ms: number | null) => {
    if (ms == null) return null;
    const d = new Date(ms);
    const hm =
      d.getHours() === 0 && d.getMinutes() === 0
        ? ""
        : ` ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
    return `${d.getMonth() + 1}/${d.getDate()}${hm}`;
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-xl">
        <DialogHeader>
          <DialogTitle>收件箱分诊</DialogTitle>
          <DialogDescription>
            {finished
              ? "本轮流清了"
              : "逐条决定归属：数字键归入项目 · T 今天 · M 明天 · N 清日期 · P 优先级 · D 删除 · Backspace 撤销"}
          </DialogDescription>
        </DialogHeader>

        {/* 进度条（与周回顾同版式） */}
        <div className="flex items-center gap-2 text-xs text-muted-foreground">
          <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-muted">
            <div
              className="h-full rounded-full bg-primary transition-all"
              style={{
                width: `${queue.length === 0 ? 100 : (Math.min(idx, queue.length) / queue.length) * 100}%`,
              }}
            />
          </div>
          <span className="tabular-nums">
            {Math.min(idx, queue.length)} / {queue.length}
          </span>
        </div>

        {finished ? (
          <div className="flex flex-col items-center gap-2 py-8 text-muted-foreground">
            <CheckCircle2 className="size-8 text-emerald-500" />
            <p className="text-sm font-medium text-foreground">收件箱已清空</p>
            <p className="text-xs">{formatTriageSummary(moved, scheduled, skipped, deleted)}</p>
          </div>
        ) : (
          current != null && (
            <>
              {/* 当前卡：标题 + 元信息（截止/优先级） */}
              <div className="rounded-lg border px-4 py-3" data-testid="triage-card">
                <p className="text-base font-medium leading-snug">{current.title}</p>
                <p className="mt-1 text-xs text-muted-foreground">
                  {current.due_date != null && <>截止 {dueLabel(current.due_date)} · </>}
                  {current.priority > 0 && <>优先级 {PRIORITY_LABELS[current.priority]} · </>}
                  未分组
                </p>
              </div>

              {/* 项目快捷位：1-9 键位映射；超出项目数走下拉（鼠标路径） */}
              <div className="grid grid-cols-3 gap-1.5">
                {[...keyMap.entries()].map(([digit, p]) => (
                  <Button
                    key={digit}
                    variant="outline"
                    size="sm"
                    disabled={busy}
                    onClick={() => void assign(p)}
                    className="justify-start"
                  >
                    <span
                      className="size-2 shrink-0 rounded-full"
                      style={{ background: p.hex_color || TODO_ACCENT }}
                    />
                    <span className="min-w-0 flex-1 truncate text-left">{p.title}</span>
                    <KeyHint>{String(digit)}</KeyHint>
                  </Button>
                ))}
                {overflowProjects.length > 0 && (
                  <Select
                    onValueChange={(v) => {
                      const p = projects.find((x) => x.id === Number(v));
                      if (p) void assign(p);
                    }}
                  >
                    <SelectTrigger className="h-8 text-xs" aria-label="归入其他项目">
                      <SelectValue placeholder="其他项目…" />
                    </SelectTrigger>
                    <SelectContent>
                      {overflowProjects.map((p) => (
                        <SelectItem key={p.id} value={String(p.id)}>
                          {p.title}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              </div>

              {/* 动作行 */}
              <div className="flex flex-wrap items-center gap-1.5">
                <Button variant="outline" size="sm" disabled={busy} onClick={() => void schedule(0)}>
                  <Sun className="size-3.5" /> 今天 <KeyHint>T</KeyHint>
                </Button>
                <Button variant="outline" size="sm" disabled={busy} onClick={() => void schedule(1)}>
                  <Sunrise className="size-3.5" /> 明天 <KeyHint>M</KeyHint>
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  disabled={busy || current.due_date == null}
                  onClick={() => void clearDue()}
                >
                  <CalendarX2 className="size-3.5" /> 清日期 <KeyHint>N</KeyHint>
                </Button>
                <Button variant="outline" size="sm" disabled={busy} onClick={() => void bumpPriority()}>
                  <Flag className="size-3.5" />
                  {current.priority > 0 ? PRIORITY_LABELS[current.priority] : "优先级"} <KeyHint>P</KeyHint>
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={busy}
                  className="text-destructive hover:text-destructive"
                  onClick={remove}
                >
                  <Trash2 className="size-3.5" /> 删除 <KeyHint>D</KeyHint>
                </Button>
              </div>
            </>
          )
        )}

        <DialogFooter className="gap-2">
          <Button variant="ghost" size="sm" disabled={history.length === 0} onClick={() => void undoLast()}>
            <Undo2 className="size-3.5" /> 撤销上一条 <KeyHint>⌫</KeyHint>
          </Button>
          {!finished && (
            <Button variant="outline" size="sm" onClick={skip}>
              跳过 <KeyHint>Enter</KeyHint>
            </Button>
          )}
          <Button className="ml-auto" onClick={() => onOpenChange(false)}>
            {finished ? "完成" : "收起"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** 键位角标（纯展示） */
function KeyHint({ children }: { children: string }) {
  return <span className="ml-0.5 text-[10px] text-muted-foreground">{children}</span>;
}
