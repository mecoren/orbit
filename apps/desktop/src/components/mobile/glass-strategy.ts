/**
 * 玻璃模糊层的渐隐策略（05 §三）：
 * - mask：backdrop-filter 全强度 + -webkit-mask-image 垂直渐变，淡出最顺滑；
 * - segmented：不支持 mask 时降级为弱 blur + 线性渐变背景近似。
 */
export type GlassStrategy = "mask" | "segmented";

export function pickGlassStrategy(supportsMask: boolean): GlassStrategy {
  return supportsMask ? "mask" : "segmented";
}
