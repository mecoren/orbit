/**
 * constant-interval —— 持续提醒间隔的档位与文案（双端同一口径的桌面侧）
 *
 * 持续提醒（G2，`is_constant = 1`）到期未完成时按「行级间隔」原地顺延。
 * 间隔落库列 `todo_reminders.constant_interval_ms`，core 侧按
 * [1 分钟, 24 小时] 钳制（`clamp_constant_interval_ms`）；本文件只负责
 * 选择档位、归一与展示文案，**不重复实现钳制语义**——写入前调用
 * [normalizeConstantIntervalMs]，越界值由后端与本地同口径收敛。
 *
 * 设置页的「默认间隔」只是**新建提醒的初值**（本机 localStorage，不随云同步）：
 * 单条提醒的档位始终可覆盖，改设置不会回改已存在的提醒。
 */
import { LS_CONSTANT_INTERVAL_DEFAULT } from "./constants";

/** 默认间隔（5 分钟）：与 core `DEFAULT_CONSTANT_INTERVAL_MS` 一致 */
export const DEFAULT_CONSTANT_INTERVAL_MS = 5 * 60_000;
/** 间隔下限（1 分钟）：与 core `MIN_CONSTANT_INTERVAL_MS` 一致 */
export const MIN_CONSTANT_INTERVAL_MS = 60_000;
/** 间隔上限（24 小时）：与 core `MAX_CONSTANT_INTERVAL_MS` 一致 */
export const MAX_CONSTANT_INTERVAL_MS = 24 * 60 * 60_000;

/** 预设档位（分钟）：1/5/10/15/30/60，覆盖「吵一点」到「一小时一催」 */
export const CONSTANT_INTERVAL_PRESETS_MIN = [1, 5, 10, 15, 30, 60] as const;

/**
 * 归一间隔：非正/缺失 → 默认 5 分钟；越界钳到 [1 分钟, 24 小时]。
 * 与 core `clamp_constant_interval_ms` 同语义（老库存量/跨端脏值都能落位）。
 */
export function normalizeConstantIntervalMs(
  ms: number | null | undefined,
): number {
  if (ms == null || !Number.isFinite(ms) || ms <= 0) {
    return DEFAULT_CONSTANT_INTERVAL_MS;
  }
  return Math.min(MAX_CONSTANT_INTERVAL_MS, Math.max(MIN_CONSTANT_INTERVAL_MS, Math.round(ms)));
}

/**
 * 下拉档位：预设 ∪ 当前值。
 * 当前值不在预设内（跨端写入的自定义分钟数）时补进去，避免选择器显示空白。
 */
export function constantIntervalOptions(currentMs: number): number[] {
  const current = normalizeConstantIntervalMs(currentMs);
  const preset = CONSTANT_INTERVAL_PRESETS_MIN.map((m) => m * 60_000);
  return preset.includes(current)
    ? preset
    : [...preset, current].sort((a, b) => a - b);
}

/**
 * 间隔文案：「每 5 分钟」/「每 1 小时」。
 * 整小时档走小时措辞，其余（含 90 分钟这类自定义值）用分钟，避免 1.5 小时。
 */
export function formatConstantInterval(ms: number): string {
  const normalized = normalizeConstantIntervalMs(ms);
  const minutes = Math.round(normalized / 60_000);
  if (minutes % 60 === 0) {
    return `每 ${minutes / 60} 小时`;
  }
  return `每 ${minutes} 分钟`;
}

/**
 * 读取「新建提醒的默认间隔」：缺省/非法/越界回落 5 分钟。
 * 仅作初值——已存在的提醒走各自行上的 `constant_interval_ms`。
 */
export function getDefaultConstantIntervalMs(): number {
  try {
    const raw = localStorage.getItem(LS_CONSTANT_INTERVAL_DEFAULT);
    if (raw == null) return DEFAULT_CONSTANT_INTERVAL_MS;
    const n = Number(raw);
    if (!Number.isFinite(n) || n <= 0) return DEFAULT_CONSTANT_INTERVAL_MS;
    return normalizeConstantIntervalMs(n);
  } catch {
    // localStorage 不可用（隐私模式等）时静默——默认间隔非关键路径
    return DEFAULT_CONSTANT_INTERVAL_MS;
  }
}

/** 写入「新建提醒的默认间隔」（本机设置；读取端仍有容错兜底） */
export function setDefaultConstantIntervalMs(ms: number): void {
  try {
    localStorage.setItem(
      LS_CONSTANT_INTERVAL_DEFAULT,
      String(normalizeConstantIntervalMs(ms)),
    );
  } catch {
    // 同上：非关键路径静默
  }
}
