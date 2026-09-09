/**
 * 回收站面板 —— /todo/trash（07 报告 #3 回收站落地；挂在 TodoShell 内，
 * 侧栏常驻、任务面板的选中态跨面板保留）
 *
 * 数据 = todo_tasks 墓碑行（is_deleted=1），最近删除排最前。
 * 行为：
 * - 恢复：翻转回存活态（原项目已删则落未分组），react-query 全量失效刷新；
 * - 彻底删除：物理 DELETE（二次确认，destructive）；
 * - 清空回收站：全部墓碑物理删除（计数确认）；
 * - 保留期徽标：按设置档位显示「N 天后自动清除」/「永久保留」。
 * 自动过期清理由 Rust 守护（trash_scheduler 60s tick）执行，页面只读展示。
 */
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { ArchiveRestore, Inbox, Trash2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/business/empty-state";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  hideFromQueries,
  useUndoableDeleteAction,
} from "@/hooks/use-undoable-delete";
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
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import {
  trashMeta,
  trashPurgeAll,
  trashTaskPurge,
  trashTaskRestore,
  trashTasksList,
  type TodoTask,
} from "@/lib/tauri";

const DAY_MS = 86_400_000;

/** 保留档位 → 文案（0 = 永久） */
function retentionLabel(days: number): string {
  if (days === 0) return "永久保留";
  return `${days} 天`;
}

/** 剩余天数文案：永久 → 删除日期；有档位 → N 天后自动清除 */
function expiresLabel(task: TodoTask, retentionDays: number): string {
  const deletedAt = task.deleted_at ?? 0;
  const deletedText = new Date(deletedAt).toLocaleDateString();
  if (retentionDays === 0) return `删除于 ${deletedText}`;
  const remain = Math.ceil((deletedAt + retentionDays * DAY_MS - Date.now()) / DAY_MS);
  if (remain <= 0) return "即将自动清除";
  return `${remain} 天后自动清除`;
}

