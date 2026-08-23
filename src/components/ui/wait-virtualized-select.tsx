import * as React from "react";
import * as PopoverPrimitive from "@radix-ui/react-popover";
import { Check, ChevronDown } from "lucide-react";

import { cn } from "@/lib/utils";

export interface WaitVirtualizedSelectOption {
  value: string;
  label: string;
}

interface WaitVirtualizedSelectProps {
  value: string;
  onValueChange: (value: string) => void;
  options: WaitVirtualizedSelectOption[];
  placeholder?: string;
  /** 作用在 trigger 上（宽度等），与 shadcn SelectTrigger 一致 */
  className?: string;
  /** 作用在 popover 内容容器上 */
  contentClassName?: string;
  /** 弹层内容宽度（px）。默认跟随触发器宽度；超长文本（如年份）可放宽避免截断 */
  contentWidth?: number;
  ariaLabel?: string;
  size?: "sm" | "default";
  /** 单项高度（px），默认 32 与 shadcn SelectItem 对齐 */
  itemHeight?: number;
  /** 滚动视口最大高度（px），默认 256 = max-h-64 */
  viewportHeight?: number;
  /** 上下额外渲染的缓冲项数 */
  overscan?: number;
  disabled?: boolean;
}

/**
 * 公共「虚拟滚动下拉」组件。
 *
 * 设计目标：在超长列表（如 1900–2100 共 201 个年份）场景下，只渲染可视区内的
 * 选项，避免一次性挂载成百上千节点；同时**视觉与动画完全对齐 shadcn Select**——
 * trigger 复用 SelectTrigger 的样式类，popover 内容复用 SelectContent 的
 * `animate-in/zoom-in` 动画类，明暗主题自动适配。
 *
 * 实现上用 Radix Popover 负责定位 / 点击外部关闭 / Esc 关闭 / 动画外壳，
 * 内部用「占位高度 + 仅渲染可视窗口」的标准虚拟列表；键盘方向键、Home/End、
 * 回车选中、首字母 typeahead 均自管，不依赖 Radix Select 的 item 测量。
 */
