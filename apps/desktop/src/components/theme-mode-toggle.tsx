import {
  forwardRef,
  useEffect,
  useState,
  type ComponentPropsWithoutRef,
} from "react";
import { Moon, Sun, Monitor } from "lucide-react";

import {
  type ThemeMode,
  getStoredThemeMode,
  setThemeMode,
} from "@/lib/color-theme";
import { cn } from "@/lib/utils";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

const MODE_CYCLE: ThemeMode[] = ["system", "light", "dark"];

const MODE_ICONS: Record<ThemeMode, typeof Sun> = {
  light: Sun,
  dark: Moon,
  system: Monitor,
};

const MODE_LABELS: Record<ThemeMode, string> = {
  light: "浅色",
  dark: "深色",
  system: "跟随系统",
};

export interface ThemeModeToggleProps
  extends Omit<ComponentPropsWithoutRef<"button">, "onClick"> {
  variant?: "default" | "ghost" | "sidebar";
}

export const ThemeModeToggle = forwardRef<
  HTMLButtonElement,
  ThemeModeToggleProps
>(function ThemeModeToggle({ className, variant = "ghost", ...props }, ref) {
  const [mode, setMode] = useState<ThemeMode>(() => getStoredThemeMode());

  useEffect(() => {
    const handleStorage = (e: StorageEvent) => {
      if (e.key === "theme_mode") {
        setMode(getStoredThemeMode());
      }
    };
    window.addEventListener("storage", handleStorage);
    return () => window.removeEventListener("storage", handleStorage);
  }, []);

  const handleClick = () => {
    const nextIndex = (MODE_CYCLE.indexOf(mode) + 1) % MODE_CYCLE.length;
    const next = MODE_CYCLE[nextIndex];
    setMode(next);
    setThemeMode(next);
  };

  const Icon = MODE_ICONS[mode];
  const label = MODE_LABELS[mode];

  if (variant === "sidebar") {
    return (
      <button
        ref={ref}
        type="button"
        onClick={handleClick}
        className={cn(
          "flex w-full items-center gap-3 rounded-md px-2 py-1.5 text-sm text-sidebar-foreground transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
          className,
        )}
        {...props}
      >
        <span className="flex size-4 shrink-0 items-center justify-center">
          <Icon className="size-4" />
        </span>
        <span className="truncate">{label}</span>
      </button>
    );
  }

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          ref={ref}
          type="button"
          onClick={handleClick}
          className={cn(
            "flex items-center justify-center rounded-md text-sm text-foreground transition-colors",
            "hover:bg-accent hover:text-accent-foreground",
            "focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring",
            "h-8 w-8",
            className,
          )}
          {...props}
        >
          <Icon className="size-4" />
        </button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  );
});
