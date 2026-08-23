/**
 * 设计令牌（Design Tokens）—— 桌面端颜色主题 Layer 1
 *
 * 职责：
 * - 定义 ColorPalette 语义化接口（custom 色板派生返回类型）
 * - 定义 PaletteMeta 元数据接口（预设色板：仅 id/mode/accent + 预览色）
 * - 提供 5 套预设色板元数据（生效色值由 CSS [data-palette="..."] 块注入，TS 不再重复）
 * - 提供 deriveCustomPalette(accent) 工厂：由 accent 色派生 custom 色板的 inline override 字段
 *
 * 单一来源说明：
 * - 预设色板：CSS 为单一来源（index.css 的 [data-palette="..."] 块），TS 仅保留元数据 + 预览色
 * - 自定义色板：TS 派生 6 个 inline override 字段（含 color-mix 派生，依赖运行时 accent）
 * - previewSwatches 是"展示用元数据"（非生效用色），供 theme-section 预览条渲染
 *
 * 设计说明：
 * - 色彩空间使用 OKLCH（感知均匀，Tauri WebView2 Chromium 111+ 支持）
 * - 桌面端独立设计色板，不复用移动端 color_theme.dart 的 7 套预设
 */

export type PaletteMode = 'dark' | 'light';

/**
 * 色板语义化字段（custom 色板派生返回类型）
 *
 * 每个字段对应一个 CSS 变量（--background / --foreground 等）。
 * 预设色板由 CSS [data-palette="..."] 块注入，TS 不再持有这些值。
 * 仅 custom 色板通过 deriveCustomPalette 派生 6 个 inline override 字段。
 */
export interface ColorPalette {
  id: string;
  displayName: string;
  mode: PaletteMode;
  accent: string;
  background: string;
  foreground: string;
  card: string;
  cardForeground: string;
  popover: string;
  popoverForeground: string;
  primary: string;
  primaryForeground: string;
  secondary: string;
  secondaryForeground: string;
  muted: string;
  mutedForeground: string;
  /** hover/accent 背景（对应 shadcn/ui 的 --accent） */
  accentBg: string;
  accentFg: string;
  destructive: string;
  border: string;
  input: string;
  ring: string;
  sidebar: string;
  sidebarForeground: string;
  sidebarPrimary: string;
  sidebarPrimaryForeground: string;
  sidebarAccent: string;
  sidebarAccentForeground: string;
  sidebarBorder: string;
  sidebarRing: string;
}

/**
 * 预设色板元数据（不含生效色值）
 *
 * 生效色值由 CSS [data-palette="..."] 块注入，TS 仅保留：
 * - id/displayName/mode/accent：供 UI 列表渲染与逻辑判断
 * - previewSwatches：[accent, background] 展示用预览色（非生效用色）
 */
export interface PaletteMeta {
  id: string;
  displayName: string;
  mode: PaletteMode;
  accent: string;
  /** 预览色 [accent, background]，仅供 theme-section 预览条展示 */
  previewSwatches: [string, string];
}

// ============================================================
// 5 套预设色板元数据（4 深色 + 1 亮色）
// 生效色值见 index.css 的 [data-palette="..."] 块
// ============================================================

/** 黑曜石 - 默认深色（VS Code Dark+ 风格，蓝调） */
const obsidian: PaletteMeta = {
  id: 'obsidian',
  displayName: '黑曜石',
  mode: 'dark',
  accent: 'oklch(0.62 0.19 264)',
  previewSwatches: ['oklch(0.62 0.19 264)', 'oklch(0.16 0.01 264)'],
};

/** 深海 - 青蓝调 */
const deepSea: PaletteMeta = {
  id: 'deep-sea',
  displayName: '深海',
  mode: 'dark',
  accent: 'oklch(0.62 0.16 220)',
  previewSwatches: ['oklch(0.62 0.16 220)', 'oklch(0.16 0.01 220)'],
};

/** 暮光 - 橙红暖调 */
const twilight: PaletteMeta = {
  id: 'twilight',
  displayName: '暮光',
  mode: 'dark',
  accent: 'oklch(0.62 0.20 25)',
  previewSwatches: ['oklch(0.62 0.20 25)', 'oklch(0.16 0.01 25)'],
};

/** 翡翠夜 - 翠绿护眼 */
const emeraldNight: PaletteMeta = {
  id: 'emerald-night',
  displayName: '翡翠夜',
  mode: 'dark',
  accent: 'oklch(0.62 0.16 162)',
  previewSwatches: ['oklch(0.62 0.16 162)', 'oklch(0.16 0.01 162)'],
};

/** 日光 - 亮色模式默认 */
const daylight: PaletteMeta = {
  id: 'daylight',
  displayName: '日光',
  mode: 'light',
  accent: 'oklch(0.55 0.22 264)',
  previewSwatches: ['oklch(0.55 0.22 264)', 'oklch(0.99 0.005 264)'],
};

/** 所有预设色板元数据（只读常量） */
export const PRESET_PALETTES: readonly PaletteMeta[] = [
  obsidian,
  deepSea,
  twilight,
  emeraldNight,
  daylight,
] as const;

export const DEFAULT_PALETTE_ID = 'obsidian';

