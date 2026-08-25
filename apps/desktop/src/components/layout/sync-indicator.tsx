/**
 * SyncIndicator — 右下角悬浮同步状态指示器（03 文档 §八 origin 过滤约定）
 *
 * - 仅响应 origin=background 的 sync-progress 事件（Manual 的进度由设置页展示，
 *   Exit 由遮罩层消费——MVP 未做退出同步）
 * - phase=done/error 时自动隐藏；key_mismatch 错误跳转恢复引导页
 */
import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { RefreshCw } from "lucide-react";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
// 本组件渲染在 <RouterProvider> 之外（全局悬浮层），
// 不能用 useNavigate()，改用数据路由器的命令式导航
import { router } from "@/router";

interface SyncProgressEvent {
  phase: "starting" | "pushing" | "pulling" | "merging" | "local_data_applied" | "attachments" | "done" | "error";
  origin: "background" | "manual" | "exit";
  display_name?: string;
  current?: number;
  total?: number;
  message?: string;
}

function progressText(e: SyncProgressEvent): string {
  switch (e.phase) {
    case "starting":
      return "准备同步…";
    case "pushing":
      return `正在上传${e.display_name ?? ""} ${e.current ?? 0}/${e.total ?? 0}…`;
    case "pulling":
      return `正在下载${e.display_name ?? ""} ${e.current ?? 0}/${e.total ?? 0}…`;
    case "merging":
      return `正在合并${e.display_name ?? ""}…`;
    case "local_data_applied":
      return "本地数据已更新";
    case "attachments":
      return "同步附件中…";
    default:
      return "";
  }
}

export function SyncIndicator() {
  const [visible, setVisible] = useState(false);
  const [text, setText] = useState("");
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    const unlisten = listen<SyncProgressEvent>("sync-progress", (evt) => {
      const p = evt.payload;
      if (p.origin !== "background") return;

      if (p.phase === "done") {
        setText("同步完成");
        // 短暂展示完成后隐藏
        if (hideTimer.current) clearTimeout(hideTimer.current);
        hideTimer.current = setTimeout(() => setVisible(false), 2000);
        return;
      }
      if (p.phase === "error") {
        setVisible(false);
        toast.error(`后台自动同步失败：${p.message ?? "未知错误"}`);
        return;
      }
      if (hideTimer.current) {
        clearTimeout(hideTimer.current);
        hideTimer.current = null;
      }
      setVisible(true);
      setText(progressText(p));
    });

    const unlistenMismatch = listen("sync-key-mismatch", () => {
      setVisible(false);
      void router.navigate("/sync-recovery");
    });

    return () => {
      unlisten.then((fn) => fn());
      unlistenMismatch.then((fn) => fn());
      if (hideTimer.current) clearTimeout(hideTimer.current);
    };
  }, []);

  if (!visible) return null;

  return (
    <div
      className={cn(
        "fixed bottom-4 right-4 z-50 flex items-center gap-2 rounded-full border bg-card px-3 py-1.5 shadow-lg",
      )}
    >
      <RefreshCw className="size-3.5 animate-spin text-primary" />
      <span className="text-xs text-muted-foreground">{text || "同步中…"}</span>
    </div>
  );
}
