/**
 * 窗口控制按钮组（最小化 / 最大化-还原 / 关闭）
 *
 * 移植自 qraft src/components/ui/window-controls.tsx，适配 orbit：
 * - 无 i18n，文案用中文字面量（qraft zh-CN：最小化/最大化/还原/关闭）
 * - orbit 仅面向 Windows（tauri.conf.json decorations:false），不做
 *   macOS 分支；jsdom/浏览器 mock 下 getCurrentWindow() 降级为空操作
 * - 命中区 46×32px（Win11 规范），hover 仅背景 alpha 提升，无缩放抖动
 * - 最大化状态时图标切换为「还原」（前层方块 + 后层 L 形描边，
 *   后层被前层遮挡的部分不绘制，避免交叉线形成"链环"观感）
 *
 * 图标采用内联 SVG，对齐 Win11 原生标题栏规格：
 * 16×16 viewBox 按 16px（size-4）渲染，内容统一落在 10×10 居中盒子，
 * 描边统一 1.25，保证三个图标视觉大小、粗细、端点风格完全一致。
 * 样式见 index.css 的 .window-control 选择器。
 */

import { type JSX } from "react";

import {
  closeMainWindow,
  minimizeWindow,
  toggleMaximizeWindow,
  useMaximized,
} from "@/lib/window";

const ICON_SIZE_CLASS = "size-4";
const STROKE_WIDTH = 1.25;
/**
 * 方框图标的路径圆角半径。
 * SVG 描边以路径为中心线，可见圆角为：
 * - 外侧 = rx + strokeWidth/2 = 1.625 + 0.625 = 2.25px
 * - 内侧 = rx - strokeWidth/2 = 1px
 * 内外均为明确圆角，与 Win11 窗口圆角（8px）的曲率观感一致，
 * 避免小 rx 时"外圆内尖"的不协调。
 */
const CORNER_RADIUS = 1.625;
const STROKE_PROPS = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: STROKE_WIDTH,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

function MinimizeIcon(): JSX.Element {
  return (
    <svg viewBox="0 0 16 16" className={ICON_SIZE_CLASS} aria-hidden {...STROKE_PROPS}>
      <line x1="3" y1="8" x2="13" y2="8" />
    </svg>
  );
}

function MaximizeIcon(): JSX.Element {
  return (
    <svg viewBox="0 0 16 16" className={ICON_SIZE_CLASS} aria-hidden {...STROKE_PROPS}>
      {/* SVG 描边以路径为中心：外侧圆角 = rx + strokeWidth/2 ≈ 2.25px，
       * 内侧圆角 = rx - strokeWidth/2 = 1px，与 Win11 窗口圆角曲率观感一致 */}
      <rect x="3" y="3" width="10" height="10" rx={CORNER_RADIUS} />
    </svg>
  );
}

function RestoreIcon(): JSX.Element {
  // 后层方块可见描边（左上角一段 + 右侧 L 形），三个可见拐角
  // 用与 CORNER_RADIUS 一致的圆弧过渡，使内外圆角与前层方块完全相同；
  // 若直接用直角折线，round join 只能提供 0.625px 外圆角，与前层 2.25px 不一致。
  const r = CORNER_RADIUS;
  const backPath =
    `M6 6 ` +
    `L6 ${3 + r} ` +
    `A${r} ${r} 0 0 1 ${6 + r} 3 ` +
    `L${13 - r} 3 ` +
    `A${r} ${r} 0 0 1 13 ${3 + r} ` +
    `L13 ${10 - r} ` +
    `A${r} ${r} 0 0 1 ${13 - r} 10 ` +
    `L10 10`;
  return (
    <svg viewBox="0 0 16 16" className={ICON_SIZE_CLASS} aria-hidden {...STROKE_PROPS}>
      {/* 后层方块：仅绘制未被前层遮挡的可见描边 */}
      <path d={backPath} />
      {/* 前层方块：左下，完整绘制，圆角与最大化方框一致 */}
      <rect x="3" y="6" width="7" height="7" rx={CORNER_RADIUS} />
    </svg>
  );
}

function CloseIcon(): JSX.Element {
  return (
    <svg viewBox="0 0 16 16" className={ICON_SIZE_CLASS} aria-hidden {...STROKE_PROPS}>
      <line x1="3" y1="3" x2="13" y2="13" />
      <line x1="13" y1="3" x2="3" y2="13" />
    </svg>
  );
}

export function WindowControls(): JSX.Element {
  const maximized = useMaximized();

  return (
    <div className="window-controls" data-testid="window-controls">
      <button
        type="button"
        className="window-control"
        aria-label="最小化"
        title="最小化"
        onClick={() => void minimizeWindow()}
      >
        <MinimizeIcon />
      </button>
      <button
        type="button"
        className="window-control"
        aria-label={maximized ? "还原" : "最大化"}
        title={maximized ? "还原" : "最大化"}
        onClick={() => void toggleMaximizeWindow()}
        data-testid="window-toggle-maximize"
      >
        {maximized ? <RestoreIcon /> : <MaximizeIcon />}
      </button>
      <button
        type="button"
        className="window-control window-control--close"
        aria-label="关闭"
        title="关闭"
        onClick={() => void closeMainWindow()}
      >
        <CloseIcon />
      </button>
    </div>
  );
}
