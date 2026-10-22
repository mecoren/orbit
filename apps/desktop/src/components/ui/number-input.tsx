/**
 * NumberInput — 紧凑数字步进输入（shadcn 风格）
 *
 * 为什么不直接用 `<Input type="number">`：各平台原生 spinner 样式不一致
 * （Windows WebView2 的上下箭头 + 系统描边，与主题令牌完全不搭），且
 * 原生箭头无法跟随主题色。这里隐藏原生 spinner，右侧换成自绘的上下
 * 步进按钮组：边框/焦点环沿用 shadcn Input 的 `border-input` /
 * `ring-ring` 令牌，整组共享一个焦点环（内层 input 自环关闭）。
 *
 * 受控字符串语义：value 是原始输入串（空串 = 清除/未设），步进只做
 * 数值增减后写回字符串，不格式化、不落库——落盘口径由调用方决定
 * （如 today-strip 的 localStorage 预算）。
 *
 * 尺寸由 className 控制（如 `h-6 w-16`）；内部字号固定 text-xs，
 * 定位就是「行内紧凑小控件」，大尺寸表单请用标准 Input。
 */
import { ChevronDown, ChevronUp } from "lucide-react";

import { cn } from "@/lib/utils";

interface NumberInputProps {
  /** 原始输入串（空串 = 未设） */
  value: string;
  onValueChange: (value: string) => void;
  min?: number;
  max?: number;
  /** 步进幅度，默认 1 */
  step?: number;
  placeholder?: string;
  disabled?: boolean;
  /** 外层尺寸类（h-6 w-16 等） */
  className?: string;
  ariaLabel?: string;
}

/**
 * 步进纯函数：方向 +1/-1，按 min/max 夹取。
 *
 * 空/非法值（未设态）的起步语义：增加 → 一档 step；减少 → 落到下限
 * min（无 min 则 0）。结果一律写回字符串，避免小数格式化噪音。
 */
export function nudgeNumberValue(
  raw: string,
  direction: 1 | -1,
  opts: { min?: number; max?: number; step?: number } = {},
): string {
  const step = opts.step ?? 1;
  const parsed = Number.parseInt(raw, 10);
  let next = Number.isFinite(parsed)
    ? parsed + direction * step
    : direction === 1
      ? step
      : (opts.min ?? 0);
  if (opts.min != null) next = Math.max(opts.min, next);
  if (opts.max != null) next = Math.min(opts.max, next);
  return String(next);
}

export function NumberInput({
  value,
  onValueChange,
  min,
  max,
  step = 1,
  placeholder,
  disabled,
  className,
  ariaLabel,
}: NumberInputProps) {
  return (
    <div
      data-slot="number-input"
      className={cn(
        "border-input focus-within:border-ring focus-within:ring-ring/50 flex items-center overflow-hidden rounded-md border bg-transparent text-xs shadow-xs transition-[color,box-shadow] focus-within:ring-2",
        disabled && "pointer-events-none opacity-50",
        className,
      )}
    >
      <input
        type="text"
        inputMode="numeric"
        autoComplete="off"
        value={value}
        placeholder={placeholder}
        disabled={disabled}
        aria-label={ariaLabel}
        onChange={(e) => onValueChange(e.target.value.replace(/[^\d]/g, ""))}
        className="placeholder:text-muted-foreground min-w-0 flex-1 bg-transparent px-1.5 text-xs tabular-nums outline-none"
      />
      <div className="border-input flex h-full shrink-0 flex-col border-l">
        <button
          type="button"
          tabIndex={-1}
          aria-label="增加"
          onClick={() => onValueChange(nudgeNumberValue(value, 1, { min, max, step }))}
          className="text-muted-foreground hover:text-foreground hover:bg-accent flex flex-1 items-center justify-center px-1"
        >
          <ChevronUp className="size-2.5" />
        </button>
        <button
          type="button"
          tabIndex={-1}
          aria-label="减少"
          onClick={() => onValueChange(nudgeNumberValue(value, -1, { min, max, step }))}
          className="text-muted-foreground hover:text-foreground hover:bg-accent flex flex-1 items-center justify-center px-1"
        >
          <ChevronDown className="size-2.5" />
        </button>
      </div>
    </div>
  );
}
