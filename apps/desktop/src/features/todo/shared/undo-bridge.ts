/**
 * 非 React 模块（task-actions / batch-actions）的撤销入栈注册点。
 *
 * Provider 挂载时注入推送函数（use-undo-stack.tsx），卸载置 null；
 * 惰性构造（传函数）仅在 pusher 存在时调用——未注册时整体 no-op，
 * 保证 node 环境测试与未挂 Provider 场景不误报。
 */
import type { UndoEntry } from "./undo-stack";

type PushFn = (entry: UndoEntry | (() => UndoEntry)) => void;

let pusher: PushFn | null = null;

export function setUndoPusher(fn: PushFn | null): void {
  pusher = fn;
}

export function pushUndo(entry: UndoEntry | (() => UndoEntry)): void {
  pusher?.(entry);
}
