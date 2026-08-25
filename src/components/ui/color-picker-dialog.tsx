/**
 * 通用颜色选择弹窗（桌面端）
 *
 * 交互：
 *   - 连续调色板：HSL 取色（饱和度×明度方块 + 色相滑块），直接点选/拖动
 *   - 预设色板：常用色块快捷选择
 *   - 输入反推：HEX 文本框 或 R/G/B 数字输入，均实时反推当前颜色
 *   - 任意来源改动都会同步刷新预览与其他输入框
 *
 * 用法：
 *   <ColorPickerDialog
 *     open={open}
 *     onOpenChange={setOpen}
 *     initialColor="#0EA5E9"
 *     title="修改颜色"
 *     onConfirm={(color) => {...}}
 *   />
 */
import { useEffect, useRef, useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { cn } from "@/lib/utils";

/** 默认色（HEX 大写），未提供初始颜色时回退到此值 */
export const DEFAULT_ACCENT_COLOR = "#0EA5E9";

/**
 * 预设色板（移动端/桌面端共用，柔和现代色调）
 *
 * 色相均匀覆盖 360° 色环 + 1 中性色，色相间有明显间隔，视觉辨识度高。
 * 选用 Tailwind 500 阶色阶（中等饱和度 + 较高明度），避免 600/700 过暗、400 过亮。
 *
 * 色相分布：
 *   玫红 350°  暖橙 25°  翡翠 160°  天蓝 200°
 *   靛紫 240°  紫罗兰 280°  玫粉 330°  石墨 中性
 */
export const PRESET_COLORS: ReadonlyArray<{ hex: string; name: string }> = [
  { hex: "#F43F5E", name: "玫红" },
  { hex: "#F97316", name: "暖橙" },
  { hex: "#10B981", name: "翡翠" },
  { hex: "#0EA5E9", name: "天蓝" },
  { hex: "#6366F1", name: "靛紫" },
  { hex: "#A855F7", name: "紫罗兰" },
  { hex: "#EC4899", name: "玫粉" },
  { hex: "#64748B", name: "石墨" },
];

interface ColorPickerDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  initialColor?: string;
  title?: string;
  onConfirm: (color: string) => void;
}

// ============================================================
// 颜色工具
// ============================================================

type RGB = { r: number; g: number; b: number };
type HSL = { h: number; s: number; l: number };

function hexToRgb(hex: string): RGB | null {
  const m = hex.trim().replace(/^#/, "");
  if (/^[0-9a-fA-F]{3}$/.test(m))
    return {
      r: parseInt(m[0] + m[0], 16),
      g: parseInt(m[1] + m[1], 16),
      b: parseInt(m[2] + m[2], 16),
    };
  if (/^[0-9a-fA-F]{6}$/.test(m))
    return {
      r: parseInt(m.slice(0, 2), 16),
      g: parseInt(m.slice(2, 4), 16),
      b: parseInt(m.slice(4, 6), 16),
    };
  return null;
}

function rgbToHex({ r, g, b }: RGB): string {
  const toHex = (n: number) =>
    Math.max(0, Math.min(255, Math.round(n)))
      .toString(16)
      .padStart(2, "0");
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`.toUpperCase();
}

function normalizeHex(value: string): string | null {
  const v = value.trim();
  if (/^#?[0-9a-fA-F]{3}$/.test(v) || /^#?[0-9a-fA-F]{6}$/.test(v)) {
    const hex = v.startsWith("#") ? v : `#${v}`;
    const rgb = hexToRgb(hex);
    return rgb ? rgbToHex(rgb) : null;
  }
  return null;
}

function rgbToHsl({ r, g, b }: RGB): HSL {
  r /= 255;
  g /= 255;
  b /= 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  let h = 0;
  const l = (max + min) / 2;
  const d = max - min;
  const s = d === 0 ? 0 : d / (1 - Math.abs(2 * l - 1));
  if (d !== 0) {
    switch (max) {
      case r:
        h = ((g - b) / d) % 6;
        break;
      case g:
        h = (b - r) / d + 2;
        break;
      default:
        h = (r - g) / d + 4;
    }
    h = Math.round(h * 60);
    if (h < 0) h += 360;
  }
  return { h, s: Math.round(s * 100), l: Math.round(l * 100) };
}

