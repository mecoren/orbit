/**
 * use-exit-sync — 退出同步遮罩
 *
 * 托盘「退出」与系统真退出由 Rust 侧编排：emit `sync-exit-start`（前端显示
 * 遮罩）→ 阻塞执行同步（最多 15s，超时放行）→ emit `sync-exit-done` →
 * 销毁窗口并退出进程。
 *
 * 前端只负责展示，最长驻留 `EXIT_MASK_MAX_MS`：`sync-exit-done` 之后进程
 * 很快结束，事件可能来不及被处理，超时兜底避免遮罩残留（窗口被回收重建
 * 时也不至于卡在遮罩上）。
 */
import { useEffect, useState } from "react";

import { listen } from "@tauri-apps/api/event";

/** 遮罩最长驻留时间（略大于 Rust 侧 15s 超时，留出事件往返余量） */
const EXIT_MASK_MAX_MS = 16_000;

export const EXIT_SYNC_START_EVENT = "sync-exit-start";
export const EXIT_SYNC_DONE_EVENT = "sync-exit-done";

/** 是否正在执行退出同步（true 时渲染退出遮罩） */
export function useExitSyncMask(): boolean {
  const [exiting, setExiting] = useState(false);

  useEffect(() => {
    let timer: number | undefined;
    const clear = () => {
      if (timer !== undefined) {
        window.clearTimeout(timer);
        timer = undefined;
      }
    };

    const unlistenStart = listen(EXIT_SYNC_START_EVENT, () => {
      setExiting(true);
      clear();
      timer = window.setTimeout(() => setExiting(false), EXIT_MASK_MAX_MS);
    });
    const unlistenDone = listen(EXIT_SYNC_DONE_EVENT, () => {
      setExiting(false);
      clear();
    });

    return () => {
      clear();
      void unlistenStart.then((fn) => fn());
      void unlistenDone.then((fn) => fn());
    };
  }, []);

  return exiting;
}
