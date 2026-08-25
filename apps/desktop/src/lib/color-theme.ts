/**
 * 颜色主题 Layer 3：无闪烁切换器
 *
 * 职责：
 * - applyPalette：将色板应用到 <html> 根元素（data-palette 属性 + .dark 类 + inline style）
 * - initColorThemeOnStartup：应用启动时在 React 渲染前应用色板，避免 FOUC
 * - setPalette：运行时切换色板并持久化
 *
 * 设计说明：
 * - 预设色板：仅设置 data-palette 属性，由 CSS [data-palette="..."] 选择器接管
 * - 自定义色板：设置 data-palette="custom" + 注入 inline style 覆盖关键变量
 * - system 模式：根据 prefers-color-scheme 选择 obsidian（深色）或 daylight（亮色）
 * - 同步切换 .dark 类以兼容依赖它的第三方组件（shadcn/ui Dialog/Sheet 等）
 */

import {
  PRESET_PALETTES,
  DEFAULT_PALETTE_ID,
  deriveCustomPalette,
  type PaletteMode,
} from "./design-tokens";

export type PaletteId =
  | 'obsidian'
  | 'deep-sea'
  | 'twilight'
  | 'emerald-night'
  | 'daylight'
  | 'custom'
  | 'system';

export const PALETTE_STORAGE_KEY = "color_palette";
export const CUSTOM_ACCENT_STORAGE_KEY = "custom_palette_accent";

export type ThemeMode = 'light' | 'dark' | 'system';

export const THEME_MODE_STORAGE_KEY = "theme_mode";

const THEME_MODE_TO_PALETTE: Record<ThemeMode, PaletteId> = {
  light: 'daylight',
  dark: 'obsidian',
  system: 'system',
};

// ============================================================
// 多自定义主题支持
// 每个自定义主题 = { id, name, accent }，切换时共用 data-palette="custom"
// + inline style 注入对应 accent，并用 CURRENT_CUSTOM_THEME_ID 记录激活项
// ============================================================

export interface CustomTheme {
  id: string;
  name: string;
  accent: string;
  /** 基底：true=浅色，false=深色 */
  mode: 'light' | 'dark';
}

export const CUSTOM_THEMES_KEY = "color_theme_custom_themes";
export const CURRENT_CUSTOM_THEME_ID_KEY = "color_theme_current_custom_id";

function readCustomThemes(): CustomTheme[] {
  try {
    const raw = localStorage.getItem(CUSTOM_THEMES_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) return parsed as CustomTheme[];
  } catch {
    /* 忽略损坏数据 */
  }
  return [];
}

function writeCustomThemes(themes: CustomTheme[]): void {
  localStorage.setItem(CUSTOM_THEMES_KEY, JSON.stringify(themes));
}

/** 读取全部自定义主题 */
export function getCustomThemes(): CustomTheme[] {
  return readCustomThemes();
}

/** 读取当前激活的自定义主题 ID（无则返回 null） */
export function getCurrentCustomThemeId(): string | null {
  return localStorage.getItem(CURRENT_CUSTOM_THEME_ID_KEY);
}

/** 读取当前激活的自定义主题（无则返回 null） */
export function getCurrentCustomTheme(): CustomTheme | null {
  const id = getCurrentCustomThemeId();
  if (!id) return null;
  return readCustomThemes().find((t) => t.id === id) ?? null;
}

