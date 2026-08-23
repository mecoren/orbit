import { useEffect, useRef } from "react";

interface EqualizerLoaderProps {
  /** 画布整体宽度（px），默认 160 */
  size?: number;
  /** 可选的加载说明文字 */
  label?: string;
  /** 内联模式：仅渲染 svg，不包裹 flex 列容器，用于按钮内等紧凑场景 */
  inline?: boolean;
  className?: string;
}

/**
 * 加载动画：3 个圆角方块错落弹跳（物理模拟）。
 *
 * 复刻参考实现 bounce-blocks.ts 的物理模型：
 * - 三个方块依次从地面向上起跳（按延迟错落，而非坠落）
 * - 重力减速至最高点后回落，触地按弹性系数反弹（能量衰减，最终静止）
 * - 撞击速度越大，落地挤压越扁（体积守恒：变宽的同时变矮）
 * - 挤压量经弹簧-阻尼恢复，带果冻般的回弹余震
 * - 方块越高，地面影子越小越淡
 * - 静止片刻后依次再次起跳，循环播放
 *
 * 颜色取自主题强调色 `--primary`（受用户自定义 accent 与明暗主题自动影响），
 * 因此无需在 JS 中读取颜色，仅通过 `currentColor` 跟随 CSS 变量即可。
 */

// —— 物理常量（参考 bounce-blocks.ts）——
const GRAVITY = 2600; // 重力加速度 px/s²
const RESTITUTION = 0.62; // 弹性系数（0~1）
const STIFFNESS = 170; // 挤压回弹弹簧刚度
const DAMPING = 14; // 挤压回弹阻尼
const REST_DELAY = 0.7; // 静止后等待多久再次起跳（s），保证循环连续
// 起跳初速度（向上，px/s）：v²=2gh → 640²/(2×2600)≈79px 高
const JUMP_VELOCITY = 640;

// 方块边长（逻辑 px）与地板位置（逻辑 y）
const DOT_SIZE = 31;
const GROUND_Y = 121;
// 方块圆角半径
const DOT_RX = 10;

// 3 个方块的圆心 x 与延迟落下时间（s），形成从左到右的错落起跳。
// 方块下落约需 0.35s，延迟取 0 / 0.65 / 1.3s，保证上一个落地后下一个才起跳，
// 依次进行的节奏清晰。
const CENTERS = [23.5, 81.5, 139.5];
const DELAYS = [0, 0.65, 1.3];

const clamp = (v: number, min: number, max: number) =>
  Math.min(max, Math.max(min, v));

/** 单个方块的物理状态：贴地等待 → 依次起跳 → 重力回落/挤压/反弹 → 静止后再起跳 */
class Block {
  cx: number;
  delay: number;
  cycElapsed = 0; // 本周期已流逝时间（用于延迟与重放计时）
  y = GROUND_Y - DOT_SIZE; // 顶边 y（初始贴地）
  vy = 0; // 垂直速度
  squash = 0; // >0 压扁，<0 拉长
  squashVel = 0;
  active = false; // 延迟未到前贴地等待
  resting = false; // 反弹太弱已静止贴地
  restTimer = 0;

  constructor(cx: number, delay: number) {
    this.cx = cx;
    this.delay = delay;
  }

  /** 重置状态。首次 `reset()` 后贴地等待 delay 再起跳；循环重放传 true 立即起跳，保持错落节奏。 */
  reset(immediateJump = false) {
    this.cycElapsed = 0;
    this.y = GROUND_Y - DOT_SIZE;
    this.vy = 0;
    this.squash = 0;
    this.squashVel = 0;
    this.active = immediateJump;
    this.resting = false;
    this.restTimer = 0;
    if (immediateJump) this.vy = -JUMP_VELOCITY;
  }

  update(dt: number) {
    this.cycElapsed += dt;

    if (!this.active) {
      // 贴地等待：到延迟时刻向上起跳（依次跳起，而非坠落）
      if (this.cycElapsed >= this.delay) {
        this.active = true;
        this.vy = -JUMP_VELOCITY;
      } else {
        return;
      }
    }

    if (this.resting) {
      // 贴地静止：仅弹簧恢复 + 重放计时
      this.y = GROUND_Y - DOT_SIZE;
      this.squashVel += (-STIFFNESS * this.squash - DAMPING * this.squashVel) * dt;
      this.squash += this.squashVel * dt;
      if (Math.abs(this.squash) < 0.001 && Math.abs(this.squashVel) < 0.5) {
        this.restTimer += dt;
        if (this.restTimer > REST_DELAY) this.reset(true); // 循环：立即再次起跳
      }
      return;
    }

    // 重力 + 位移积分
    this.vy += GRAVITY * dt;
    this.y += this.vy * dt;

    // 地面碰撞：撞击速度决定挤压量，按弹性系数反弹
    if (this.y + DOT_SIZE >= GROUND_Y && this.vy > 0) {
      this.y = GROUND_Y - DOT_SIZE;
      const impact = this.vy;
      this.vy = -impact * RESTITUTION;
      this.squash = clamp(impact / 2400, 0, 0.55);
      this.squashVel = 0;
      // 反弹太弱直接静止，避免无限微弹
      if (Math.abs(this.vy) < 60) {
        this.vy = 0;
        this.resting = true;
        this.restTimer = 0;
      }
    }

    // 挤压量的弹簧恢复（果冻般回弹）
    this.squashVel += (-STIFFNESS * this.squash - DAMPING * this.squashVel) * dt;
    this.squash += this.squashVel * dt;
  }
}

