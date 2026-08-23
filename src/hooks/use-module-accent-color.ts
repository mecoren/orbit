/**
 * use-module-accent-color — 按 module_key 读取功能模块强调色
 *
 * 数据来源：复用 useNavData 的查询缓存（NAV_QUERY_KEY），
 * 避免为读取颜色再发起一次 featureModuleListEnabled 请求。
 *
 * Orbit 语境（04 文档 §5.1）：todo 模块强调色兜底硬编码 #3B82F6，
 * DB 中 accent_color 存在时优先。
 */
import { useQuery } from "@tanstack/react-query";
import { NAV_QUERY_KEY } from "@/hooks/use-nav-data";
import { featureModuleListEnabled } from "@/lib/tauri";

export function useModuleAccentColor(moduleKey: string | undefined): string | undefined {
  const { data: modules } = useQuery({
    queryKey: NAV_QUERY_KEY,
    queryFn: featureModuleListEnabled,
    staleTime: 30_000,
  });
  if (!moduleKey) return undefined;
  return modules?.find((m) => m.module_key === moduleKey)?.accent_color || "#3B82F6";
}
