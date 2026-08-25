import type { LucideIcon } from "lucide-react";
import { AlertCircle } from "lucide-react";

import { cn } from "@/lib/utils";

interface ErrorStateProps {
  /** 错误信息文本 */
  message: string;
  /** 左侧图标，默认 AlertCircle */
  icon?: LucideIcon;
  /** 附加样式类 */
  className?: string;
}

/**
 * 统一错误状态展示组件
 *
 * 替代各页面手写的 `{error && <div className="...text-destructive...">}` 红字块，
 * 与 [EmptyState] 形成对称的状态组件体系。
 *
 * 默认样式：destructive/10 背景 + destructive/30 边框 + AlertCircle 图标 + break-all 文本。
 */
export function ErrorState({
  message,
  icon: Icon = AlertCircle,
  className,
}: ErrorStateProps) {
  return (
    <div
      className={cn(
        "flex items-center gap-2 rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive",
        className,
      )}
    >
      <Icon className="size-4 shrink-0" />
      <span className="break-all">{message}</span>
    </div>
  );
}
