/**
 * 设置页导航分类模型（对齐 wait-home：左导航 + 右内容布局）
 */
import { CloudUpload, Palette, Shield, type LucideIcon } from "lucide-react";

export interface CategoryItem {
  key: string;
  label: string;
  icon: LucideIcon;
}

/** Orbit MVP 分类：安全 / 主题 / 同步与备份（M3 起追加同步） */
export const settingsCategories: CategoryItem[] = [
  { key: "security", label: "安全", icon: Shield },
  { key: "theme", label: "主题", icon: Palette },
  { key: "sync", label: "同步与备份", icon: CloudUpload },
];

export type SettingsCategoryKey = (typeof settingsCategories)[number]["key"];
