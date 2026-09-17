/**
 * 通知历史分区（#5；Todoist 同款通知页）
 *
 * 桌面 Windows Toast 一旦错过或清掉就无处回看——本面板回看呈现轨迹
 * （提醒到期 / 推迟 / 完成），数据源 notification_log（只读本地表，
 * 各端各自记录，不随云同步）。列表倒序 + kind 徽标 + 清空。
 */
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Bell, BellRing, CheckCircle2, Clock4, Trash2 } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
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
import { notificationLogClear, notificationLogList } from "@/lib/tauri";

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

/** kind 中文标签（与 Rust 写入口径一一） */
const KIND_LABELS: Record<string, string> = {
  reminder_due: "提醒到期",
  snooze: "推迟",
  complete: "完成",
  boot_skip: "跳过",
};

function kindIcon(kind: string) {
  if (kind === "snooze") return Clock4;
  if (kind === "complete") return CheckCircle2;
  return kind === "boot_skip" ? Bell : BellRing;
}

/** 时间展示：当日 HH:mm；跨日补日期（轨迹回看以近为主） */
function fmtTime(ms: number): string {
  const d = new Date(ms);
  const now = new Date();
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  return sameDay ? hm : `${d.getMonth() + 1}/${d.getDate()} ${hm}`;
}

export function NotificationHistorySection() {
  const queryClient = useQueryClient();
  // 清空二次确认：物理删除本地通知记录（普通确认即可，非同步数据）
  const [clearOpen, setClearOpen] = useState(false);
  const { data: rows = [] } = useQuery({
    queryKey: ["notification-log", "list"],
    queryFn: () => notificationLogList(undefined, 100),
    staleTime: 30_000,
  });

  const clearMutation = useMutation({
    mutationFn: () => notificationLogClear(),
    onSuccess: (n) => {
      queryClient.invalidateQueries({ queryKey: ["notification-log"] });
      toast.success(`已清空通知历史（${n} 条）`);
    },
    onError: () => toast.error("清空失败"),
  });

  return (
    <div className="flex flex-col gap-6">
      <SectionHeader
        title="通知历史"
        desc="提醒到期与处置动作的呈现轨迹回看。本表为本地记录（各端各自记录各自的轨迹），不随云同步。"
      />

      <div className="flex items-center justify-between">
        <span className="text-sm text-muted-foreground">{rows.length} 条记录</span>
        <Button
          variant="outline"
          size="sm"
          disabled={rows.length === 0 || clearMutation.isPending}
          onClick={() => setClearOpen(true)}
        >
          <Trash2 className="mr-1 size-3.5" />
          清空
        </Button>
      </div>

      {/* 清空确认：物理删除全部本地通知记录，不可撤销（普通确认） */}
      <AlertDialog open={clearOpen} onOpenChange={setClearOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>清空通知历史</AlertDialogTitle>
            <AlertDialogDescription>
              将删除全部 {rows.length} 条本地通知记录，此操作不可撤销。
              记录仅存于本机，不影响任务数据与云同步。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              disabled={clearMutation.isPending}
              onClick={() => {
                setClearOpen(false);
                clearMutation.mutate();
              }}
            >
              确认清空
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <div className="rounded-lg border border-border/60">
        {rows.length === 0 ? (
          <div className="flex flex-col items-center gap-2 px-4 py-10 text-muted-foreground">
            <Bell className="size-8" />
            <span className="text-sm">暂无通知记录；提醒到期后在此回看轨迹。</span>
          </div>
        ) : (
          rows.map((r, i) => {
            const Icon = kindIcon(r.kind);
            return (
              <div
                key={r.id}
                className={
                  "flex items-center gap-3 px-4 py-2.5" +
                  (i > 0 ? " border-t border-border/40" : "")
                }
              >
                <Icon className="size-4 shrink-0 text-muted-foreground" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm">{r.task_title}</div>
                  <div className="text-xs text-muted-foreground">
                    {KIND_LABELS[r.kind] ?? r.kind} · {fmtTime(r.created_at)}
                  </div>
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}
