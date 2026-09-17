/**
 * TimeHMSelect — 时:分二合一选择器（手输 + 下拉）。
 *
 * 背景：日期弹层的时间行、快捷新增提醒、抽屉截止/提醒弹层、自动备份时刻
 * 四处原来各有一份原生数字框（时/分），只能点上下箭头，整点等常用值要点
 * 很多下；自动备份侧已换成 shadcn Select 下拉但不能手输。本组件统一口径：
 * 左侧 Input 直接输数字（失焦/回车提交，越界钳制、空草稿回退原值），
 * 右侧 chevron 按钮展开选项列表点选。
 *
 * 实现注意：下拉列表刻意不用 Radix Select/Popover（portal 传送门）——
 * 本组件常驻在 DateTimePicker 等 PopoverContent 内，portal 套 portal 会
 * 触发 Radix 焦点陷阱与定位测量异常（quick-add-bar 与 drawer 注释有记录），
 * 故用相对定位容器 + 绝对定位内联列表（无 portal），外部点击/Esc 关闭，
 * 空间不足时向上展开。
 */

import { useEffect, useMemo, useRef, useState } from "react";
import { Check, ChevronDown } from "lucide-react";

import { Input } from "@/components/ui/input";
import { attachManualWheelScroll } from "@/lib/manual-wheel-scroll";
import { cn } from "@/lib/utils";

/** 草稿清洗：只留数字，最多 2 位（输入过程中的中间态不过度纠正） */
export function sanitizeTimeDigits(raw: string): string {
  return raw.replace(/\D/g, "").slice(0, 2);
}

/** 数值钳制到 [0, max]（提交口径；非数字按 0 处理） */
export function clampTimeUnit(n: number, max: number): number {
  if (!Number.isFinite(n)) return 0;
  return Math.min(max, Math.max(0, Math.floor(n)));
}

/** 提交格式化：钳制 + 补零（如 9 → "09"，25 在小时档 → "23"） */
export function formatTimeUnit(n: number, max: number): string {
  return String(clampTimeUnit(n, max)).padStart(2, "0");
}

interface TimeUnitBoxProps {
  /** 已提交的补零串（如 "09"）；调用方保证 2 位，不足位用 padStart 归一 */
  value: string;
  /** 上界：小时 23 / 分钟 59 */
  max: number;
  /** 提交回调（恒为补零串；空草稿视为取消、不回调） */
  onCommit: (v: string) => void;
  ariaLabel: string;
  disabled?: boolean;
  /** 输入框 id（供外部 Label htmlFor 聚焦，如备份时刻） */
  inputId?: string;
}

/**
 * 单个时间单位（时/分）：可输 Input + 下拉列表。
 *
 * 编辑语义：聚焦时把已提交值装入草稿并全选，方便整体替换；键入只做
 * 数字清洗不即时提交（避免输第二位时被已提交值顶掉）；失焦/回车按
 * 钳制补零提交，空草稿回退原值；Esc 取消草稿。下拉点选即时提交。
 */
