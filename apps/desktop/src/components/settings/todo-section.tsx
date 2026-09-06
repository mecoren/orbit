/**
 * 待办分区（回收站落地：保留时间档位设置）
 *
 * 保留档位存 cfg_kv（trash_retention_days，Rust 侧守卫/展示的单一数据源）：
 * 7 天 / 30 天（默认）/ 90 天 / 永久。TTL 自动清理由 Rust 守护执行，
 * 切换档位即时生效（下一轮 tick 按新档位判定）。
 */
import { useState } from "react";
import { toast } from "sonner";
import { Trash2 } from "lucide-react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { trashMeta, trashSetRetentionDays } from "@/lib/tauri";

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

/** 档位 pill（与主题分区同规格） */
const PILL_CLS = "h-7 px-3";

const CHOICES: { days: number; label: string }[] = [
  { days: 7, label: "7 天" },
  { days: 30, label: "30 天" },
  { days: 90, label: "90 天" },
  { days: 0, label: "永久" },
];

export function TodoSection() {
  const qc = useQueryClient();
  const [pending, setPending] = useState<number | null>(null);

  const metaQuery = useQuery({
    queryKey: ["trash", "meta"],
    queryFn: trashMeta,
    staleTime: 2 * 60 * 1000,
  });
  const retention = metaQuery.data?.retention_days ?? 30;

  const saveMutation = useMutation({
    mutationFn: (days: number) => trashSetRetentionDays(days),
    onSuccess: (_void, days) => {
      toast.success(days === 0 ? "回收站已设为永久保留" : `保留时间已设为 ${days} 天`);
      void qc.invalidateQueries({ queryKey: ["trash"] });
      setPending(null);
    },
    onError: (e) => {
      toast.error(String(e));
      setPending(null);
    },
  });

  return (
    <div className="space-y-4">
      <SectionHeader title="待办" desc="删除行为与回收站保留时间" />

      <div className="space-y-4 rounded-lg border p-5">
        <div className="flex items-center gap-3">
          <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-muted">
            <Trash2 className="size-4 text-muted-foreground" />
          </div>
          <div>
            <p className="text-sm font-medium">回收站保留时间</p>
            <p className="text-xs text-muted-foreground">
              删除的任务进入回收站，超过保留时间后自动清除
            </p>
          </div>
        </div>

        <div className="flex gap-1.5">
          {CHOICES.map(({ days, label }) => {
            const active = retention === days;
            const saving = pending === days;
            return (
              <Button
                key={days}
                size="sm"
                variant={active ? "default" : "outline"}
                className={cn(PILL_CLS, "flex-1 px-2")}
                disabled={saveMutation.isPending}
                onClick={() => {
                  if (active) return;
                  setPending(days);
                  saveMutation.mutate(days);
                }}
              >
                {saving ? "保存中…" : label}
              </Button>
            );
          })}
        </div>

        <p className="text-xs text-muted-foreground">
          提示：保留时间为本机设置，不随云同步；启用云同步时，自动清除仅对已同步到
          云端的删除生效，避免其他设备把任务误恢复回来。
        </p>
      </div>
    </div>
  );
}
