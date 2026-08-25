/**
 * EqSpinner 物理模型 —— 蓝本 bounce-blocks（src/components/EqualizerLoader.tsx）的
 * 纯函数移植，逻辑坐标与蓝本一致（画布高 121、球径 31、起跳初速 640）。
 * 与组件解耦以便 vitest 数值回归（发散/静置/循环三性质）。
 *
 * 模型：贴地等待 delay → 向上起跳 → 重力回落 → 触地按弹性反弹 + 撞击挤压
 *       （一次性赋值，非逐帧泵入）→ 反弹过弱进入 resting 静置 → REST_DELAY 后再起跳循环。
 */

// —— 物理常量（逐值对齐蓝本，05 §五：重力 2600、restitution 0.62、弹簧 170/14、延迟 0/.65/1.3s）——
export const GRAVITY = 2600;
export const RESTITUTION = 0.62;
export const STIFFNESS = 170;
export const DAMPING = 14;
export const REST_DELAY = 0.7;
export const JUMP_VELOCITY = 640;
/** 逻辑坐标：地面 y、球径（蓝本原值，渲染层按 size 等比缩放） */
export const GROUND_Y = 121;
export const DOT_SIZE = 31;
/** 三球入场延迟（s）：错落节奏=上一球落地后下一球才起跳 */
export const DELAYS = [0, 0.65, 1.3];

export interface BlockState {
  delay: number;
  /** 本周期已流逝时间（s）：延迟入场与静止重放共用 */
  cycElapsed: number;
  /** 球顶边逻辑 y；GROUND_Y - DOT_SIZE = 贴地 */
  y: number;
  vy: number;
  /** >0 压扁 / <0 拉长 */
  squash: number;
  squashVel: number;
  /** 延迟未到前贴地等待 */
  active: boolean;
  /** 反弹过弱已静置贴地 */
  resting: boolean;
  restTimer: number;
}

const clamp = (v: number, min: number, max: number) => Math.min(max, Math.max(min, v));

export function createBlock(delay: number): BlockState {
  return {
    delay,
    cycElapsed: 0,
    y: GROUND_Y - DOT_SIZE,
    vy: 0,
    squash: 0,
    squashVel: 0,
    active: false,
    resting: false,
    restTimer: 0,
  };
}

/** 单步推进（dt 秒）。就地修改状态；语义逐行对齐蓝本 Block.update。 */
export function stepBlock(b: BlockState, dt: number): void {
  b.cycElapsed += dt;

  if (!b.active) {
    // 贴地等待：到延迟时刻向上起跳（依次跳起，而非坠落）
    if (b.cycElapsed >= b.delay) {
      b.active = true;
      b.vy = -JUMP_VELOCITY;
    } else {
      return;
    }
  }

  if (b.resting) {
    // 贴地静止：仅弹簧恢复 + 重放计时
    b.y = GROUND_Y - DOT_SIZE;
    b.squashVel += (-STIFFNESS * b.squash - DAMPING * b.squashVel) * dt;
    b.squash += b.squashVel * dt;
    if (Math.abs(b.squash) < 0.001 && Math.abs(b.squashVel) < 0.5) {
      b.restTimer += dt;
      if (b.restTimer > REST_DELAY) resetBlock(b, true); // 循环：立即再次起跳
    }
    return;
  }

  // 重力 + 位移积分
  b.vy += GRAVITY * dt;
  b.y += b.vy * dt;

  // 地面碰撞：仅在向下运动时判定（防静置帧反复触发）；撞击速度决定挤压量，按弹性系数反弹
  if (b.y + DOT_SIZE >= GROUND_Y && b.vy > 0) {
    b.y = GROUND_Y - DOT_SIZE;
    const impact = b.vy;
    b.vy = -impact * RESTITUTION;
    // 经验标定（蓝本原值）：挤压为撞击时一次性赋值，随后由弹簧-阻尼恢复果冻回弹
    b.squash = clamp(impact / 2400, 0, 0.55);
    b.squashVel = 0;
    // 反弹太弱直接静止，避免无限微跳空转
    if (Math.abs(b.vy) < 60) {
      b.vy = 0;
      b.resting = true;
      b.restTimer = 0;
    }
  }

  // 挤压量的弹簧恢复（果冻般回弹）
  b.squashVel += (-STIFFNESS * b.squash - DAMPING * b.squashVel) * dt;
  b.squash += b.squashVel * dt;
}

/** 重置状态。首次 reset() 后贴地等待 delay 再起跳；循环重放 immediateJump=true 立即起跳。 */
export function resetBlock(b: BlockState, immediateJump = false): void {
  b.cycElapsed = 0;
  b.y = GROUND_Y - DOT_SIZE;
  b.vy = 0;
  b.squash = 0;
  b.squashVel = 0;
  b.active = immediateJump;
  b.resting = false;
  b.restTimer = 0;
  if (immediateJump) b.vy = -JUMP_VELOCITY;
}
