/**
 * 冷启动首屏标记（度量专用，docs/09 §六）
 *
 * cold-start.mjs 以 ORBIT_PERF_MARKER=<路径> 启动 release exe（未设置时
 * Rust 侧 no-op），本模块在 boot 门控落到持续画面（解锁页/主界面）后
 * 上报「首屏就绪」时刻。双 rAF = 等这一帧真正绘制上屏再上报，取代旧
 * 口径「首窗句柄 + 400ms 拍定常数」。每进程只记第一笔（Rust 侧 once 闸），
 * 上报失败静默——度量链路绝不影响启动。
 */
import { perfFirstScreenMark } from "./tauri";

export function markFirstScreenReady(): void {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      void perfFirstScreenMark().catch(() => {});
    });
  });
}
