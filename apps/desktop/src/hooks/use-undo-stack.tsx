/**
 * A5 通用撤销 Provider：Ctrl+Z 全局快捷键 + 撤销 toast。
 *
 * - 栈本体经 undo-bridge 注册点对非 React 模块（task-actions /
 *   batch-actions）开放推送，Provider 挂载时注入。
 * - 快捷键焦点守卫：焦点位于输入控件时让位浏览器原生撤销。
 * - 撤销成功后全量失效 react-query（与 db-change 事件同口径）。
 */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  createUndoStack,
  isUndoShortcut,
  undoToastText,
  type UndoEntry,
} from "@/features/todo/shared/undo-stack";
import { setUndoPusher } from "@/features/todo/shared/undo-bridge";

export interface UndoStackApi {
  push: (entry: UndoEntry | (() => UndoEntry)) => void;
  undo: () => void;
  last: UndoEntry | null;
  canUndo: boolean;
}

const UndoStackContext = createContext<UndoStackApi>({
  push: () => {},
  undo: () => {},
  last: null,
  canUndo: false,
});

/** 焦点位于可编辑控件时让位原生撤销（activeElement 的输入判定） */
function isEditableTarget(el: Element | null): boolean {
  return (
    el instanceof HTMLInputElement ||
    el instanceof HTMLTextAreaElement ||
    (el instanceof HTMLElement && el.isContentEditable)
  );
}

export function UndoStackProvider({ children }: { children: ReactNode }) {
  const qc = useQueryClient();
  const [, setVersion] = useState(0); // push/undo 后重渲染 context value
  const stackRef = useRef(createUndoStack());
  const stack = stackRef.current;

  const push = useCallback((entry: UndoEntry | (() => UndoEntry)) => {
    stack.push(typeof entry === "function" ? entry() : entry);
    setVersion((v) => v + 1);
  }, [stack]);

  const undo = useCallback(() => {
    void (async () => {
      const snapshot = stack.last;
      if (!snapshot) return;
      const outcome = await stack.undo();
      setVersion((v) => v + 1);
      if (outcome.undone) {
        void qc.invalidateQueries();
        toast.success(undoToastText(outcome.entry));
      } else if (outcome.reason === "failed") {
        toast.error(`撤销「${snapshot.label}」失败，请手动检查`);
      }
    })();
  }, [qc, stack]);

  // 非 React 模块入栈注册（task-actions / batch-actions）
  useEffect(() => {
    setUndoPusher(push);
    return () => setUndoPusher(null);
  }, [push]);

  // Ctrl+Z 全局快捷键（输入控件内让位原生撤销）
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!isUndoShortcut(e)) return;
      if (isEditableTarget(document.activeElement)) return;
      e.preventDefault();
      undo();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [undo]);

  return (
    <UndoStackContext.Provider
      value={{ push, undo, last: stack.last, canUndo: stack.last != null }}
    >
      {children}
    </UndoStackContext.Provider>
  );
}

export function useUndoStackInfo(): UndoStackApi {
  return useContext(UndoStackContext);
}
