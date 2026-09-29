/**
 * CalendarSection — 日历分区（节假日数据：每月自动更新 + 按年补写 + 缓存查看）
 *
 * 口径（对齐 PiggyCount，2026-09-29 修订）：
 * - 自动更新由 Rust 守护执行（**每月一次**：跨月后首次 tick / 首次启动即拉取），
 *   本分区只写总开关；「上次更新」读 `holiday_meta` 记账，与日历页工具栏同源；
 * - 手动「立即更新」拉今年（12 月加明年），无视记账；
 * - 「按年份范围获取」补写 2013 ~ 明年的历史 / 未来年份（分片并发 + 熔断），
 *   逐年进度经 `holiday-progress` 事件回传，可中途取消；
 * - 年份分组标题右侧「更新该年」就地重拉单年（AC-E3）。
 *
 * 每日更新时刻（`holiday_set_fixed_hour`）已随每月口径下线。
 */
import { useMemo, useState } from "react";
import { CalendarDays, Database, Loader2, RefreshCw, X } from "lucide-react";
import { toast } from "sonner";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import {
  HOLIDAY_FETCH_YEAR_MIN,
  holidayFetchRange,
  holidayFetchYear,
  holidayFetchYearMax,
  holidayMeta,
  holidayCancelFetch,
  holidaySetAutoEnabled,
  holidaysList,
  holidaysUpdate,
} from "@/lib/tauri";
import {
  holidayFailedYearsLabel,
  holidayProgressLabel,
  holidayProgressPercent,
  useHolidayProgress,
} from "@/features/todo/shared/use-holiday-progress";
import {
  groupHolidaysByYear,
  summarizeHolidayCache,
  holidayMdLabel,
} from "./calendar-cache-format";

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

