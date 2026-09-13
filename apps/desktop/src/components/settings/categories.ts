/**
 * 设置页导航分类模型（对齐 wait-home：左导航 + 右内容布局）
 */
import { Bell, CloudUpload, FileStack, Keyboard, ListTodo, Palette, RefreshCw, Shield, type LucideIcon } from "lucide-react";

export interface CategoryItem {
  key: string;
  label: string;
  icon: LucideIcon;
}

/** Orbit MVP 分类：安全 / 主题 / 待办（回收站保留时间）/ 同步与备份 / 快捷键 / 任务模板 / 通知历史 */
export const settingsCategories: CategoryItem[] = [
  { key: "security", label: "安全", icon: Shield },
  { key: "theme", label: "主题", icon: Palette },
  { key: "todo", label: "待办", icon: ListTodo },
  { key: "sync", label: "同步与备份", icon: CloudUpload },
  { key: "shortcuts", label: "快捷键", icon: Keyboard },
  { key: "templates", label: "任务模板", icon: FileStack },
  { key: "notifications", label: "通知历史", icon: Bell },
  { key: "updater", label: "关于与更新", icon: RefreshCw },
];

export type SettingsCategoryKey = (typeof settingsCategories)[number]["key"];