/** 回收站面板（TodoShell 嵌套路由 /todo/trash；壳层提供侧栏与弹层） */
export function TrashPanel() {
  const qc = useQueryClient();
  const [purgeTarget, setPurgeTarget] = useState<TodoTask | null>(null);
  const [purgeAllOpen, setPurgeAllOpen] = useState(false);

  const trashQuery = useQuery({
    queryKey: ["trash", "tasks"],
    queryFn: trashTasksList,
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });
  const metaQuery = useQuery({
    queryKey: ["trash", "meta"],
    queryFn: trashMeta,
    staleTime: 2 * 60 * 1000,
  });

  const tasks = trashQuery.data ?? [];
  const retentionDays = metaQuery.data?.retention_days ?? 30;

  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: ["trash"] });
    // 任务列表/项目计数等业务缓存一并失效（恢复后正常列表要能看到）
    void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
    void qc.invalidateQueries({ queryKey: ["todo-task-detail"] });
  };

  const restoreMutation = useMutation({
    mutationFn: (id: number) => trashTaskRestore(id),
    onSuccess: (t) => {
      toast.success(`已恢复「${t.title}」`);
      invalidate();
    },
    onError: (e) => toast.error(String(e)),
  });

  // 彻底删除/清空走可撤销删除（P0#3 同款延迟提交）：purge 是物理 DELETE，
  // 撤销只能在提交前拦截——乐观隐藏行 + 5s 撤销窗口后才真正落库。
  const undoableDelete = useUndoableDeleteAction();

  // 彻底删除（可撤销）：乐观摘除回收站缓存行，5s 内点撤销恢复
  const confirmPurge = (t: TodoTask) => {
    setPurgeTarget(null);
    undoableDelete({
      entityLabel: "任务",
      recordName: t.title,
      hide: (qc) => hideFromQueries<TodoTask>(qc, ["trash", "tasks"], t.id),
      commit: async () => {
        await trashTaskPurge(t.id);
      },
    });
  };

  // 清空回收站（可撤销，整批单笔）：一次隐藏全部墓碑 + 一次提交，
  // 撤销一键整批恢复（批量删除同款单槽位口径——逐条循环会互相 flush 落库）
  const confirmPurgeAll = () => {
    setPurgeAllOpen(false);
    const ids = tasks.map((t) => t.id);
    undoableDelete({
      entityLabel: "任务",
      count: ids.length,
      hide: (qc) => {
        for (const id of ids) hideFromQueries<TodoTask>(qc, ["trash", "tasks"], id);
      },
      commit: async () => {
        await trashPurgeAll();
      },
    });
  };

  return (
    <div className="flex h-full flex-col">
      {/* 工具栏 */}
      <div className="flex items-center justify-between gap-3 border-b px-4 py-3">
        <div className="flex items-baseline gap-2">
          <h1 className="text-lg font-semibold">回收站</h1>
          <span className="text-sm text-muted-foreground">{tasks.length}</span>
          <span className="text-xs text-muted-foreground">
            （保留 {retentionLabel(retentionDays)}，可在设置 - 待办中调整）
          </span>
        </div>
        <Button
          variant="outline"
          size="sm"
          className="h-8"
          disabled={tasks.length === 0}
          onClick={() => setPurgeAllOpen(true)}
        >
          <Trash2 size={14} className="mr-1" />
          清空回收站
        </Button>
      </div>

      {/* 列表区：空态在 ScrollArea 外普通容器里垂直居中（ScrollArea 内 h-full
          解析不到视口高度会顶对齐，对齐 TaskListView/CalendarView 空态口径） */}
      {tasks.length === 0 ? (
        <div className="flex min-h-0 flex-1 items-center justify-center overflow-y-auto">
          <EmptyState
            icon={Inbox}
            title="回收站是空的"
            hint="删除的任务会先进入这里，过期后自动清除"
          />
        </div>
      ) : (
        <ScrollArea className="min-h-0 flex-1">
          <div className="mx-auto max-w-2xl space-y-0.5 p-4">
            {tasks.map((t) => (
              <div
                key={t.id}
                className="group flex items-center gap-3 rounded-md border px-3 py-2.5"
              >
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">{t.title}</p>
                  <p className="mt-0.5 text-xs text-muted-foreground">
                    {expiresLabel(t, retentionDays)}
                  </p>
                </div>
                <Tooltip>
                  <TooltipTrigger asChild>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="size-8"
                      aria-label="恢复"
                      disabled={restoreMutation.isPending}
                      onClick={() => restoreMutation.mutate(t.id)}
                    >
                      <ArchiveRestore className="size-4" />
                    </Button>
                  </TooltipTrigger>
                  <TooltipContent>恢复到任务列表</TooltipContent>
                </Tooltip>
                <Tooltip>
                  <TooltipTrigger asChild>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="size-8 text-destructive hover:text-destructive"
                      aria-label="彻底删除"
                      onClick={() => setPurgeTarget(t)}
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </TooltipTrigger>
                  <TooltipContent>彻底删除（5 秒内可撤销）</TooltipContent>
                </Tooltip>
              </div>
            ))}
          </div>
        </ScrollArea>
      )}

      {/* 彻底删除确认 */}
      <AlertDialog
        open={purgeTarget != null}
        onOpenChange={(o) => !o && setPurgeTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>彻底删除任务</AlertDialogTitle>
            <AlertDialogDescription className="break-words">
              确定要彻底删除「{purgeTarget?.title}」吗？任务及其子任务、评论、提醒将一并被清除，
              删除后 5 秒内可撤销。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => {
                if (purgeTarget) confirmPurge(purgeTarget);
              }}
            >
              彻底删除
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* 清空确认 */}
      <AlertDialog open={purgeAllOpen} onOpenChange={setPurgeAllOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>清空回收站</AlertDialogTitle>
            <AlertDialogDescription>
              确定要清空回收站中的 {tasks.length} 个任务吗？删除后 5 秒内可整批撤销。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => confirmPurgeAll()}
            >
              清空
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
