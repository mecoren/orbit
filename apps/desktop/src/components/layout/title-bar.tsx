import { useEffect, useState, type ReactNode } from "react";
import { useNavigate } from "react-router";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { CheckSquare, Copy, Info, Minus, Settings, Square, X } from "lucide-react";

import { cn } from "@/lib/utils";
import { useAppStore } from "@/stores/app-store";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { ThemeModeToggle } from "@/components/theme-mode-toggle";

// 窗口控制按钮：Windows 原生风格，hover 时切换背景
function WindowButton({
  children,
  onClick,
  className,
  ariaLabel,
}: {
  children: ReactNode;
  onClick: () => void;
  className?: string;
  ariaLabel: string;
}) {
  return (
    <button
      type="button"
      aria-label={ariaLabel}
      className={cn(
        "flex h-9 w-12 items-center justify-center text-muted-foreground transition-colors",
        "hover:bg-muted hover:text-foreground",
        className,
      )}
      onClick={onClick}
    >
      {children}
    </button>
  );
}

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
  const [isMaximized, setIsMaximized] = useState(false);
  const toggleCommand = useAppStore((s) => s.toggleCommand);
  const setSearchOpen = useAppStore((s) => s.setSearchOpen);

  // 监听窗口大小变化：onResized 触发时同步 isMaximized，用于切换最大化图标 ▢/❐
  useEffect(() => {
    const unlistenPromise = appWindow.onResized(async () => {
      setIsMaximized(await appWindow.isMaximized());
    });
    // 初始化时同步一次当前状态，避免首次渲染图标错误
    appWindow.isMaximized().then(setIsMaximized).catch(() => {});
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, [appWindow]);

  // 全局快捷键：Ctrl/Cmd+P 命令面板；Ctrl/Cmd+K 全局搜索
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!(e.ctrlKey || e.metaKey)) return;
      if (e.key === "p") {
        e.preventDefault();
        toggleCommand();
      } else if (e.key === "k") {
        e.preventDefault();
        setSearchOpen(true);
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [toggleCommand, setSearchOpen]);

  return (
    <>
      <div
        className="relative flex h-9 items-center border-b bg-background/60 dark:bg-background/85"
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

        {/* 右侧：待办、设置、关于、主题、窗口控制按钮（不响应拖拽，避免点击被吞） */}
        <div className="ml-auto flex items-center gap-1 pr-0" data-tauri-drag-region={false}>
          <TitleBarIconButton to="/todo" icon={CheckSquare} label="待办" />
          <TitleBarIconButton to="/settings" icon={Settings} label="设置" />
          <TitleBarIconButton to="/about" icon={Info} label="关于" />
          <ThemeModeToggle />
          <WindowButton
            ariaLabel="最小化"
            onClick={() => appWindow.minimize()}
          >
            <Minus className="size-3" />
          </WindowButton>
          <WindowButton
            ariaLabel="最大化"
            onClick={() => appWindow.toggleMaximize()}
          >
            {isMaximized ? (
              <Copy className="size-3" />
            ) : (
              <Square className="size-3" />
            )}
          </WindowButton>
          <WindowButton
            ariaLabel="关闭"
            onClick={() => appWindow.close()}
            className="hover:bg-[#E81123] hover:text-white"
          >
            <X className="size-3" />
          </WindowButton>
        </div>
      </div>
    </>
  );
}
