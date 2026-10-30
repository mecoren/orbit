/**
 * 回收站面板 —— /todo/trash（07 报告 #3 回收站落地；挂在 TodoShell 内，
 * 侧栏常驻、任务面板的选中态跨面板保留）
 *
 * 数据 = todo_tasks 墓碑行（is_deleted=1），最近删除排最前。
 * 行为：
 * - 恢复 / 彻底删除：行尾图标钮先出**行内小弹框**确认（ConfirmPopover，
 *   锚定在钮下方、点外部即取消），确认后恢复翻转存活态 / 物理 DELETE
 *   （彻底删除另留 5s 撤销窗口）；
 * - 清空回收站 / 清理过期：一次能清掉整站墓碑的批量物理删除，走两段式确认——
 *   两段都是 `DangerousConfirmDialog`，每段 3 秒时停（`PURGE_HOLD_SECONDS`，比全局
 *   危险操作 5s 略短）：第一段读后果点「继续」，第二段独立再时停一次，第二击才执行；
 * - 保留期徽标：按设置档位显示「N 天后自动清除」/「永久保留」。
 * 自动过期清理由 Rust 守护（trash_scheduler 60s tick）执行，页面只读展示。
 */
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { ArchiveRestore, Inbox, Trash2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { DangerousConfirmDialog } from "@/components/ui/dangerous-confirm-dialog";
import { EmptyState } from "@/components/business/empty-state";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  hideFromQueries,
  useUndoableDeleteAction,
} from "@/hooks/use-undoable-delete";
import { ConfirmPopover } from "../shared/confirm-popover";
import {
  trashMeta,
  trashPurgeAll,
  trashPurgeExpired,
  trashTaskPurge,
  trashTaskRestore,
  trashTasksList,
  type TodoTask,
} from "@/lib/tauri";

const DAY_MS = 86_400_000;

