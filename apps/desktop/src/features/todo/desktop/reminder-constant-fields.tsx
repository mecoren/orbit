/**
 * reminder-constant-fields —— 「持续提醒」开关 + 间隔档位（详情/新建抽屉共用）
 *
 * 两个抽屉此前各写一份开关行；加间隔档位后抽成一个部件，避免三处漂移
 * （详情编辑既有行 / 详情新增行 / 新建抽屉）。档位走 shadcn Select 原语，
 * 关闭持续提醒时整行隐藏（一次性提醒没有间隔语义）。
 */

import { Switch } from "@/components/ui/switch";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  constantIntervalOptions,
  formatConstantInterval,
} from "../shared/constant-interval";

export function ReminderConstantFields({
  enabled,
  intervalMs,
  onEnabledChange,
  onIntervalChange,
}: {
  enabled: boolean;
  /** 当前间隔（毫秒；调用方保证已经过 normalizeConstantIntervalMs） */
  intervalMs: number;
  onEnabledChange: (v: boolean) => void;
  onIntervalChange: (ms: number) => void;
}) {
  return (
    <div className="space-y-1.5">
      <label className="flex cursor-pointer items-center justify-between gap-2 text-xs text-muted-foreground">
        <span>持续提醒（响到完成为止）</span>
        <Switch
          checked={enabled}
          onCheckedChange={onEnabledChange}
          aria-label="持续提醒"
        />
      </label>
      {enabled && (
        <label className="flex items-center justify-between gap-2 text-xs text-muted-foreground">
          <span>提醒间隔</span>
          <Select
            value={String(intervalMs)}
            onValueChange={(v) => onIntervalChange(Number(v))}
          >
            <SelectTrigger
              size="sm"
              className="w-28 text-xs"
              aria-label="提醒间隔"
            >
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {constantIntervalOptions(intervalMs).map((ms) => (
                <SelectItem key={ms} value={String(ms)} className="text-xs">
                  {formatConstantInterval(ms)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </label>
      )}
    </div>
  );
}
