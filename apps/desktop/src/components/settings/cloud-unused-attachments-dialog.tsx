/**
 * 云端孤儿附件清理弹窗（设置 → 诊断 → 云端存储「清理云端孤儿附件」）
 *
 * 设计口径（docs/15）：
 * - 清单来自 core `cloud_unused_attachments_scan`：**云端对象集 − 云端引用集**
 *   （`todo_task_attachments` 云端分桶中 `is_deleted = 0` 的 hash 并集）。
 *   不看本机账本——本机「无引用」只是本机视角，离线设备的行可能还没 push。
 * - 只列年龄窗口（30 天）外的对象；服务端不给 mtime 的一律不列（宁可漏收）。
 * - 执行删除时原样回传扫描结果的 `epoch`：扫描后他端 push 过 → 拒绝并要求重扫。
 * - 破坏性动作走 DangerousConfirmDialog 五秒冷静期；文案必须写清「云端密文
 *   对象被删」「其他设备有本地副本会自动重传」「都无副本即永久丢失」。
 * - 删除成功后刷新清单与诊断读数；清单清空自动关层。
 */
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { CloudOff, FileText } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { DangerousConfirmDialog } from "@/components/ui/dangerous-confirm-dialog";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { cloudUnusedAttachmentsDelete, cloudUnusedAttachmentsScan } from "@/lib/tauri";
import { formatBytes, formatCount } from "./diagnostics-format";
import {
  cloudAttachmentLabel,
  cloudItemBytes,
  cloudKindLabel,
  formatCloudLastModified,
  summarizeCloudSelection,
  toggleAllCloud,
} from "./cloud-unused-attachments-selection";

interface CloudUnusedAttachmentsDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 清理成功后回调（诊断页重新采集读数） */
  onCleaned: () => void;
}

