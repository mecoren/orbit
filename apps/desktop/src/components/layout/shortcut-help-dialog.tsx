// apps/desktop/src/components/layout/shortcut-help-dialog.tsx
/**
 * ShortcutHelpDialog — 快捷键帮助面板（? 呼出，快捷键 discoverability（全仓审计高价值缺口））
 *
 * 数据源为 features/todo/shared/shortcut-help.ts 常量表（单一口径源，
 * 同目录 .test.ts 锁结构）；Todoist/Things 3 同款 "?" 呼出惯例。
 * 挂 AppShell 层级（与命令面板/全局搜索平级），键监听在 TitleBar
 * 全局 keydown handler 内统一注册。
 */
import { Keyboard } from "lucide-react";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { SHORTCUT_GROUPS } from "@/features/todo/shared/shortcut-help";

interface ShortcutHelpDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

/** 键位徽章：mono 字体 + muted 底，形制对齐表格外键位展示惯例 */
function Key({ label }: { label: string }) {
  return (
    <kbd className="inline-flex h-6 min-w-6 items-center justify-center rounded-md border border-border/60 bg-muted px-1.5 font-mono text-xs font-medium text-muted-foreground">
      {label}
    </kbd>
  );
}

export function ShortcutHelpDialog({ open, onOpenChange }: ShortcutHelpDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Keyboard className="size-4" />
            键盘快捷键
          </DialogTitle>
          <DialogDescription>
            提升操作效率的快捷键一览；按 Esc 关闭。
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-5">
          {SHORTCUT_GROUPS.map((group) => (
            <section key={group.title}>
              <h3 className="mb-2 text-xs font-medium text-muted-foreground">
                {group.title}
              </h3>
              <div className="flex flex-col gap-1.5">
                {group.entries.map((entry) => (
                  <div
                    key={entry.keys}
                    className="flex items-center justify-between gap-4 rounded-md px-2 py-1 hover:bg-accent/30"
                  >
                    <span className="flex items-center gap-1.5">
                      {entry.keys.split("+").map((part, i) => (
                        <span key={part} className="flex items-center gap-1.5">
                          {i > 0 && (
                            <span className="text-xs text-muted-foreground">+</span>
                          )}
                          <Key label={part} />
                        </span>
                      ))}
                    </span>
                    <span className="text-sm text-foreground/80">{entry.action}</span>
                  </div>
                ))}
              </div>
            </section>
          ))}
        </div>
      </DialogContent>
    </Dialog>
  );
}