export function EqualizerLoader({
  size = 160,
  label,
  inline = false,
  className,
}: EqualizerLoaderProps) {
  const rectRefs = useRef<(SVGRectElement | null)[]>([]);
  const shadowRefs = useRef<(SVGEllipseElement | null)[]>([]);

  useEffect(() => {
    const blocks = CENTERS.map((cx, i) => new Block(cx, DELAYS[i]));
    let last = performance.now();
    let raf = 0;

    const frame = (t: number) => {
      const dt = Math.min((t - last) / 1000, 1 / 30); // 限幅防止切后台飞穿
      last = t;
      blocks.forEach((b) => b.update(dt));

      blocks.forEach((b, i) => {
        const rect = rectRefs.current[i];
        const shadow = shadowRefs.current[i];
        if (!rect || !shadow) return;

        const bottom = b.y + DOT_SIZE;
        const sy = 1 - b.squash; // 纵向压扁
        const sx = 1 + b.squash * 0.7; // 横向变宽（近似体积守恒）
        const w = DOT_SIZE * sx;
        const h = DOT_SIZE * sy;

        // 锚点 = 底部中心，保证挤压时贴地变形
        rect.setAttribute("x", String(b.cx - w / 2));
        rect.setAttribute("y", String(bottom - h));
        rect.setAttribute("width", String(w));
        rect.setAttribute("height", String(h));

        // 影子：越高越小越淡
        const hgt = GROUND_Y - bottom;
        const tt = clamp(hgt / 400, 0, 1);
        const sw = DOT_SIZE * (1.15 - 0.55 * tt);
        shadow.setAttribute("rx", String(sw / 2));
        shadow.setAttribute("ry", String(sw / 9));
        shadow.setAttribute("opacity", String(0.25 * (1 - tt * 0.8)));
      });

      raf = requestAnimationFrame(frame);
    };

    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, []);

  const svg = (
    <svg
      width={size}
      height={size * (140 / 164)}
      viewBox="0 0 164 140"
      className={inline ? className : "equalizer-loader"}
      role="status"
      aria-label={label ?? "加载中"}
      // 强调色：跟随 --primary（用户自定义 accent / 明暗主题自动联动）
      style={{
        color: "var(--primary)",
        // 极淡的同色辉光，提升质感而不喧宾夺主
        filter:
          "drop-shadow(0 0 6px color-mix(in srgb, currentColor 45%, transparent))",
      }}
    >
      {CENTERS.map((cx, i) => (
        <g key={i}>
          {/* 地面影子：随高度变小变淡 */}
          <ellipse
            ref={(el) => {
              shadowRefs.current[i] = el;
            }}
            cx={cx}
            cy={GROUND_Y + 8}
            rx={(DOT_SIZE * 1.15) / 2}
            ry={(DOT_SIZE * 1.15) / 9}
            fill="currentColor"
            opacity="0.25"
          />
          {/* 方块：强调色填充 + 描边（边框跟随挤压同步变化） */}
          <rect
            ref={(el) => {
              rectRefs.current[i] = el;
            }}
            x={cx - DOT_SIZE / 2}
            y={GROUND_Y - DOT_SIZE}
            width={DOT_SIZE}
            height={DOT_SIZE}
            rx={DOT_RX}
            fill="currentColor"
            stroke="currentColor"
            strokeWidth="2"
            vectorEffect="non-scaling-stroke"
          />
        </g>
      ))}
    </svg>
  );

  // 内联模式：直接返回 svg，由调用方控制布局（如按钮内的 margin）
  if (inline) return svg;

  return (
    <div className={`flex flex-col items-center gap-3 ${className ?? ""}`}>
      {svg}
      {label ? (
        <p className="text-sm text-muted-foreground">{label}</p>
      ) : null}
    </div>
  );
}
