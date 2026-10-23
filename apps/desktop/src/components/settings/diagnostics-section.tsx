/**
 * 诊断分区（docs/09 内存与性能治理专项「应用内诊断分区」）
 *
 * 设计口径：
 * - **只读**：数据来自 core 的 `diagnostics_snapshot`（不 emit db-change、不进同步
 *   白名单），WebView 侧读数（JS 堆 / DOM 节点数）只在点「刷新」时采一次——
 *   诊断分区不该自己成为常驻内存开销。
 * - 两类读数分开摆：**本地存储**（库体积/行数/附件缓存）与**运行时**（WebView 堆），
 *   前者由 Rust 侧量、后者由前端量，混在一起会让人误判口径。
 * - `performance.memory` 是 Chromium 私有 API（WebView2 有、Safari/Firefox 没有），
 *   取不到时明写「当前环境不支持」而不是显示 0——0 会被读成「内存占用为零」。
 */
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Activity, Cloud, FileCog, HardDrive, RefreshCw, Trash2 } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { DangerousConfirmDialog } from "@/components/ui/dangerous-confirm-dialog";
import { cn } from "@/lib/utils";
import { cloudOrphanChunksGc, diagnosticsSnapshot, syncConfigGet } from "@/lib/tauri";
import { formatBytes, formatCount } from "./diagnostics-format";
import { CloudUnusedAttachmentsDialog } from "./cloud-unused-attachments-dialog";
import { UnusedAttachmentsDialog } from "./unused-attachments-dialog";

/** Chromium 私有扩展（TS 标准库无此声明） */
interface ChromiumPerformance extends Performance {
  memory?: { usedJSHeapSize: number; totalJSHeapSize: number };
}

/** WebView 侧运行时读数（点刷新时采一次） */
interface RuntimeReadings {
  /** JS 堆已用（字节）；环境不支持时 null */
  heapUsedBytes: number | null;
  /** JS 堆已提交（字节）；环境不支持时 null */
  heapTotalBytes: number | null;
  /** 当前 DOM 节点数（`document.querySelectorAll("*").length` 的同源口径） */
  domNodes: number;
}

function readRuntime(): RuntimeReadings {
  const memory = (performance as ChromiumPerformance).memory;
  return {
    heapUsedBytes: memory ? memory.usedJSHeapSize : null,
    heapTotalBytes: memory ? memory.totalJSHeapSize : null,
    domNodes: document.querySelectorAll("*").length,
  };
}

/** 一行读数 */
function Reading({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="flex items-baseline justify-between gap-4 py-1.5">
      <span className="text-sm text-muted-foreground">{label}</span>
      <span className="text-right">
        <span className="font-mono text-sm tabular-nums">{value}</span>
        {hint ? <span className="ml-2 text-xs text-muted-foreground">{hint}</span> : null}
      </span>
    </div>
  );
}

