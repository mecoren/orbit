/**
 * 详情页描述悬浮预览设置（localStorage 本机视图态，不随云同步）
 *
 * 默认开启 + 800ms 悬浮延迟（防呆：误滑过不闪弹层）；键值风格对齐
 * todo_view_mode 等 04 §七 localStorage 约定。纯函数 + 容错解析，
 * 与设置页/详情抽屉两端解耦。
 */
import { LS_DESC_PREVIEW_DELAY, LS_DESC_PREVIEW_ENABLED } from "./constants";

export const DESC_PREVIEW_DELAY_DEFAULT = 800;

/** 档位式延迟选项（毫秒）——设置页 Select 用；自定义数值仍可被读取端接受 */
export const DESC_PREVIEW_DELAY_CHOICES = [
  { ms: 300, label: "0.3 秒" },
  { ms: 500, label: "0.5 秒" },
  { ms: 800, label: "0.8 秒（默认）" },
  { ms: 1500, label: "1.5 秒" },
  { ms: 3000, label: "3 秒" },
] as const;

/** 读取「是否开启悬浮预览」；缺省/非法值回退默认开启 */
export function getDescPreviewEnabled(): boolean {
  try {
    const v = localStorage.getItem(LS_DESC_PREVIEW_ENABLED);
    if (v == null) return true;
    return v === "1";
  } catch {
    return true;
  }
}

/** 写入开关（"1"/"0"） */
export function setDescPreviewEnabled(enabled: boolean): void {
  try {
    localStorage.setItem(LS_DESC_PREVIEW_ENABLED, enabled ? "1" : "0");
  } catch {
    // localStorage 不可用（隐私模式等）时静默——预览功能本身非关键路径
  }
}

/** 读取悬浮延迟毫秒；缺省/非法/越界回退默认 800ms */
export function getDescPreviewDelayMs(): number {
  try {
    const v = localStorage.getItem(LS_DESC_PREVIEW_DELAY);
    if (v == null) return DESC_PREVIEW_DELAY_DEFAULT;
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0 || n > 60_000) return DESC_PREVIEW_DELAY_DEFAULT;
    return Math.round(n);
  } catch {
    return DESC_PREVIEW_DELAY_DEFAULT;
  }
}

/** 写入延迟毫秒（调用方保证合法档位；读取端仍有容错兜底） */
export function setDescPreviewDelayMs(ms: number): void {
  try {
    localStorage.setItem(LS_DESC_PREVIEW_DELAY, String(ms));
  } catch {
    // 同上：非关键路径静默
  }
}