function hslToRgb({ h, s, l }: HSL): RGB {
  s /= 100;
  l /= 100;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  let r = 0;
  let g = 0;
  let b = 0;
  if (h < 60) [r, g, b] = [c, x, 0];
  else if (h < 120) [r, g, b] = [x, c, 0];
  else if (h < 180) [r, g, b] = [0, c, x];
  else if (h < 240) [r, g, b] = [0, x, c];
  else if (h < 300) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  return {
    r: Math.round((r + m) * 255),
    g: Math.round((g + m) * 255),
    b: Math.round((b + m) * 255),
  };
}

// ============================================================
// 子组件：饱和度×明度方块
// ============================================================

function SVPanel({
  hsl,
  onChange,
}: {
  hsl: HSL;
  onChange: (next: HSL) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);

  const updateFromEvent = (clientX: number, clientY: number) => {
    const el = ref.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const x = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    const y = Math.min(1, Math.max(0, (clientY - rect.top) / rect.height));
    onChange({ ...hsl, s: Math.round(x * 100), l: Math.round((1 - y) * 100) });
  };

  return (
    <div
      ref={ref}
      className="relative h-40 w-full cursor-crosshair rounded-md border"
      style={{
        backgroundColor: `hsl(${hsl.h}, 100%, 50%)`,
        backgroundImage:
          "linear-gradient(to top, #000, transparent), linear-gradient(to right, #fff, transparent)",
      }}
      onPointerDown={(e) => {
        dragging.current = true;
        e.currentTarget.setPointerCapture(e.pointerId);
        updateFromEvent(e.clientX, e.clientY);
      }}
      onPointerMove={(e) => {
        if (dragging.current) updateFromEvent(e.clientX, e.clientY);
      }}
      onPointerUp={(e) => {
        dragging.current = false;
        e.currentTarget.releasePointerCapture(e.pointerId);
      }}
    >
      {/* 取色游标 */}
      <div
        className="pointer-events-none absolute h-4 w-4 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white shadow"
        style={{
          left: `${hsl.s}%`,
          top: `${100 - hsl.l}%`,
          backgroundColor: rgbToHex(hslToRgb(hsl)),
        }}
      />
    </div>
  );
}

// ============================================================
// 子组件：色相滑块
// ============================================================

function HueSlider({
  hue,
  onChange,
}: {
  hue: number;
  onChange: (hue: number) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);

  const update = (clientX: number) => {
    const el = ref.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const x = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    onChange(Math.round(x * 360));
  };

  return (
    <div
      ref={ref}
      className="relative h-4 w-full cursor-pointer rounded-full border"
      style={{
        background:
          "linear-gradient(to right, #f00 0%, #ff0 17%, #0f0 33%, #0ff 50%, #00f 67%, #f0f 83%, #f00 100%)",
      }}
      onPointerDown={(e) => {
        dragging.current = true;
        e.currentTarget.setPointerCapture(e.pointerId);
        update(e.clientX);
      }}
      onPointerMove={(e) => {
        if (dragging.current) update(e.clientX);
      }}
      onPointerUp={(e) => {
        dragging.current = false;
        e.currentTarget.releasePointerCapture(e.pointerId);
      }}
    >
      <div
        className="pointer-events-none absolute top-1/2 h-5 w-5 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white shadow"
        style={{ left: `${(hue / 360) * 100}%`, backgroundColor: `hsl(${hue},100%,50%)` }}
      />
    </div>
  );
}

// ============================================================
// 主组件
// ============================================================

