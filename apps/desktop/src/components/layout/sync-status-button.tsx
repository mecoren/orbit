/**
 * SyncStatusButton — 标题栏左上角云同步状态图标（03 文档 §八 / ADR 0003）
 *
 * 设计口径：
 * - 状态收敛：配置与解锁状态来自 `sync-config` / `sync-crypto-status` 查询，
 *   运行态由 `sync-progress` / `sync-finished` 事件与手动同步返回值驱动，
 *   派生规则见 `lib/sync-status`（纯函数 + 共置单测）。原右下角 SyncIndicator
 *   只消费 origin=background，本组件承载全部来源，故不再保留第二处同步指示。
 * - 点击：未配置 / 未解锁 → 跳设置页同步分区引导；同步中 → 信息型 toast 不重入；
 *   就绪 → 立即同步（点击时权威复核一次 syncCryptoStatus，避免缓存滞后误跳设置页）。
 * - 失败态保留到下次同步（悬浮可见原因）；后台来源失败仍弹 toast，不因图标承载而静默。
 * - 备份链路（backup_* / full_backup_*）与本组件无关，备份入口仍在设置页。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import { Check, Cloud } from "lucide-react";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { type SyncFinishedEvent } from "@/lib/events";
import {
  deriveSyncStatus,
  estimateNextSyncAt,
  formatLastSynced,
  formatNextSync,
  syncProgressText,
  syncResultSummary,
  syncStatusLabel,
  type SyncProgressEvent,
  type SyncRunPhase,
  type SyncUiStatus,
} from "@/lib/sync-status";
import {
  cloudSyncNow,
  syncConfigGet,
  syncCryptoStatus,
  syncErrorTag,
} from "@/lib/tauri";

/** 成功态停留时长：对勾回弹展示后回落待命态 */
const SUCCESS_HOLD_MS = 1800;

/** 错误消息去 `[tag] ` 前缀（与设置页同步卡同口径） */
function errMsg(err: unknown): string {
  const msg = err instanceof Error ? err.message : String(err);
  return msg.replace(/^\[\w+\]\s*/, "");
}

