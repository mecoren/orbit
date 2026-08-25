/**
 * 可撤销删除 Hook（P0，07 报告 §五-P0#3）
 *
 * 流程：hide() 乐观摘除缓存行 → success toast（action=撤销，duration=UNDO_DELAY_MS）
 *   ├─ 点撤销 → cancel 计时 + invalidateQueries 恢复显示
 *   └─ 超时 → commit() 真删除 → invalidateQueries 刷新计数/关联缓存
 *
 * Provider 挂在 ListPage 层：任务行（虚拟化滚动会卸载）与详情抽屉（关闭即卸载）
 * 都可能中途消失，撤销状态必须活得更久。
 *
 * 已知限制（MVP 接受）：窗口期内任何无关写库会触发全局 invalidateQueries，
 * 以 DB 真值覆盖缓存使被隐藏的未提交行短暂"复活"，落库后再消失；
 * 中期方向是按实体收窄失效粒度（events.ts 粗粒度失效改造）。
 */
import { createContext, useCallback, useContext, useEffect, useRef, type ReactNode } from "react";
import { useQueryClient, type QueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { UNDO_DELAY_MS, createDelayedRun, type DelayedRun } from "@/features/todo/shared/undo-delete";

export interface UndoableDeleteInput {
  /** 实体中文名，如"任务"/"项目"/"标签" */
  entityLabel: string;
  /** 记录名（标题等），用于 toast 文案 */
  recordName?: string;
  /** 真删除命令（延迟执行；内部已 catch，无需调用方兜底） */
  commit: () => Promise<unknown>;
  /** 乐观隐藏：从 react-query 数组型缓存中摘除该行 */
  hide: (qc: QueryClient) => void;
}

/** 按 id 从匹配 keyPrefix 的数组缓存中隐藏一行（前缀匹配多个同族变体 key） */
export function hideFromQueries<T extends { id: number }>(
  qc: QueryClient,
  keyPrefix: readonly unknown[],
  id: number,
) {
  qc.setQueriesData<T[]>({ queryKey: keyPrefix }, (old) =>
    old?.some((r) => r.id === id) ? old.filter((r) => r.id !== id) : old,
  );
}

function useUndoableDeleteImpl() {
  const qc = useQueryClient();
  const pendingRef = useRef<DelayedRun | null>(null);

  // 卸载兜底：窗口期未结束就离开页面 → 立即提交，避免"看似删了实际没删"
  useEffect(() => () => pendingRef.current?.flush(), []);

  return useCallback(
    (input: UndoableDeleteInput) => {
      input.hide(qc);
      pendingRef.current?.flush(); // 连续删除：上一笔先落库（MVP 单槽位足够）
      // self 守卫：上一笔 run 的 finally 不得清掉指向本笔的引用，
      // 否则第二笔的撤销点击会静默失效（审查 C1）
      let self: DelayedRun | null = null;
      self = createDelayedRun(async () => {
        try {
          await input.commit();
        } catch {
          toast.error(`删除${input.entityLabel}失败`);
        } finally {
          if (pendingRef.current === self) pendingRef.current = null;
          void qc.invalidateQueries();
        }
      }, UNDO_DELAY_MS);
      pendingRef.current = self;

      let toastId: string | number = "";
      toastId = toast.success(
        `已删除${input.entityLabel}${input.recordName ? `「${input.recordName}」` : ""}`,
        {
          duration: UNDO_DELAY_MS,
          action: {
            label: "撤销",
            onClick: () => {
              if (pendingRef.current?.cancel()) {
                pendingRef.current = null;
                void qc.invalidateQueries(); // 恢复被隐藏的行
                toast.dismiss(toastId);
              }
            },
          },
        },
      );
    },
    [qc],
  );
}

const UndoableDeleteContext = createContext<(input: UndoableDeleteInput) => void>(() => {});

export function UndoableDeleteProvider({ children }: { children: ReactNode }) {
  const del = useUndoableDeleteImpl();
  return <UndoableDeleteContext.Provider value={del}>{children}</UndoableDeleteContext.Provider>;
}

/** 页面树内任意删除入口取同一撤销实例 */
export function useUndoableDeleteAction() {
  return useContext(UndoableDeleteContext);
}
