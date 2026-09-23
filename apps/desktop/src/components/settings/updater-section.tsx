/**
 * updater-section — 应用内更新（07 backlog #20，tauri-plugin-updater）
 *
 * 手动「检查更新」→ 下载 → 安装重启三段式；不自动检查（本地优先应用的
 * 更新时机应归用户掌控）。签名密钥未注入（ADR 0004 未签名路径）时
 * endpoint 有响应但签名校验失败——按「安装包未签名」语义提示，检查
 * 本身失败则提示网络/配置问题。
 *
 * 插件模块动态 import：mock IPC 环境（e2e/vitest 纯浏览器）无 updater
 * 通道，静态导入会在页面加载即抛错；动态导入把失败收敛到点击路径的
 * try/catch 兜底文案。
 */
import { useState } from "react";
import { Download, Loader2, RotateCcw } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { resolveReleaseFallbackUrl } from "@/lib/update-fallback";

/** 点击时加载的插件模块类型（编译期无浏览器 fallback 报错） */
type UpdaterModule = typeof import("@tauri-apps/plugin-updater");
type ProcessModule = typeof import("@tauri-apps/plugin-process");

export function UpdaterSection() {
  const [checking, setChecking] = useState(false);
  const [downloading, setDownloading] = useState(false);
  const [version, setVersion] = useState<string | null>(null);
  const [pendingInstall, setPendingInstall] = useState<(() => Promise<void>) | null>(null);
  const [lastChecked, setLastChecked] = useState<number | null>(null);

  /**
   * 兜底出口：复制 Release 页下载链接。
   *
   * 项目未引入 opener 插件（外链直开需新依赖 + capabilities），剪贴板是最短
   * 可用路径；剪贴板不可用（无焦点/权限）时退化为把链接摆在提示里手抄。
   */
  const copyFallbackLink = async (version: string | null) => {
    const url = resolveReleaseFallbackUrl(version);
    try {
      await navigator.clipboard.writeText(url);
      toast.success("下载链接已复制", { description: url });
    } catch {
      toast.info("请手动打开下载页", { description: url });
    }
  };

  const checkForUpdate = async () => {
    if (checking) return;
    setChecking(true);
    try {
      const updater: UpdaterModule = await import("@tauri-apps/plugin-updater");
      const result = await updater.check();
      if (result != null) {
        setVersion(result.version);
        setPendingInstall(() => () => result.downloadAndInstall());
        toast.success(`发现新版本 ${result.version}`);
      } else {
        setVersion(null);
        setPendingInstall(null);
        toast.success("已是最新版本");
      }
      setLastChecked(Date.now());
    } catch (e) {
      // 常见两类：endpoint 不可达（网络/未发布 latest.json）与签名校验失败
      //（签名密钥未注入的未签名路径）。两者都不该是死路——给 Release 页出口
      toast.error("检查更新失败", {
        description: `${e instanceof Error ? e.message : String(e)}——可就地升级不可用时，从 Release 页手动下载。`,
        action: {
          label: "复制下载链接",
          onClick: () => void copyFallbackLink(null),
        },
      });
    } finally {
      setChecking(false);
    }
  };

  const downloadAndInstall = async () => {
    if (!pendingInstall || downloading) return;
    setDownloading(true);
    try {
      await pendingInstall();
      toast.success("更新已下载，即将重启");
      const process: ProcessModule = await import("@tauri-apps/plugin-process");
      await process.relaunch();
    } catch (e) {
      // 下载/安装失败（签名校验、当前安装方式不被清单覆盖、权限）同样给出口：
      // 复制该版本的 Release tag 链接，用户可手动下载对应安装包
      toast.error("更新失败", {
        description: `${e instanceof Error ? e.message : String(e)}——可复制该版本下载链接后手动安装。`,
        action: {
          label: "复制下载链接",
          onClick: () => void copyFallbackLink(version),
        },
      });
    } finally {
      setDownloading(false);
    }
  };

  return (
    <section className="space-y-4">
      <div>
        <h2 className="text-base font-semibold text-foreground">应用更新</h2>
        <p className="mt-1 text-[13px] text-muted-foreground">
          从 GitHub Releases 检查新版本；安装包未签名期间（ADR 0004
          证书物料未注入）更新校验可能失败，可从 Release 页手动下载。
        </p>
      </div>

      <div className="flex items-center gap-3">
        <Button onClick={() => void checkForUpdate()} disabled={checking || downloading}>
          {checking ? (
            <Loader2 className="size-4 animate-spin" />
          ) : (
            <Download className="size-4" />
          )}
          检查更新
        </Button>
        {version && (
          <Button
            variant="outline"
            onClick={() => void downloadAndInstall()}
            disabled={downloading}
          >
            {downloading ? (
              <Loader2 className="size-4 animate-spin" />
            ) : (
              <RotateCcw className="size-4" />
            )}
            下载并安装 {version}
          </Button>
        )}
      </div>

      {lastChecked != null && (
        <p className="text-[12px] text-muted-foreground">
          上次检查：{new Date(lastChecked).toLocaleTimeString()}
        </p>
      )}
    </section>
  );
}
