/**
 * 命令面板（Orbit 精简版）
 *
 * 04 文档 §六：Ctrl+P / cmdk CommandDialog。
 * ⚖ 分组精简：路由组「待办」+ 系统组（设置/关于）；
 * ⚖③ 最近任务组：数据链路在 M2 接入（todo 查询命令就绪后填充），
 * 点击行为按 §7-③ 写入 selectedTaskId 并打开详情抽屉。
 */
import { useMemo } from "react";
import { useNavigate } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { CheckSquare, Clock, Info, LayoutGrid, Plus, Settings, SunMoon } from "lucide-react";

import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { useTodoStore } from "@/features/todo/store";
import { useAppStore } from "@/stores/app-store";
import { getStoredThemeMode, setThemeMode, type ThemeMode } from "@/lib/color-theme";
import { todoTaskList } from "@/lib/tauri";

interface RouteItem {
  label: string;
  path: string;
  group: string;
}

/** 路由清单（与 sidebar 分组命名一致） */
const ROUTES: RouteItem[] = [
  { label: "待办", path: "/todo", group: "待办" },
  { label: "设置", path: "/settings", group: "系统" },
  { label: "关于", path: "/about", group: "系统" },
];

function routeIcon(path: string) {
  if (path === "/todo") return <CheckSquare className="size-4" />;
  if (path === "/settings") return <Settings className="size-4" />;
  if (path === "/about") return <Info className="size-4" />;
  return null;
}

interface CommandPaletteProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function CommandPalette({ open, onOpenChange }: CommandPaletteProps) {
  const navigate = useNavigate();
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const bumpTaskFormIntent = useAppStore((s) => s.bumpTaskFormIntent);
  const bumpViewToggleIntent = useAppStore((s) => s.bumpViewToggleIntent);

  /** 与 components/theme-mode-toggle.tsx 相同的三态循环 */
  const cycleTheme = () => {
    const CYCLE: ThemeMode[] = ["system", "light", "dark"];
    const next = CYCLE[(CYCLE.indexOf(getStoredThemeMode()) + 1) % CYCLE.length];
    setThemeMode(next);
  };

  // 最近任务组（⚖③ M2 接线）：复用 ["todo_tasks"] 缓存，updated_at 降序取前 5
  const { data: tasks } = useQuery({
    queryKey: ["todo_tasks"],
    queryFn: () => todoTaskList({ page: 1, page_size: 1000 }),
    enabled: open,
  });
  const recentTasks = useMemo(
    () =>
      (tasks ?? [])
        .filter((t) => !t.is_deleted)
        .sort((a, b) => b.updated_at - a.updated_at)
        .slice(0, 5),
    [tasks],
  );

  const go = (path: string) => {
    navigate(path);
    onOpenChange(false);
  };

  const groupedRoutes = useMemo(() => {
    const map = new Map<string, RouteItem[]>();
    for (const route of ROUTES) {
      if (!map.has(route.group)) map.set(route.group, []);
      map.get(route.group)!.push(route);
    }
    return Array.from(map.entries());
  }, []);

  return (
    <CommandDialog open={open} onOpenChange={onOpenChange}>
      <CommandInput placeholder="搜索页面或最近任务..." autoFocus />
      <CommandList>
        <CommandEmpty>无匹配结果</CommandEmpty>
        <CommandGroup heading="命令">
          <CommandItem
            value="新建任务 new task"
            onSelect={() => {
              onOpenChange(false);
              bumpTaskFormIntent();
            }}
          >
            <Plus className="size-4" />
            <span>新建任务</span>
          </CommandItem>
          <CommandItem
            value="切换主题 theme light dark system"
            onSelect={() => {
              cycleTheme();
              onOpenChange(false);
            }}
          >
            <SunMoon className="size-4" />
            <span>切换主题</span>
          </CommandItem>
          <CommandItem
            value="切换视图 view kanban list 看板 列表"
            onSelect={() => {
              onOpenChange(false);
              bumpViewToggleIntent();
            }}
          >
            <LayoutGrid className="size-4" />
            <span>切换列表/看板视图</span>
          </CommandItem>
        </CommandGroup>
        {groupedRoutes.map(([group, items]) => (
          <CommandGroup key={group} heading={group}>
            {items.map((item) => (
              <CommandItem
                key={item.path}
                value={`${item.label} ${item.group}`}
                onSelect={() => go(item.path)}
              >
                {routeIcon(item.path)}
                <span>{item.label}</span>
              </CommandItem>
            ))}
          </CommandGroup>
        ))}
        {recentTasks.length > 0 && (
          <CommandGroup heading="最近任务">
            {recentTasks.map((t) => (
              <CommandItem
                key={t.id}
                value={t.title}
                onSelect={() => {
                  setSelectedTaskId(t.id);
                  go("/todo");
                }}
              >
                <Clock className="size-4" />
                <span className="flex-1 truncate">{t.title}</span>
              </CommandItem>
            ))}
          </CommandGroup>
        )}
      </CommandList>
    </CommandDialog>
  );
}
