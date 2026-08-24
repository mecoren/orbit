/**
 * MobileSettingsScreen —— 移动设置页 /settings（06 任务 4.8 同步开关最小 UI，M4 Task 17）
 *
 * 三卡结构：「云同步」（总开关 + 引擎摘要 + 立即同步 + 最近结果）、「安全」（主密码状态只读）、
 * 「关于」（版本号 + 关于页入口）。移动端不做凭据表单（跨端录入记 M6+）：
 * 开关切换走「先 Get 再合并提交」，缺省键=跳过语义（Rust serde default），密码留空沿用原凭据。
 */
import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router";

import { LiquidGlassTitleBar } from "@/components/mobile/liquid-glass-title-bar";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { EqSpinner } from "@/components/mobile/eq-spinner";
import { waitToast } from "@/components/mobile/wait-toast";
import { SectionCard } from "@/features/todo/mobile/section-card";
import { TODO_ACCENT } from "@/features/todo/shared/constants";
import { Switch } from "@/components/ui/switch";
import {
  cloudSyncIsRunning,
  cloudSyncNow,
  masterAuthHas,
  syncConfigGet,
  syncConfigSave,
  type SyncConfigInput,
  type SyncConfigView,
} from "@/lib/tauri";

/** 与 package.json / tauri.conf.json / Cargo.toml 保持一致（同 about-page） */
const APP_VERSION = "0.1.0";

/** 错误消息转用户文案（保留 tag 前缀供开发排查，同 sync-section） */
function errMsg(err: unknown): string {
  const msg = err instanceof Error ? err.message : String(err);
  return msg.replace(/^\[\w+\]\s*/, "");
}

/** 引擎摘要行（脱敏不显示凭据）：webdav→base_url host / s3→bucket */
function engineSummary(config: SyncConfigView): string {
  if (config.engine === "s3") return `S3 · ${config.bucket || "-"}`;
  let host = config.endpoint;
  try {
    host = new URL(config.endpoint).host || config.endpoint;
  } catch {
    // 非 URL 形态直接原样展示
  }
  return `WebDAV · ${host}`;
}

