/**
 * DangerousConfirmDialog — 危险操作五秒时停确认弹层
 *
 * 口径：不可撤销的数据覆盖/丢失类操作（全量备份恢复、以本机为准重置云端、
 * 改密换钥等）统一走此组件。确认钮在 `holdSeconds` 倒计时走完前禁用，
 * 强制阅读后果文案，防误触。
 *
 * 门控模式（`holdPaused`）：带异步前置准备的弹层（如备份恢复需先解密读
 * 预览）把倒计时起点压到准备完成后——暂停期间确认钮禁用并显示等待文案，
 * 不走字；`holdPaused` 翻 false 才从满格开始计时，保证用户有完整冷静期
 * 先看到决策依据再读后果（解密慢时倒计时不再与加载并行消耗）。
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

/**
 * 确认钮文案归一：门控暂停中优先显示等待文案（倒计时尚未起算），
 * 否则走正常倒计时文案。抽纯函数便于单测（沿仓库纯函数共置惯例）。
 */
export function resolveHoldLabel(
  remaining: number,
  confirmLabel: string,
  holdPaused: boolean,
  holdPendingLabel: string,
): string {
  if (holdPaused) return holdPendingLabel;
  return formatHoldLabel(remaining, confirmLabel);
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
  /**
   * 倒计时门控：为 true 时不走字、确认钮禁用并显示 `holdPendingLabel`
   * （备份恢复传预览 loading 态，解密完成前时停不起算）；默认 false
   * （开层即计时，保持改密/重置云端等纯文案弹层既有口径）。
   */
  holdPaused?: boolean;
  /** 门控暂停期间确认钮文案，默认“请稍候…” */
  holdPendingLabel?: string;
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
  holdPaused = false,
  holdPendingLabel = "请稍候…",
  busy = false,
  onConfirm,
  body,
  contentClassName,
}: DangerousConfirmDialogProps) {
  const [countdown, setCountdown] = useState(holdSeconds);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  // 开层从头计时，走完停表；关层/卸载复位，下次打开重计。
  // 门控暂停中（holdPaused）不清倒计时走字：停表并保持满格，
  // 翻 false 时从满格起算（预览就绪后才开始完整冷静期）。
  useEffect(() => {
    if (!open || holdPaused) {
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
  }, [open, holdSeconds, holdPaused]);

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
            disabled={holdPaused || countdown > 0 || busy}
            onClick={onConfirm}
          >
            {resolveHoldLabel(countdown, confirmLabel, holdPaused, holdPendingLabel)}
          </Button>
        </div>
      </div>
    </div>
  );
}