export function CalendarSection() {
  const qc = useQueryClient();

  const metaQuery = useQuery({
    queryKey: ["holidays", "meta"],
    queryFn: holidayMeta,
    staleTime: 2 * 60 * 1000,
  });
  const autoEnabled = metaQuery.data?.auto_enabled ?? true;
  const lastUpdate = metaQuery.data?.last_update_ms ?? 0;

  const autoMutation = useMutation({
    mutationFn: (enabled: boolean) => holidaySetAutoEnabled(enabled),
    onSuccess: (_void, enabled) => {
      toast.success(
        enabled
          ? "已开启每月自动更新"
          : "已关闭自动更新（仍可手动更新与按年份补写）",
      );
      void qc.invalidateQueries({ queryKey: ["holidays"] });
    },
    onError: (e) => toast.error(String(e)),
  });

  const listQuery = useQuery({
    queryKey: ["holidays", "list"],
    queryFn: holidaysList,
    staleTime: 2 * 60 * 1000,
  });
  const cache = listQuery.data ?? [];
  const summary = summarizeHolidayCache(cache);
  const groups = groupHolidaysByYear(cache);

  const [updatingCache, setUpdatingCache] = useState(false);
  const [fetchingYear, setFetchingYear] = useState<number | null>(null);
  const [rangeBusy, setRangeBusy] = useState(false);
  const { progress, failedYears, clear: clearProgress } = useHolidayProgress();

  /** 可选年份：2013 ~ 明年（下界 = 数据源实测有数据的最早年份） */
  const yearOptions = useMemo(() => {
    const max = holidayFetchYearMax();
    const out: number[] = [];
    for (let y = HOLIDAY_FETCH_YEAR_MIN; y <= max; y += 1) out.push(y);
    return out;
  }, []);
  const [rangeStart, setRangeStart] = useState<number>(() =>
    Math.max(HOLIDAY_FETCH_YEAR_MIN, new Date().getFullYear()),
  );
  const [rangeEnd, setRangeEnd] = useState<number>(() => holidayFetchYearMax());

  const refreshCache = async () => {
    setUpdatingCache(true);
    try {
      await holidaysUpdate();
      await qc.invalidateQueries({ queryKey: ["holidays"] });
      toast.success("节假日数据已更新");
    } catch (err) {
      toast.error(`节假日更新失败：${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setUpdatingCache(false);
    }
  };

  /** 单年补写（分组标题「更新该年」；AC-E7：空响应提示「无数据」而非报错） */
  const fetchOneYear = async (year: number) => {
    if (fetchingYear !== null) return;
    setFetchingYear(year);
    try {
      const outcome = await holidayFetchYear(year);
      await qc.invalidateQueries({ queryKey: ["holidays"] });
      if (outcome.row_count === 0) {
        toast.message(`${year} 年线上无数据`);
      } else {
        toast.success(`${year} 年数据已更新（${outcome.row_count} 条）`);
      }
    } catch (err) {
      toast.error(`${year} 年更新失败：${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setFetchingYear(null);
    }
  };

  /** 范围补写（起止年份自动排序；进度经事件回传，可取消） */
  const fetchRange = async () => {
    if (rangeBusy) return;
    const start = Math.min(rangeStart, rangeEnd);
    const end = Math.max(rangeStart, rangeEnd);
    setRangeBusy(true);
    try {
      const summary = await holidayFetchRange(start, end);
      await qc.invalidateQueries({ queryKey: ["holidays"] });
      if (summary.cancelled) {
        toast.message("已取消范围更新（已完成的年份保留）");
      } else if (summary.failed > 0) {
        // 部分成功不是错误：如实报出三个计数 + 失败年份（warning 级，非 error）
        const parts = [`成功 ${summary.ok} 年`, `失败 ${summary.failed} 年`];
        if (summary.empty > 0) parts.push(`无数据 ${summary.empty} 年`);
        const failedLabel = holidayFailedYearsLabel(failedYears);
        toast.warning(`范围更新完成：${parts.join(" · ")}`, {
          description: failedLabel
            ? `失败年份：${failedLabel}（沿用原缓存）`
            : "失败年份沿用原缓存",
        });
      } else if (summary.empty > 0) {
        toast.success(
          `范围更新完成：成功 ${summary.ok}（其中 ${summary.empty} 年线上无数据）`,
        );
      } else {
        toast.success(`范围更新完成：成功 ${summary.ok}`);
      }
    } catch (err) {
      toast.error(`范围更新失败：${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setRangeBusy(false);
    }
  };

  const cancelRange = () => {
    void holidayCancelFetch();
  };

  const pct = holidayProgressPercent(progress);

  return (
    <div className="space-y-4">
      <SectionHeader title="日历" desc="节假日数据的联网更新" />

      <div className="space-y-4 rounded-lg border p-5">
        <div className="flex items-start gap-3">
          <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-muted">
            <CalendarDays className="size-4 text-muted-foreground" />
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-sm font-medium">每月自动更新</p>
            <p className="text-xs text-muted-foreground">
              日历中的放假/调休数据每月联网更新一次（跨月后首次启动即拉取），
              也可在日历页手动更新
            </p>
          </div>
          <Switch
            checked={autoEnabled}
            disabled={metaQuery.isLoading || autoMutation.isPending}
            onCheckedChange={(v) => autoMutation.mutate(v)}
            aria-label="节假日每月自动更新开关"
          />
        </div>

        <p className="text-xs text-muted-foreground">
          {lastUpdate > 0
            ? `上次更新：${new Date(lastUpdate).toLocaleString()}`
            : "尚未成功更新过"}
        </p>

        <p className="text-xs text-muted-foreground">
          提示：关闭自动更新后仍可手动更新与按年份补写；本机设置，不随云同步。
        </p>
      </div>

      <div className="space-y-4 rounded-lg border p-5">
        <div className="flex items-center gap-3">
          <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-muted">
            <Database className="size-4 text-muted-foreground" />
          </div>
          <div>
            <p className="text-sm font-medium">数据缓存</p>
            <p className="text-xs text-muted-foreground">
              本地已缓存的放假/调休数据（未缓存的年份回落内置表，日历照常显示徽标）
            </p>
          </div>
        </div>

        {listQuery.isLoading ? (
          <p className="text-xs text-muted-foreground">缓存加载中…</p>
        ) : listQuery.isError ? (
          <p className="text-xs text-muted-foreground">缓存加载失败</p>
        ) : summary.total === 0 ? (
          <p className="text-xs text-muted-foreground">暂无节假日缓存</p>
        ) : (
          <p className="text-xs text-muted-foreground">
            共 {summary.total} 条（放假 {summary.offDays} · 补班 {summary.workdays}）·
            覆盖年份 {summary.years.join("、")}
          </p>
        )}

        <div className="flex flex-wrap items-center gap-3">
          <button
            type="button"
            onClick={refreshCache}
            disabled={updatingCache}
            className="inline-flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-xs font-medium hover:bg-accent disabled:opacity-50"
          >
            {updatingCache ? (
              <Loader2 className="size-3.5 animate-spin" />
            ) : (
              <RefreshCw className="size-3.5" />
            )}
            {updatingCache ? "更新中…" : "立即更新"}
          </button>

          <span className="text-muted-foreground/40">|</span>

          <span className="text-xs text-muted-foreground">按年份范围获取</span>
          <Select
            value={String(rangeStart)}
            onValueChange={(v) => setRangeStart(Number(v))}
            disabled={rangeBusy}
          >
            <SelectTrigger className="w-24" aria-label="起始年份">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {yearOptions.map((y) => (
                <SelectItem key={y} value={String(y)}>
                  {y}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <span className="text-xs text-muted-foreground">至</span>
          <Select
            value={String(rangeEnd)}
            onValueChange={(v) => setRangeEnd(Number(v))}
            disabled={rangeBusy}
          >
            <SelectTrigger className="w-24" aria-label="结束年份">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {yearOptions.map((y) => (
                <SelectItem key={y} value={String(y)}>
                  {y}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <button
            type="button"
            onClick={() => void fetchRange()}
            disabled={rangeBusy}
            className="inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
          >
            {rangeBusy ? (
              <Loader2 className="size-3.5 animate-spin" />
            ) : (
              <CalendarDays className="size-3.5" />
            )}
            {rangeBusy ? "获取中…" : "获取"}
          </button>
        </div>

        {(rangeBusy || progress) && (
          <div className="space-y-2 rounded-md border bg-muted/40 p-3">
            <div className="flex items-center justify-between gap-3">
              <span className="text-xs">
                {holidayProgressLabel(progress) || "准备中…"}
              </span>
              {rangeBusy ? (
                <button
                  type="button"
                  onClick={cancelRange}
                  className="inline-flex items-center gap-1 rounded-md border px-2 py-1 text-xs hover:bg-accent"
                >
                  <X className="size-3" />
                  取消
                </button>
              ) : (
                <button
                  type="button"
                  onClick={clearProgress}
                  className="rounded-md border px-2 py-1 text-xs hover:bg-accent"
                >
                  收起
                </button>
              )}
            </div>
            <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
              <div
                className={
                  "h-full rounded-full bg-primary transition-all duration-slow ease-out" +
                  (pct === null ? " animate-pulse" : "")
                }
                style={{ width: pct === null ? "100%" : `${pct}%` }}
              />
            </div>
          </div>
        )}

        {summary.total > 0 && (
          <div className="space-y-2">
            {groups.map((g) => (
              <details key={g.year} open={g.year === summary.years[0]}>
                <summary className="flex cursor-pointer items-center justify-between gap-2 text-sm font-medium">
                  <span>
                    {g.year} 年（{g.items.length} 条）
                  </span>
                  <button
                    type="button"
                    title={`更新 ${g.year} 年`}
                    aria-label={`更新 ${g.year} 年`}
                    disabled={fetchingYear !== null}
                    onClick={(e) => {
                      e.preventDefault();
                      void fetchOneYear(g.year);
                    }}
                    className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-xs font-normal text-muted-foreground hover:bg-accent disabled:opacity-50"
                  >
                    {fetchingYear === g.year ? (
                      <Loader2 className="size-3 animate-spin" />
                    ) : (
                      <RefreshCw className="size-3" />
                    )}
                    更新该年
                  </button>
                </summary>
                <ul className="mt-1 space-y-1 pl-1">
                  {g.items.map((h) => (
                    <li key={h.date} className="flex items-center gap-2 text-xs">
                      <span className="w-14 shrink-0 tabular-nums text-muted-foreground">
                        {holidayMdLabel(h.date)}
                      </span>
                      <span
                        className="inline-flex size-4 shrink-0 items-center justify-center rounded text-[10px] font-semibold text-white"
                        style={{
                          backgroundColor: h.is_holiday ? "#4C7DF0" : "#FF7043",
                        }}
                        title={h.name}
                      >
                        {h.is_holiday ? "休" : "班"}
                      </span>
                      <span className="truncate">{h.name}</span>
                    </li>
                  ))}
                </ul>
              </details>
            ))}
          </div>
        )}

        <p className="text-xs text-muted-foreground">
          联网拉取整年数据（2013 ~ 明年），单年失败自动跳过、连续失败即中止；
          失败时旧缓存保留。
        </p>
      </div>
    </div>
  );
}
