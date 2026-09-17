/**
 * DangerousConfirmDialog — 危险操作五秒时停确认弹层
 *
 * 口径：不可撤销的数据覆盖/丢失类操作（全量备份恢复、以本机为准重置云端、
 * 改密换钥等）统一走此组件。确认钮在 `holdSeconds` 倒计时走完前禁用，
 * 强制阅读后果文案，防误触。
 *
 * 实现注意：刻意不用 Radix AlertDialog（Portal 传送门），而用页面内联
 * fixed 遮罩 + 白框。实测某版本 WebView2 下 Radix Portal 的 Content
 * 挂载后画不出来（只有灰罩没有白框、页面被焦点陷阱冻住，Chromium 正常），
 * 内联实现在同环境一次点亮。为避开该坑，本组件及恢复确认框统一内联口径；
 * 其余普通确认仍可用 shadcn AlertDialog 原语（已验证可显示）。
 */

import { useEffect, useRef, useState, type ReactNode } from "react";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

/** 默认强制冷静期（秒）：与恢复页 rekey 口径一致 */
export const DANGEROUS_HOLD_SECONDS = 5;

/**
 * 确认钮文案：倒计时未走完显示剩余秒数，走完显示正常确认文案。
 * 抽纯函数便于单测（组件内倒计时逻辑不进单测，沿仓库纯函数共置惯例）。
 */
export function formatHoldLabel(remaining: number, confirmLabel: string): string {
  if (remaining > 0) return `请阅读后果（${remaining}s）`;
  return confirmLabel;
}

interface DangerousConfirmDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description: ReactNode;
  /** 倒计时走完后的确认钮文案，默认“确认” */
  confirmLabel?: string;
  /** 强制冷静期秒数，默认 5 */
  holdSeconds?: number;
  /** 执行中（禁用双钮，确认钮转圈由调用方文案体现） */
  busy?: boolean;
  /** 点确认后的回调（调用方负责关层清状态） */
  onConfirm: () => void;
  /** 标题与按钮之间的补充内容（如恢复预览；渲染在普通 div 内） */
  body?: ReactNode;
  /** 弹层宽度覆写（如预览内容较宽时传 "sm:max-w-xl"） */
  contentClassName?: string;
}

export function DangerousConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel = "确认",
  holdSeconds = DANGEROUS_HOLD_SECONDS,
  busy = false,
  onConfirm,
  body,
  contentClassName,
}: DangerousConfirmDialogProps) {
  const [countdown, setCountdown] = useState(holdSeconds);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  // 开层从头计时，走完停表；关层/卸载复位，下次打开重计
  useEffect(() => {
    if (!open) {
      if (timer.current) clearInterval(timer.current);
      timer.current = null;
      setCountdown(holdSeconds);
      return;
    }
    setCountdown(holdSeconds);
    timer.current = setInterval(() => {
      setCountdown((n) => {
        if (n <= 1) {
          if (timer.current) clearInterval(timer.current);
          timer.current = null;
          return 0;
        }
        return n - 1;
      });
    }, 1000);
    return () => {
      if (timer.current) clearInterval(timer.current);
      timer.current = null;
    };
  }, [open, holdSeconds]);

  // 开层期间锁背景滚动（Radix 原语自带行为，内联实现手动补齐）
  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, [open]);

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center bg-black/50 p-4"
      onClick={() => {
        if (!busy) onOpenChange(false);
      }}
    >
      <div
        role="alertdialog"
        aria-modal="true"
        aria-label={title}
        className={cn(
          "max-h-[85vh] w-full overflow-auto rounded-lg border bg-background p-6 shadow-lg sm:max-w-lg",
          contentClassName,
        )}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex flex-col gap-2">
          <h2 className="text-lg leading-none font-semibold">{title}</h2>
          <div className="text-sm break-words text-muted-foreground">{description}</div>
        </div>
        {body}
        <div className="mt-4 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="outline" disabled={busy} onClick={() => onOpenChange(false)}>
            取消
          </Button>
          <Button
            className="bg-destructive text-white hover:bg-destructive/90"
            disabled={countdown > 0 || busy}
            onClick={onConfirm}
          >
            {formatHoldLabel(countdown, confirmLabel)}
          </Button>
        </div>
      </div>
    </div>
  );
}
