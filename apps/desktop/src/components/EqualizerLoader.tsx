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
 * 加载动画：3 个圆角方块波浪式连跳（物理模拟）。
 *
 * - 三个方块按相位错开、永不停顿地循环起跳（落地瞬间立即再次满弹起跳）
 * - 重力减速至最高点后回落，触地带果冻般的挤压回弹
 * - 撞击速度越大，落地挤压越扁（体积守恒：变宽的同时变矮）
 * - 空中高速移动时轻微拉伸，快出慢收，更有弹性
 * - 全程无静止帧，任何时刻都有方块在运动，观感灵动流畅
 *
 * 颜色取自主题强调色 `--primary`（受用户自定义 accent 与明暗主题自动影响），
 * 因此无需在 JS 中读取颜色，仅通过 `currentColor` 跟随 CSS 变量即可。
 */

// —— 物理常量 ——
const GRAVITY = 2800; // 重力加速度 px/s²（干脆利落，不拖沓）
const STIFFNESS = 220; // 挤压回弹弹簧刚度（恢复更快，更 Q 弹）
const DAMPING = 12; // 挤压回弹阻尼（低阻尼保留一点果冻余震）
const AIR_STRETCH = 0.14; // 空中随速度拉伸的最大比例
// 起跳初速度（向上，px/s）：v²=2gh → 700²/(2×2800)=87.5px 高
const JUMP_VELOCITY = 700;

// 方块边长（逻辑 px）与地板位置（逻辑 y）
const DOT_SIZE = 31;
const GROUND_Y = 121;
// 方块圆角半径
const DOT_RX = 10;

// 3 个方块的圆心 x 与起跳相位（s）。
// 单块腾空周期 ≈ 2×700/2800 = 0.5s，相位取 0 / 1/6 / 1/3 周期，
// 三个方块此起彼伏形成从左到右的连续波浪。
const CENTERS = [23.5, 81.5, 139.5];
const DELAYS = [0, 0.5 / 6, 0.5 / 3];

const clamp = (v: number, min: number, max: number) =>
  Math.min(max, Math.max(min, v));

/** 单个方块的物理状态：相位等待 → 起跳 → 重力回落 → 落地挤压 → 立即再次起跳（永续循环） */
class Block {
  cx: number;
  wait: number; // 剩余的首次起跳延迟（s）
  y = GROUND_Y - DOT_SIZE; // 顶边 y（初始贴地）
  vy = 0; // 垂直速度
  squash = 0; // >0 压扁，<0 拉长
  squashVel = 0;

  constructor(cx: number, delay: number) {
    this.cx = cx;
    this.wait = delay;
  }

  update(dt: number) {
    if (this.wait > 0) {
      // 相位等待：到点起跳
      this.wait -= dt;
      if (this.wait > 0) return;
      dt = -this.wait;
      this.wait = 0;
      this.vy = -JUMP_VELOCITY;
    }

    // 子步进积分：低帧率下物理依旧稳定，不会穿地或跳变
    const steps = Math.max(1, Math.ceil(dt / (1 / 120)));
    const h = dt / steps;
    for (let s = 0; s < steps; s++) {
      // 重力 + 位移
      this.vy += GRAVITY * h;
      this.y += this.vy * h;

      // 地面碰撞：撞击越猛挤压越扁，落地瞬间立即满弹起跳，节奏永不停顿
      if (this.y + DOT_SIZE >= GROUND_Y && this.vy > 0) {
        this.y = GROUND_Y - DOT_SIZE;
        this.squash = clamp(this.vy / 2400, 0.12, 0.42);
        this.squashVel = 0;
        this.vy = -JUMP_VELOCITY;
      }

      // 挤压量的弹簧恢复（果冻般回弹）
      this.squashVel += (-STIFFNESS * this.squash - DAMPING * this.squashVel) * h;
      this.squash += this.squashVel * h;
    }
  }
}

export function EqualizerLoader({
  size = 160,
  label,
  inline = false,
  className,
}: EqualizerLoaderProps) {
  const rectRefs = useRef<(SVGRectElement | null)[]>([]);

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
        if (!rect) return;

        // 空中高速移动时轻微拉伸（快出慢收），落地挤压由弹簧接管
        const stretch =
          clamp(Math.abs(b.vy) / JUMP_VELOCITY, 0, 1) * AIR_STRETCH;
        const total = b.squash - stretch;
        const sy = 1 - total; // 空中拉长，落地压扁
        const sx = 1 + total * 0.7; // 横向反向补偿（近似体积守恒）
        const w = DOT_SIZE * sx;
        const h = DOT_SIZE * sy;

        // 锚点 = 底部中心，保证挤压时贴地变形
        const bottom = b.y + DOT_SIZE;
        rect.setAttribute("x", String(b.cx - w / 2));
        rect.setAttribute("y", String(bottom - h));
        rect.setAttribute("width", String(w));
        rect.setAttribute("height", String(h));
      });

      raf = requestAnimationFrame(frame);
    };

    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, []);

  const svg = (
    <svg
      width={size}
      height={size * (128 / 164)}
      viewBox="0 0 164 128"
      className={inline ? className : "equalizer-loader"}
      role="status"
      aria-label={label ?? "加载中"}
      // 强调色：跟随 --primary（用户自定义 accent / 明暗主题自动联动）。
      // 注意：不要在此处加 CSS filter（drop-shadow 等），滤镜会强制每帧对整块
      // SVG 重新光栅化，是动画掉帧的主要元凶。
      style={{ color: "var(--primary)" }}
    >
      {CENTERS.map((cx, i) => (
        <g key={i}>
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
