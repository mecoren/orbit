/**
 * CalendarSection — 日历分区（节假日数据每日更新时刻）
 *
 * 背景：桥位 `holiday_set_fixed_hour` 早已注册（`commands/holiday_cmd.rs`、`lib/tauri.ts`
 * 也有包装）但 UI 零消费——每日自动更新时刻只能吃 core 缺省 08:00，用户想按自己的
 * 开机时间调整没有出口（错过时刻虽会在下次启动补更）。本分区把它交给用户，与移动端
 * 设置页「日历与节假日」卡同口径（docs/07 #60）。
 *
 * 口径：日程由 Rust 守护执行（每日固定时刻一次 + 错过补更），本分区只写配置；
 * 「上次更新」读 `holiday_meta` 记账，与日历页工具栏共用同一份服务端真值。
 */
import { CalendarDays } from "lucide-react";
import { toast } from "sonner";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { holidayMeta, holidaySetFixedHour } from "@/lib/tauri";

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

/** 0-23 整点候选 */
const HOURS = Array.from({ length: 24 }, (_, h) => h);

/** 整点文案（HH:00，与移动端同口径） */
export const holidayHourLabel = (h: number) => `${String(h).padStart(2, "0")}:00`;

export function CalendarSection() {
  const qc = useQueryClient();

  const metaQuery = useQuery({
    queryKey: ["holidays", "meta"],
    queryFn: holidayMeta,
    staleTime: 2 * 60 * 1000,
  });
  const fixedHour = metaQuery.data?.fixed_hour ?? 8;
  const lastUpdate = metaQuery.data?.last_update_ms ?? 0;

  const saveMutation = useMutation({
    mutationFn: (hour: number) => holidaySetFixedHour(hour),
    onSuccess: (_void, hour) => {
      toast.success(`节假日每日更新时刻已设为 ${holidayHourLabel(hour)}`);
      void qc.invalidateQueries({ queryKey: ["holidays"] });
    },
    onError: (e) => toast.error(String(e)),
  });

  return (
    <div className="space-y-4">
      <SectionHeader title="日历" desc="节假日数据的联网更新" />

      <div className="space-y-4 rounded-lg border p-5">
        <div className="flex items-center gap-3">
          <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-muted">
            <CalendarDays className="size-4 text-muted-foreground" />
          </div>
          <div>
            <p className="text-sm font-medium">每日更新时刻</p>
            <p className="text-xs text-muted-foreground">
              日历中的放假/调休数据每天联网更新一次，也可在日历页手动更新
            </p>
          </div>
        </div>

        <div className="flex items-center gap-3">
          <Select
            value={String(fixedHour)}
            onValueChange={(v) => saveMutation.mutate(Number(v))}
            disabled={saveMutation.isPending}
          >
            <SelectTrigger className="w-28" aria-label="节假日每日更新时刻">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {HOURS.map((h) => (
                <SelectItem key={h} value={String(h)}>
                  {holidayHourLabel(h)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <span className="text-xs text-muted-foreground">
            {lastUpdate > 0
              ? `上次更新：${new Date(lastUpdate).toLocaleString()}`
              : "尚未成功更新过"}
          </span>
        </div>

        <p className="text-xs text-muted-foreground">
          提示：错过设定时刻会在下次启动时补更；本机设置，不随云同步。
        </p>
      </div>
    </div>
  );
}
