/**
 * use-startup-sync — 启动静默同步（03 文档 §八「启动场景预留」）
 *
 * 流程：DB 就绪后延迟触发（让首屏数据加载先行）：
 * 1. 未配置云同步 → 跳过
 * 2. 钥匙串静默解锁失败（无缓存/密码已变）→ 不打扰，等用户手动解锁
 * 3. cloud_sync_pull_then_push(Background)：先拉远端再推本地，新设备场景
 *    避免本地旧数据先占推送窗口；进度由标题栏左上角云图标（SyncStatusButton）展示
 *
 * 失败静默（网络/配置类，启动场景不打扰）；key_mismatch 引导恢复页
 * （与后台调度器行为对齐）。引擎互斥锁保证与 60s 定时调度并发时自动跳过。
 */
import { useEffect } from "react";

// 本 hook 渲染在 <RouterProvider> 之外（ReadyShell），故用命令式导航
import { router } from "@/router";
import {
  cloudSyncPullThenPush,
  syncConfigGet,
  syncCryptoRestoreSession,
  syncErrorTag,
} from "@/lib/tauri";

/** 延迟触发：避开首屏查询高峰 */
const STARTUP_SYNC_DELAY_MS = 1500;

export function useStartupSync() {
  useEffect(() => {
    let cancelled = false;
    const timer = setTimeout(() => {
      void (async () => {
        const config = await syncConfigGet().catch(() => null);
        if (!config || cancelled) return;
        const restored = await syncCryptoRestoreSession().catch(() => false);
        if (!restored || cancelled) return;
        try {
          await cloudSyncPullThenPush("background");
        } catch (err) {
          if (syncErrorTag(err) === "key_mismatch") {
            void router.navigate("/sync-recovery");
          }
        }
      })();
    }, STARTUP_SYNC_DELAY_MS);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, []);
}