export function SettingsMobileScreen() {
  const navigate = useNavigate();
  const scrollRef = useRef<HTMLDivElement>(null);

  const [config, setConfig] = useState<SyncConfigView | null>(null);
  const [savingSwitch, setSavingSwitch] = useState(false);
  const [running, setRunning] = useState(false);
  /** 最近一次手动同步的结果行（成功摘要或错误文案；空则回落到 last_synced_at 展示） */
  const [syncMsg, setSyncMsg] = useState<string | null>(null);
  const [masterAuthed, setMasterAuthed] = useState(false);

  useEffect(() => {
    syncConfigGet().then(setConfig).catch(() => {});
    masterAuthHas().then(setMasterAuthed).catch(() => {});
    // 后台同步进行中时禁用手动触发
    cloudSyncIsRunning().then(setRunning).catch(() => {});
  }, []);

  /**
   * 总开关：先 Get 取最新配置再合并提交（缺省键=跳过语义；密码不回传 → 后端沿用原凭据）。
   * 未配置引擎时不触发保存（开关禁用 + 引导文案）。
   */
  const handleAutoSyncToggle = async (next: boolean) => {
    if (savingSwitch) return;
    setSavingSwitch(true);
    try {
      const latest = await syncConfigGet();
      if (!latest) return;
      const input: SyncConfigInput = {
        engine: latest.engine === "s3" ? "s3" : "webdav",
        endpoint: latest.endpoint,
        bucket: latest.bucket,
        region: latest.region,
        username: latest.username,
        base_path: latest.base_path,
        interval_minutes: latest.interval_minutes,
        auto_sync_enabled: next,
        sync_on_change: latest.sync_on_change,
        skip_tls_verify: latest.skip_tls_verify,
        timeout_seconds: latest.timeout_seconds,
      };
      const saved = await syncConfigSave(input);
      setConfig(saved);
    } catch {
      waitToast.destructive("保存失败");
      // 受控 Switch 状态未变，视觉自动回弹
    } finally {
      setSavingSwitch(false);
    }
  };

  const handleSyncNow = async () => {
    setRunning(true);
    setSyncMsg(null);
    try {
      const result = await cloudSyncNow("manual");
      setSyncMsg(
        result.skipped
          ? "已有同步任务在进行中"
          : `同步完成：推送 ${result.pushed_modules} 模块 / 拉取 ${result.pulled_modules} 模块` +
              (result.errors.length ? `（${result.errors.length} 个非致命错误）` : ""),
      );
    } catch (err) {
      setSyncMsg(`同步失败：${errMsg(err)}`);
    } finally {
      setRunning(false);
      syncConfigGet().then(setConfig).catch(() => {});
    }
  };

  return (
    <div className="h-dvh bg-[var(--m-bg)] text-[var(--m-text)]">
      {/* 滚动容器 ref 与标题栏同 commit 赋值（LiquidGlassTitleBar scrollRef 契约） */}
      <div ref={scrollRef} className="h-full overflow-y-auto overscroll-y-contain">
        <LiquidGlassTitleBar
          title="设置"
          onBack={() => navigate(-1)}
          scrollRef={scrollRef}
        />

        <div className="space-y-3 p-4">
          {/* 一、云同步（06 任务 4.8 最小集） */}
          <SectionCard title="云同步">
            <div className="flex items-center gap-3 py-1">
              <div className="min-w-0 flex-1">
                <p className="text-sm font-medium">自动同步</p>
                {config && (
                  <p className="truncate text-xs text-[var(--m-sub)]">
                    {engineSummary(config)}
                  </p>
                )}
              </div>
              <Switch
                checked={config?.auto_sync_enabled ?? false}
                disabled={!config || savingSwitch}
                onCheckedChange={(next) => void handleAutoSyncToggle(next)}
                aria-label="自动同步"
              />
            </div>
            {!config && (
              <p className="pt-1 text-xs text-[var(--m-sub)]">
                尚未配置同步引擎，请在桌面端完成配置后同步使用
              </p>
            )}
            <button
              type="button"
              disabled={running || !config}
              onClick={() => void handleSyncNow()}
              className="mt-3 flex w-full items-center justify-center gap-2 rounded-lg py-2 text-sm font-medium text-white disabled:opacity-50"
              style={{ background: TODO_ACCENT }}
            >
              {running && <EqSpinner size={20} color="#ffffff" />}
              立即同步
            </button>
            <p className="truncate pt-2 text-xs text-[var(--m-sub)]">
              {syncMsg ??
                (config?.last_synced_at
                  ? `上次同步：${new Date(config.last_synced_at).toLocaleString()}`
                  : "从未同步")}
            </p>
          </SectionCard>

          {/* 二、安全（只读）。ADR 0001 §七-③：Android 无 SQLCipher，「开启主密码」迁移
              （sqlcipher_export）必败且会造成明文库混合状态——移动端安全卡只读展示、
              不提供开启/迁移入口以规避该路径；修改入口记 M6+ */}
          <SectionCard title="安全">
            <div className="flex items-center justify-between py-1">
              <span className="text-sm font-medium">主密码</span>
              <span className="text-sm text-[var(--m-sub)]">
                {masterAuthed ? "已设置" : "免密模式"}
              </span>
            </div>
          </SectionCard>

          {/* 三、关于 */}
          <SectionCard title="关于">
            <div className="flex items-center justify-between py-1">
              <span className="text-sm font-medium">版本</span>
              <span className="text-sm text-[var(--m-sub)]">{APP_VERSION}</span>
            </div>
            <button
              type="button"
              onClick={() => navigate("/about")}
              className="flex w-full items-center justify-between py-1 text-left active:opacity-70"
            >
              <span className="text-sm font-medium">关于循迹</span>
              <MaterialIcon name="chevron_right_rounded" size={22} color="var(--m-sub)" />
            </button>
          </SectionCard>

          <div className="m-safe-bottom" aria-hidden />
        </div>
      </div>
    </div>
  );
}