/**
 * 由 accent 色派生自定义色板
 *
 * 策略：固定深色基底 + accent 派生关键交互色（primary/ring/sidebar-primary 等），
 * 避免用户手动配置 25+ 字段。
 *
 * 派生规则：
 * - primary = accent（直接使用）
 * - ring = accent（直接使用）
 * - sidebarPrimary = accent
 * - sidebarAccent = color-mix(accent 20% transparent)（半透明高亮）
 * - accentBg = color-mix(accent 15% transparent)（hover 背景）
 * - 其余字段使用与 obsidian 一致的深色基底
 *
 * 注意：返回的字符串中包含 color-mix() CSS 函数，
 * 由 color-theme.ts 注入到 <html> 的 inline style 中生效。
 */
export function deriveCustomPalette(
  accent: string,
  mode: PaletteMode = 'dark',
): ColorPalette {
  const isLight = mode === 'light';
  return {
    id: 'custom',
    displayName: '自定义',
    mode,
    accent,
    background: isLight ? 'oklch(0.99 0.005 264)' : 'oklch(0.16 0 0)',
    foreground: isLight ? 'oklch(0.18 0.01 264)' : 'oklch(0.96 0 0)',
    card: isLight ? 'oklch(1 0 0)' : 'oklch(0.21 0 0)',
    cardForeground: isLight ? 'oklch(0.18 0.01 264)' : 'oklch(0.96 0 0)',
    popover: isLight ? 'oklch(1 0 0)' : 'oklch(0.21 0 0)',
    popoverForeground: isLight ? 'oklch(0.18 0.01 264)' : 'oklch(0.96 0 0)',
    primary: accent,
    primaryForeground: 'oklch(0.99 0 0)',
    secondary: isLight ? 'oklch(0.96 0.01 264)' : 'oklch(0.27 0 0)',
    secondaryForeground: isLight ? 'oklch(0.20 0.01 264)' : 'oklch(0.96 0 0)',
    muted: isLight ? 'oklch(0.96 0.01 264)' : 'oklch(0.24 0 0)',
    mutedForeground: isLight ? 'oklch(0.52 0.01 264)' : 'oklch(0.68 0 0)',
    // 使用 color-mix 派生半透明高亮色
    accentBg: `color-mix(in srgb, ${accent} ${isLight ? "12%" : "15%"}, transparent)`,
    accentFg: isLight ? 'oklch(0.18 0.01 264)' : 'oklch(0.96 0 0)',
    destructive: isLight
      ? 'oklch(0.577 0.245 27.325)'
      : 'oklch(0.704 0.191 22.216)',
    border: isLight ? 'oklch(0.92 0.005 264)' : 'oklch(1 0 0 / 10%)',
    input: isLight ? 'oklch(0.92 0.005 264)' : 'oklch(1 0 0 / 15%)',
    ring: accent,
    sidebar: isLight ? 'oklch(0.97 0.005 264)' : 'oklch(0.18 0 0)',
    sidebarForeground: isLight ? 'oklch(0.18 0.01 264)' : 'oklch(0.96 0 0)',
    sidebarPrimary: accent,
    sidebarPrimaryForeground: 'oklch(0.99 0 0)',
    sidebarAccent: `color-mix(in srgb, ${accent} ${isLight ? "16%" : "20%"}, transparent)`,
    sidebarAccentForeground: isLight ? 'oklch(0.18 0.01 264)' : 'oklch(0.96 0 0)',
    sidebarBorder: isLight ? 'oklch(0.92 0.005 264)' : 'oklch(1 0 0 / 10%)',
    sidebarRing: accent,
  };
}

/**
 * 根据 ID 查找色板
 *
 * - id === 'custom' 且提供 customAccent：返回派生的自定义色板（ColorPalette）
 * - id 为预设之一：返回对应预设元数据（PaletteMeta）
 * - 找不到：回退到默认 obsidian
 */
export function getPaletteById(
  id: string,
  customAccent?: string | null,
): PaletteMeta | ColorPalette {
  if (id === 'custom' && customAccent) {
    return deriveCustomPalette(customAccent);
  }
  return PRESET_PALETTES.find((p) => p.id === id) ?? PRESET_PALETTES[0];
}

// ============================================================
// 动效时长 Token
// ============================================================

/** 动效时长语义档位 */
export interface DurationToken {
  /** Token 名（供 UI 列表渲染） */
  name: string;
  /** CSS 变量名（不含 -- 前缀） */
  cssVar: string;
  /** 时长值（毫秒） */
  ms: number;
  /** Tailwind 类名后缀（duration-xxx 中的 xxx） */
  tailwindSuffix: string;
  /** 语义说明 */
  description: string;
}

/** 4 档动效时长 token */
export const DURATION_TOKENS: readonly DurationToken[] = [
  {
    name: 'instant',
    cssVar: 'duration-instant',
    ms: 100,
    tailwindSuffix: 'instant',
    description: '即时反馈（按下/松开、右键菜单）',
  },
  {
    name: 'fast',
    cssVar: 'duration-fast',
    ms: 150,
    tailwindSuffix: 'fast',
    description: '快速过渡（Tooltip、hover 色变）',
  },
  {
    name: 'base',
    cssVar: 'duration-base',
    ms: 200,
    tailwindSuffix: 'base',
    description: '标准动画（Dialog/Popover/Select 等核心弹窗）',
  },
  {
    name: 'slow',
    cssVar: 'duration-slow',
    ms: 300,
    tailwindSuffix: 'slow',
    description: '慢速动画（Sheet 侧滑/Accordion/Switch）',
  },
] as const;

/** 按 token 名查找时长（毫秒） */
export function getDurationMs(name: 'instant' | 'fast' | 'base' | 'slow'): number {
  const token = DURATION_TOKENS.find((t) => t.name === name);
  return token?.ms ?? 200;
}
