/**
 * Mica 云母材质 Hook（微信风格窗口材质）
 *
 * 实现说明（2026-07-30 重构）：
 * - 材质由 Rust 端 setup 阶段通过 Windows DWM API 直接设置
 *   （见 src-tauri/src/commands/mica_cmd.rs 的 apply_mica_dwm），
 *   绕过 Tauri 原生 windowEffects 在无边框窗口上对 Mica 的支持局限。
 * - 主题联动：监听 <html> 的 .dark class 变化，亮色开 Mica、暗色关 Mica。
 *   暗色背景叠加 Mica 会显著降低前景文字对比度，故暗色模式下禁用材质透出。
 * - 临时调试：挂载时调用 mica_diagnostics 命令，将链路证据打印到控制台
 *   并写入 localStorage，便于排查「Mica 不渲染」的根因。
 *   调试完成后请删除 invoke 块。
 */
import { useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";

export interface MicaDiagnostics {
  platform: string;
  windowsBuild?: number;
  windowsMajor?: number;
  windowsMinor?: number;
  micaSupported: boolean;
  /** 系统「个性化 → 颜色 → 透明效果」开关；false 时 Mica 不会渲染 */
  transparencyEnabled?: boolean;
  topHwnd?: string;
  hasNoRedirectionBitmap?: boolean;
  backdropBefore?: number;
  backdropAfter?: number;
  applyResult: string;
}

/** 当前是否处于暗色模式（依据 <html>.dark class） */
function isDarkMode(): boolean {
  return document.documentElement.classList.contains("dark");
}

/** 按当前主题模式应用或关闭 Mica：亮色开、暗色关 */
function syncMicaWithTheme() {
  if (isDarkMode()) {
    invoke("disable_mica").catch((err) =>
      console.error("[mica] disable_mica failed", err),
    );
  } else {
    invoke("apply_mica").catch((err) =>
      console.error("[mica] apply_mica failed", err),
    );
  }
}

export function useMicaEffect() {
  useEffect(() => {
    // 首次按当前主题同步一次
    syncMicaWithTheme();

    // 监听 <html> class 变化，主题切换时实时联动 Mica
    const observer = new MutationObserver((mutations) => {
      for (const m of mutations) {
        if (m.type === "attributes" && m.attributeName === "class") {
          syncMicaWithTheme();
          return;
        }
      }
    });
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class"],
    });

    // 临时调试：抓取诊断证据
    invoke<MicaDiagnostics>("mica_diagnostics")
      .then((diag) => {
        const payload = JSON.stringify(diag, null, 2);
        console.log("[mica-diagnostics]", payload);
        if (diag.platform === "windows" && diag.transparencyEnabled === false) {
          console.warn(
            "[mica] 系统「设置 → 个性化 → 颜色 → 透明效果」已关闭，" +
              "DWM 会静默忽略 Mica 材质设置。请开启该选项后重启应用。",
          );
        }
        try {
          localStorage.setItem("__mica_diagnostics__", payload);
        } catch {
          /* ignore quota error */
        }
      })
      .catch((err) => {
        console.error("[mica-diagnostics] invoke failed", err);
      });

    return () => observer.disconnect();
  }, []);
}