/** 新增自定义主题（随机 id），返回新主题 */
export function addCustomTheme(
  name: string,
  accent: string,
  mode: 'light' | 'dark' = 'dark',
): CustomTheme {
  const theme: CustomTheme = {
    id: `custom-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
    name: name.trim() || "自定义主题",
    accent,
    mode,
  };
  const themes = readCustomThemes();
  themes.push(theme);
  writeCustomThemes(themes);
  return theme;
}

/** 重命名自定义主题 */
export function renameCustomTheme(id: string, name: string): void {
  const themes = readCustomThemes().map((t) =>
    t.id === id ? { ...t, name: name.trim() || t.name } : t,
  );
  writeCustomThemes(themes);
}

/** 修改自定义主题（名称 / 强调色 / 基底），按需更新当前激活项 */
export function updateCustomTheme(
  id: string,
  patch: Partial<Pick<CustomTheme, "name" | "accent" | "mode">>,
): void {
  const themes = readCustomThemes().map((t) =>
    t.id === id
      ? {
          ...t,
          ...(patch.name !== undefined ? { name: patch.name.trim() || t.name } : {}),
          ...(patch.accent !== undefined ? { accent: patch.accent } : {}),
          ...(patch.mode !== undefined ? { mode: patch.mode } : {}),
        }
      : t,
  );
  writeCustomThemes(themes);
  // 若修改的是当前激活主题，实时应用变更
  if (getCurrentCustomThemeId() === id) {
    const updated = themes.find((t) => t.id === id);
    if (updated) setPalette("custom", updated.accent);
  }
}

/** 删除自定义主题；若删除的是当前激活项，回退到默认预设 */
export function removeCustomTheme(id: string): void {
  const themes = readCustomThemes().filter((t) => t.id !== id);
  writeCustomThemes(themes);
  if (getCurrentCustomThemeId() === id) {
    localStorage.removeItem(CURRENT_CUSTOM_THEME_ID_KEY);
    // 回退到默认色板
    localStorage.setItem(PALETTE_STORAGE_KEY, 'system');
    applyPalette('system', null);
  }
}

/** 选择（激活）某个自定义主题：记录 id + 应用 accent */
export function selectCustomTheme(id: string): void {
  const theme = readCustomThemes().find((t) => t.id === id);
  if (!theme) return;
  localStorage.setItem(CURRENT_CUSTOM_THEME_ID_KEY, id);
  setPalette('custom', theme.accent);
}

/**
 * 从 localStorage 读取色板 ID
 *
 * 未设置或值非法时回退为 'system'（跟随系统主题）。
 */
export function getStoredPaletteId(): PaletteId {
  const stored = getStoredPaletteIdRaw();
  return stored ?? 'system';
}

/**
 * 读取原始存储的色板 ID（Fix-19）
 *
 * 与 {@link getStoredPaletteId} 的区别：用户从未显式选择过色板时返回 null
 * （而非回退值），供启动逻辑区分「显式选择了 system」与「从未选择」两种情况。
 * 值非法（localStorage 数据损坏）视为未设置。
 */
function getStoredPaletteIdRaw(): PaletteId | null {
  const VALID_PALETTE_IDS: readonly string[] = [
    'obsidian',
    'deep-sea',
    'twilight',
    'emerald-night',
    'daylight',
    'custom',
    'system',
  ];
  const stored = localStorage.getItem(PALETTE_STORAGE_KEY);
  return stored && (VALID_PALETTE_IDS as readonly string[]).includes(stored)
    ? (stored as PaletteId)
    : null;
}

/**
 * 从 localStorage 读取主题模式
 *
 * 未设置或值非法时回退为 'system'。
 */
export function getStoredThemeMode(): ThemeMode {
  const stored = localStorage.getItem(THEME_MODE_STORAGE_KEY) as ThemeMode | null;
  if (stored === 'light' || stored === 'dark' || stored === 'system') {
    return stored;
  }
  return 'system';
}

/**
 * 从 localStorage 读取自定义 accent 色
 *
 * 未设置时返回 null。
 */
export function getStoredCustomAccent(): string | null {
  return localStorage.getItem(CUSTOM_ACCENT_STORAGE_KEY);
}

/**
 * 将色板应用到 <html> 根元素
 *
 * 策略：
 * 1. 预设色板：设置 data-palette 属性，清除 inline style（生效色值由 CSS 注入）
 * 2. 自定义色板：设置 data-palette="custom" + 注入 inline style 覆盖关键变量
 * 3. 同步切换 .dark 类（深色色板添加，亮色移除）
 *
 * 注意：切换 data-palette 属性后，CSS [data-palette="..."] 选择器
 * 立即应用新的 CSS 变量值，Tailwind utility class 通过 var() 引用，
 * 整页颜色瞬时切换，无 React 重渲染。
 */
export function applyPalette(
  paletteId: PaletteId,
  customAccent?: string | null,
  customMode?: 'light' | 'dark',
): void {
  const root = document.documentElement;

  // 解析 system 模式为具体预设 ID
  let resolvedId: string = paletteId;
  if (paletteId === 'system') {
    const isDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    resolvedId = isDark ? 'obsidian' : 'daylight';
  }

  // 从预设元数据查找 mode；custom 路径单独派生
  const presetMeta = PRESET_PALETTES.find((p) => p.id === resolvedId);
  const isCustom = resolvedId === 'custom' && !!customAccent;

  let mode: PaletteMode;
  if (isCustom) {
    // 自定义色板：基底由 customMode 决定（亮色 / 深色）
    mode = customMode ?? 'dark';
  } else if (presetMeta) {
    mode = presetMeta.mode;
  } else {
    // 回退到默认 obsidian
    mode = 'dark';
    resolvedId = DEFAULT_PALETTE_ID;
  }

  root.setAttribute('data-palette', resolvedId);
  root.setAttribute('data-custom-mode', isCustom ? mode : 'dark');
  root.classList.toggle('dark', mode === 'dark');

  if (isCustom) {
    // 自定义色板：派生 6 个 inline override 覆盖 [data-palette="custom"] 默认值
    const palette = deriveCustomPalette(customAccent!, mode);
    root.style.setProperty('--primary', palette.primary);
    root.style.setProperty('--ring', palette.ring);
    root.style.setProperty('--sidebar-primary', palette.sidebarPrimary);
    root.style.setProperty('--sidebar-ring', palette.sidebarRing);
    root.style.setProperty('--accent', palette.accentBg);
    root.style.setProperty('--sidebar-accent', palette.sidebarAccent);
  } else {
    // 预设色板：清除 inline style，让 [data-palette="..."] 选择器接管
    root.style.removeProperty('--primary');
    root.style.removeProperty('--ring');
    root.style.removeProperty('--sidebar-primary');
    root.style.removeProperty('--sidebar-ring');
    root.style.removeProperty('--accent');
    root.style.removeProperty('--sidebar-accent');
  }
}

/**
 * 应用启动时初始化色板（无闪烁）
 *
 * 必须在 React 渲染前调用（main.tsx 入口处）。
 *
 * **Fix-19**：优先应用用户显式选择的色板（`setPalette` 写入的
 * `PALETTE_STORAGE_KEY`）。历史问题：启动只读 `THEME_MODE_STORAGE_KEY`
 * 并映射为默认色板（light→daylight / dark→obsidian / system→跟随系统），
 * 用户选择的 deep-sea/twilight/emerald-night/custom 重启后全部回退默认。
 * 两 key 语义：`PALETTE_STORAGE_KEY` 记录显式色板选择（更具体的意图），
 * `THEME_MODE_STORAGE_KEY` 仅在其不存在时作为旧数据回退。
 *
 * 若为 system 模式，注册 prefers-color-scheme 监听器实时切换。
 *
 * 返回清理函数（应用生命周期内通常不需要清理）。
 */
export function initColorThemeOnStartup(): () => void {
  const storedPalette = getStoredPaletteIdRaw();
  const mode = getStoredThemeMode();
  let paletteId: PaletteId = storedPalette ?? THEME_MODE_TO_PALETTE[mode];

  if (paletteId === 'custom') {
    const theme = getCurrentCustomTheme();
    if (theme) {
      // 自定义主题：accent + 基底 mode 一并还原
      applyPalette('custom', theme.accent, theme.mode);
    } else {
      // 自定义主题列表损坏/被清空：清理脏数据并回退到模式映射的预设
      localStorage.removeItem(PALETTE_STORAGE_KEY);
      localStorage.removeItem(CURRENT_CUSTOM_THEME_ID_KEY);
      paletteId = THEME_MODE_TO_PALETTE[mode];
      applyPalette(paletteId, null);
    }
  } else {
    applyPalette(paletteId, getStoredCustomAccent());
  }

  if (paletteId === 'system') {
    const mql = window.matchMedia("(prefers-color-scheme: dark)");
    const handler = () => applyPalette('system', getStoredCustomAccent());
    mql.addEventListener('change', handler);
    return () => mql.removeEventListener('change', handler);
  }

  return () => {};
}

/**
 * 运行时切换色板（无闪烁）
 *
 * 同时持久化到 localStorage。
 *
 * @param paletteId 目标色板 ID
 * @param customAccent 自定义 accent 色（仅 paletteId === 'custom' 时使用）
 */
export function setPalette(
  paletteId: PaletteId,
  customAccent?: string,
): void {
  localStorage.setItem(PALETTE_STORAGE_KEY, paletteId);
  if (customAccent !== undefined) {
    localStorage.setItem(CUSTOM_ACCENT_STORAGE_KEY, customAccent);
  }
  // 自定义色板：从当前激活主题读取基底 mode（亮/暗）
  const customMode =
    paletteId === 'custom' ? getCurrentCustomTheme()?.mode : undefined;
  applyPalette(
    paletteId,
    customAccent ?? getStoredCustomAccent(),
    customMode,
  );
}

/**
 * 运行时切换主题模式（无闪烁）
 *
 * 同时持久化 theme_mode 并映射到对应色板。
 */
export function setThemeMode(mode: ThemeMode): void {
  localStorage.setItem(THEME_MODE_STORAGE_KEY, mode);
  setPalette(THEME_MODE_TO_PALETTE[mode]);
}
