/**
 * 主题分区（对齐 wait-home ThemeSection）
 *
 * 结构：分区标题 + 颜色主题卡（跟随系统/5 预设/自定义色板网格 +
 * 显示模式三态）+ 字体卡（字号/字重档位 + 预览框）。
 * 自定义色板支持新增 / 编辑（名称 + 基底 + 强调色）/ 删除。
 */
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { Monitor, Moon, Palette, Pencil, Plus, Sun, Trash2, Type } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { ColorPickerDialog } from "@/components/ui/color-picker-dialog";
import {
  applyFontSizeLevel,
  applyFontWeightLevel,
  FONT_SIZE_LEVELS,
  FONT_SIZE_STORAGE_KEY,
  FONT_WEIGHT_LEVELS,
  FONT_WEIGHT_STORAGE_KEY,
} from "@/lib/theme";
import {
  addCustomTheme,
  getCustomThemes,
  getCurrentCustomThemeId,
  getStoredPaletteId,
  getStoredThemeMode,
  removeCustomTheme,
  selectCustomTheme,
  setPalette,
  setThemeMode,
  updateCustomTheme,
  type CustomTheme,
  type PaletteId,
  type ThemeMode,
} from "@/lib/color-theme";
import { PRESET_PALETTES } from "@/lib/design-tokens";

/** 跟随系统条目（双 swatch 预览用中性灰） */
const SYSTEM_ENTRY = { id: "system" as const, label: "跟随系统", swatches: ["#64748B", "#F1F5F9"] };

interface PaletteCardDef {
  key: string;
  label: string;
  swatches: [string, string];
}

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

/** 统一档位按钮规格：显示模式/字号/字重/基底四组 pill 共用（同高 28px，选中 default/未选 outline） */
const PILL_CLS = "h-7 px-3";

function CardShell({
  icon: Icon,
  title,
  desc,
  children,
}: {
  icon: typeof Palette;
  title: string;
  desc: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-4 rounded-lg border p-5">
      <div className="flex items-center gap-3">
        <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-muted">
          <Icon className="size-4 text-muted-foreground" />
        </div>
        <div>
          <p className="text-sm font-medium">{title}</p>
          <p className="text-xs text-muted-foreground">{desc}</p>
        </div>
      </div>
      {children}
    </div>
  );
}

