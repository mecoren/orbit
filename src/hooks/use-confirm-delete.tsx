/**
 * 删除确认 Hook
 *
 * 为列表页删除操作提供统一的二次确认对话框，避免误删。
 * 基于 AlertDialog 组件，与详情页 ConfirmDialog 设计对齐：
 * - 标题模块化（如"删除影视"）
 * - 描述带具体记录名（「xxx」）
 * - 确认按钮文案"删除"
 *
 * 使用方式：
 * ```tsx
 * const { confirmDelete, dialogElement } = useConfirmDelete();
 *
 * const handleDelete = (id: number) => {
 *   const record = data.find(x => x.id === id);
 *   confirmDelete(async () => {
 *     await movieDelete(id);
 *     await refetch();
 *   }, {
 *     entityLabel: "影视",
 *     recordName: record?.title,
 *   });
 * };
 *
 * return (
 *   <>
 *     {dialogElement}
 *   </>
 * );
 * ```
 */
import { useCallback, useState } from "react";

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";

interface ConfirmDeleteOptions {
  /** 实体中文名（如"影视"、"图书"），用于拼接标题"删除{entityLabel}" */
  entityLabel?: string;
  /** 记录名称（如标题、名称），用于拼接描述"确定要删除「{recordName}」吗？此操作无法撤销。" */
  recordName?: string;
  /** 完整自定义描述文案（优先级高于 recordName 拼接） */
  description?: string;
  /** 确认按钮文案，默认"删除" */
  confirmText?: string;
}

export function useConfirmDelete() {
  const [open, setOpen] = useState(false);
  const [pendingAction, setPendingAction] = useState<(() => void | Promise<void>) | null>(null);
  // 弹窗文案状态（独立管理，避免与 pendingAction 闭包耦合）
  const [title, setTitle] = useState<string>("确认删除");
  const [description, setDescription] = useState<string | null>(null);
  const [confirmText, setConfirmText] = useState<string>("删除");

  /**
   * 触发确认对话框
   *
   * @param onConfirm 用户点击"删除"后执行的回调（支持 async）
   * @param options.entityLabel 实体中文名，拼接标题"删除{entityLabel}"
   * @param options.recordName 记录名称，拼接描述"确定要删除「{recordName}」吗？此操作无法撤销。"
   * @param options.description 完整自定义描述（优先级高于 recordName）
   * @param options.confirmText 确认按钮文案，默认"删除"
   */
  const confirmDelete = useCallback(
    (
      onConfirm: () => void | Promise<void>,
      options?: ConfirmDeleteOptions,
    ) => {
      setPendingAction(() => onConfirm);
      // 标题：优先用 entityLabel 拼接，否则回退"确认删除"
      setTitle(options?.entityLabel ? `删除${options.entityLabel}` : "确认删除");
      // 描述：优先用完整 description，其次用 recordName 拼接，最后回退通用文案
      setDescription(
        options?.description ??
          (options?.recordName
            ? `确定要删除「${options.recordName}」吗？此操作无法撤销。`
            : "此操作不可撤销，确定要删除这条记录吗？"),
      );
      setConfirmText(options?.confirmText ?? "删除");
      setOpen(true);
    },
    [],
  );

  const handleConfirm = useCallback(() => {
    setOpen(false);
    const action = pendingAction;
    setPendingAction(null);
    if (action) {
      // 异步执行，不阻塞 UI 关闭
      void action();
    }
  }, [pendingAction]);

  const handleCancel = useCallback(() => {
    setOpen(false);
    setPendingAction(null);
  }, []);

  const dialogElement = (
    <AlertDialog open={open} onOpenChange={(v) => !v && handleCancel()}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>
            {description ?? "此操作不可撤销，确定要删除这条记录吗？"}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel onClick={handleCancel}>取消</AlertDialogCancel>
          <AlertDialogAction
            onClick={handleConfirm}
            className="bg-destructive text-white hover:bg-destructive/90"
          >
            {confirmText}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );

  return { confirmDelete, dialogElement };
}
