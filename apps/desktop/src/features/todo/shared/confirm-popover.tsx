/**
 * ConfirmPopover —— 行内删除确认小弹框（qraft tab 关闭确认同形制）
 *
 * 用于详情抽屉内轻量行的删除/清除确认：确认框锚定在目标行下方而非
 * 屏幕中央（居中 AlertDialog 打断感强），点外部 / Esc 均视为取消。
 * 子任务 / 关联任务 / 评论 / 提醒 / 截止日期清除共用同一形制。
 *
 * 受控组件：open / onOpenChange 由使用方按行持有（confirmDelete 按 id
 * 匹配），确认时组件负责关闭再回调 onConfirm。
 */
import type { ReactNode } from "react";

import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";

export interface ConfirmPopoverProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 确认框标题（如「删除评论」） */
  title: string;
  /** 说明文案（如「确定要删除这条评论吗？」） */
  description: ReactNode;
  /** 确认按钮文案（默认「删除」） */
  confirmLabel?: string;
  /** 确认回调（删除/清除动作本体；关闭弹框由组件完成） */
  onConfirm: () => void;
  /** 触发行内容（PopoverTrigger asChild 包住目标行） */
  children: ReactNode;
  /** 锚定对齐（默认右缘对齐，随删除按钮一侧） */
  align?: "start" | "center" | "end";
}

export function ConfirmPopover({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel = "删除",
  onConfirm,
  children,
  align = "end",
}: ConfirmPopoverProps) {
  return (
    <Popover open={open} onOpenChange={onOpenChange}>
      <PopoverTrigger asChild>
        {children}
      </PopoverTrigger>
      <PopoverContent align={align} side="bottom" className="w-56 p-3">
        <p className="text-xs font-semibold">{title}</p>
        <p className="mt-1 break-words text-[10px] text-muted-foreground">{description}</p>
        <div className="mt-2.5 flex justify-end gap-1">
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="h-7 px-2.5 text-xs"
            onClick={() => onOpenChange(false)}
          >
            取消
          </Button>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="h-7 px-2.5 text-xs text-destructive hover:bg-destructive/10 hover:text-destructive"
            onClick={() => {
              onOpenChange(false);
              onConfirm();
            }}
          >
            {confirmLabel}
          </Button>
        </div>
      </PopoverContent>
    </Popover>
  );
}
