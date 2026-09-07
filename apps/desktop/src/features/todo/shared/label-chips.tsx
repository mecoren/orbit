/**
 * LabelChips — 任务标签迷你条目（列表行 / 看板卡 / 日历行共用）
 *
 * 形式：左色点（hex_color）+ 右标签名（常规 muted 文字）——
 * 原彩字描边淡底胶囊与元信息行其余 muted 元素抢视觉，且与
 * 优先级圆点口径不统一；改为点色即可分辨、文字回归安静层级。
 * 超 max 折叠为 +N。
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
            className="inline-flex min-w-0 items-center gap-1"
          >
            <span
              aria-hidden
              className="size-1.5 shrink-0 rounded-full"
              style={{ background: hex }}
            />
            <span className="max-w-[72px] truncate text-[10px] text-muted-foreground">
              {l.title}
            </span>
          </span>
        );
      })}
      {rest > 0 && (
        <span className="text-[10px] text-muted-foreground">+{rest}</span>
      )}
    </span>
  );
}
