/**
 * B3 剪贴板截图直粘附件 + B3+ 拖放文件入附件（零依赖方案）
 *
 * 不装 tauri-plugin-clipboard-manager：桌面 webview 的 paste 事件自带
 * clipboardData.files（截图工具写入的位图是真 File 对象）。监听范围 =
 * 详情抽屉附件区（错粘风险控制：全局粘进"选中任务"易误投）。
 * 焦点守卫：焦点在输入控件时让位原生粘贴（文本粘贴到标题/描述不受影响）。
 *
 * 拖放（2026-09-14，Todoist/Things/MS To Do 桌面标配）：附件区 drop
 * 事件自带 dataTransfer.files（拖入文件是真 File 对象，与粘贴同构——
 * 不需要 dragover 读路径，也就不需要 tauri fs 权限）。范围同样限定
 * 附件区：拖到描述输入框的文本放置（拖字符串）不受影响——有
 * types.includes("Files") 守卫。多文件逐个入附件（走同一 20×50MB 守卫）。
 */
import { useCallback, useEffect, useRef } from "react";
import type { DragEvent as ReactDragEvent } from "react";
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

/** 从 drop 事件提取文件列表；非文件拖放（拖文本/拖任务行）返回空 */
export function extractFilesFromDrop(e: DragEvent): File[] {
  if (!e.dataTransfer?.types.includes("Files")) return [];
  return Array.from(e.dataTransfer.files);
}

/** 通用入附件通道：文件数组逐个走 bytes 通道（hash 由 Rust 内容寻址算） */
async function addFilesAsAttachments(
  files: File[],
  taskId: number,
  onSuccess: (count: number) => void,
  onError: (msg: string) => void,
) {
  const { taskAttachmentAdd } = await import("@/lib/tauri");
  let added = 0;
  const failed: string[] = [];
  for (const f of files) {
    try {
      const bytes = new Uint8Array(await f.arrayBuffer());
      await taskAttachmentAdd(taskId, f.name || "附件", f.type || "application/octet-stream", Array.from(bytes));
      added++;
    } catch (err) {
      failed.push(f.name || "附件");
      if (added === 0 && failed.length === 1) {
        // 首个即失败（多为超 50MB 守卫）：直接提示不静默
        onError(`${f.name || "附件"}：${err}`);
        return;
      }
    }
  }
  if (added > 0) onSuccess(added);
  if (failed.length > 0) onError(`未添加：${failed.join("、")}`);
}

/**
 * 详情抽屉附件区挂载：window 级 paste 监听（粘贴事件焦点在 body 时
 * 仍冒泡到 window），命中图片则经既有 bytes 通道入附件库（hash 由 Rust 算）。
 * 返回 drop 事件处理器——由附件区容器 onDrop 消费（拖放命中范围 =
 * 光标所在附件区视觉区，window 级监听拖放会吞掉文本域的正常放置）。
 */
export function usePasteAttachment(taskId: number | null) {
  const qc = useQueryClient();
  const busyRef = useRef(false);

  const invalidate = () => {
    if (taskId != null) void qc.invalidateQueries({ queryKey: ["task-attachments", taskId] });
  };

  const onDrop = useCallback(async (e: ReactDragEvent) => {
    if (taskId == null || busyRef.current) return;
    const files = extractFilesFromDrop(e.nativeEvent);
    if (files.length === 0) return;
    e.preventDefault();
    e.stopPropagation();
    busyRef.current = true;
    try {
      await addFilesAsAttachments(
        files,
        taskId,
        (n) => {
          invalidate();
          toast.success(n === 1 ? `已添加附件「${files[0].name}」` : `已添加 ${n} 个附件`);
        },
        (msg) => toast.error(`附件添加失败：${msg}`),
      );
    } finally {
      busyRef.current = false;
    }
  }, [taskId, invalidate]);

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

  return { onDrop };
}