export function CloudUnusedAttachmentsDialog({
  open,
  onOpenChange,
  onCleaned,
}: CloudUnusedAttachmentsDialogProps) {
  const [selected, setSelected] = useState<Set<string>>(new Set());
  /** 待确认的 hash 列表（null = 未弹确认层） */
  const [confirming, setConfirming] = useState<string[] | null>(null);
  const [busy, setBusy] = useState(false);

  const { data, isPending, refetch } = useQuery({
    queryKey: ["cloud_attachments_unused"],
    queryFn: cloudUnusedAttachmentsScan,
    enabled: open,
    staleTime: 0,
    gcTime: 0,
    refetchOnWindowFocus: false,
    // 未配置同步/未解锁不是「可重试」错误：别在三秒内连打三次
    retry: false,
  });
  const items = data?.items ?? [];
  const summary = summarizeCloudSelection(items, selected);
  const minAgeDays = Math.round((data?.min_age_secs ?? 0) / 86400);

  useEffect(() => {
    if (!open) setSelected(new Set());
  }, [open]);

  // 清单刷新后剔除已不存在的 hash（删除成功/别处已清理）
  useEffect(() => {
    if (!data) return;
    setSelected((prev) => {
      const next = new Set<string>();
      for (const item of data.items) if (prev.has(item.hash)) next.add(item.hash);
      return next.size === prev.size ? prev : next;
    });
  }, [data]);

  const toggleOne = (hash: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(hash)) next.delete(hash);
      else next.add(hash);
      return next;
    });
  };

  const confirmingBytes = items
    .filter((i) => confirming?.includes(i.hash))
    .reduce((sum, i) => sum + cloudItemBytes(i), 0);

  const remove = async (hashes: string[]) => {
    setBusy(true);
    try {
      const result = await cloudUnusedAttachmentsDelete(hashes, data?.epoch ?? 0);
      setConfirming(null);
      onCleaned();

      if (result.stale_manifest) {
        toast.warning("云端刚有新的同步活动", {
          description: "引用集可能已变化，已重新扫描；请确认清单后再清理。",
        });
        await refetch();
        return;
      }

      if (result.deleted_assets === 0) {
        toast.info("没有可清理的云端附件", {
          description: "清单可能已过期，已自动刷新。",
        });
        await refetch();
        return;
      }

      const skipped =
        result.skipped_referenced > 0
          ? `；${result.skipped_referenced} 个仍被其他设备引用，已跳过`
          : "";
      if (result.errors.length > 0) {
        toast.warning(`已清理 ${formatCount(result.deleted_assets)} 个云端附件（部分失败）`, {
          description: `${result.errors[0]}${skipped}`,
        });
      } else {
        toast.success(`已清理 ${formatCount(result.deleted_assets)} 个云端附件`, {
          description: `删除 ${formatCount(result.deleted_objects)} 个云端对象${
            skipped || `；本地账本清理 ${formatCount(result.local_rows_cleaned)} 行`
          }`,
        });
      }

      const next = await refetch();
      if ((next.data?.items.length ?? 0) === 0) onOpenChange(false);
    } catch (e) {
      toast.error("清理云端附件失败", {
        description: e instanceof Error ? e.message : String(e),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      {/*
        两段式：确认期间先关掉列表层。Radix 模态 Dialog 会给 body 设
        pointer-events:none 并用 FocusScope 锁焦点，内联的 DangerousConfirmDialog
        叠在 z-[60] 上也点不动；列表层收起后遮罩才能正常交互。
      */}
      <Dialog
        open={open && confirming == null}
        onOpenChange={(o) => {
          if (!o && confirming == null) onOpenChange(false);
        }}
      >
        <DialogContent className="sm:max-w-2xl">
          <DialogHeader>
            <DialogTitle>清理云端孤儿附件</DialogTitle>
            <DialogDescription>
              以下云端附件已无任何设备引用。仅列出 {minAgeDays || 30}{" "}
              天前上传的对象；删除的是云端密文副本，其他设备若仍持有本地文件会在下次同步自动重传。
            </DialogDescription>
          </DialogHeader>

          {isPending ? (
            <div className="py-10 text-center text-sm text-muted-foreground">扫描云端…</div>
          ) : items.length === 0 ? (
            <div className="flex flex-col items-center gap-2 rounded-md border border-dashed py-10 text-center">
              <CloudOff className="size-8 text-muted-foreground" />
              <p className="text-sm font-medium">没有可清理的云端附件</p>
              <p className="text-xs text-muted-foreground">
                云端对象均被任务引用，或上传不足 {minAgeDays || 30} 天。
              </p>
            </div>
          ) : (
            <>
              <div className="flex items-center justify-between gap-4">
                <label className="flex cursor-pointer items-center gap-2 text-sm">
                  <Checkbox
                    checked={
                      summary.allSelected
                        ? true
                        : summary.count > 0
                          ? "indeterminate"
                          : false
                    }
                    onCheckedChange={() => setSelected((prev) => toggleAllCloud(items, prev))}
                    aria-label="全选云端孤儿附件"
                  />
                  全选
                </label>
                <span className="text-xs text-muted-foreground tabular-nums">
                  已选 {summary.count} / 共 {items.length} 项 · 合计{" "}
                  {formatBytes(summary.bytes)}
                </span>
              </div>

              <ul className="max-h-[50vh] divide-y overflow-auto rounded-md border">
                {items.map((item) => {
                  const label = cloudAttachmentLabel(item);
                  const bytes = cloudItemBytes(item);
                  return (
                    <li
                      key={item.hash}
                      className="flex items-center gap-3 px-3 py-2 hover:bg-accent"
                    >
                      <Checkbox
                        checked={selected.has(item.hash)}
                        onCheckedChange={() => toggleOne(item.hash)}
                        aria-label={`选择 ${label}`}
                      />
                      <FileText className="size-4 shrink-0 text-muted-foreground" />
                      <span className="min-w-0 flex-1 truncate text-sm" title={item.hash}>
                        {label}
                      </span>
                      <Badge variant="outline" className="shrink-0">
                        {cloudKindLabel(item.kind)}
                      </Badge>
                      {item.is_local_cached ? (
                        <Badge variant="secondary" className="shrink-0">
                          本地有副本
                        </Badge>
                      ) : null}
                      <span className="w-24 shrink-0 text-right font-mono text-xs text-muted-foreground tabular-nums">
                        {bytes > 0 ? formatBytes(bytes) : "体积未知"}
                      </span>
                      <span className="w-20 shrink-0 text-right font-mono text-xs text-muted-foreground tabular-nums">
                        {formatCloudLastModified(item.last_modified)}
                      </span>
                    </li>
                  );
                })}
              </ul>

              <DialogFooter className="sm:justify-between">
                <Button
                  variant="outline"
                  className="text-destructive hover:text-destructive"
                  disabled={busy}
                  onClick={() => setConfirming(items.map((i) => i.hash))}
                >
                  全部删除
                </Button>
                <Button
                  variant="destructive"
                  disabled={busy || summary.count === 0}
                  onClick={() => setConfirming([...selected])}
                >
                  删除选中{summary.count > 0 ? ` (${summary.count})` : ""}
                </Button>
              </DialogFooter>
            </>
          )}
        </DialogContent>
      </Dialog>

      <DangerousConfirmDialog
        open={confirming != null}
        onOpenChange={(o) => {
          if (!o) setConfirming(null);
        }}
        title="永久删除云端附件"
        description={
          <>
            将从云端删除 {confirming?.length ?? 0} 个附件对象（合计{" "}
            {formatBytes(confirmingBytes)}），不可恢复。其他设备若仍持有本地副本，
            会在下次同步时自动重新上传；
            <span className="font-medium text-destructive">
              所有设备都没有本地副本的附件将永久丢失
            </span>
            。
          </>
        }
        confirmLabel="删除"
        busy={busy}
        onConfirm={() => {
          if (confirming) void remove(confirming);
        }}
      />
    </>
  );
}
