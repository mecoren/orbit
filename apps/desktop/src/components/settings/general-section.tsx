/**
 * 通用分区（开机自启动，07 backlog #51）
 *
 * - 自启状态的真值在系统注册项里（Windows HKCU Run / macOS LaunchAgent
 *   plist / Linux XDG .desktop），本组件不做本地副本：挂载时问系统，
 *   切换后回读系统返回为准（用户在系统「启动应用」里禁用的状态可见）。
 * - 自启拉起的进程带 `--hidden`：静默驻留托盘、不弹主窗，壳层已接隐藏
 *   回收链（见 startup_cmd / lib.rs setup）。
 * - 插件模块动态 import：mock IPC 环境（e2e / vitest 纯浏览器）无 autostart
 *   通道，静态导入会在页面加载即抛错；动态导入把失败收敛到「关闭」态。
 */
import { useEffect, useState } from "react";
import { Power } from "lucide-react";
import { toast } from "sonner";

import { Switch } from "@/components/ui/switch";

/** 动态加载的插件模块类型（编译期无浏览器 fallback 报错） */
type AutostartModule = typeof import("@tauri-apps/plugin-autostart");

export function GeneralSection() {
  /** null = 状态查询中：开关禁用，避免拿未定的真值去写系统 */
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const m: AutostartModule = await import("@tauri-apps/plugin-autostart");
        const v = await m.isEnabled();
        if (!cancelled) setEnabled(v);
      } catch {
        // 纯浏览器 / 不支持的环境：按关闭展示（真实 Tauri 下不会走到）
        if (!cancelled) setEnabled(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const toggle = async (next: boolean) => {
    if (busy) return;
    setBusy(true);
    try {
      const m: AutostartModule = await import("@tauri-apps/plugin-autostart");
      await (next ? m.enable() : m.disable());
      // 回读系统真值（enable 写注册项后 isEnabled 才是准的）
      setEnabled(await m.isEnabled().catch(() => next));
      toast.success(next ? "已开启开机自启动" : "已关闭开机自启动");
    } catch (e) {
      toast.error("设置开机自启动失败", {
        description: e instanceof Error ? e.message : String(e),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-base font-semibold">通用</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">应用启动行为</p>
      </div>

      <div className="space-y-4 rounded-lg border p-5">
        <div className="flex items-center gap-3">
          <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-muted">
            <Power className="size-4 text-muted-foreground" />
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-sm font-medium">开机自启动</p>
            <p className="text-xs text-muted-foreground">
              登录系统后在后台自动运行，静默驻留托盘（不弹主窗口），同步与提醒提前就绪
            </p>
          </div>
          <Switch
            checked={enabled === true}
            disabled={enabled === null || busy}
            onCheckedChange={(v) => void toggle(v)}
            aria-label="开机自启动开关"
          />
        </div>

        <p className="text-xs text-muted-foreground">
          提示：本开关直接读写系统启动项（Windows 任务管理器「启动应用」/ macOS
          登录项 / Linux 启动应用程序），状态以系统为准；卸载前建议先关闭。
        </p>
        <p className="text-xs text-muted-foreground">
          提示：已设置主密码时，自启只负责提前就绪——仍需解锁应用后提醒轮询才会运行。
        </p>
      </div>
    </div>
  );
}
