/**
 * 工具栏收拢双菜单（TickTick Web 同款形态，prd/desktop-toolbar-dropdown）：
 *
 * - SortMenuButton「↑↓」：分组（仅看板）/ 排序档 / 顺序（升/降序）+ 状态/优先级
 *   筛选子菜单就地展开（筛选与排序同属「行怎么排」语义，收在一处）；
 * - MoreMenuButton「···」：顶部视图图标排（当前高亮、点按不关菜单）+ 隐藏已完成
 *   + 存为视图 + 搜索或跳转 + 标签管理。
 *
 * 全部状态由 task-panel 持有、props 注入（面板是唯一状态源，本文件纯 UI 转发）；
 * 数据语义与收拢前逐项等价——aria-label 沿用原文案（列表视图/存为视图/标签管理…），
 * e2e 选择器平移成本最小。
 */
import {
  ArrowUpDown,
  CalendarDays,
  Ellipsis,
  Grid2x2,
  LayoutGrid,
  ListTodo,
  Table2,
} from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import {
  type TaskSortDir,
  type TaskSortKey,
} from "../shared/task-filters";
import { type KanbanGroupBy } from "./kanban-view";
// 仅类型反向引用（inline type 擦除，无运行时环）：三态类型真源在 task-panel
import { type PriorityFilter, type StatusFilter, type ViewMode } from "./task-panel";

/** 视图图标排元数据（与原五联钮同序同 icon；aria-label 原样保留供 e2e 复用） */
const VIEW_TABS: { key: ViewMode; label: string; icon: typeof ListTodo }[] = [
  { key: "list", label: "列表视图", icon: ListTodo },
  { key: "kanban", label: "看板视图", icon: LayoutGrid },
  { key: "calendar", label: "日历视图", icon: CalendarDays },
  { key: "table", label: "表格视图", icon: Table2 },
  { key: "matrix", label: "矩阵视图", icon: Grid2x2 },
];

const SORT_LABEL: Record<TaskSortKey, string> = {
  manual: "拖拽顺序",
  due: "截止时间",
  priority: "优先级",
  title: "标题",
  created: "创建时间",
};

const STATUS_LABEL: Record<StatusFilter, string> = {
  all: "全部状态",
  undone: "未完成",
  pending: "待办",
  doing: "进行中",
  done: "已完成",
};

const PRIORITY_ITEMS: { value: PriorityFilter; label: string }[] = [
  { value: "all", label: "全部优先级" },
  { value: "0", label: "无优先级" },
  { value: "1", label: "低" },
  { value: "2", label: "中" },
  { value: "3", label: "高" },
  { value: "4", label: "紧急" },
  { value: "5", label: "立即处理" },
];

/** 菜单触发钮统一规格：Tooltip → DropdownMenuTrigger → Button 链（asChild 必须逐层落到
 *  真实 DOM 元素，中间不能隔函数组件——ref/aria 状态会被丢掉）；h-8 w-8 ghost 与原工具栏 icon 钮同观感 */
function MenuTrigger({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="icon" className="h-8 w-8" aria-label={label}>
            {children}
          </Button>
        </DropdownMenuTrigger>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  );
}

interface SortMenuButtonProps {
  viewMode: ViewMode;
  sortKey: TaskSortKey;
  onSortKeyChange: (k: TaskSortKey) => void;
  /** 当前生效方向（manual 档 = BASE 兜底，菜单侧不判空） */
  sortDir: TaskSortDir;
  onSortDirChange: (d: TaskSortDir) => void;
  kanbanGroupBy: KanbanGroupBy;
  onKanbanGroupByChange: (g: KanbanGroupBy) => void;
  statusFilter: StatusFilter;
  onStatusFilterChange: (s: StatusFilter) => void;
  priorityFilter: PriorityFilter;
  onPriorityFilterChange: (p: PriorityFilter) => void;
}

