import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";
import { Inbox } from "lucide-react";

import { cn } from "@/lib/utils";

interface EmptyStateProps {
  /** 主图标，默认 Inbox */
  icon?: LucideIcon;
  /** 主文案（如"暂无任务"） */
  title: string;
  /** 辅助说明 */
  hint?: string;
  /** 底部动作（如"新建任务"按钮） */
  action?: ReactNode;
  /** 附加样式类 */
  className?: string;
}

/**
 * 统一空状态展示组件（error-state.tsx 注释中预告的对称件）：
 * 居中图标 + 主文案 + 辅助说明 + 可选动作按钮。
 */
export function EmptyState({ icon: Icon = Inbox, title, hint, action, className }: EmptyStateProps) {
  return (
    <div className={cn("flex flex-col items-center gap-2 px-8 py-16 text-center", className)}>
      <Icon className="size-10 text-muted-foreground/40" />
      <p className="text-sm text-muted-foreground">{title}</p>
      {hint ? <p className="text-xs text-muted-foreground/70">{hint}</p> : null}
      {action ? <div className="mt-2">{action}</div> : null}
    </div>
  );
}
