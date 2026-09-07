/**
 * ReminderToast —— 到期提醒的自定义 toast 内容（sonner toast.custom）
 *
 * 系统通知只有一条正文无交互入口；此 in-app toast 承载推迟操作
 * （10 分钟 / 30 分钟 / 1 小时，删旧建新语义见 reminder-snooze.ts）
 * 与「查看任务」详情入口（§7-③ selectedTaskId 规范）。
 * 样式对齐 sonner 默认 toast：normal-bg/text/border 令牌 + warning 橙色
 * 图标条，与 sonner.tsx 包装的设计令牌保持一致。
 */
import { useState } from "react";
import { toast } from "sonner";
import { BellRing, ExternalLink, X } from "lucide-react";

import { SNOOZE_PRESETS, snoozeTargetLabel } from "./reminder-snooze";

export interface ReminderToastProps {
  title: string;
  remindAt: number;
  /** 推迟按钮回调（minutes 档位）；编排与失败提示在组件内完成 */
  onSnooze: (minutes: number) => Promise<boolean>;
  /** 查看任务按钮回调（打开详情抽屉）；调用后 toast 关闭由组件完成 */
  onViewTask: () => void;
  onDone: () => void;
}

export function ReminderToast({
  title,
  remindAt,
  onSnooze,
  onViewTask,
  onDone,
}: ReminderToastProps) {
  const [busy, setBusy] = useState(false);

  async function snooze(minutes: number) {
    if (busy) return;
    setBusy(true);
    const ok = await onSnooze(minutes);
    onDone();
    if (ok) {
      toast.success(
        `已推迟到 ${new Date(remindAt + minutes * 60_000).toLocaleString("zh-CN", {
          hour: "2-digit",
          minute: "2-digit",
        })}`,
        { description: title, duration: 4_000 },
      );
    } else {
      toast.error("推迟失败，请稍后重试", { duration: 4_000 });
    }
  }

  /** 查看任务：打开详情抽屉（§7-③ selectedTaskId 规范，导航 /todo） */
  function viewTask() {
    onViewTask();
    onDone();
  }

  return (
    <div
      data-testid="reminder-toast"
      className="pointer-events-auto flex w-full gap-3 rounded-lg border p-4 shadow-lg"
      style={{
        background: "var(--normal-bg, var(--popover))",
        color: "var(--normal-text, var(--popover-foreground))",
        borderColor: "var(--normal-border, var(--border))",
      }}
    >
      <div className="mt-0.5 shrink-0 text-orange-500" aria-hidden>
        <BellRing className="size-5" />
      </div>
      <div className="min-w-0 flex-1">
        <p className="break-words text-sm font-medium leading-tight">{title}</p>
        <p className="mt-1 text-xs opacity-70">
          待办提醒 ·{" "}
          {new Date(remindAt).toLocaleString("zh-CN", {
            hour: "2-digit",
            minute: "2-digit",
          })}
        </p>
        <div className="mt-2.5 flex flex-wrap gap-2">
          <button
            type="button"
            data-testid="view-task"
            title="打开任务详情"
            onClick={viewTask}
            className="inline-flex h-7 items-center gap-1 rounded-md bg-accent px-2.5 text-xs font-medium text-accent-foreground transition-colors hover:bg-accent/85"
          >
            <ExternalLink className="size-3" />
            查看任务
          </button>
          {SNOOZE_PRESETS.map((p) => (
            <button
              key={p.minutes}
              type="button"
              disabled={busy}
              data-testid={`snooze-${p.minutes}`}
              title={`推迟到 ${snoozeTargetLabel(remindAt, p.minutes)}`}
              onClick={() => void snooze(p.minutes)}
              className="h-7 rounded-md border px-2.5 text-xs font-medium transition-colors hover:bg-accent hover:text-accent-foreground disabled:pointer-events-none disabled:opacity-50"
            >
              推迟 {p.label}
            </button>
          ))}
        </div>
      </div>
      <button
        type="button"
        aria-label="关闭提醒"
        className="mt-0.5 shrink-0 rounded-md p-1 opacity-60 transition-opacity hover:opacity-100"
        onClick={onDone}
      >
        <X className="size-4" />
      </button>
    </div>
  );
}