/** 批量物理删除两段确认的时停秒数（本页口径 3s；全局危险操作默认 5s） */
const PURGE_HOLD_SECONDS = 3;

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
  // 行尾动作（恢复 / 彻底删除）统一走行内小弹框确认：{ 行 id, 动作 }，null 关闭。
  const [confirmAction, setConfirmAction] = useState<{
    id: number;
    kind: "restore" | "purge";
  } | null>(null);
  // 批量物理删除的两段式确认阶段：null 关闭 / read 读后果 / final 时停后执行。
  // 这两颗钮一次可清掉整站墓碑，误触代价远大于单条删除，故多一道时停门。
  const [purgeAllStage, setPurgeAllStage] = useState<"read" | "final" | null>(null);
  const [purgeExpiredStage, setPurgeExpiredStage] = useState<"read" | "final" | null>(null);

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
    setPurgeAllStage(null);
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

  // 立即清理过期（#107）：不等 60s 守护 tick。core 会跳过「删除尚未 push」
  // 的墓碑（guarded），这里如实把跳过条数告诉用户，避免误以为全清了。
  const purgeExpiredMutation = useMutation({
    mutationFn: trashPurgeExpired,
    onSuccess: (stats) => {
      setPurgeExpiredStage(null);
      const guardedHint =
        stats.guarded > 0 ? `${stats.guarded} 条因删除尚未同步到云端而保留。` : undefined;
      if (stats.purged === 0) {
        toast.info("没有可清理的过期任务", {
          description: guardedHint ?? "保留期内的任务不会被提前清除。",
        });
      } else {
        toast.success(`已清理 ${stats.purged} 条过期任务`, { description: guardedHint });
      }
      invalidate();
    },
    onError: (e) => toast.error(String(e)),
  });

  return (
    <div role="region" aria-label="回收站" className="flex h-full flex-col">
      {/* 工具栏 */}
      <div className="flex items-center justify-between gap-3 border-b px-4 py-3">
        <div className="flex items-baseline gap-2">
          <h1 className="text-lg font-semibold">回收站</h1>
          <span className="text-sm text-muted-foreground">{tasks.length}</span>
          <span className="text-xs text-muted-foreground">
            （保留 {retentionLabel(retentionDays)}，可在设置 - 待办中调整）
          </span>
        </div>
        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            size="sm"
            className="h-8"
            // 永久保留档不存在「过期」，禁用入口——否则要走完两段确认才被告知无事可做
            disabled={tasks.length === 0 || purgeExpiredMutation.isPending || retentionDays === 0}
            onClick={() => setPurgeExpiredStage("read")}
          >
            <Trash2 size={14} className="mr-1" />
            清理过期
          </Button>
          <Button
            variant="outline"
            size="sm"
            className="h-8"
            disabled={tasks.length === 0}
            onClick={() => setPurgeAllStage("read")}
          >
            <Trash2 size={14} className="mr-1" />
            清空回收站
          </Button>
        </div>
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
                {/* 行尾两钮都先出小弹框确认（行内轻量形制，不打断地居中弹层） */}
                <ConfirmPopover
                  open={confirmAction?.id === t.id && confirmAction.kind === "restore"}
                  onOpenChange={(o) =>
                    setConfirmAction(o ? { id: t.id, kind: "restore" } : null)
                  }
                  title="恢复任务"
                  description={`确定要把「${t.title}」恢复到任务列表吗？`}
                  confirmLabel="恢复"
                  tooltip="恢复到任务列表"
                  onConfirm={() => restoreMutation.mutate(t.id)}
                >
                  <Button
                    variant="ghost"
                    size="icon"
                    className="size-8"
                    aria-label="恢复"
                    disabled={restoreMutation.isPending}
                  >
                    <ArchiveRestore className="size-4" />
                  </Button>
                </ConfirmPopover>
                <ConfirmPopover
                  open={confirmAction?.id === t.id && confirmAction.kind === "purge"}
                  onOpenChange={(o) => setConfirmAction(o ? { id: t.id, kind: "purge" } : null)}
                  title="彻底删除任务"
                  description={`确定要彻底删除「${t.title}」吗？任务及其子任务、评论、提醒将一并被清除，删除后 5 秒内可撤销。`}
                  confirmLabel="彻底删除"
                  tooltip="彻底删除（5 秒内可撤销）"
                  onConfirm={() => confirmPurge(t)}
                >
                  <Button
                    variant="ghost"
                    size="icon"
                    className="size-8 text-destructive hover:text-destructive"
                    aria-label="彻底删除"
                  >
                    <Trash2 className="size-4" />
                  </Button>
                </ConfirmPopover>
              </div>
            ))}
          </div>
        </ScrollArea>
      )}

      {/* 清理过期 · 第一段：读后果（同样 5 秒时停——两段都时停，读完再进第二段）。
          两段都用 DangerousConfirmDialog（同一内联时停原语）：曾用 AlertDialogAction 做
          「继续」，它点击即关层并回调 onOpenChange(false)，把阶段复位成 null，与切段互相
          抵消，表现为点「继续」毫无反应（2026-10-29 踩坑）。 */}
      <DangerousConfirmDialog
        open={purgeExpiredStage === "read"}
        onOpenChange={(o) => {
          if (!o) setPurgeExpiredStage(null);
        }}
        title="清理过期任务"
        description={`立即执行一次保留期清理（等价于后台守护每 60 秒的一轮）。只物理删除已超过 ${retentionDays} 天保留期的任务，删除尚未同步到云端的会跳过。确认后还需再确认一次才会真正执行。`}
        confirmLabel="继续"
        holdSeconds={PURGE_HOLD_SECONDS}
        onConfirm={() => setPurgeExpiredStage("final")}
      />

      {/* 清理过期 · 第二段：3 秒时停走完才可点，点了即真删 */}
      <DangerousConfirmDialog
        open={purgeExpiredStage === "final"}
        onOpenChange={(o) => {
          if (!o) setPurgeExpiredStage(null);
        }}
        title="再次确认：清理过期任务"
        description={`确认后将物理删除已超过 ${retentionDays} 天保留期的任务（删除尚未同步到云端的会跳过），该操作不可撤销。`}
        confirmLabel="立即清理"
        holdSeconds={PURGE_HOLD_SECONDS}
        busy={purgeExpiredMutation.isPending}
        onConfirm={() => purgeExpiredMutation.mutate()}
      />

      {/* 清空回收站 · 第一段：读后果（计数 + 影响面，同样 3 秒时停） */}
      <DangerousConfirmDialog
        open={purgeAllStage === "read"}
        onOpenChange={(o) => {
          if (!o) setPurgeAllStage(null);
        }}
        title="清空回收站"
        description={`确定要清空回收站中的 ${tasks.length} 个任务吗？任务及其子任务、评论、提醒将一并被清除。确认后还需再确认一次才会真正执行。`}
        confirmLabel="继续"
        holdSeconds={PURGE_HOLD_SECONDS}
        onConfirm={() => setPurgeAllStage("final")}
      />

      {/* 清空回收站 · 第二段：3 秒时停走完才可点，点了即真删（仍留 5s 撤销窗口） */}
      <DangerousConfirmDialog
        open={purgeAllStage === "final"}
        onOpenChange={(o) => {
          if (!o) setPurgeAllStage(null);
        }}
        title="再次确认：清空回收站"
        description={`即将永久删除 ${tasks.length} 个任务及其子任务、评论、提醒。执行后仅剩 5 秒撤销窗口（提示条上点撤销可整批恢复）。`}
        confirmLabel="清空回收站"
        holdSeconds={PURGE_HOLD_SECONDS}
        onConfirm={() => confirmPurgeAll()}
      />
    </div>
  );
}