export function ColorPickerDialog({
  open,
  onOpenChange,
  initialColor = DEFAULT_ACCENT_COLOR,
  title = "选择颜色",
  onConfirm,
}: ColorPickerDialogProps) {
  const [selected, setSelected] = useState(initialColor);
  const [hexInput, setHexInput] = useState(initialColor);
  const [rgbInput, setRgbInput] = useState<RGB>({ r: 14, g: 165, b: 233 });

  const apply = (rgb: RGB, opts?: { syncHex?: boolean; syncRgb?: boolean }) => {
    const hex = rgbToHex(rgb);
    setSelected(hex);
    if (opts?.syncHex !== false) setHexInput(hex);
    if (opts?.syncRgb !== false) setRgbInput(rgb);
  };

  useEffect(() => {
    if (open) {
      const norm = normalizeHex(initialColor) ?? DEFAULT_ACCENT_COLOR;
      const rgb = hexToRgb(norm) ?? { r: 14, g: 165, b: 233 };
      setSelected(norm);
      setHexInput(norm);
      setRgbInput(rgb);
    }
  }, [open, initialColor]);

  const hsl = rgbToHsl(rgbInput);

  const handleHexInput = (value: string) => {
    setHexInput(value);
    const norm = normalizeHex(value);
    if (norm) apply(hexToRgb(norm)!);
  };

  const handleRgbInput = (key: keyof RGB, raw: string) => {
    const n = Math.max(0, Math.min(255, Number(raw) || 0));
    const next = { ...rgbInput, [key]: n };
    setRgbInput(next);
    apply(next, { syncHex: true });
  };

  const handleSvChange = (next: HSL) => {
    apply(hslToRgb(next), { syncRgb: true });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>在调色板中点选，或直接输入 HEX / RGB</DialogDescription>
        </DialogHeader>

        {/* 当前颜色预览：更大的色块 + hex 名称叠加，更现代 */}
        <div
          className="relative h-16 w-full overflow-hidden rounded-lg border shadow-inner"
          style={{ backgroundColor: selected }}
        >
          <div className="absolute inset-x-0 bottom-0 flex items-center justify-between bg-gradient-to-t from-black/40 to-transparent px-3 py-2 text-xs text-white">
            <span className="font-medium tracking-wide">
              {PRESET_COLORS.find((p) => p.hex.toUpperCase() === selected.toUpperCase())?.name ?? "自定义"}
            </span>
            <span className="font-mono opacity-90">{selected}</span>
          </div>
        </div>

        {/* 连续调色板（HSL） */}
        <div className="flex flex-col gap-3">
          <SVPanel hsl={hsl} onChange={handleSvChange} />
          <HueSlider hue={hsl.h} onChange={(h) => handleSvChange({ ...hsl, h })} />
        </div>

        {/* 预设色板：8 色 + 圆角更柔和 + 选中态显示光晕 */}
        <div className="grid grid-cols-8 gap-1.5">
          {PRESET_COLORS.map((preset) => {
            const isSelected = selected.toUpperCase() === preset.hex.toUpperCase();
            return (
              <button
                key={preset.hex}
                type="button"
                title={`${preset.name} · ${preset.hex}`}
                className={cn(
                  "group relative h-9 w-full rounded-lg transition-all",
                  "ring-offset-background hover:scale-105 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2",
                  isSelected
                    ? "ring-2 ring-foreground ring-offset-2 ring-offset-background shadow-sm"
                    : "ring-1 ring-black/5 dark:ring-white/10",
                )}
                style={{ backgroundColor: preset.hex }}
                onClick={() => apply(hexToRgb(preset.hex)!)}
                aria-label={`选择 ${preset.name} ${preset.hex}`}
                aria-pressed={isSelected}
              />
            );
          })}
        </div>

        {/* HEX 输入 */}
        <div className="space-y-1.5">
          <Label htmlFor="cp-hex" className="text-xs text-muted-foreground">
            HEX
          </Label>
          <Input
            id="cp-hex"
            value={hexInput}
            onChange={(e) => handleHexInput(e.target.value)}
            placeholder="#0EA5E9"
            className="font-mono"
          />
        </div>

        {/* RGB 输入（反推） */}
        <div className="space-y-1.5">
          <Label className="text-xs text-muted-foreground">RGB</Label>
          <div className="grid grid-cols-3 gap-1.5">
            {(["r", "g", "b"] as const).map((key, i) => (
              <div
                key={key}
                className="flex items-center gap-1 rounded-md border border-input bg-background px-2 py-1 focus-within:ring-2 focus-within:ring-ring focus-within:ring-offset-1"
              >
                <span className="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
                  {["R", "G", "B"][i]}
                </span>
                <Input
                  type="number"
                  min={0}
                  max={255}
                  value={rgbInput[key]}
                  onChange={(e) => handleRgbInput(key, e.target.value)}
                  className="h-6 w-full border-0 bg-transparent p-0 font-mono text-xs shadow-none focus-visible:ring-0 focus-visible:ring-offset-0"
                />
              </div>
            ))}
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            取消
          </Button>
          <Button
            onClick={() => {
              onConfirm(normalizeHex(hexInput) ?? selected);
              onOpenChange(false);
            }}
          >
            确定
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
