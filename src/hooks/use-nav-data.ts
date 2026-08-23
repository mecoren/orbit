/**
 * use-nav-data — 壳导航数据 Hook（Orbit 精简版）
 *
 * 按 04 文档 §六 ⚖ 决策重写：单组「待办」，去除 wait-home 的
 * 收藏组 / nav-config / my_nav_items / career 聚合逻辑。
 * queryKey ["nav-data"] 同时供强调色读取（use-module-accent-color）。
 */
import { useQuery } from "@tanstack/react-query";
import { CheckSquare, type LucideIcon } from "lucide-react";

import { featureModuleListEnabled, type FeatureModule } from "@/lib/tauri";

/** 单条导航项数据 */
export interface NavItemData {
  routePath: string;
  label: string;
  icon: LucideIcon;
  /** 强调色（来自功能模块配置） */
  color?: string;
  module?: FeatureModule;
}

/** 导航分组 */
export interface NavGroup {
  id: "todo" | "settings";
  title: string;
  icon: LucideIcon;
  items: NavItemData[];
}

/** React Query 缓存键（02 文档 §五 queryKey 约定） */
export const NAV_QUERY_KEY = ["nav-data"] as const;

/**
 * 组装壳导航：MVP 仅一个「待办」入口。
 * 数据源为 cfg_feature_modules 中 module_key='todo' 的启用行；
 * 查询失败时回退到静态项，保证壳永远可渲染。
 */
export function useNavData(): {
  groups: NavGroup[];
  loading: boolean;
  refetch: () => void;
} {
  const { data: modules, isLoading, refetch } = useQuery({
    queryKey: NAV_QUERY_KEY,
    queryFn: featureModuleListEnabled,
    // 壳级数据允许陈旧展示（staleTime 与列表页一致取 2min）
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });

  const todo = modules?.find((m) => m.module_key === "todo");

  const groups: NavGroup[] = [
    {
      id: "todo",
      title: todo?.module_name || "待办",
      icon: CheckSquare,
      items: [
        {
          routePath: "/todo",
          label: todo?.module_name || "待办",
          icon: CheckSquare,
          color: todo?.accent_color || "#3B82F6",
          module: todo,
        },
      ],
    },
  ];

  return { groups, loading: isLoading, refetch };
}