/** 「↑↓」排序菜单：分组（仅看板）/ 排序 / 顺序（manual 档隐藏方向行）+ 状态/优先级筛选 */
export function SortMenuButton(props: SortMenuButtonProps) {
  const {
    viewMode,
    sortKey,
    onSortKeyChange,
    sortDir,
    onSortDirChange,
    kanbanGroupBy,
    onKanbanGroupByChange,
    statusFilter,
    onStatusFilterChange,
    priorityFilter,
    onPriorityFilterChange,
  } = props;

  return (
    <DropdownMenu>
      {/* 菜单内含状态/优先级筛选，触发钮文案不叫「排序」单指一域 */}
      <MenuTrigger label="排序与筛选">
        <ArrowUpDown size={14} />
      </MenuTrigger>
      <DropdownMenuContent align="end" className="min-w-40">
        {/* 分组：仅看板视图有意义（与收拢前条件一致） */}
        {viewMode === "kanban" && (
          <DropdownMenuSub>
            <DropdownMenuSubTrigger>
              <span className="flex-1">分组</span>
              <span className="text-xs text-muted-foreground">
                {kanbanGroupBy === "project" ? "按项目" : "按状态"}
              </span>
            </DropdownMenuSubTrigger>
            <DropdownMenuSubContent>
              <DropdownMenuRadioGroup
                value={kanbanGroupBy}
                onValueChange={(v) => onKanbanGroupByChange(v as KanbanGroupBy)}
              >
                <DropdownMenuRadioItem value="project">按项目</DropdownMenuRadioItem>
                <DropdownMenuRadioItem value="status">按状态</DropdownMenuRadioItem>
              </DropdownMenuRadioGroup>
            </DropdownMenuSubContent>
          </DropdownMenuSub>
        )}

        <DropdownMenuSub>
          <DropdownMenuSubTrigger>
            <span className="flex-1">排序</span>
            <span className="text-xs text-muted-foreground">{SORT_LABEL[sortKey]}</span>
          </DropdownMenuSubTrigger>
          <DropdownMenuSubContent>
            <DropdownMenuRadioGroup
              value={sortKey}
              onValueChange={(v) => onSortKeyChange(v as TaskSortKey)}
            >
              <DropdownMenuRadioItem value="manual">拖拽顺序</DropdownMenuRadioItem>
              <DropdownMenuRadioItem value="due">截止时间</DropdownMenuRadioItem>
              <DropdownMenuRadioItem value="priority">优先级</DropdownMenuRadioItem>
              <DropdownMenuRadioItem value="title">标题</DropdownMenuRadioItem>
              <DropdownMenuRadioItem value="created">创建时间</DropdownMenuRadioItem>
            </DropdownMenuRadioGroup>
          </DropdownMenuSubContent>
        </DropdownMenuSub>

        {/* 顺序：拖拽序无方向概念，整行隐藏（收拢前语义：manual 恒 position 升序） */}
        {sortKey !== "manual" && (
          <DropdownMenuSub>
            <DropdownMenuSubTrigger>
              <span className="flex-1">顺序</span>
              <span className="text-xs text-muted-foreground">
                {sortDir === "asc" ? "升序" : "降序"}
              </span>
            </DropdownMenuSubTrigger>
            <DropdownMenuSubContent>
              <DropdownMenuRadioGroup
                value={sortDir}
                onValueChange={(v) => onSortDirChange(v as TaskSortDir)}
              >
                <DropdownMenuRadioItem value="asc">升序</DropdownMenuRadioItem>
                <DropdownMenuRadioItem value="desc">降序</DropdownMenuRadioItem>
              </DropdownMenuRadioGroup>
            </DropdownMenuSubContent>
          </DropdownMenuSub>
        )}

        <DropdownMenuSeparator />

        {/* 状态/优先级筛选（与排序同属「行怎么呈现」语义，收在「↑↓」下） */}
        <DropdownMenuSub>
          <DropdownMenuSubTrigger>
            <span className="flex-1">状态</span>
            <span className="text-xs text-muted-foreground">{STATUS_LABEL[statusFilter]}</span>
          </DropdownMenuSubTrigger>
          <DropdownMenuSubContent>
            <DropdownMenuRadioGroup
              value={statusFilter}
              onValueChange={(v) => onStatusFilterChange(v as StatusFilter)}
            >
              {(Object.keys(STATUS_LABEL) as StatusFilter[]).map((k) => (
                <DropdownMenuRadioItem key={k} value={k}>
                  {STATUS_LABEL[k]}
                </DropdownMenuRadioItem>
              ))}
            </DropdownMenuRadioGroup>
          </DropdownMenuSubContent>
        </DropdownMenuSub>

        <DropdownMenuSub>
          <DropdownMenuSubTrigger>
            <span className="flex-1">优先级</span>
            <span className="text-xs text-muted-foreground">
              {PRIORITY_ITEMS.find((i) => i.value === priorityFilter)?.label}
            </span>
          </DropdownMenuSubTrigger>
          <DropdownMenuSubContent>
            <DropdownMenuRadioGroup
              value={priorityFilter}
              onValueChange={(v) => onPriorityFilterChange(v as PriorityFilter)}
            >
              {PRIORITY_ITEMS.map((i) => (
                <DropdownMenuRadioItem key={i.value} value={i.value}>
                  {i.label}
                </DropdownMenuRadioItem>
              ))}
            </DropdownMenuRadioGroup>
          </DropdownMenuSubContent>
        </DropdownMenuSub>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

interface MoreMenuButtonProps {
  viewMode: ViewMode;
  onViewModeChange: (m: ViewMode) => void;
  hideDone: boolean;
  onHideDoneChange: (v: boolean) => void;
  /** 置灰条件原样保留：Logbook 视图 / 已完成状态筛选下开关无意义 */
  hideDoneDisabled: boolean;
  onSaveAsView: () => void;
  onOpenCommand: () => void;
  onOpenLabels: () => void;
}

/** 「···」更多菜单：视图图标排 + 显示/入口类低频项收拢 */
export function MoreMenuButton(props: MoreMenuButtonProps) {
  const {
    viewMode,
    onViewModeChange,
    hideDone,
    onHideDoneChange,
    hideDoneDisabled,
    onSaveAsView,
    onOpenCommand,
    onOpenLabels,
  } = props;

  return (
    <DropdownMenu>
      <MenuTrigger label="更多">
        <Ellipsis size={14} />
      </MenuTrigger>
      <DropdownMenuContent align="end" className="min-w-48">
        {/* 视图图标排：普通 button 不触发 Radix 关菜单（点按即切、菜单保持）；
            aria-label 与原五联钮一致，e2e 选择器零改动 */}
        <div className="flex items-center justify-between gap-1 px-2 py-1.5">
          {VIEW_TABS.map(({ key, label, icon: Icon }) => (
            <Tooltip key={key}>
              <TooltipTrigger asChild>
                <button
                  type="button"
                  aria-label={label}
                  onClick={() => onViewModeChange(key)}
                  className={cn(
                    "flex h-8 w-8 items-center justify-center rounded-md",
                    viewMode === key ? "bg-primary/10 text-primary" : "hover:bg-accent",
                  )}
                >
                  <Icon size={14} />
                </button>
              </TooltipTrigger>
              <TooltipContent>{label}</TooltipContent>
            </Tooltip>
          ))}
        </div>
        <DropdownMenuSeparator />

        {/* CheckboxItem 原语默认 pl-8 给左侧勾选指示器留位，文字会比普通 MenuItem
            缩进一截；这里文字左对齐各项、指示器移到行尾（Win11 切换项同款），
            role=menuitemcheckbox 与 aria-checked 不变，e2e 选择器零改动 */}
        <DropdownMenuCheckboxItem
          checked={hideDone}
          disabled={hideDoneDisabled}
          onCheckedChange={(v) => onHideDoneChange(v === true)}
          className="pl-2 [&>span]:left-auto [&>span]:right-2"
        >
          隐藏已完成
        </DropdownMenuCheckboxItem>
        <DropdownMenuSeparator />

        {/* 存为视图：预填链路在 task-panel（buildConditions），此处仅回调 */}
        <DropdownMenuItem onSelect={() => onSaveAsView()}>存为视图</DropdownMenuItem>
        <DropdownMenuItem onSelect={() => onOpenCommand()}>
          搜索或跳转
          <DropdownMenuShortcut>Ctrl+P</DropdownMenuShortcut>
        </DropdownMenuItem>
        <DropdownMenuItem onSelect={() => onOpenLabels()}>标签管理</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
