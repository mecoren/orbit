import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { pickSnapIndex, springStep } from "./bottom-sheet-logic";

interface BottomSheetProps {
  open: boolean;
  onClose: () => void;
  /** 可选标题条：与把手同处拖拽热区（05 §4.3 选择弹层头部规格） */
  title?: string;
  /**
   * 归一化 snap 点（相对视口高），默认表单抽屉 [.35, .65, 1]（05 §五：snap .65/.35/1.0）。
   * 关闭位（0 档）自动并入档位梯；打开动画目标取最大非满档（默认即 .65）。
   */
  snapPoints?: number[];
  children: ReactNode;
}

/** scrollSpring(1,170,24)（05 §五），质量归一为 1 */
const SPRING = { stiffness: 170, damping: 24 };
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/**
 * 移动端 snap 弹簧底部抽屉（05 §四/§五）。
 *
 * 几何约定：面板高度 = 视口高，锚定在屏幕下方之外（bottom = -maxHeight），
 * translate 0 = 贴底关闭位，负值向上抬起；snap f 对应 translate = -f·maxHeight，
 * 纯平移无缩放。收敛判据 |v|<8 && |pos-target|<0.5；关闭动画到位后才触发 onClose。
 *
 * 拖拽热区分离：pointer 拖拽只绑在顶部把手区（把手 + 可选 title，touchAction:none）
 * 与遮罩层；内容区保持原生滚动，不设 touchAction:none，保证表单内容可滚动。
 * move 时采样最近 (t, y) 样本，up 时以末段位移/时间差得 px/s 交给 pickSnapIndex
 * （drawerVelocity=500px/s）。遮罩点按（位移 <5px）视为点击关闭。
 *
 * 键盘避让（05 §五，独立订阅）：visualViewport resize/scroll → 面板内容容器动态
 * paddingBottom = max(0, innerHeight - vv.height - vv.offsetTop)，卸载时清理监听。
 */
