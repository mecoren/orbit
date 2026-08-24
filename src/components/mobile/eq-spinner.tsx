import { useEffect, useRef } from "react";
import { DELAYS, DOT_SIZE, GROUND_Y, createBlock, stepBlock } from "./eq-spinner-physics";

/**
 * EqSpinner —— 三球错峰弹跳加载指示器（05 §五：移植 web 版 bounce-blocks 物理模型）。
 * 物理常量与状态机在 eq-spinner-physics.ts（纯函数，含 vitest 数值回归）；
 * 本组件只做 rAF 调度与 transform 直写，零 React 重渲，卸载时 cancelAnimationFrame。
 *
 * 渲染坐标 = 逻辑坐标 × (size / GROUND_Y)，各尺寸下节奏与观感完全一致。
 */
const kScale = (size: number) => size / GROUND_Y;

export function EqSpinner({ size = 48, color = "#4E8CFF" }: { size?: number; color?: string }) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const container = ref.current;
    if (!container) return;
    const balls = Array.from(container.children) as HTMLElement[];
    const blocks = DELAYS.map((d) => createBlock(d));
    const k = kScale(size);
    let raf = 0;
    let last = performance.now();
    const tick = (now: number) => {
      const dt = Math.min((now - last) / 1000, 0.032);
      last = now;
      balls.forEach((ball, i) => {
        const b = blocks[i];
        stepBlock(b, dt);
        // 相对贴地位置的位移（≤0 为腾空），逻辑 y → 像素
        const groundTop = GROUND_Y - DOT_SIZE;
        const dy = (b.y - groundTop) * k;
        ball.style.transform = `translateY(${dy}px) scale(${1 + b.squash}, ${1 - b.squash})`;
        ball.style.opacity = b.active || b.cycElapsed >= b.delay ? "1" : "0";
      });
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [size]);

  // 球径 = 31/121 × 容器高；三球水平均分（i*34% 左缘对齐，右缘不越界）
  const ballSize = Math.round(DOT_SIZE * kScale(size));
  return (
    <div ref={ref} role="status" aria-label="加载中" className="relative overflow-hidden" style={{ width: size, height: size }}>
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          className="absolute rounded-full"
          style={{
            width: ballSize,
            height: ballSize,
            left: `${8 + i * 30}%`,
            top: size - ballSize,
            background: color,
            opacity: 0,
            transformOrigin: "center bottom",
            willChange: "transform",
          }}
        />
      ))}
    </div>
  );
}
