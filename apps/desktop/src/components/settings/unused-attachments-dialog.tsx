/**
 * 未使用附件清理弹窗（设置 → 诊断 → 本地存储「清除未使用附件」）
 *
 * 设计口径：
 * - 清单来自 core `attachments_unused_list`（无任何存活任务引用的账本行），
 *   **只在开层时查询**（`enabled: open`），不成为诊断页的常驻开销；
 * - 删除只作用于本机（本地文件 + 账本行），云端对象保留——多设备引用计数
 *   不可靠，宁可留孤儿也不误删（与 `gc_local_attachments` 同口径）；
 * - 破坏性动作统一走 DangerousConfirmDialog 五秒冷静期；实际执行时 Rust 侧
 *   会重查存活引用集，弹窗打开期间被重新挂载的附件不会被误删；
 * - 删除成功后刷新清单与诊断读数，清单清空即关层。
 */
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { FileText, PackageOpen } from "lucide-react";
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
import { attachmentsUnusedDelete, attachmentsUnusedList } from "@/lib/tauri";
import { formatBytes, formatCount } from "./diagnostics-format";
import {
  attachmentLabel,
  summarizeSelection,
  toggleAll,
} from "./unused-attachments-selection";

interface UnusedAttachmentsDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 清理成功后回调（诊断页重新采集读数） */
  onCleaned: () => void;
}

export function UnusedAttachmentsDialog({
  open,
  onOpenChange,
  onCleaned,
}: UnusedAttachmentsDialogProps) {
  const [selected, setSelected] = useState<Set<string>>(new Set());
  /** 待确认的 hash 列表（null = 未弹确认层） */
  const [confirming, setConfirming] = useState<string[] | null>(null);
  const [busy, setBusy] = useState(false);

  const { data, isPending, refetch } = useQuery({
    queryKey: ["attachments_unused"],
    queryFn: attachmentsUnusedList,
    enabled: open,
    staleTime: 0,
    gcTime: 0,
    // 只认「开层」这一次读取：切回窗口不额外拉清单
    refetchOnWindowFocus: false,
  });
  const items = data ?? [];
  const summary = summarizeSelection(items, selected);

  // 关层清选中，下次打开从零开始勾选
  useEffect(() => {
    if (!open) setSelected(new Set());
  }, [open]);

  // 清单刷新后剔除已不存在的 hash（删除成功后 / 别处已清理）
  useEffect(() => {
    if (!data) return;
    setSelected((prev) => {
      const next = new Set<string>();
      for (const item of data) if (prev.has(item.hash)) next.add(item.hash);
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
    .reduce((sum, i) => sum + i.size_bytes, 0);

  const remove = async (hashes: string[]) => {
    setBusy(true);
    try {
      const target = new Set(hashes);
      const bytes = items
        .filter((i) => target.has(i.hash))
        .reduce((sum, i) => sum + i.size_bytes, 0);
      const cleaned = await attachmentsUnusedDelete(hashes);
      if (cleaned === 0) {
        // 清单过期或别处已清理：不谎报「释放 X」
        toast.info("没有可清理的附件", { description: "清单可能已过期，已自动刷新。" });
      } else {
        toast.success(`已清理 ${formatCount(cleaned)} 个未使用附件`, {
          description: `释放 ${formatBytes(bytes)}（云端副本保留）`,
        });
      }
      setConfirming(null);
      onCleaned();
      const next = await refetch();
      if ((next.data?.length ?? 0) === 0) onOpenChange(false);
    } catch (e) {
      toast.error("清理未使用附件失败", {
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
        叠在 z-[60] 也会点不动/不被 Tab 找到；列表层收起后遮罩才能正常交互
        （与「PopoverContent 内禁嵌 Popover」的两段式口径同源）。
      */}
      <Dialog
        open={open && confirming == null}
        onOpenChange={(o) => {
          if (!o && confirming == null) onOpenChange(false);
        }}
      >
        <DialogContent className="sm:max-w-xl">
          <DialogHeader>
            <DialogTitle>清除未使用附件</DialogTitle>
            <DialogDescription>
              以下附件未被任何任务引用，删除仅作用于本机（云端副本保留）。
            </DialogDescription>
          </DialogHeader>

          {isPending ? (
            <div className="py-10 text-center text-sm text-muted-foreground">读取中…</div>
          ) : items.length === 0 ? (
            <div className="flex flex-col items-center gap-2 rounded-md border border-dashed py-10 text-center">
              <PackageOpen className="size-8 text-muted-foreground" />
              <p className="text-sm font-medium">没有未使用的附件</p>
              <p className="text-xs text-muted-foreground">
                所有附件均被任务引用，或已被自动清理。
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
                    onCheckedChange={() => setSelected((prev) => toggleAll(items, prev))}
                    aria-label="全选未使用附件"
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
                  const label = attachmentLabel(item);
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
                      <span className="min-w-0 flex-1 truncate text-sm" title={label}>
                        {label}
                      </span>
                      <Badge
                        variant={item.is_local_cached ? "secondary" : "outline"}
                        className="shrink-0"
                      >
                        {item.is_local_cached ? "本地已缓存" : "仅账本记录"}
                      </Badge>
                      <span className="w-20 shrink-0 text-right font-mono text-xs text-muted-foreground tabular-nums">
                        {formatBytes(item.size_bytes)}
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
        title="永久删除未使用附件"
        description={
          <>
            将永久删除本机上的 {confirming?.length ?? 0} 个附件文件与账本记录（合计{" "}
            {formatBytes(confirmingBytes)}），不可恢复。云端副本保留；未上传云端的
            附件删除后无法从其他设备找回。
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
