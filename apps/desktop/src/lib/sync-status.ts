/**
 * sync-status — 云同步状态展示口径（左上角云图标 / 设置页共用）
 *
 * 全部为纯函数：状态派生、时间文案、进度文案、结果摘要。口径约定：
 * - 状态优先级：未配置 > 未就绪（未设置密码或已锁定）> 运行态；
 * - 「下次自动同步」按调度器判据（`last_synced_at + interval_minutes`）估算，
 *   仅作展示（调度器实际以 60s tick 判定），故文案带「约」；
 * - 时间戳为毫秒，展示一律走本地时区（与设置页同步卡同口径）；
 * - 只读展示不涉及备份，备份链路（backup_* / full_backup_*）与本模块无关。
 */

/** 云图标展示状态 */
export type SyncUiStatus = "unconfigured" | "locked" | "idle" | "syncing" | "success" | "error";

/** 组件内维护的运行态（配置/解锁维度由服务端状态派生） */
export type SyncRunPhase = "idle" | "syncing" | "success" | "error";

/** Rust TauriProgressSender emit("sync-progress") 载荷（snake_case 直传） */
export interface SyncProgressEvent {
  phase:
    | "starting"
    | "pushing"
    | "pulling"
    | "merging"
    | "local_data_applied"
    | "attachments"
    | "done"
    | "error";
  origin: "background" | "manual" | "exit";
  display_name?: string;
  current?: number;
  total?: number;
  message?: string;
}

/** 派生展示状态（优先级：未配置 > 未就绪 > 运行态） */
export function deriveSyncStatus(input: {
  hasConfig: boolean;
  hasPassword: boolean;
  isUnlocked: boolean;
  runPhase: SyncRunPhase;
}): SyncUiStatus {
  if (!input.hasConfig) return "unconfigured";
  if (!input.hasPassword || !input.isUnlocked) return "locked";
  return input.runPhase;
}

/** 状态行文案（悬浮提示首行；locked 区分「未设置密码」与「已锁定」） */
export function syncStatusLabel(status: SyncUiStatus, hasPassword = true): string {
  switch (status) {
    case "unconfigured":
      return "未配置云同步";
    case "locked":
      return hasPassword ? "同步密码已锁定" : "未设置同步密码";
    case "syncing":
      return "正在同步…";
    case "success":
      return "同步完成";
    case "error":
      return "同步失败";
    default:
      return "已就绪";
  }
}

/** 上次同步时间文案；null / 0（从未成功记账）→ 「从未同步」 */
export function formatLastSynced(lastSyncedAt: number | null): string {
  if (lastSyncedAt == null || lastSyncedAt <= 0) return "从未同步";
  return new Date(lastSyncedAt).toLocaleString();
}

/** 下次自动同步估算时间戳；未启用定时 / 间隔非法 / 无上次同步时间 → null */
export function estimateNextSyncAt(config: {
  auto_sync_enabled: boolean;
  interval_minutes: number;
  last_synced_at: number | null;
}): number | null {
  const { auto_sync_enabled, interval_minutes, last_synced_at } = config;
  if (!auto_sync_enabled || interval_minutes <= 0) return null;
  if (last_synced_at == null || last_synced_at <= 0) return null;
  return last_synced_at + interval_minutes * 60_000;
}

/** 下次自动同步展示文案 */
export function formatNextSync(nextAt: number | null): string {
  if (nextAt == null) return "未启用定时同步";
  return `约 ${new Date(nextAt).toLocaleString()}`;
}

/** 进度事件 → 中文文案（含计数；终态同样复用） */
export function syncProgressText(e: {
  phase: SyncProgressEvent["phase"];
  display_name?: string;
  current?: number;
  total?: number;
  message?: string;
}): string {
  switch (e.phase) {
    case "starting":
      return "准备同步…";
    case "pushing":
      return `正在上传${e.display_name ?? ""} ${e.current ?? 0}/${e.total ?? 0}…`;
    case "pulling":
      return `正在下载${e.display_name ?? ""} ${e.current ?? 0}/${e.total ?? 0}…`;
    case "merging":
      return `正在合并${e.display_name ?? ""}…`;
    case "local_data_applied":
      return "本地数据已更新";
    case "attachments":
      return "同步附件中…";
    case "done":
      return "同步完成";
    case "error":
      return e.message ? `同步失败：${e.message}` : "同步失败";
    default:
      return "";
  }
}

/** 同步结果摘要（成功提示 / 底部面板文案） */
export function syncResultSummary(r: {
  pushed_modules: number;
  pulled_modules: number;
  skipped: boolean;
  errors: string[];
}): string {
  if (r.skipped) return "已有同步任务在进行中";
  const base = `同步完成：推送 ${r.pushed_modules} 模块 / 拉取 ${r.pulled_modules} 模块`;
  return r.errors.length ? `${base}（${r.errors.length} 个非致命错误）` : base;
}
