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
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Activity, Cloud, Cpu, FileCog, FileText, FolderOpen, HardDrive, RefreshCw, Trash2 } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { DangerousConfirmDialog } from "@/components/ui/dangerous-confirm-dialog";
import { cn } from "@/lib/utils";
import {
  cloudOrphanChunksGc,
  cloudSyncPullThenPush,
  cloudSyncPushOnly,
  diagnosticsSnapshot,
  fullBackupDeviceInfo,
  logOverview,
  micaDiagnostics,
  syncConfigGet,
  type LogOverview,
  type MicaDiagnostics,
} from "@/lib/tauri";
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
  const [diagSyncBusy, setDiagSyncBusy] = useState<"push" | "pull" | null>(null);
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
  // Mica 链路读数（Windows 独有）：build / 透明效果 / DWM 背景类型 before→after。
  // 命令本身幂等重断言一次材质，故只在挂载与点刷新时采集。
  const [mica, setMica] = useState<MicaDiagnostics | null>(null);
  useEffect(() => {
    let cancelled = false;
    void micaDiagnostics()
      .then((m) => {
        if (!cancelled) setMica(m);
      })
      .catch(() => {
        /* 非 Windows/命令不可用时保持「尚未采集」，不阻塞诊断分区 */
      });
    return () => {
      cancelled = true;
    };
  }, []);
  // 设备 ID 进程内不变，取一次即可（与备份清单 device_id 同源）
  const { data: device } = useQuery({
    queryKey: ["full_backup_device"],
    queryFn: fullBackupDeviceInfo,
    staleTime: Infinity,
  });

  // 日志目录读数：与诊断快照同口径（点刷新时重采；目录内容会随运行变化）
  const { data: logs, refetch: refetchLogs } = useQuery<LogOverview>({
    queryKey: ["log_overview"],
    queryFn: logOverview,
    staleTime: 0,
    gcTime: 0,
  });

  /**
   * 用系统默认程序打开日志目录 / 某个日志文件。
   *
   * 走 `plugin-shell` 的 `open`（与「非图片附件用系统程序打开」同一通道），
   * 不新增插件与权限。路径全部由 Rust 侧给出，前端不拼路径——两处拼法
   * 一旦分叉就会出现「打开的是 A、插件写的是 B」。
   */
  const openLogPath = async (target: string, what: string) => {
    if (!target) {
      toast.error(`未取到${what}路径`);
      return;
    }
    try {
      const { open } = await import("@tauri-apps/plugin-shell");
      await open(target);
    } catch (e) {
      toast.error(`打开${what}失败`, {
        description: e instanceof Error ? e.message : String(e),
      });
    }
  };
  const openLogDir = () => openLogPath(logs?.dir ?? "", "日志目录");
  const openLatestLog = () => {
    // files 已按修改时间倒序（Rust 侧排序），首个即最新
    const latest = logs?.files[0];
    if (!latest || !logs?.dir) {
      toast.info("目录内暂无日志文件");
      return;
    }
    const sep = logs.dir.includes("\\") ? "\\" : "/";
    void openLogPath(`${logs.dir}${sep}${latest.name}`, "最新日志");
  };
  const openLogFile = (name: string) => {
    if (!logs?.dir) return;
    const sep = logs.dir.includes("\\") ? "\\" : "/";
    void openLogPath(`${logs.dir}${sep}${name}`, "日志文件");
  };

  const refresh = () => {
    setRuntime(readRuntime());
    void refetch();
    void refetchLogs();
    void micaDiagnostics()
      .then(setMica)
      .catch(() => {
        /* 同上：读数不可用不弹错 */
      });
  };

  /**
   * 单向同步诊断（#107）：`pull` = 先拉后推，`push` = 只推不拉。
   * 只用于排障（判断是拉取侧还是推送侧卡住），不做常规入口——单向同步
   * 会跳过多端合并的一侧，连续点可能让对端改动晚一轮才可见。
   */
  const runDiagnosticSync = async (mode: "push" | "pull") => {
    setDiagSyncBusy(mode);
    try {
      const result =
        mode === "push" ? await cloudSyncPushOnly("manual") : await cloudSyncPullThenPush("manual");
      if (result.skipped) {
        toast.info("已有同步任务在进行中");
      } else if (result.errors.length > 0) {
        toast.warning(`同步完成但有 ${result.errors.length} 条错误`, {
          description: result.errors[0],
        });
      } else {
        toast.success(
          mode === "push"
            ? `仅推送完成：${result.pushed_modules} 个模块`
            : `先拉后推完成：拉取 ${result.pulled_modules} 个模块`,
          { description: `耗时 ${(result.duration_ms / 1000).toFixed(1)}s` },
        );
      }
      void refetch();
    } catch (e) {
      toast.error("诊断同步失败", {
        description: e instanceof Error ? e.message : String(e),
      });
    } finally {
      setDiagSyncBusy(null);
    }
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
          <div className="flex flex-wrap items-center gap-2 border-t pt-3">
            <span className="mr-1 text-xs text-muted-foreground">单向同步（排障）</span>
            <Button
              variant="outline"
              size="sm"
              disabled={diagSyncBusy != null}
              onClick={() => void runDiagnosticSync("push")}
            >
              仅推送
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={diagSyncBusy != null}
              onClick={() => void runDiagnosticSync("pull")}
            >
              先拉后推
            </Button>
            {diagSyncBusy != null ? (
              <span className="text-xs text-muted-foreground">进行中…</span>
            ) : null}
          </div>
          <p className="text-xs text-muted-foreground">
            云端附件对象不会被自动回收（删除任务/卸载附件后仍留在网盘）。附件清理只扫描 30
            天前、且无任何设备引用的对象；服务端不提供时间的对象一律跳过。「回收孤儿数据桶」
            清的是同步清单已不再引用的旧分桶（24 小时窗口）。均需同步密钥已解锁。
            单向同步只用于判断卡在拉取还是推送；它会跳过另一侧，不要当作常规同步使用。
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

      <div className="space-y-2 rounded-lg border p-5">
        <div className="flex items-center gap-2">
          <Cpu className="size-4 text-muted-foreground" />
          <p className="text-sm font-medium">运行环境</p>
        </div>
        <div className="divide-y">
          <Reading label="应用版本" value={__APP_VERSION__} />
          <Reading
            label="设备 ID"
            value={device?.device_id || "未初始化"}
            hint="与备份清单 device_id 同源"
          />
          {mica ? (
            <>
              <Reading label="平台" value={mica.platform} />
              {mica.windowsBuild != null ? (
                <Reading
                  label="Windows 版本"
                  value={`${mica.windowsMajor ?? 0}.${mica.windowsMinor ?? 0}.${mica.windowsBuild}`}
                />
              ) : null}
              <Reading
                label="Mica 支持"
                value={mica.micaSupported ? "是（build ≥ 22000）" : "否"}
              />
              {mica.transparencyEnabled != null ? (
                <Reading
                  label="系统透明效果"
                  value={mica.transparencyEnabled ? "已开启" : "已关闭（Mica 不会渲染）"}
                />
              ) : null}
              {mica.backdropBefore != null || mica.backdropAfter != null ? (
                <Reading
                  label="DWM 背景类型"
                  value={`${mica.backdropBefore ?? "-"} → ${mica.backdropAfter ?? "-"}`}
                  hint="4 = Mica"
                />
              ) : null}
              <Reading label="材质应用结果" value={mica.applyResult} />
            </>
          ) : (
            <Reading label="材质读数" value="尚未采集" hint="点右上角刷新" />
          )}
        </div>
        <p className="text-xs text-muted-foreground">
          Mica 链路读数来自 Rust 侧 DWM 直调（仅 Windows）；非 Windows 平台只显示平台名。
        </p>
      </div>

      <div className="space-y-2 rounded-lg border p-5">
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <FileCog className="size-4 text-muted-foreground" />
            <p className="text-sm font-medium">日志文件</p>
          </div>
          <div className="flex items-center gap-2">
            <Button variant="outline" size="sm" onClick={() => void openLogDir()}>
              <FolderOpen className="size-4" />
              打开目录
            </Button>
            <Button variant="outline" size="sm" onClick={() => void openLatestLog()}>
              <FileText className="size-4" />
              打开最新日志
            </Button>
          </div>
        </div>
        {logs == null ? (
          <p className="text-xs text-muted-foreground">读取中…</p>
        ) : !logs.readable ? (
          <p className="text-xs text-destructive">
            {logs.reason ?? "日志目录不可读"}
            {logs.dir ? <span className="text-muted-foreground">（{logs.dir}）</span> : null}
          </p>
        ) : (
          <>
            <div className="divide-y">
              {logs.files.length === 0 ? (
                <p className="text-xs text-muted-foreground">目录内暂无日志文件。</p>
              ) : (
                logs.files.map((f) => (
                  <div key={f.name} className="flex items-center justify-between gap-3 py-1.5">
                    <button
                      type="button"
                      className="truncate text-left text-xs text-foreground underline-offset-2 hover:underline"
                      onClick={() => void openLogFile(f.name)}
                      title="用系统默认程序打开"
                    >
                      {f.name}
                    </button>
                    <span className="shrink-0 text-xs text-muted-foreground">
                      {formatBytes(f.size_bytes)}
                      {f.modified_ms > 0
                        ? ` · ${new Date(f.modified_ms).toLocaleString("zh-CN")}`
                        : ""}
                    </span>
                  </div>
                ))
              )}
            </div>
            <p className="break-all font-mono text-xs text-muted-foreground">{logs.dir}</p>
          </>
        )}
        <p className="text-xs text-muted-foreground">
          日志落盘位置由系统决定（Windows 在 AppData\Local，macOS 在 ~/Library/Logs），
          不受「数据目录」设置影响。报障时点「打开最新日志」即可取到当前这份；
          日志不含主密码、同步密码与云端凭据（脱敏红线见 docs/02 §九）。
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
