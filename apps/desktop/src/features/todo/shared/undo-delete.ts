/**
 * 删除撤销核心调度（P0，07 报告 §五-P0#3）
 *
 * 策略：延迟提交——UI 先乐观隐藏行，UNDO_DELAY_MS 撤销窗口后才执行真删除；
 * 无需后端 restore 语义。窗口期内退出应用 = 未删除（安全方向）。
 */

/** 可注入计时器（测试注入 fake timers） */
export interface TimerApi {
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (id: unknown) => void;
}

export interface DelayedRun {
  /** 拦截待执行删除；返回 true = 确实拦截了一次 */
  cancel(): boolean;
  /** 立即执行并作废计时（组件卸载兜底） */
  flush(): void;
}

/** 撤销窗口时长（ms），与 toast duration 保持一致 */
export const UNDO_DELAY_MS = 5000;

export function createDelayedRun(
  run: () => Promise<unknown> | unknown,
  delayMs: number,
  timers: TimerApi = {
    // 包装为 lambda：Node/DOM 双类型环境下原生签名与 TimerApi 型变不兼容
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (id) => clearTimeout(id as Parameters<typeof clearTimeout>[0]),
  },
): DelayedRun {
  let cancelled = false;
  let ran = false;
  const fire = () => {
    if (!cancelled && !ran) {
      ran = true;
      void run();
    }
  };
  const id = timers.setTimeout(fire, delayMs);
  return {
    cancel() {
      if (cancelled || ran) return false;
      cancelled = true;
      timers.clearTimeout(id);
      return true;
    },
    flush() {
      if (cancelled || ran) return;
      cancelled = true;
      timers.clearTimeout(id);
      void run();
    },
  };
}
