/**
 * Lucide 图标映射（桌面端）
 *
 * 提供两套图标来源：
 *   1. getIcon(name)：按图标名称字符串（PascalCase，如 "Film"）查找 Lucide 组件。
 *      适用于 icon_variant 等场景。
 *   2. getModuleIcon(moduleKey)：按 module_key 查找语义图标。
 *      与侧边栏导航 (use-nav-data.FIXED_ICONS) 共享同一份映射，
 *      确保导航配置页 / 收藏项 / 添加候选列表的图标与左侧导航菜单完全一致。
 *
 * 数据库 cfg_feature_modules.icon 字段存的是 Material Icons 名称（如 "movie"、
 * "menu_book"），与桌面端 Lucide 命名不一致，故桌面端不读取该字段，统一走 module_key 映射。
 */
import type { LucideIcon } from "lucide-react";
import {
  // 通用回退
  LayoutGrid,
  // 通用按名称映射（保留以兼容旧用法）
  Film,
  Book,
  Gamepad2,
  Smartphone,
  MapPin,
  Calendar,
  CalendarCheck,
  Gift,
  CheckSquare,
  FolderKanban,
  Briefcase,
  Wallet,
  Building2,
  Users,
  HeartPulse,
  Baby,
  Receipt,
  CreditCard,
  Phone,
  // 应用服务图标选择器候选
  MessageCircle,
  Mail,
  PhoneCall,
  UserPlus,
  ShoppingCart,
  ShoppingBag,
  Landmark,
  Banknote,
  Coins,
  Music,
  Headphones,
  Clapperboard,
  Tv,
  MonitorPlay,
  Palette,
  Brush,
  Dumbbell,
  Wrench,
  BookOpen,
  BookText,
  Cloud,
  CloudUpload,
  Bell,
  BellRing,
  Bookmark,
  Lightbulb,
  Folder,
  FolderOpen,
  Package,
  Box,
  Plane,
  Car,
  Utensils,
  Heart,
  Star,
  Lock,
  Key,
  Home,
  FileText,
  File,
  Camera,
  Image,
  Globe,
  Stethoscope,
  Calculator,
  Coffee,
  // 路由 / 设置（与 routePathIcons 一致）
  Settings,
  Info,
  Rocket,
} from "lucide-react";

/** 图标名称 → Lucide 组件映射表（PascalCase 名称） */
export const iconMap: Record<string, LucideIcon> = {
  Film,
  Book,
  Gamepad2,
  Smartphone,
  MapPin,
  Calendar,
  CalendarCheck,
  Gift,
  CheckSquare,
  FolderKanban,
  Briefcase,
  Wallet,
  Building2,
  Users,
  HeartPulse,
  Baby,
  Receipt,
  CreditCard,
  Phone,
  MessageCircle,
  Mail,
  PhoneCall,
  UserPlus,
  ShoppingCart,
  ShoppingBag,
  Landmark,
  Banknote,
  Coins,
  Music,
  Headphones,
  Clapperboard,
  Tv,
  MonitorPlay,
  Palette,
  Brush,
  Dumbbell,
  Wrench,
  BookOpen,
  BookText,
  Cloud,
  CloudUpload,
  Bell,
  BellRing,
  Bookmark,
  Lightbulb,
  Folder,
  FolderOpen,
  Package,
  Box,
  Plane,
  Car,
  Utensils,
  Heart,
  Star,
  Lock,
  Key,
  Home,
  FileText,
  File,
  Camera,
  Image,
  Globe,
  Stethoscope,
  Calculator,
  Coffee,
};

/**
 * 按 PascalCase 名称获取 Lucide 图标组件
 * 未知名称回退到 LayoutGrid，保证渲染不中断
 */
export function getIcon(name: string): LucideIcon {
  return iconMap[name] ?? LayoutGrid;
}

/**
 * module_key → 固定语义图标
 *
 * 与侧边栏导航 (use-nav-data.FIXED_ICONS) 保持一致，
 * 保证导航配置页 / 收藏项 / 添加候选列表的图标与左侧导航菜单完全统一。
 *
 * 选择理由：数据库 cfg_feature_modules.icon 字段存的是 Material Icons 名称
 * （如 "movie" / "menu_book" / "sports_esports"），与桌面端 Lucide 命名不一致，
 * 故桌面端统一按 module_key 查表，不读取该字段。
 */
export const moduleKeyIcons: Record<string, LucideIcon> = {
  // —— 记录类 ——
  movie: Film,
  book: BookOpen,
  game: Gamepad2,
  device: Smartphone,
  outing: MapPin,
  important_date: CalendarCheck,
  gift_card: Gift,
  phone: Smartphone,
  // —— 扩展类 ——
  todo: CheckSquare,
  career: Rocket,
  project: FolderKanban,
  work_experience: Briefcase,
  salary: Banknote,
  company: Building2,
  family_member: Users,
  period: Heart,
  pregnancy: Baby,
  women_health: HeartPulse,
};

/**
 * 路由路径（连字符风格）→ 语义图标
 *
 * 与 use-nav-data.FIXED_ICONS 保持一致，覆盖首页/设置/关于等
 * 不在 cfg_feature_modules 表中的特殊路径。
 */
export const routePathIcons: Record<string, LucideIcon> = {
  "/": Home,
  "/home": Home,
  "/settings": Settings,
  "/about": Info,
};

/**
 * 按 module_key 获取语义图标
 * 未知 key 回退到 LayoutGrid
 */
export function getModuleIcon(moduleKey: string): LucideIcon {
  return moduleKeyIcons[moduleKey] ?? LayoutGrid;
}

/**
 * 按路由路径（连字符风格）获取语义图标
 * 未知路径回退到 LayoutGrid
 */
export function getRoutePathIcon(routePath: string): LucideIcon {
  return routePathIcons[routePath] ?? LayoutGrid;
}

/**
 * 应用服务图标选择器候选（展示顺序即此顺序；名称与 iconMap 完全一致）
 */
export const ICON_PICKER_CHOICES: string[] = [
  "MessageCircle", "Mail", "Phone", "PhoneCall", "Users", "UserPlus",
  "Wallet", "CreditCard", "ShoppingCart", "ShoppingBag", "Banknote", "Landmark", "Coins",
  "Gamepad2", "Music", "Headphones", "Film", "Clapperboard", "Tv", "MonitorPlay",
  "Palette", "Brush", "Dumbbell", "Wrench", "BookOpen", "BookText",
  "Cloud", "CloudUpload", "Bell", "BellRing", "Bookmark", "Lightbulb",
  "Folder", "FolderOpen", "Package", "Box", "Plane", "Car", "Utensils",
  "Heart", "Star", "Lock", "Key", "Home", "FileText", "File",
  "Camera", "Image", "Globe", "Gift", "Stethoscope", "Building2", "Briefcase",
  "Calculator", "Smartphone", "Calendar", "MapPin", "Coffee",
];