export function ThemeSection() {
  // ---- 色板状态 ----
  const [paletteIdState, setPaletteIdState] = useState<PaletteId>("system");
  const [customs, setCustoms] = useState<CustomTheme[]>([]);
  const [currentCustomId, setCurrentCustomId] = useState<string | null>(null);
  const [mode, setModeState] = useState<ThemeMode>("system");

  // ---- 新增/编辑自定义主题弹窗 ----
  const [editorOpen, setEditorOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null); // null=新增
  const [draftName, setDraftName] = useState("");
  const [draftAccent, setDraftAccent] = useState("#0EA5E9");
  const [draftMode, setDraftMode] = useState<"light" | "dark">("dark");
  const [pickerOpen, setPickerOpen] = useState(false);

  // ---- 字体状态 ----
  const [sizeLevel, setSizeLevel] = useState(1);
  const [weightLevel, setWeightLevel] = useState(1);

  const refreshCustoms = () => {
    setCustoms(getCustomThemes());
    setCurrentCustomId(getCurrentCustomThemeId());
  };

  useEffect(() => {
    setPaletteIdState(getStoredPaletteId());
    setModeState(getStoredThemeMode());
    refreshCustoms();
    const s = localStorage.getItem(FONT_SIZE_STORAGE_KEY);
    const w = localStorage.getItem(FONT_WEIGHT_STORAGE_KEY);
    if (s) setSizeLevel(Number(s));
    if (w) setWeightLevel(Number(w));
  }, []);

  /** 应用预设/跟随系统 */
  const handlePalette = (id: PaletteId) => {
    setPalette(id);
    setPaletteIdState(id);
    if (id !== "custom") setCurrentCustomId(null);
  };

  /** 应用自定义主题 */
  const handleCustom = (theme: CustomTheme) => {
    selectCustomTheme(theme.id);
    setPaletteIdState("custom");
    setCurrentCustomId(theme.id);
  };

  const handleMode = (m: ThemeMode) => {
    setThemeMode(m);
    setModeState(m);
    setPaletteIdState(m === "light" ? "daylight" : m === "dark" ? "obsidian" : "system");
    toast.success(
      m === "light" ? "已切换亮色" : m === "dark" ? "已切换暗色" : "已跟随系统",
    );
  };

  const openAdd = () => {
    setEditingId(null);
    setDraftName("");
    setDraftAccent("#0EA5E9");
    setDraftMode("dark");
    setEditorOpen(true);
  };

  const openEdit = (t: CustomTheme) => {
    setEditingId(t.id);
    setDraftName(t.name);
    setDraftAccent(t.accent);
    setDraftMode(t.mode);
    setEditorOpen(true);
  };

  const submitEditor = () => {
    if (editingId == null) {
      const t = addCustomTheme(draftName, draftAccent, draftMode);
      selectCustomTheme(t.id);
      toast.success("已添加自定义主题");
    } else {
      updateCustomTheme(editingId, { name: draftName, accent: draftAccent, mode: draftMode });
      toast.success("已保存修改");
    }
    refreshCustoms();
    setPaletteIdState("custom");
    setEditorOpen(false);
  };

  const deleteCustom = (t: CustomTheme) => {
    removeCustomTheme(t.id);
    refreshCustoms();
    if (getCurrentCustomThemeId() === null && paletteIdState === "custom") {
      setPaletteIdState("system");
    }
  };

  const handleSizeLevel = (lv: number) => {
    applyFontSizeLevel(lv);
    localStorage.setItem(FONT_SIZE_STORAGE_KEY, String(lv));
    setSizeLevel(lv);
  };

  const handleWeightLevel = (lv: number) => {
    applyFontWeightLevel(lv);
    localStorage.setItem(FONT_WEIGHT_STORAGE_KEY, String(lv));
    setWeightLevel(lv);
  };

  // ---- 色板卡片数据（跟随系统 → 预设 → 自定义）----
  const presetCards: PaletteCardDef[] = PRESET_PALETTES.map((p) => ({
    key: p.id,
    label: p.displayName,
    swatches: p.previewSwatches,
  }));
  const customCards: PaletteCardDef[] = customs.map((t) => ({
    key: `custom:${t.id}`,
    label: t.name,
    swatches: [t.accent, t.mode === "dark" ? "#18181B" : "#FAFAFA"],
  }));

  const isSelected = (key: string) =>
    key.startsWith("custom:")
      ? paletteIdState === "custom" &&
        currentCustomId != null &&
        key === `custom:${currentCustomId}`
      : paletteIdState === key && paletteIdState !== "custom";

  return (
    <div className="space-y-4">
      <SectionHeader title="主题" desc="选择应用的显示主题与字体" />

      {/* ===== 颜色主题 ===== */}
      <CardShell icon={Palette} title="颜色主题" desc="选择预设色板或自定义强调色，切换即时生效">
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          {/* 跟随系统 */}
          <button
            type="button"
            onClick={() => handlePalette("system")}
            className={cn(
              "rounded-lg border p-1.5 text-left transition-colors",
              isSelected("system")
                ? "border-primary bg-primary/5 text-primary"
                : "hover:bg-accent/50",
            )}
          >
            <span className="flex h-12 gap-1 overflow-hidden rounded-md">
              {SYSTEM_ENTRY.swatches.map((c, i) => (
                <span key={i} className="flex-1" style={{ background: c }} />
              ))}
            </span>
            <span className="mt-1.5 block truncate px-0.5 text-sm">{SYSTEM_ENTRY.label}</span>
          </button>

          {/* 预设色板 */}
          {presetCards.map((card) => (
            <button
              key={card.key}
              type="button"
              onClick={() => handlePalette(card.key as PaletteId)}
              className={cn(
                "rounded-lg border p-1.5 text-left transition-colors",
                isSelected(card.key)
                  ? "border-primary bg-primary/5 text-primary"
                  : "hover:bg-accent/50",
              )}
            >
              <span className="flex h-12 gap-1 overflow-hidden rounded-md">
                {card.swatches.map((c, i) => (
                  <span key={i} className="flex-1" style={{ background: c }} />
                ))}
              </span>
              <span className="mt-1.5 block truncate px-0.5 text-sm">{card.label}</span>
            </button>
          ))}

          {/* 自定义主题 */}
          {customCards.map((card, i) => {
            const theme = customs[i];
            return (
              <div
                key={card.key}
                className={cn(
                  "group relative rounded-lg border p-1.5 text-left transition-colors",
                  isSelected(card.key)
                    ? "border-primary bg-primary/5 text-primary"
                    : "hover:bg-accent/50",
                )}
              >
                <button
                  type="button"
                  onClick={() => handleCustom(theme)}
                  className="block w-full"
                >
                  <span className="flex h-12 gap-1 overflow-hidden rounded-md">
                    {card.swatches.map((c, j) => (
                      <span key={j} className="flex-1" style={{ background: c }} />
                    ))}
                  </span>
                  <span className="mt-1.5 block truncate px-0.5 pr-8 text-sm">{card.label}</span>
                </button>
                <div className="absolute right-2 top-2 flex opacity-0 transition-opacity group-hover:opacity-100">
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-6 w-6"
                    onClick={(e) => {
                      e.stopPropagation();
                      openEdit(theme);
                    }}
                  >
                    <Pencil className="size-3" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="text-destructive hover:text-destructive h-6 w-6"
                    onClick={(e) => {
                      e.stopPropagation();
                      deleteCustom(theme);
                    }}
                  >
                    <Trash2 className="size-3" />
                  </Button>
                </div>
              </div>
            );
          })}

          {/* 添加自定义 */}
          <button
            type="button"
            onClick={openAdd}
            className="flex h-[76px] items-center justify-center gap-1.5 rounded-lg border border-dashed text-sm text-muted-foreground transition-colors hover:bg-accent/50 hover:text-foreground"
          >
            <Plus className="size-4" />
            添加自定义
          </button>
        </div>

        {/* 显示模式三态 */}
        <div className="flex items-center gap-3 border-t pt-3">
          <span className="text-xs text-muted-foreground">显示模式</span>
          <div className="flex gap-1.5">
            {([
              { m: "light" as ThemeMode, icon: Sun, label: "亮色" },
              { m: "dark" as ThemeMode, icon: Moon, label: "暗色" },
              { m: "system" as ThemeMode, icon: Monitor, label: "跟随系统" },
            ]).map(({ m, icon: Icon, label }) => (
              <Button
                key={m}
                variant={mode === m ? "default" : "outline"}
                size="sm"
                className={PILL_CLS}
                onClick={() => handleMode(m)}
              >
                <Icon size={13} className="mr-1" />
                {label}
              </Button>
            ))}
          </div>
        </div>
      </CardShell>

      {/* ===== 字体 ===== */}
      <CardShell icon={Type} title="字体" desc="调整应用全局字号与字重">
        <div className="grid gap-3 sm:grid-cols-2">
          <div>
            <p className="mb-1.5 text-xs text-muted-foreground">字号</p>
            <div className="flex gap-1.5">
              {FONT_SIZE_LEVELS.map((lv, i) => (
                <Button
                  key={lv.label}
                  size="sm"
                  variant={sizeLevel === i ? "default" : "outline"}
                  className={cn(PILL_CLS, "flex-1 px-2")}
                  onClick={() => handleSizeLevel(i)}
                >
                  {lv.label}
                </Button>
              ))}
            </div>
          </div>
          <div>
            <p className="mb-1.5 text-xs text-muted-foreground">字重</p>
            <div className="flex gap-1.5">
              {FONT_WEIGHT_LEVELS.map((lv, i) => (
                <Button
                  key={lv.label}
                  size="sm"
                  variant={weightLevel === i ? "default" : "outline"}
                  className={cn(PILL_CLS, "flex-1 px-2")}
                  style={{ fontWeight: lv.weight }}
                  onClick={() => handleWeightLevel(i)}
                >
                  {lv.label}
                </Button>
              ))}
            </div>
          </div>
        </div>

        {/* 预览框 */}
        <div className="rounded-md border bg-muted/30 p-3">
          <p className="text-sm leading-relaxed">
            The quick brown fox jumps over the lazy dog.
            敏捷的棕色狐狸跳过了懒狗的背。
          </p>
        </div>
      </CardShell>

      {/* ===== 新增/编辑自定义主题 Dialog ===== */}
      <Dialog open={editorOpen} onOpenChange={setEditorOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>{editingId == null ? "添加自定义主题" : "编辑自定义主题"}</DialogTitle>
          </DialogHeader>
          <div className="space-y-4">
            <div className="space-y-1.5">
              <Label htmlFor="theme-name">主题名称</Label>
              <Input
                id="theme-name"
                autoFocus
                maxLength={20}
                value={draftName}
                placeholder="例如：海盐蓝"
                onChange={(e) => setDraftName(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label>基底</Label>
              <div className="flex gap-1.5">
                {(["dark", "light"] as const).map((m) => (
                  <Button
                    key={m}
                    size="sm"
                    variant={draftMode === m ? "default" : "outline"}
                    className={cn(PILL_CLS, "flex-1")}
                    onClick={() => setDraftMode(m)}
                  >
                    {m === "dark" ? "深色" : "浅色"}
                  </Button>
                ))}
              </div>
            </div>
            <div className="space-y-1.5">
              <Label>强调色</Label>
              <Button
                type="button"
                variant="outline"
                className="w-full justify-start"
                onClick={() => setPickerOpen(true)}
              >
                <span
                  className="mr-2 inline-block size-4 shrink-0 rounded-full border"
                  style={{ background: draftAccent }}
                />
                {draftAccent.toUpperCase()}
              </Button>
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setEditorOpen(false)}>
              取消
            </Button>
            <Button disabled={!draftName.trim()} onClick={submitEditor}>
              保存
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* 强调色取色器 */}
      <ColorPickerDialog
        open={pickerOpen}
        onOpenChange={setPickerOpen}
        initialColor={draftAccent}
        title="选择强调色"
        onConfirm={(color) => setDraftAccent(color)}
      />
    </div>
  );
}
