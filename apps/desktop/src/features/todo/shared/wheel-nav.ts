/**
 * 滚轮步进导航——日历类头部 hover 滚轮切月/切年共用。
 *
 * 之所以不直接用 React onWheel：
 * - React 的 wheel 监听是 passive 的，调 preventDefault 会告警；
 *   切月/年时必须吃掉事件，否则页面（抽屉内联日历）会跟着滚动。
 * - 用 ref 挂原生 `{ passive: false }` 监听，按需 preventDefault。
 *
 * 三个让位规则（缺一不可）：
 * 1. `ctrlKey`/`metaKey` 直接放行——那是浏览器缩放手势；
 * 2. 事件落在年/月下拉列表（`[data-slot="select-content"]` / `[role="listbox"]`）直接放行——
 *    列表自己的原生滚动优先，不能一边滚列表一边翻月；
 * 3. 触控板连续小增量走累积阈值 + 前沿后沿节流——突发手势合并为一次渲染，
 *    且冷却期内的步数不清零（旧实现直接丢弃，快速连滑会丢月）。
 */
import { useCallback, useRef } from "react";

/** 累积满多少 px 翻一档（鼠标一刻度约 100px 必触发，触控板慢滑约攒几次） */
export const WHEEL_STEP_THRESHOLD_PX = 24;
/** 翻档后多少 ms 内忽略后续事件（防一次手势连翻） */
export const WHEEL_STEP_COOLDOWN_MS = 150;

/** 年/月下拉列表容器（只认列表本身，不认外层弹层——日期弹层自己就宿在 Popover 里） */
const DROPDOWN_LIST_SELECTOR = '[data-slot="select-content"], [role="listbox"]';

/** 主轴位移（像素）：纵向优先，纵向为 0 时取横向（横滑板/Shift+滚轮）；缩放手势返回 0 */
export function wheelDeltaPx(e: WheelEvent): number {
  if (e.ctrlKey || e.metaKey) return 0;
  const raw = e.deltaY !== 0 ? e.deltaY : e.deltaX;
  // Firefox 行模式增量按 16px/行折算（与 manual-wheel-scroll 同口径）
  return e.deltaMode === 1 ? raw * 16 : raw;
}

export interface WheelStepState {
  fire: boolean;
  dir: 1 | -1;
  rest: number;
}

/**
 * 纯函数：把单次位移并入累积，满阈值吐出一步并保留余量。
 * 余量保留保证触控板慢滑手感连续；单次超大位移只吐一步（多步由节流拆到后续事件）。
 *
 * 换向清零：累积余量与本次位移反号时先清零再累积——否则往下滚残留 +10 后往上滚 8px
 * 会被算成 +2 继续向前（来回滚方向错乱），正确语义是新的反向手势；零位移不清。
 */
export function consumeWheelStep(
  acc: number,
  delta: number,
  threshold: number = WHEEL_STEP_THRESHOLD_PX,
): WheelStepState {
  const base = acc * delta < 0 ? 0 : acc;
  const next = base + delta;
  if (Math.abs(next) < threshold) return { fire: false, dir: 1, rest: next };
  const dir = next > 0 ? 1 : -1;
  return { fire: true, dir, rest: next - dir * threshold };
}

export interface AttachWheelStepOptions {
  threshold?: number;
  cooldownMs?: number;
}

/** 在元素上挂滚轮步进监听，返回解绑函数（供回调 ref cleanup）
 *
 * 节流语义（前沿 + 后沿，零丢步）：
 * - 冷却期外首个步进立即触发（单击无延迟感）；
 * - 冷却期内的步进累积，期满一次性触发合计（快速连滑只多一次渲染，不丢月）。
 */
export function attachWheelStep(
  el: HTMLElement,
  onSteps: (steps: number) => void,
  opts: AttachWheelStepOptions = {},
): () => void {
  const threshold = opts.threshold ?? WHEEL_STEP_THRESHOLD_PX;
  const cooldownMs = opts.cooldownMs ?? WHEEL_STEP_COOLDOWN_MS;
  let acc = 0;
  let pending = 0;
  let lastFlush = 0;
  let trailing: ReturnType<typeof setTimeout> | null = null;

  const flush = () => {
    trailing = null;
    if (pending === 0) return;
    lastFlush = Date.now();
    const n = pending;
    pending = 0;
    onSteps(n);
  };

  const onWheel = (e: WheelEvent) => {
    // 下拉列表内滚动不接管（见文件头规则 2；注意不能用 popper wrapper 判定，
    // 日期弹层整体就宿在外层 Popover 里，那样会把弹层自己的滚轮全吞掉）
    if ((e.target as HTMLElement | null)?.closest?.(DROPDOWN_LIST_SELECTOR)) return;
    const delta = wheelDeltaPx(e);
    if (delta === 0) return;
    // 接管手势：页面/抽屉不再滚动
    e.preventDefault();
    const r = consumeWheelStep(acc, delta, threshold);
    acc = r.rest;
    if (!r.fire) return;
    pending += r.dir;
    if (Date.now() - lastFlush >= cooldownMs) {
      if (trailing != null) {
        clearTimeout(trailing);
        trailing = null;
      }
      flush();
    } else if (trailing == null) {
      trailing = setTimeout(flush, cooldownMs);
    }
  };

  el.addEventListener("wheel", onWheel, { passive: false });
  return () => {
    if (trailing != null) clearTimeout(trailing);
    el.removeEventListener("wheel", onWheel);
  };
}

/**
 * 回调 ref 版（React 19 支持返回 cleanup）：`<div ref={useWheelStepRef(onSteps)}> …`。
 * onSteps 用 ref 转存，调用方无需 useCallback 包裝也不會重掛监听。
 */
export function useWheelStepRef(
  onSteps: (steps: number) => void,
  opts: AttachWheelStepOptions = {},
): (el: HTMLElement | null) => void {
  const onStepsRef = useRef(onSteps);
  onStepsRef.current = onSteps;
  const optsRef = useRef(opts);
  optsRef.current = opts;

  return useCallback((el: HTMLElement | null) => {
    if (el == null) return;
    return attachWheelStep(el, (n) => onStepsRef.current(n), optsRef.current);
  }, []);
}

/**
 * 年月整体平移 n 个月（month 为 0-based；跨年自动进位，负数正确回绕）。
 * 滚轮批量步进的归一出口，避免各调用方手写取模（负数取模易错）。
 */
export function shiftYearMonth(
  year: number,
  month: number,
  steps: number,
): { year: number; month: number } {
  const total = year * 12 + month + steps;
  const nextYear = Math.floor(total / 12);
  return { year: nextYear, month: total - nextYear * 12 };
}
