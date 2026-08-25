/**
 * BottomSheet 纯物理逻辑。
 * 规格来源：05 §四/§五 —— snap .65/.35/1.0、scrollSpring(1,170,24)、drawerVelocity=500px/s。
 */

/**
 * touchend 选点：速度主导（|v|>500px/s 时从最近档沿滑动方向步进一档，边界钳制），否则吸附最近档。
 * 语义边界（MVP 简化）：单次手势至多跨一档——极快挥动也不会连跳多档；
 * 最近邻平局时保留低索引（数值更小的档），调用方传入升序数组结果可预期。
 * 坐标约定与测试一致："上滑"用负速度表示，对应取数值更大的一档（高度空间：值越大越靠上）。
 * @param offsetPx 当前面板抬起高度 px（高度空间，≥0）
 * @param velocityPxPerS 屏幕坐标末段采样速度 px/s（clientY 差分，上滑为负）
 * @param snapsPx snap 点像素数组（建议升序；内部按最近邻比较）
 */
export function pickSnapIndex(offsetPx: number, velocityPxPerS: number, snapsPx: number[]): number {
  let best = 0;
  for (let i = 1; i < snapsPx.length; i++) {
    if (Math.abs(snapsPx[i] - offsetPx) < Math.abs(snapsPx[best] - offsetPx)) best = i;
  }
  if (velocityPxPerS < -500) return Math.min(best + 1, snapsPx.length - 1);
  if (velocityPxPerS > 500) return Math.max(best - 1, 0);
  return best;
}

/** 半隐式欧拉弹簧积分一步（scrollSpring 1,170,24 / drawerSpring 1,300,25 通用） */
export function springStep(
  pos: number,
  vel: number,
  target: number,
  stiffness: number,
  damping: number,
  dt: number,
): [number, number] {
  const nv = vel + (-stiffness * (pos - target) - damping * vel) * dt;
  return [pos + nv * dt, nv];
}
