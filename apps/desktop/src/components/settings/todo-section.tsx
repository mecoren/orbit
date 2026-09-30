/**
 * 待办分区（回收站保留时间 + 描述悬浮预览 + 每日摘要提醒）
 *
 * - 保留档位存 cfg_kv（trash_retention_days，Rust 侧守卫/展示的单一数据源）：
 *   7 天 / 30 天（默认）/ 90 天 / 永久。TTL 自动清理由 Rust 守护执行，
 *   切换档位即时生效（下一轮 tick 按新档位判定）。
 * - 描述悬浮预览存 localStorage 本机视图态（desc_preview_enabled /
 *   desc_preview_delay，默认开启 + 0.8s 防呆延迟），不随云同步。
 * - 每日摘要提醒（G3）存 cfg_kv（digest_enabled / digest_time）：到点由 Rust
 *   守护（60s tick）发一条汇总系统通知。通知文案由 Rust 侧 summary_body
 *   生成（与移动端同一份实现），本卡只做计数预览。
 */
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { BellRing, Trash2 } from "lucide-react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { TimeHMSelect as SharedTimeHMSelect } from "@/components/business/time-hm-select";
import {
  digestPrefs,
  digestSetPrefs,
  digestSummary,
  trashMeta,
  trashSetRetentionDays,
} from "@/lib/tauri";
import {
  DESC_PREVIEW_DELAY_CHOICES,
  DESC_PREVIEW_DELAY_DEFAULT,
  getDescPreviewDelayMs,
  getDescPreviewEnabled,
  setDescPreviewDelayMs,
  setDescPreviewEnabled,
} from "@/features/todo/shared/desc-preview-pref";

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

  // 描述悬浮预览（本机 localStorage，非同步配置）
  const [previewEnabled, setPreviewEnabled] = useState(true);
  const [previewDelay, setPreviewDelay] = useState(DESC_PREVIEW_DELAY_DEFAULT);

  useEffect(() => {
    setPreviewEnabled(getDescPreviewEnabled());
    setPreviewDelay(getDescPreviewDelayMs());
  }, []);

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
      <SectionHeader
        title="待办"
        desc="删除行为、回收站保留时间与每日摘要提醒"
      />

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

      <div className="space-y-4 rounded-lg border p-5">
        <div className="flex items-center gap-3">
          <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-muted">
            <Trash2 className="size-4 text-muted-foreground" />
          </div>
          <div>
            <p className="text-sm font-medium">描述悬浮预览</p>
            <p className="text-xs text-muted-foreground">
              详情页描述过长被截断时，鼠标停留后弹出全量预览浮层
            </p>
          </div>
        </div>

        <div className="flex items-center gap-3">
          <Switch
            checked={previewEnabled}
            onCheckedChange={(v) => {
              setPreviewEnabled(v);
              setDescPreviewEnabled(v);
              toast.success(v ? "已开启描述悬浮预览" : "已关闭描述悬浮预览");
            }}
            aria-label="描述悬浮预览开关"
          />
          <Select
            value={String(previewDelay)}
            onValueChange={(v) => {
              const ms = Number(v);
              setPreviewDelay(ms);
              setDescPreviewDelayMs(ms);
            }}
            disabled={!previewEnabled}
          >
            <SelectTrigger className="w-36" aria-label="悬浮预览延迟">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {DESC_PREVIEW_DELAY_CHOICES.map(({ ms, label }) => (
                <SelectItem key={ms} value={String(ms)}>
                  {label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <span className="text-xs text-muted-foreground">停留时长达到后预览</span>
        </div>

        <p className="text-xs text-muted-foreground">
          提示：仅对被高度上限截断的描述生效；本机设置，不随云同步。
        </p>
      </div>

      <DigestCard />
    </div>
  );
}

/** 每日摘要提醒（G3，对标 TickTick Daily Reminder） */
function DigestCard() {
  const qc = useQueryClient();

  const prefsQuery = useQuery({
    queryKey: ["digest", "prefs"],
    queryFn: digestPrefs,
    staleTime: 2 * 60 * 1000,
  });
  // 计数预览：进入设置页拉一次当前口径（「今天会提醒什么」）
  const summaryQuery = useQuery({
    queryKey: ["digest", "summary"],
    queryFn: digestSummary,
    staleTime: 60 * 1000,
  });

  const prefs = prefsQuery.data;
  const enabled = prefs?.enabled ?? false;
  const hh = String(prefs?.hour ?? 8).padStart(2, "0");
  const mm = String(prefs?.minute ?? 0).padStart(2, "0");

  const saveMutation = useMutation({
    mutationFn: (next: { enabled: boolean; hour: number; minute: number }) =>
      digestSetPrefs(next.enabled, next.hour, next.minute),
    onSuccess: (_void, next) => {
      toast.success(
        next.enabled
          ? `已开启每日摘要提醒（每天 ${String(next.hour).padStart(2, "0")}:${String(next.minute).padStart(2, "0")}）`
          : "已关闭每日摘要提醒",
      );
      void qc.invalidateQueries({ queryKey: ["digest"] });
    },
    onError: (e) => toast.error(String(e)),
  });

  const preview = summaryQuery.data;
  const previewText = preview
    ? `今日截止 ${preview.due_today} · 逾期 ${preview.overdue} · 今日已完成 ${preview.done_today}`
    : "统计中…";

  return (
    <div className="space-y-4 rounded-lg border p-5">
      <div className="flex items-center gap-3">
        <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-muted">
          <BellRing className="size-4 text-muted-foreground" />
        </div>
        <div>
          <p className="text-sm font-medium">每日摘要提醒</p>
          <p className="text-xs text-muted-foreground">
            每天固定时刻一条汇总通知，回顾今天的待办与逾期
          </p>
        </div>
      </div>

      <div className="flex items-center gap-3">
        <Switch
          checked={enabled}
          disabled={saveMutation.isPending || prefs == null}
          onCheckedChange={(v) =>
            saveMutation.mutate({
              enabled: v,
              hour: prefs?.hour ?? 8,
              minute: prefs?.minute ?? 0,
            })
          }
          aria-label="每日摘要提醒开关"
        />
        <SharedTimeHMSelect
          hour={hh}
          minute={mm}
          hourSuffix="时"
          minuteSuffix="分"
          hourInputId="digest-hour"
          disabled={!enabled || saveMutation.isPending || prefs == null}
          onHourChange={(h) =>
            saveMutation.mutate({ enabled, hour: Number(h), minute: Number(mm) })
          }
          onMinuteChange={(m) =>
            saveMutation.mutate({ enabled, hour: Number(hh), minute: Number(m) })
          }
        />
        <span className="text-xs text-muted-foreground">每天此刻提醒</span>
      </div>

      <p className="text-xs text-muted-foreground">
        当前口径预览：{previewText}（通知文案由 Rust 侧统一生成；同一天只提醒一次，
        迟到超过 12 小时则静默跳过当天）。
      </p>

      <p className="text-xs text-muted-foreground">
        提示：本机设置，不随云同步；应用需在提醒时刻附近运行（错过时刻当天内仍会补发）。
      </p>
    </div>
  );
}
