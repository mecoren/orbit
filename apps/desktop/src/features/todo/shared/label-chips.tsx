/**
 * LabelChips — 任务标签迷你 chip（列表行 / 看板卡共用）
 *
 * 颜色分配：chip 文字/边框/底色均取标签自选色 hex_color
 * （新建标签 8 色板随机、标签管理器十色板），底色/边框加透明度派生，
 * 与详情抽屉标签区同语义。超 max 折叠为 +N。
 */
import type { TodoLabel } from "@/lib/tauri";
import { cn } from "@/lib/utils";

/** hex_color 兜底（历史数据可能为空串） */
const FALLBACK_COLOR = "#6B7280";

export function LabelChips({
  labels,
  className,
  max = 3,
}: {
  labels: TodoLabel[];
  className?: string;
  /** 最多直显的标签数，超出折叠 +N */
  max?: number;
}) {
  if (labels.length === 0) return null;
  const shown = labels.slice(0, max);
  const rest = labels.length - shown.length;
  return (
    <span className={cn("inline-flex min-w-0 items-center gap-1", className)}>
      {shown.map((l) => {
        const hex = l.hex_color || FALLBACK_COLOR;
        return (
          <span
            key={l.id}
            title={l.title}
            className="inline-flex max-w-[72px] items-center truncate rounded border px-1 text-[10px] leading-4"
            style={{
              color: hex,
              borderColor: `${hex}59`,
              background: `${hex}1A`,
            }}
          >
            {l.title}
          </span>
        );
      })}
      {rest > 0 && (
        <span className="text-[10px] text-muted-foreground">+{rest}</span>
      )}
    </span>
  );
}