export function SyncStatusButton() {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [runPhase, setRunPhase] = useState<SyncRunPhase>("idle");
  const [progress, setProgress] = useState("");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const { data: config } = useQuery({
    queryKey: ["sync-config"],
    queryFn: syncConfigGet,
    staleTime: 60_000,
  });
  const { data: crypto } = useQuery({
    queryKey: ["sync-crypto-status"],
    queryFn: syncCryptoStatus,
    staleTime: 30_000,
  });

  const clearHideTimer = useCallback(() => {
    if (hideTimer.current) {
      clearTimeout(hideTimer.current);
      hideTimer.current = null;
    }
  }, []);

  /** 进入成功态，SUCCESS_HOLD_MS 后回落待命（对勾动画只播一次） */
  const showSuccess = useCallback(() => {
    clearHideTimer();
    setRunPhase("success");
    setProgress("");
    setErrorMessage(null);
    hideTimer.current = setTimeout(() => setRunPhase("idle"), SUCCESS_HOLD_MS);
  }, [clearHideTimer]);

  useEffect(() => {
    const refreshConfig = () => {
      void qc.invalidateQueries({ queryKey: ["sync-config"] });
    };

    const unlistenProgress = listen<SyncProgressEvent>("sync-progress", (evt) => {
      const p = evt.payload;
      if (p.phase === "done") {
        showSuccess();
        refreshConfig();
        return;
      }
      if (p.phase === "error") {
        clearHideTimer();
        setRunPhase("error");
        setProgress("");
        setErrorMessage(p.message ?? "未知错误");
        // 后台自动同步失败此前由 SyncIndicator 提示，并入图标后仍保留可见告警
        if (p.origin === "background") {
          toast.error(`后台自动同步失败：${p.message ?? "未知错误"}`);
        }
        return;
      }
      clearHideTimer();
      setRunPhase("syncing");
      setErrorMessage(null);
      setProgress(syncProgressText(p));
    });

    // 记账落库（last_synced_at）在 sync-finished 之后，故终态与时间刷新都在此收口
    const unlistenFinished = listen<SyncFinishedEvent>("sync-finished", (evt) => {
      if (!evt.payload.skipped) showSuccess();
      refreshConfig();
    });

    const unlistenMismatch = listen("sync-key-mismatch", () => {
      clearHideTimer();
      setRunPhase("idle");
      setProgress("");
      void navigate("/sync-recovery");
    });

    return () => {
      unlistenProgress.then((fn) => fn());
      unlistenFinished.then((fn) => fn());
      unlistenMismatch.then((fn) => fn());
      clearHideTimer();
    };
  }, [clearHideTimer, navigate, qc, showSuccess]);

  const handleClick = async () => {
    if (runPhase === "syncing") {
      toast.info("已有同步任务在进行中");
      return;
    }
    if (config == null) {
      navigate("/settings");
      return;
    }
    // 权威复核：设置页刚解锁/加锁时缓存可能仍在 staleTime 内
    const cryptoNow = await syncCryptoStatus().catch(() => null);
    if (cryptoNow) qc.setQueryData(["sync-crypto-status"], cryptoNow);
    if (!cryptoNow?.has_password || !cryptoNow.is_unlocked) {
      navigate("/settings");
      return;
    }

    clearHideTimer();
    setRunPhase("syncing");
    setProgress("正在同步…");
    setErrorMessage(null);
    try {
      const result = await cloudSyncNow("manual");
      if (result.skipped) {
        setRunPhase("idle");
        setProgress("");
        toast.info(syncResultSummary(result));
      } else {
        showSuccess();
        toast.success(syncResultSummary(result));
      }
      void qc.invalidateQueries({ queryKey: ["sync-config"] });
    } catch (err) {
      if (syncErrorTag(err) === "key_mismatch") {
        setRunPhase("idle");
        setProgress("");
        navigate("/sync-recovery");
        return;
      }
      const message = errMsg(err);
      setRunPhase("error");
      setProgress("");
      setErrorMessage(message);
      toast.error(message);
    }
  };

  // 查询未落定前按待命态渲染，避免首帧闪一次「未配置 / 已锁定」
  const status: SyncUiStatus =
    config === undefined || crypto === undefined
      ? "idle"
      : deriveSyncStatus({
          hasConfig: config !== null,
          hasPassword: crypto.has_password,
          isUnlocked: crypto.is_unlocked,
          runPhase,
        });

  const nextAt = config
    ? estimateNextSyncAt({
        auto_sync_enabled: config.auto_sync_enabled,
        interval_minutes: config.interval_minutes,
        last_synced_at: config.last_synced_at,
      })
    : null;

  const hint =
    status === "syncing"
      ? "同步进行中…"
      : status === "unconfigured" || status === "locked"
        ? "点击前往设置"
        : "点击立即同步";

  const syncing = status === "syncing";
  const failed = status === "error";
  const notReady = status === "unconfigured" || status === "locked";

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className={cn(
            "relative size-8 transition-transform active:scale-[0.96]",
            status === "idle" && "text-muted-foreground hover:text-foreground",
            syncing && "text-primary",
            status === "success" && "text-success",
            failed && "text-destructive",
            notReady && "text-muted-foreground/60 hover:text-muted-foreground",
          )}
          aria-label="云同步"
          onClick={() => void handleClick()}
        >
          <Cloud className="size-4" />
          {/* 同步中：主题色旋转环绕（终态与待命态不渲染，避免常驻 RAF） */}
          {syncing && (
            <span className="pointer-events-none absolute inset-0 m-auto size-[22px] animate-spin rounded-full border-2 border-primary/70 border-t-transparent" />
          )}
          {/* 成功：对勾徽标一次性回弹（tailwindcss-animate 的 keyframes 在 v4 下不可靠，用自绘 keyframes） */}
          {status === "success" && (
            <span className="animate-sync-pop absolute -top-0.5 -right-0.5 flex size-4 items-center justify-center rounded-full bg-success text-white">
              <Check data-icon className="size-2.5" strokeWidth={3} />
            </span>
          )}
          {failed && (
            <span className="absolute -top-0.5 -right-0.5 size-2 rounded-full bg-destructive ring-2 ring-background" />
          )}
        </Button>
      </TooltipTrigger>
      <TooltipContent side="bottom" align="start" className="flex flex-col gap-0.5">
        <span className="font-medium">
          {syncStatusLabel(status, crypto?.has_password ?? false)}
        </span>
        {progress ? <span>{progress}</span> : null}
        {errorMessage ? <span>原因：{errorMessage}</span> : null}
        <span>上次同步：{formatLastSynced(config?.last_synced_at ?? null)}</span>
        <span>下次自动同步：{formatNextSync(nextAt)}</span>
        <span className="opacity-75">{hint}</span>
      </TooltipContent>
    </Tooltip>
  );
}
