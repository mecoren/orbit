import { useEffect, useRef } from "react";

/**
 * EqSpinner —— 三球错峰弹跳加载指示器（05 §三/§五 EqSpinner 物理参数，移植 wait-home bounce-blocks）：
 * 重力 2600 px/s²、restitution 0.62、挤压弹簧 170/14、三球延迟 0/.65/1.3s。
 * rAF 驱动、transform 直写，不触发 React 重渲；卸载时 cancelAnimationFrame。
 */
const GRAVITY = 2600;
const RESTITUTION = 0.62;
const SQUASH_STIFFNESS = 170;
const SQUASH_DAMPING = 14;
/** 三球入场延迟（ms）：0 / .65s / 1.3s */
const DELAYS = [0, 650, 1300];

interface BallState {
  y: number;
  vy: number;
  squash: number;
  squashV: number;
}

export function EqSpinner({ size = 48, color = "#4E8CFF" }: { size?: number; color?: string }) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const container = ref.current;
    if (!container) return;
    const balls = Array.from(container.children) as HTMLElement[];
    const dropH = size * 0.9;
    const state: BallState[] = balls.map(() => ({ y: -dropH, vy: 0, squash: 1, squashV: 0 }));
    const start = performance.now();
    let raf = 0;
    let last = performance.now();
    const tick = (now: number) => {
      const dt = Math.min((now - last) / 1000, 0.032);
      last = now;
      balls.forEach((ball, i) => {
        const s = state[i];
        const active = now - start >= DELAYS[i]; // 三球延迟入场
        if (active) {
          s.vy += GRAVITY * dt;
          s.y += s.vy * dt * (size / 48); // 尺寸缩放位移
          if (s.y >= 0) {
            // 触地
            s.y = 0;
            s.vy = Math.abs(s.vy) > 40 ? -Math.abs(s.vy) * RESTITUTION : 0;
            // 经验标定，观感对齐蓝本：挤压冲量随帧注入（非严格物理量纲）
            s.squashV -= 2600 * dt;
          }
          // 挤压弹簧回弹
          const force = -SQUASH_STIFFNESS * (s.squash - 1);
          s.squashV += force * dt;
          s.squashV -= SQUASH_DAMPING * s.squashV * dt;
          // 经验标定，观感对齐蓝本：×10 增益补偿小步长下的弹簧响应
          s.squash += s.squashV * dt * 10;
        }
        ball.style.transform = `translateY(${s.y}px) scale(${2 - s.squash}, ${s.squash})`;
        ball.style.opacity = active ? "1" : "0";
      });
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [size]);

  const ballSize = Math.max(size * 0.16, 4);
  return (
    <div ref={ref} className="relative overflow-hidden" style={{ width: size, height: size }}>
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          className="absolute rounded-full"
          style={{
            width: ballSize * 2,
            height: ballSize * 2,
            left: `${8 + i * 34}%`,
            top: size - ballSize * 2,
            background: color,
            transformOrigin: "center bottom",
            willChange: "transform",
          }}
        />
      ))}
    </div>
  );
}
