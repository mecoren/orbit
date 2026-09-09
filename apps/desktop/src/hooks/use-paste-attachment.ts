/**
 * B3 剪贴板截图直粘附件（零依赖方案）
 *
 * 不装 tauri-plugin-clipboard-manager：桌面 webview 的 paste 事件自带
 * clipboardData.files（截图工具写入的位图是真 File 对象）。监听范围 =
 * 详情抽屉附件区（错粘风险控制：全局粘进"选中任务"易误投）。
 * 焦点守卫：焦点在输入控件时让位原生粘贴（文本粘贴到标题/描述不受影响）。
 */
import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

/** 从 paste 事件提取第一个图片文件；截图位图无 name 时按时间戳生成 */
export function extractImageFromPaste(
  e: ClipboardEvent,
): { file: File; name: string; mime: string } | null {
  const files = e.clipboardData?.files;
  if (!files) return null;
  for (const f of Array.from(files)) {
    if (f.type.startsWith("image/")) {
      return { file: f, name: f.name || pastedImageName(f.type), mime: f.type };
    }
  }
  return null;
}

/** 生成「粘贴图片_yyyyMMdd_HHmmss.扩展名」（jpeg→jpg，未知 mime 回退 png） */
export function pastedImageName(mime: string, now = new Date()): string {
  const ext = mime === "image/jpeg" ? "jpg" : "png";
  const p = (n: number) => String(n).padStart(2, "0");
  return `粘贴图片_${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}_${p(
    now.getHours(),
  )}${p(now.getMinutes())}${p(now.getSeconds())}.${ext}`;
}

/** 焦点位于可编辑控件时让位原生粘贴 */
function isEditableTarget(el: Element | null): boolean {
  return (
    el instanceof HTMLInputElement ||
    el instanceof HTMLTextAreaElement ||
    (el instanceof HTMLElement && el.isContentEditable)
  );
}

/**
 * 详情抽屉附件区挂载：window 级 paste 监听（粘贴事件焦点在 body 时
 * 仍冒泡到 window），命中图片则经既有 bytes 通道入附件库（hash 由 Rust 算）。
 */
export function usePasteAttachment(taskId: number | null) {
  const qc = useQueryClient();
  const busyRef = useRef(false);

  useEffect(() => {
    if (taskId == null) return;
    const onPaste = async (e: ClipboardEvent) => {
      if (busyRef.current) return;
      if (isEditableTarget(document.activeElement)) return;
      const found = extractImageFromPaste(e);
      if (!found) return;
      e.preventDefault();
      busyRef.current = true;
      try {
        const bytes = new Uint8Array(await found.file.arrayBuffer());
        const { taskAttachmentAdd } = await import("@/lib/tauri");
        await taskAttachmentAdd(taskId, found.name, found.mime, Array.from(bytes));
        void qc.invalidateQueries({ queryKey: ["task-attachments", taskId] });
        toast.success(`已粘贴附件「${found.name}」`);
      } catch (err) {
        toast.error(`粘贴附件失败：${err}`);
      } finally {
        busyRef.current = false;
      }
    };
    window.addEventListener("paste", onPaste);
    return () => window.removeEventListener("paste", onPaste);
  }, [taskId, qc]);
}