function TimeUnitBox({ value, max, onCommit, ariaLabel, disabled, inputId }: TimeUnitBoxProps) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState<string | null>(null);
  const [openUp, setOpenUp] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  const shown = draft ?? value;

  const commitText = (text: string) => {
    const clean = sanitizeTimeDigits(text);
    if (clean === "") return; // 空草稿视为取消，保持原值
    onCommit(formatTimeUnit(Number(clean), max));
  };

  // 下拉打开期间：外部点击/Esc 关闭（内联列表无 portal，document 监听即可）
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: PointerEvent) => {
      // 鼠标中/右键不关（如中键自动滚动取位），只响应主键与触摸
      if (e.pointerType === "mouse" && e.button !== 0) return;
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open ]);

  // 下拉打开期间：window 捕获手动滚轮（Dialog/Sheet 的 RemoveScroll 会在
  // document 级吞掉 wheel，列表元素上的监听收不到——见 manual-wheel-scroll）
  useEffect(() => {
    if (!open) return;
    const el = listRef.current;
    if (!el) return;
    return attachManualWheelScroll(el);
  }, [open ]);

  useEffect(() => {
    if (disabled) setOpen(false);
  }, [disabled ]);

  const options = useMemo(
    () => Array.from({ length: max + 1 }, (_, i) => String(i).padStart(2, "0")),
    [max ],
  );

  const toggleOpen = () => {
    if (disabled) return;
    const next = !open;
    if (next && rootRef.current) {
      // 下方空间不足 220px 时向上展开（如视口底部弹层）
      const rect = rootRef.current.getBoundingClientRect();
      setOpenUp(window.innerHeight - rect.bottom < 220);
    }
    setDraft(null);
    setOpen(next);
  };

  // 打开后把当前值滚到可视区（分钟 60 项，选中项常在下方）
  useEffect(() => {
    if (!open) return;
    listRef.current
      ?.querySelector('[data-selected="true"]')
      ?.scrollIntoView({ block: "nearest" });
  }, [open ]);

  return (
    <div ref={rootRef} className="relative shrink-0">
      <div className="flex">
        <Input
          id={inputId}
          value={shown}
          inputMode="numeric"
          aria-label={ariaLabel}
          disabled={disabled}
          onFocus={(e) => {
            setDraft(value);
            e.target.select();
          }}
          onChange={(e) => setDraft(sanitizeTimeDigits(e.target.value))}
          onBlur={() => {
            if (draft != null) commitText(draft);
            setDraft(null);
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter") (e.target as HTMLInputElement).blur();
            if (e.key === "Escape" && draft != null) {
              setDraft(null);
              (e.target as HTMLInputElement).blur();
            }
          }}
          className="h-8 w-12 rounded-r-none border-r-0 px-1.5 text-center tabular-nums"
        />
        <button
          type="button"
          aria-label={`${ariaLabel}下拉选择`}
          aria-haspopup="listbox"
          aria-expanded={open}
          disabled={disabled}
          onClick={toggleOpen}
          className="flex h-8 w-7 shrink-0 items-center justify-center rounded-r-md border border-input bg-transparent transition-colors hover:bg-accent disabled:cursor-not-allowed disabled:opacity-50"
        >
          <ChevronDown className="size-3.5 opacity-50" />
        </button>
      </div>
      {open && (
        <div
          ref={listRef}
          role="listbox"
          aria-label={ariaLabel}
          className={cn(
            "absolute z-50 max-h-48 w-full min-w-24 overflow-auto rounded-md border bg-popover p-1 shadow-md",
            openUp ? "bottom-full mb-1" : "top-full mt-1",
          )}
        >
          {options.map((opt) => (
            <button
              key={opt}
              type="button"
              role="option"
              aria-selected={opt === value}
              data-selected={opt === value}
              onClick={() => {
                setDraft(null);
                onCommit(opt);
                setOpen(false);
              }}
              // 与项目下拉（shadcn SelectItem / 年份虚拟列表）同款行样式：
              // text-sm + rounded-sm + 右侧勾选，选中态只用勾选表达
              className="relative flex w-full cursor-default items-center gap-2 rounded-sm py-1.5 pr-8 pl-2 text-sm tabular-nums text-foreground outline-none select-none hover:bg-accent hover:text-accent-foreground"
            >
              <span className="flex-1 truncate">{opt}</span>
              {opt === value && (
                <span className="absolute right-2 flex size-4 items-center justify-center">
                  <Check className="size-4" />
                </span>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

interface TimeHMSelectProps {
  /** 小时补零串 "00"–"23" */
  hour: string;
  /** 分钟补零串 "00"–"59" */
  minute: string;
  onHourChange: (hh: string) => void;
  onMinuteChange: (mm: string) => void;
  disabled?: boolean;
  /** 单位后缀（如自动备份「时/分」；日期弹层默认只留冒号分隔不传） */
  hourSuffix?: string;
  minuteSuffix?: string;
  /** 小时输入框 id（供外部 Label htmlFor 聚焦） */
  hourInputId?: string;
}

export function TimeHMSelect({
  hour,
  minute,
  onHourChange,
  onMinuteChange,
  disabled,
  hourSuffix,
  minuteSuffix,
  hourInputId,
}: TimeHMSelectProps) {
  return (
    <div className="flex items-center gap-1.5">
      <TimeUnitBox
        value={hour}
        max={23}
        onCommit={onHourChange}
        ariaLabel="小时"
        disabled={disabled}
        inputId={hourInputId}
      />
      {hourSuffix ? (
        <span className="shrink-0 text-xs text-muted-foreground">{hourSuffix}</span>
      ) : null}
      <span className="shrink-0 text-muted-foreground">:</span>
      <TimeUnitBox
        value={minute}
        max={59}
        onCommit={onMinuteChange}
        ariaLabel="分钟"
        disabled={disabled}
      />
      {minuteSuffix ? (
        <span className="shrink-0 text-xs text-muted-foreground">{minuteSuffix}</span>
      ) : null}
    </div>
  );
}
