/**
 * QuickAddBar — 底部常驻快速输入栏（04 文档 §3.5 复刻；背景与应用背景同色）
 *
 * 输入后浮现四个快捷 Popover（截止日期 / 提醒时间 / 优先级 / 项目）；
 * Enter 提交并保持焦点连续录入；Esc 重置。
 * 提醒时间为独立实体：任务创建成功后追加 todo_reminders_create。
 */
import { useRef, useState } from "react";
import { format } from "date-fns";
import { zhCN } from "date-fns/locale";
import { Calendar, CalendarPlus, Clock, Flag, Folder, Plus } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { WaitCalendar } from "@/components/ui/wait-calendar";
import { DateTimePicker } from "@/components/business/date-picker";
import { todoReminderCreate, todoTaskCreate, type TodoProject } from "@/lib/tauri";
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
  /** 提醒时间草稿（DateTimePicker 值格式 YYYY-MM-DDTHH:MM；空 = 不提醒） */
  const [remindDraft, setRemindDraft] = useState("");
  const [projectId, setProjectId] = useState<number | null | "default">("default");

  const hasInput = title.trim().length > 0;
  const effectiveProjectId =
    projectId === "default" ? (defaultProjectId ?? null) : projectId;

  const reset = () => {
    setTitle("");
    setPriority(0);
    setDueDate(null);
    setRemindDraft("");
    setProjectId("default");
  };

  const submit = async () => {
    const t = title.trim();
    if (!t) return;
    try {
      const created = await todoTaskCreate({
        title: t,
        priority,
        due_date: dueDate ? dueDate.getTime() : null,
        project_id: effectiveProjectId,
      });
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
            if (e.key === "Enter") void submit();
            if (e.key === "Escape") reset();
          }}
          placeholder="添加任务"
          className="h-7 min-w-0 flex-1 border-0 bg-transparent px-1 shadow-none focus-visible:ring-0"
        />

        {/* 有输入后才浮现的快捷区（shrink-0 防止被输入框挤压变形） */}
        {hasInput && (
          <div className="flex shrink-0 items-center gap-0.5">
            {/* 截止日期 */}
            <Popover>
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
              {/* 宽度需设上限：DayPicker 表格 w-full+aspect-square 在无界 w-auto 下无法收敛 */}
              <PopoverContent align="end" className="w-auto min-w-[280px] max-w-[320px] p-3">
                <p className="mb-2 text-sm font-medium">截止日期</p>
                <WaitCalendar
                  mode="single"
                  selected={dueDate ?? undefined}
                  onSelect={(d) => setDueDate(d ?? null)}
                />
                <div className="mt-2 flex justify-end gap-2 border-t pt-2">
                  {dueDate && (
                    <Button variant="link" size="sm" onClick={() => setDueDate(null)}>
                      清除
                    </Button>
                  )}
                  <Button size="sm" variant="outline" onClick={() => setDueDate(new Date())}>
                    今天
                  </Button>
                </div>
              </PopoverContent>
            </Popover>

            {/* 提醒时间 */}
            <Popover>
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
            <Popover>
              <PopoverTrigger asChild>
                <Button
                  variant="ghost"
                  size="icon"
                  className="h-7 w-7"
                  style={{ color: PRIORITY_COLOR[priority] || undefined }}
                >
                  <Flag className="size-4" />
                </Button>
              </PopoverTrigger>
              <PopoverContent align="end" className="w-40 p-1">
                {PRIORITY_LABELS.map((label, i) => (
                  <button
                    key={i}
                    type="button"
                    onClick={() => setPriority(i)}
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
            <Popover>
              <PopoverTrigger asChild>
                <Button variant="ghost" size="icon" className="h-7 w-7">
                  <Folder className="size-4" />
                </Button>
              </PopoverTrigger>
              <PopoverContent align="end" className="w-56 p-1">
                <button
                  type="button"
                  onClick={() => setProjectId(null)}
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
                    onClick={() => setProjectId(p.id)}
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
