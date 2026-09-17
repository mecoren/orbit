/**
 * use-startup-sync — 进入应用强制同步
 *
 * 流程：DB 就绪后延迟触发（让首屏数据加载先行）：
 * 1. 未配置云同步 → 跳过（不打扰）
 * 2. 钥匙串静默解锁失败（无缓存/密码已变）→ 跳过，等用户手动解锁
 * 3. cloudSyncForce("background")：**强制**同步——不再受「自动同步总开关 /
 *    同步间隔 / 修改后立即同步」等设置约束（「进入应用」本身就是触发条件），
 *    先拉后推保证新设备场景下不会用本地旧数据先占推送窗口
 *
 * 失败静默（网络/配置类，启动场景不打扰）；key_mismatch 引导恢复页
 * （与后台调度器行为对齐）。引擎互斥锁保证与 60s 定时调度并发时有序等待。
 */
import { useEffect } from "react";

// 本 hook 渲染在 <RouterProvider> 之外（ReadyShell），故用命令式导航
import { router } from "@/router";
import {
  cloudSyncForce,
  syncConfigGet,
  syncCryptoRestoreSession,
  syncErrorTag,
} from "@/lib/tauri";

/** 延迟触发：避开首屏查询高峰 */
const STARTUP_SYNC_DELAY_MS = 1500;

/** 引擎忙时的等待上限（定时同步/修改后推送正在跑时短暂等待，不静默丢弃） */
const STARTUP_SYNC_WAIT_IDLE_MS = 3000;

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
          await cloudSyncForce("background", STARTUP_SYNC_WAIT_IDLE_MS);
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