export function BottomSheet({ open, onClose, title, snapPoints = [0.35, 0.65, 1], children }: BottomSheetProps) {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  const posRef = useRef(0);
  const velRef = useRef(0);
  const rafRef = useRef(0);
  const dragRef = useRef<{ startY: number; startPos: number; active: boolean } | null>(null);
  const samplesRef = useRef<{ t: number; y: number }[]>([]);
  const draggedRef = useRef(false);
  const [maxHeight, setMaxHeight] = useState(() => (typeof window === "undefined" ? 0 : window.innerHeight));

  // 打开动画目标 = 最大非满档（默认 .65；单档如 [0.55] 即该值本身）
  const nonFull = snapPoints.filter((f) => f < 1);
  const initialFraction = nonFull.length ? nonFull[nonFull.length - 1] : snapPoints[snapPoints.length - 1];
  const initialFractionRef = useRef(initialFraction);
  initialFractionRef.current = initialFraction;

  const animateTo = useCallback(
    (target: number) => {
      cancelAnimationFrame(rafRef.current);
      velRef.current = 0;
      const loop = () => {
        const [p, v] = springStep(posRef.current, velRef.current, target, SPRING.stiffness, SPRING.damping, 1 / 60);
        posRef.current = p;
        velRef.current = v;
        if (panelRef.current) panelRef.current.style.transform = `translate3d(0,${p}px,0)`; // 纯平移
        if (Math.abs(v) < 8 && Math.abs(p - target) < 0.5) {
          posRef.current = target;
          velRef.current = 0;
          if (panelRef.current) panelRef.current.style.transform = `translate3d(0,${target}px,0)`;
          if (target === 0) onClose(); // 关闭动画到位后再卸载
          return;
        }
        rafRef.current = requestAnimationFrame(loop);
      };
      rafRef.current = requestAnimationFrame(loop);
    },
    [onClose],
  );
  const animateToRef = useRef(animateTo);
  animateToRef.current = animateTo;

  useEffect(() => {
    if (!open) return;
    setMaxHeight(window.innerHeight);
    animateToRef.current(-window.innerHeight * initialFractionRef.current); // 定位 initial snap
    return () => cancelAnimationFrame(rafRef.current);
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const vv = window.visualViewport;
    if (!vv) return;
    const apply = () => {
      const inset = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
      if (contentRef.current) contentRef.current.style.paddingBottom = `${inset}px`;
    };
    apply();
    vv.addEventListener("resize", apply);
    vv.addEventListener("scroll", apply);
    return () => {
      vv.removeEventListener("resize", apply);
      vv.removeEventListener("scroll", apply);
    };
  }, [open]);

  const beginDrag = (e: React.PointerEvent<HTMLElement>) => {
    if (!e.isPrimary) return;
    cancelAnimationFrame(rafRef.current);
    dragRef.current = { startY: e.clientY, startPos: posRef.current, active: true };
    draggedRef.current = false;
    samplesRef.current = [{ t: e.timeStamp, y: e.clientY }];
    e.currentTarget.setPointerCapture(e.pointerId);
  };

  const moveDrag = (e: React.PointerEvent<HTMLElement>) => {
    const d = dragRef.current;
    if (!d?.active) return;
    const next = clamp(d.startPos + (e.clientY - d.startY), -maxHeight, 0);
    posRef.current = next;
    if (panelRef.current) panelRef.current.style.transform = `translate3d(0,${next}px,0)`;
    if (Math.abs(e.clientY - d.startY) > 5) draggedRef.current = true;
    const samples = samplesRef.current;
    samples.push({ t: e.timeStamp, y: e.clientY });
    if (samples.length > 8) samples.shift();
  };

  const endDrag = (e: React.PointerEvent<HTMLElement>) => {
    const d = dragRef.current;
    if (!d?.active) return;
    d.active = false;
    try {
      e.currentTarget.releasePointerCapture(e.pointerId);
    } catch {
      // 指针已释放时忽略
    }
    if (!draggedRef.current) {
      animateToRef.current(0); // 遮罩点按 → 关闭
      return;
    }
    const samples = samplesRef.current;
    let velocity = 0;
    const first = samples[0];
    const last = samples[samples.length - 1];
    if (first && last && last.t > first.t) velocity = ((last.y - first.y) / (last.t - first.t)) * 1000;
    const snapsH = [0, ...snapPoints.map((f) => f * maxHeight)]; // 高度空间：0 档 = 关闭位
    const idx = pickSnapIndex(-posRef.current, velocity, snapsH);
    animateToRef.current(-snapsH[idx]);
  };

  if (!open) return null;
  const dragHandlers = {
    onPointerDown: beginDrag,
    onPointerMove: moveDrag,
    onPointerUp: endDrag,
    onPointerCancel: endDrag,
  };
  return (
    <div className="fixed inset-0 z-50">
      {/* 纯平移无缩放遮罩（05 §五）：拖拽热区之一，点按关闭 */}
      <div className="absolute inset-0 bg-black/30" style={{ touchAction: "none" }} {...dragHandlers} />
      <div
        ref={panelRef}
        className="absolute inset-x-0 flex flex-col overflow-hidden rounded-t-[20px]"
        style={{
          height: maxHeight,
          bottom: -maxHeight,
          transform: `translate3d(0,${posRef.current}px,0)`,
          background: "var(--m-surface)",
          willChange: "transform",
        }}
      >
        {/* 拖拽热区：handle 40×4/r2/@40% + 可选 title，约 48px，仅此区域禁用原生滚动 */}
        <div className="shrink-0 select-none" style={{ touchAction: "none", cursor: "grab" }} {...dragHandlers}>
          <div className="mx-auto mt-2 h-1 w-10 rounded-sm bg-[var(--m-text)]/40" />
          {title ? <div className="px-4 pb-2 pt-2 text-base font-semibold text-[var(--m-text)]">{title}</div> : null}
        </div>
        {/* 内容区保持原生滚动 + 键盘避让动态 paddingBottom */}
        <div ref={contentRef} className="min-h-0 flex-1 overflow-y-auto overscroll-contain">
          {children}
        </div>
      </div>
    </div>
  );
}
