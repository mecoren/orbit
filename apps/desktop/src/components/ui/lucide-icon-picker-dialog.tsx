import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { cn } from "@/lib/utils";
import { getIcon, ICON_PICKER_CHOICES } from "@/lib/icon-map";

interface LucideIconPickerDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title?: string;
  /** 当前已选图标名称（PascalCase），无则 undefined */
  currentIcon?: string;
  onConfirm: (iconName: string) => void;
}

export function LucideIconPickerDialog({
  open,
  onOpenChange,
  title = "选择图标",
  currentIcon,
  onConfirm,
}: LucideIconPickerDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>点选一个 Lucide 图标，将存储其名称字符串</DialogDescription>
        </DialogHeader>
        <div className="grid grid-cols-8 gap-1.5">
          {ICON_PICKER_CHOICES.map((name) => {
            const Icon = getIcon(name);
            const isSelected = currentIcon === name;
            return (
              <button
                key={name}
                type="button"
                title={name}
                className={cn(
                  "flex h-9 w-full items-center justify-center rounded-lg transition-all",
                  "hover:scale-105 hover:bg-accent/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2",
                  isSelected
                    ? "bg-accent ring-2 ring-foreground ring-offset-2 ring-offset-background"
                    : "ring-1 ring-black/5 dark:ring-white/10",
                )}
                onClick={() => {
                  onConfirm(name);
                  onOpenChange(false);
                }}
                aria-label={`选择图标 ${name}`}
                aria-pressed={isSelected}
              >
                <Icon className="size-5" />
              </button>
            );
          })}
        </div>
      </DialogContent>
    </Dialog>
  );
}
