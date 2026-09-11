/**
 * 待办模块共享常量（04 文档 §5.2 语义色 / §二 快捷视图定义）
 */
import {
  CalendarDays,
  CalendarRange,
  CheckCircle2,
  CircleDot,
  ListTodo,
  Star,
  Sunrise,
  type LucideIcon,
} from "lucide-react";

/** 模块强调色（硬编码 #3B82F6，不走 cfg 动态读取 —— 04 §5.1 决策） */
export const TODO_ACCENT = "#3B82F6";

/** 优先级 0–5 语义色（P0「无」浅灰 #D1D5DB——列表竖条/看板条/选择器/统计图全部同色） */
export const PRIORITY_COLOR = ["#D1D5DB", "#6B7280", "#3B82F6", "#F59E0B", "#EF4444", "#DC2626"];

/** 优先级 0–5 中文档位（多选批量工具条 / 右键菜单共用口径） */
export const PRIORITY_LABELS = ["无", "低", "中", "高", "紧急", "立即处理"];

/** 状态语义色 */
export const STATUS_COLOR = {
  pending: "#6B7280",
  doing: "#3B82F6",
  done: "#22C55E",
} as const;

/** 收藏星标固定色 / 逾期红（04 §5.2；逾期走 destructive token） */
export const FAVORITE_COLOR = "#FACC15";
export const OVERDUE_COLOR_CLASS = "text-destructive";

/** 「我的一天」日出高亮色（列表/表格/详情/右键菜单四处同口径，04 §5.2） */
export const MY_DAY_COLOR = "#F59E0B";

/** 10 色预设色板（04 §3.8 标签管理器与项目颜色共用同序列；新建标签随机
 *  色池同源——此前 drawer/form-sheet 各持一份 8 色池且内容不一致，收编） */
export const PRESET_10 = [
  "#EF4444", "#F59E0B", "#22C55E", "#3B82F6", "#8B5CF6",
  "#EC4899", "#14B8A6", "#F97316", "#6366F1", "#6B7280",
];

/** 快捷视图 key（my_day = 我的一天，07 报告新增项，对标微软 To Do） */
export type QuickViewKey = "all" | "undone" | "done" | "today" | "week" | "favorite" | "my_day";

export interface QuickViewDef {
  key: QuickViewKey;
  label: string;
  icon: LucideIcon;
  color: string;
}

/** 快捷视图（顺序即侧栏展示顺序；「我的一天」置顶——每日聚焦第一入口） */
export const QUICK_VIEWS: QuickViewDef[] = [
  { key: "my_day", label: "我的一天", icon: Sunrise, color: MY_DAY_COLOR },
  { key: "all", label: "全部任务", icon: ListTodo, color: "#3B82F6" },
  { key: "undone", label: "未完成", icon: CircleDot, color: "#F59E0B" },
  { key: "done", label: "已完成", icon: CheckCircle2, color: "#22C55E" },
  { key: "today", label: "今天截止", icon: CalendarDays, color: "#EF4444" },
  { key: "week", label: "本周截止", icon: CalendarRange, color: "#F59E0B" },
  { key: "favorite", label: "收藏", icon: Star, color: "#8B5CF6" },
];

/** 视图切换状态持久化键（04 §二） */
export const LS_VIEW_MODE = "todo_view_mode";
/** 未分组虚拟项位置持久化键（04 §3.1） */
export const LS_UNGROUPED_AFTER = "todo_sidebar_ungrouped_after";
/** 详情页描述悬浮预览开关（本机设置，默认开） */
export const LS_DESC_PREVIEW_ENABLED = "desc_preview_enabled";
/** 详情页描述悬浮预览延迟毫秒（默认 800） */
export const LS_DESC_PREVIEW_DELAY = "desc_preview_delay";
