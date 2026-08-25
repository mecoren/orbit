import { cn } from "@/lib/utils";

/**
 * 玻璃三件套之三：1px 五段 alpha 高光线（05 §三）。
 * 亮色 alpha [0,.85,1,.85,0]、暗色 [0,.30,.45,.30,0]（样式静态类见 index.css `.glass-hl-*`，
 * 暗色经 @media (prefers-color-scheme: dark) 覆盖；仅移动端消费，桌面无引用零成本）。
 *
 * - position="bottom"：贴元素下缘（标题栏底缘用）；
 * - position="inner-bottom"：内侧底部、左右内缩圆角线（FAB 用，Task 7 消费）。
 */
export function GlassHighlight({ position }: { position: "bottom" | "inner-bottom" }) {
  return (
    <span
      aria-hidden
      className={cn("glass-hl", position === "inner-bottom" ? "glass-hl-inner-bottom" : "glass-hl-bottom")}
    />
  );
}