export function WaitVirtualizedSelect({
  value,
  onValueChange,
  options,
  placeholder = "请选择",
  className,
  contentClassName,
  contentWidth,
  ariaLabel,
  size = "default",
  itemHeight = 32,
  viewportHeight = 256,
  overscan = 6,
  disabled,
}: WaitVirtualizedSelectProps) {
  const [open, setOpen] = React.useState(false);
  const [active, setActive] = React.useState(0);
  // 用 renderTick 驱动虚拟列表重渲染；scrollTop 放在 ref 里，避免滚动时
  // 每 1px 都触发 React 重渲染（只在新项进入可视窗口、即 floor(scrollTop/h) 变化时 tick）。
  const [, setRenderTick] = React.useState(0);
  const scrollTopRef = React.useRef(0);
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const typeBufferRef = React.useRef("");
  const typeTimerRef = React.useRef<ReturnType<typeof setTimeout> | null>(null);

  const selectedIndex = React.useMemo(
    () => options.findIndex((o) => o.value === value),
    [options, value],
  );

  const selectedLabel =
    selectedIndex >= 0 ? options[selectedIndex].label : placeholder;

  // 打开时把高亮定位到当前选中项，并居中滚动到该项
  React.useEffect(() => {
    if (!open) return;
    const idx = selectedIndex >= 0 ? selectedIndex : 0;
    setActive(idx);
    requestAnimationFrame(() => {
      const el = scrollRef.current;
      if (!el) return;
      const top = idx * itemHeight;
      el.scrollTop = Math.max(0, top - viewportHeight / 2 + itemHeight / 2);
      scrollTopRef.current = el.scrollTop;
      setRenderTick((t) => t + 1);
      el.focus();
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  // 高亮项变化时滚动到可视区
  React.useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const top = active * itemHeight;
    const bottom = top + itemHeight;
    let changed = false;
    if (top < el.scrollTop) {
      el.scrollTop = top;
      changed = true;
    } else if (bottom > el.scrollTop + el.clientHeight) {
      el.scrollTop = bottom - el.clientHeight;
      changed = true;
    }
    if (changed) {
      scrollTopRef.current = el.scrollTop;
      setRenderTick((t) => t + 1);
    }
  }, [active, itemHeight]);

  // 滚轮滚动：日期选择器嵌在 Radix Dialog/Sheet 内，其 react-remove-scroll 会在
  // document 级拦截 wheel 并 preventDefault，导致弹层内无法用滚轮原生滚动（只能拖
  // 滚动条）。这里在滚动容器上挂一个非被动、捕获阶段的 wheel 监听：preventDefault
  // 阻断原生滚动、stopPropagation 阻止事件冒泡到 Dialog 的 RemoveScroll，再手动
  // 滚动；随后 onScroll 触发并驱动可视窗口重渲染。这样既不依赖 RemoveScroll 放行，
  // 也不会出现「原生 + 手动」双重滚动。
  React.useEffect(() => {
    if (!open) return;
    const el = scrollRef.current;
    if (!el) return;
    const onWheel = (e: Event) => {
      e.preventDefault();
      const we = e as WheelEvent;
      el.scrollTop += we.deltaY;
      e.stopPropagation();
    };
    el.addEventListener("wheel", onWheel, { capture: true, passive: false });
    return () => el.removeEventListener("wheel", onWheel, { capture: true });
  }, [open]);

  const commit = React.useCallback(
    (idx: number) => {
      const opt = options[idx];
      if (!opt) return;
      onValueChange(opt.value);
      setOpen(false);
    },
    [options, onValueChange],
  );

  const onKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        setActive((a) => Math.min(options.length - 1, a + 1));
        break;
      case "ArrowUp":
        e.preventDefault();
        setActive((a) => Math.max(0, a - 1));
        break;
      case "PageDown":
        e.preventDefault();
        setActive((a) => Math.min(options.length - 1, a + 10));
        break;
      case "PageUp":
        e.preventDefault();
        setActive((a) => Math.max(0, a - 10));
        break;
      case "Home":
        e.preventDefault();
        setActive(0);
        break;
      case "End":
        e.preventDefault();
        setActive(options.length - 1);
        break;
      case "Enter":
      case " ":
        e.preventDefault();
        commit(active);
        break;
      default: {
        // 首字母 / 数字 typeahead
        if (e.key.length === 1 && /\S/.test(e.key)) {
          if (typeTimerRef.current) clearTimeout(typeTimerRef.current);
          typeBufferRef.current =
            typeBufferRef.current === ""
              ? e.key
              : typeBufferRef.current + e.key;
          const buf = typeBufferRef.current.toLowerCase();
          const hit = options.findIndex((o) =>
            o.label.toLowerCase().startsWith(buf),
          );
          if (hit >= 0) setActive(hit);
          typeTimerRef.current = setTimeout(() => {
            typeBufferRef.current = "";
          }, 700);
        }
      }
    }
  };

  // 可视窗口计算
  const total = options.length;
  const scrollTop = scrollTopRef.current;
  const startIdx = Math.max(0, Math.floor(scrollTop / itemHeight) - overscan);
  const endIdx = Math.min(
    total - 1,
    Math.ceil((scrollTop + viewportHeight) / itemHeight) + overscan,
  );

  const visible: React.ReactNode[] = [];
  for (let i = startIdx; i <= endIdx; i++) {
    const opt = options[i];
    const isSelected = opt.value === value;
    const isActive = i === active;
    visible.push(
      <button
        key={opt.value}
        type="button"
        role="option"
        aria-selected={isSelected}
        onMouseEnter={() => setActive(i)}
        onClick={() => commit(i)}
        className={cn(
          "focus:bg-accent focus:text-accent-foreground [&_svg:not([class*='text-'])]:text-muted-foreground absolute inset-x-0 flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-8 pl-2 text-sm outline-hidden select-none",
          isActive
            ? "bg-accent text-accent-foreground"
            : "text-foreground",
        )}
        style={{ top: i * itemHeight, height: itemHeight }}
      >
        <span className="flex-1 truncate">{opt.label}</span>
        {isSelected && (
          <span className="absolute right-2 flex size-4 items-center justify-center">
            <Check className="size-4" />
          </span>
        )}
      </button>,
    );
  }

  return (
    <PopoverPrimitive.Root open={open} onOpenChange={setOpen}>
      <PopoverPrimitive.Trigger asChild>
        <button
          type="button"
          role="combobox"
          aria-expanded={open}
          aria-label={ariaLabel}
          disabled={disabled}
          data-size={size}
          className={cn(
            "border-input data-[placeholder]:text-muted-foreground [&_svg:not([class*='text-'])]:text-muted-foreground flex w-fit items-center justify-between gap-2 rounded-md border bg-transparent px-3 py-2 text-sm whitespace-nowrap shadow-xs transition-[color,box-shadow] outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-50 data-[size=default]:h-9 data-[size=sm]:h-8 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
            className,
          )}
        >
          <span className="truncate">{selectedLabel}</span>
          <ChevronDown className="size-4 opacity-50" />
        </button>
      </PopoverPrimitive.Trigger>
      <PopoverPrimitive.Portal>
        <PopoverPrimitive.Content
          align="start"
          sideOffset={4}
          onOpenAutoFocus={(e) => {
            // 把焦点交给滚动列表，便于键盘导航
            e.preventDefault();
            scrollRef.current?.focus();
          }}
          className={cn(
            // 与 shadcn SelectContent 完全一致的入场/退场动画；宽度对齐 trigger，
            // 这样和 Radix Select popper 的表现一致。
            "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 relative z-50 min-w-[var(--radix-popover-trigger-width)] origin-(--radix-popover-content-transform-origin) rounded-md border p-1 shadow-md",
            contentClassName,
          )}
          style={contentWidth ? { width: contentWidth } : undefined}
        >
          <div
            ref={scrollRef}
            tabIndex={0}
            role="listbox"
            onKeyDown={onKeyDown}
            onScroll={(e) => {
              // 滚轮/拖动滚动条：立即同步滚动位置并重渲染可视窗口，
              // 保证列表始终跟手（不依赖「跨过 item 高度」的阈值，避免小步滚动时卡顿）。
              scrollTopRef.current = e.currentTarget.scrollTop;
              setRenderTick((t) => t + 1);
            }}
            className="w-full overflow-y-scroll outline-none"
            style={{ maxHeight: viewportHeight }}
          >
            <div
              className="relative w-full"
              style={{ height: total * itemHeight }}
            >
              {visible}
            </div>
          </div>
        </PopoverPrimitive.Content>
      </PopoverPrimitive.Portal>
    </PopoverPrimitive.Root>
  );
}
