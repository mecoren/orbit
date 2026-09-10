import { useEffect } from "react";
import { useNavigate } from "react-router";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { CheckSquare, Info, Settings, Trash2 } from "lucide-react";

import { useAppStore } from "@/stores/app-store";
import { isHelpShortcut } from "@/features/todo/shared/shortcut-help";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { ThemeModeToggle } from "@/components/theme-mode-toggle";
import { WindowControls } from "@/components/ui/window-controls";

/** 标题栏右上功能图标（设置 / 关于；原壳侧栏底部入口迁移至此） */
function TitleBarIconButton({
  to,
  icon: Icon,
  label,
}: {
  to: string;
  icon: typeof Settings;
  label: string;
}) {
  const navigate = useNavigate();
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="size-8 text-muted-foreground hover:text-foreground"
          onClick={() => navigate(to)}
          aria-label={label}
        >
          <Icon className="size-4" />
        </Button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  );
}

export function TitleBar() {
  const appWindow = getCurrentWindow();
  const toggleCommand = useAppStore((s) => s.toggleCommand);
  const setSearchOpen = useAppStore((s) => s.setSearchOpen);
  const setShortcutHelpOpen = useAppStore((s) => s.setShortcutHelpOpen);

  // 全局快捷键：Ctrl/Cmd+P 命令面板；Ctrl/Cmd+K 全局搜索；? 帮助面板
  //（? 为 Shift+/ 组合；输入框/文本域聚焦时豁免——正文打问号不弹帮助）
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.ctrlKey || e.metaKey) {
        if (e.key === "p") {
          e.preventDefault();
          toggleCommand();
        } else if (e.key === "k") {
          e.preventDefault();
          setSearchOpen(true);
        }
        return;
      }
      if (!isHelpShortcut(e)) return;
      const target = e.target as HTMLElement | null;
      if (target?.closest("input, textarea, [contenteditable=true]")) return;
      e.preventDefault();
      setShortcutHelpOpen(true);
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [toggleCommand, setSearchOpen, setShortcutHelpOpen]);

  return (
    <>
      <div
        className="title-bar relative flex h-9 items-center border-b bg-background/60 dark:bg-background/85"
        data-tauri-drag-region
        onDoubleClick={() => appWindow.toggleMaximize()}
      >
        {/* 中部：居中标题（可拖拽）—— 应用显示名「循迹」（README 命名约定） */}
        <div
          className="absolute left-1/2 -translate-x-1/2 select-none text-sm font-medium"
          data-tauri-drag-region
        >
          循迹
        </div>

        {/* 右侧：待办、设置、关于、主题、窗口控制按钮（不响应拖拽，避免点击被吞）。
            self-stretch：撑满标题栏全高，让 WindowControls 三键可垂直 stretch
            铺满（hover 背景贴顶到底无间隙）；其余图标钮靠 items-center 居中 */}
        <div
          className="ml-auto flex items-center gap-1 self-stretch pr-0"
          data-tauri-drag-region={false}
        >
          <TitleBarIconButton to="/todo" icon={CheckSquare} label="待办" />
          <TitleBarIconButton to="/todo/trash" icon={Trash2} label="回收站" />
          <TitleBarIconButton to="/settings" icon={Settings} label="设置" />
          <TitleBarIconButton to="/about" icon={Info} label="关于" />
          <ThemeModeToggle />
          {/* 窗口控制（Win11 规范三键）：高度占满标题栏行，贴窗口右缘 */}
          <WindowControls />
        </div>
      </div>
    </>
  );
}
