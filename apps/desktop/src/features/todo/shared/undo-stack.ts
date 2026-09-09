/**
 * 通用撤销栈（A5：Ctrl+Z 全操作可撤销）
 *
 * 设计：单栈只撤不复（无 redo——YAGNI），容量 30 防无界增长；
 * undo 回调自带错误语义（UndoOutcome），调用方按结果出 toast，
 * 抛错不炸栈、不阻断后续条目。纯函数无 React 依赖，node 测试直测。
 */
export interface UndoEntry {
  /** toast 文案实体，如「完成任务」 */
  label: string;
  /** 批量条数（>1 时 toast 带「N 条」） */
  count?: number;
  /** 回滚操作（恢复旧状态；内部不再 catch——错误经 UndoOutcome 上抛语义） */
  undo: () => Promise<void>;
}

export type UndoOutcome =
  | { undone: true; entry: UndoEntry }
  | { undone: false; reason: "empty" }
  | { undone: false; reason: "failed"; entry: UndoEntry; error: unknown };

export interface UndoStack {
  push(entry: UndoEntry): void;
  undo(): Promise<UndoOutcome>;
  last: UndoEntry | null;
  clear(): void;
}

const MAX_ENTRIES = 30;

export function createUndoStack(): UndoStack {
  const entries: UndoEntry[] = [];
  return {
    push(entry) {
      entries.push(entry);
      if (entries.length > MAX_ENTRIES) entries.shift();
    },
    async undo() {
      const entry = entries.pop();
      if (!entry) return { undone: false, reason: "empty" };
      try {
        await entry.undo();
        return { undone: true, entry };
      } catch (error) {
        return { undone: false, reason: "failed", entry, error };
      }
    },
    get last() {
      return entries.length ? entries[entries.length - 1] : null;
    },
    clear() {
      entries.length = 0;
    },
  };
}

/** Ctrl+Z 判定（shift+ctrl+z 属 redo 语义，本产品无 redo 不命中） */
export function isUndoShortcut(
  e: { ctrlKey?: boolean; metaKey?: boolean; shiftKey?: boolean; key: string },
): boolean {
  return (
    (e.ctrlKey || e.metaKey) === true &&
    e.shiftKey !== true &&
    (e.key === "z" || e.key === "Z")
  );
}

export function undoToastText(entry: UndoEntry): string {
  return entry.count && entry.count > 1
    ? `已撤销：${entry.label} ${entry.count} 条`
    : `已撤销：${entry.label}`;
}
