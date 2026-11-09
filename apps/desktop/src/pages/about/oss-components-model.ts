import type { OssComponent, OssComponentSource } from "@/lib/tauri";

/** 桌面端可见来源：Flutter 属移动壳直接依赖，桌面「关于」不展示 */
export type OssDesktopSource = Exclude<OssComponentSource, "flutter">;

/** 来源筛选：all = 全部（仅含桌面端可见来源） */
export type OssSourceFilter = "all" | OssDesktopSource;

/** 排序档：default 保留 core 给定顺序 */
export type OssSort = "default" | "name-asc" | "name-desc" | "source";

export const OSS_SOURCE_LABELS: Record<OssComponentSource, string> = {
  frontend: "前端",
  rust: "Rust",
  flutter: "Flutter",
};

/** 来源排序口径：前端 → Rust → Flutter（与 core 默认顺序一致） */
const SOURCE_ORDER: Record<OssComponentSource, number> = {
  frontend: 0,
  rust: 1,
  flutter: 2,
};

export const OSS_SOURCE_FILTERS: { value: OssSourceFilter; label: string }[] = [
  { value: "all", label: "全部" },
  { value: "frontend", label: "前端" },
  { value: "rust", label: "Rust" },
];

export const OSS_SORT_OPTIONS: { value: OssSort; label: string }[] = [
  { value: "default", label: "默认排序" },
  { value: "name-asc", label: "名称 A→Z" },
  { value: "name-desc", label: "名称 Z→A" },
  { value: "source", label: "按来源" },
];

export function ossSourceLabel(source: OssComponentSource): string {
  return OSS_SOURCE_LABELS[source];
}

/** 去掉移动壳来源（Flutter），桌面只看自己的直接依赖 */
export function desktopVisibleOssComponents(
  items: OssComponent[],
): OssComponent[] {
  return items.filter((item) => item.source !== "flutter");
}

/** 按来源筛选（不改动原数组） */
export function filterOssComponents(
  items: OssComponent[],
  filter: OssSourceFilter,
): OssComponent[] {
  if (filter === "all") return items.slice();
  return items.filter((item) => item.source === filter);
}

const byName = (a: OssComponent, b: OssComponent) =>
  a.name.localeCompare(b.name, "en", { sensitivity: "base" });

/** 排序（不改动原数组；default 保持 core 顺序） */
export function sortOssComponents(
  items: OssComponent[],
  sort: OssSort,
): OssComponent[] {
  const next = items.slice();
  switch (sort) {
    case "name-asc":
      next.sort(byName);
      break;
    case "name-desc":
      next.sort((a, b) => byName(b, a));
      break;
    case "source":
      next.sort(
        (a, b) => SOURCE_ORDER[a.source] - SOURCE_ORDER[b.source] || byName(a, b),
      );
      break;
    default:
      break;
  }
  return next;
}
