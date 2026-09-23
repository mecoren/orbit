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

/** 同步账本：单表（模块）的桶指纹摘要 */
export interface SyncLedgerModule {
  /** 表名（同步模块名） */
  table: string;
  /** 桶数 */
  buckets: number;
  /** 各桶指纹摘要，按桶键升序 */
  entries: { key: string; fp: string }[];
}

/** 指纹摘要：sha256 hex 前 8 位（够分辨桶，又不把整行铺满） */
export function shortFingerprint(fp: string): string {
  return fp.length > 8 ? fp.slice(0, 8) : fp;
}

/**
 * 桶索引快照（core `SyncState.remote_tables` / `remote_tombstones`）→ 展示行
 *
 * 表名升序；桶内按桶键升序——数据桶的键是**数字桶号的字符串形态**，直接按
 * 字符串排会把 10 排到 2 前面（桶号 ≥ 10 的库上肉眼可见），故先试数值比较。
 */
export function syncLedgerModules(
  snapshot: Record<string, Record<string, string>>,
): SyncLedgerModule[] {
  return Object.keys(snapshot)
    .sort()
    .map((table) => {
      const buckets = snapshot[table] ?? {};
      const keys = Object.keys(buckets).sort((a, b) => {
        const na = Number(a);
        const nb = Number(b);
        if (Number.isFinite(na) && Number.isFinite(nb)) return na - nb;
        return a.localeCompare(b);
      });
      return {
        table,
        buckets: keys.length,
        entries: keys.map((k) => ({ key: k, fp: shortFingerprint(buckets[k]) })),
      };
    });
}

/** 桶总数（跨表求和） */
export function countBuckets(snapshot: Record<string, Record<string, string>>): number {
  return Object.values(snapshot).reduce((n, b) => n + Object.keys(b).length, 0);
}

/** 逻辑时钟毫秒 → 展示文案；0 = 从未推进（首轮全量 / 从未成功同步） */
export function formatClockMs(value: number): string {
  if (!value || value <= 0) return "未推进";
  return new Date(value).toLocaleString();
}

/** 同步结果摘要（成功提示 / 底部面板文案） */
export function syncResultSummary(r: {
  pushed_modules: number;
  pulled_modules: number;
  skipped: boolean;
  errors: string[];
}): string {
  if (r.skipped) return "已有同步任务在进行中";
  // 无任何推拉且无错误 = 本轮无新变化（数据早已由自动推送/上一轮同步完成），
  // 直说"已是最新"，避免"推送 0 模块"被误读为同步失败
  if (r.pushed_modules === 0 && r.pulled_modules === 0 && r.errors.length === 0) {
    return "同步完成：已是最新，无需同步";
  }
  const base = `同步完成：推送 ${r.pushed_modules} 模块 / 拉取 ${r.pulled_modules} 模块`;
  return r.errors.length ? `${base}（${r.errors.length} 个非致命错误）` : base;
}

/** 同步错误 tag → 用户处置通道（F44，与移动端 `syncErrorAction` 同口径） */
export type SyncErrorAction = "recovery" | "unlock" | "upgrade" | "none";

/**
 * 错误 tag（Rust 侧 `category_tag()`）到处置动作的归类
 *
 * - `recovery`（key_mismatch）：本地密钥解不开云端密文，跳密钥恢复页；
 * - `unlock`（password / not_unlocked）：引导重输同步密码；
 * - `upgrade`（payload_version）：云端载荷版本高于本端（ADR 0010 两拍升级），
 *   处置动作是**升级应用**——若不单独归类而塌进 key_mismatch，用户会被
 *   引到密钥恢复页并可能放弃解不开的云端数据（误导且不可逆）；
 * - `none`：网络 / 数据库 / 认证 / 限流等普通失败，按原文 toast。
 */
export function syncErrorAction(tag: string | null): SyncErrorAction {
  switch (tag) {
    case "key_mismatch":
      return "recovery";
    case "password":
    case "not_unlocked":
      return "unlock";
    case "payload_version":
      return "upgrade";
    default:
      return "none";
  }
}