export function DiagnosticsSection() {
  const [runtime, setRuntime] = useState<RuntimeReadings>(() => readRuntime());
  const [cleanupOpen, setCleanupOpen] = useState(false);
  const [cloudCleanupOpen, setCloudCleanupOpen] = useState(false);
  const [chunkGcOpen, setChunkGcOpen] = useState(false);
  const [chunkGcBusy, setChunkGcBusy] = useState(false);
  const { data, isFetching, refetch } = useQuery({
    queryKey: ["diagnostics"],
    queryFn: diagnosticsSnapshot,
    // 诊断读数没有「新鲜度」概念：切回来就是新的一次测量
    staleTime: 0,
    gcTime: 0,
  });
  // 云同步是否已配置：未配置时云端清理卡片整块隐藏（点了也只会报「尚未配置」）。
  // 密钥解锁状态不在这里判定——它是会话态，卡片副标题提示，点击时由 core 拒绝。
  const { data: syncConfig } = useQuery({
    queryKey: ["sync_config"],
    queryFn: syncConfigGet,
    staleTime: 60_000,
  });
  const cloudConfigured =
    syncConfig != null && (syncConfig.engine === "webdav" || syncConfig.engine === "s3");
  const refresh = () => {
    setRuntime(readRuntime());
    void refetch();
  };

  /** 孤儿数据分桶回收（#96 尾款入口）：只动 tables/，与附件对象无关 */
  const runChunkGc = async () => {
    setChunkGcBusy(true);
    try {
      const result = await cloudOrphanChunksGc();
      if (result.deleted_buckets === 0) {
        toast.info("没有可回收的孤儿数据桶", {
          description: "清单仍在引用的桶全部保留；写入不足 24 小时的桶留给下一轮。",
        });
      } else if (result.errors.length > 0) {
        toast.warning(`已回收 ${formatCount(result.deleted_buckets)} 个孤儿分桶（部分失败）`, {
          description: result.errors[0],
        });
      } else {
        toast.success(`已回收 ${formatCount(result.deleted_buckets)} 个孤儿数据分桶`);
      }
      setChunkGcOpen(false);
      void refetch();
    } catch (e) {
      toast.error("回收孤儿数据分桶失败", {
        description: e instanceof Error ? e.message : String(e),
      });
    } finally {
      setChunkGcBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold">诊断</h2>
          <p className="mt-0.5 text-xs text-muted-foreground">
            本地存储与运行时读数（口径见 docs/09 内存专项；只读，不参与同步）
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={refresh} disabled={isFetching}>
          <RefreshCw className={cn("size-4", isFetching && "animate-spin")} />
          刷新
        </Button>
      </div>

      <div className="space-y-2 rounded-lg border p-5">
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <HardDrive className="size-4 text-muted-foreground" />
            <p className="text-sm font-medium">本地存储</p>
          </div>
          <Button variant="outline" size="sm" onClick={() => setCleanupOpen(true)}>
            <FileCog className="size-4" />
            清除未使用附件
          </Button>
        </div>
        {(data?.table_rows.length ?? 0) > 0 && (
          <div className="flex flex-wrap gap-x-2 gap-y-1 text-xs text-muted-foreground">
            {data!.table_rows
              .filter((r) => r.rows > 0)
              .map((r) => (
                <span key={r.table} className="rounded bg-muted px-1.5 py-0.5">
                  {r.table} {formatCount(r.rows)}
                </span>
              ))}
          </div>
        )}
        <div className="divide-y">
          <Reading
            label="数据库体积"
            value={formatBytes(data?.db_size_bytes)}
            hint="page_count × page_size"
          />
          <Reading
            label="墓碑行数"
            value={formatCount(data?.tombstone_rows)}
            hint="已软删、待在回收站或同步中传播"
          />
          <Reading
            label="附件缓存"
            value={formatBytes(data?.attachment_cache_bytes)}
            hint={
              data ? `${formatCount(data.attachment_cache_files)} 个文件` : undefined
            }
          />
        </div>
        <p className="text-xs text-muted-foreground">
          活行数按 `is_deleted = 0`；库体积不含 WAL 与附件目录。
        </p>
      </div>

      {cloudConfigured ? (
        <div className="space-y-2 rounded-lg border p-5">
          <div className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-2">
              <Cloud className="size-4 text-muted-foreground" />
              <p className="text-sm font-medium">云端存储</p>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Button variant="outline" size="sm" onClick={() => setCloudCleanupOpen(true)}>
                <FileCog className="size-4" />
                清理云端孤儿附件
              </Button>
              <Button variant="outline" size="sm" onClick={() => setChunkGcOpen(true)}>
                <Trash2 className="size-4" />
                回收孤儿数据桶
              </Button>
            </div>
          </div>
          <p className="text-xs text-muted-foreground">
            云端附件对象不会被自动回收（删除任务/卸载附件后仍留在网盘）。附件清理只扫描 30
            天前、且无任何设备引用的对象；服务端不提供时间的对象一律跳过。「回收孤儿数据桶」
            清的是同步清单已不再引用的旧分桶（24 小时窗口）。均需同步密钥已解锁。
          </p>
        </div>
      ) : null}

      <div className="space-y-2 rounded-lg border p-5">
        <div className="flex items-center gap-2">
          <Activity className="size-4 text-muted-foreground" />
          <p className="text-sm font-medium">运行时（WebView）</p>
        </div>
        <div className="divide-y">
          <Reading
            label="JS 堆已用"
            value={runtime.heapUsedBytes == null ? "当前环境不支持" : formatBytes(runtime.heapUsedBytes)}
          />
          <Reading
            label="JS 堆已提交"
            value={runtime.heapTotalBytes == null ? "当前环境不支持" : formatBytes(runtime.heapTotalBytes)}
          />
          <Reading label="DOM 节点数" value={formatCount(runtime.domNodes)} />
        </div>
        <p className="text-xs text-muted-foreground">
          只读快照，点「刷新」重新采集；库体积与行数来自 Rust 侧（重新查询数据库）。
        </p>
      </div>

      <UnusedAttachmentsDialog
        open={cleanupOpen}
        onOpenChange={setCleanupOpen}
        onCleaned={() => void refetch()}
      />

      <CloudUnusedAttachmentsDialog
        open={cloudCleanupOpen}
        onOpenChange={setCloudCleanupOpen}
        onCleaned={() => void refetch()}
      />

      <DangerousConfirmDialog
        open={chunkGcOpen}
        onOpenChange={setChunkGcOpen}
        title="回收孤儿数据分桶"
        description={
          <>
            将删除云端 <code>tables/</code> 下「同步清单已不再引用、且写入超过 24
            小时」的分桶对象。清单仍在引用的数据与全部附件对象不受影响。
          </>
        }
        confirmLabel="回收"
        busy={chunkGcBusy}
        onConfirm={() => void runChunkGc()}
      />
    </div>
  );
}
