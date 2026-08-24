/**
 * WaitDatePickerSheet —— 自研日历底部抽屉（05 §五 WaitDatePicker 行；M4 Task 15）
 *
 * 三视图（日 ⇄ 年月 ⇄ 年）实现方式结论：react-day-picker v9 的 captionLayout 仅支持
 * label/dropdown 组合，不具备三级视图切换能力，故取「自组头按钮」方案——DayPicker 只承担
 * 日格视图（hideNavigation + 受控 month/onMonthChange），年月/年两视图为自绘网格，
 * 头部中央按钮逐级下钻返回。改动最小且样式完全可控（v9 用法对齐桌面 wait-calendar.tsx）。
 *
 * 规格（05 §五）：36×36 圆格日历（选中实底 accent 白字、今天 1.5px 描边）、
 * 头部相对日期副标题（今天/明天/yyyy-MM-dd）、清除/确认双钮 r10；
 * datetime 模式在日格下方追加 HH:mm 时间行（原生 input[type=time] 样式化）。
 * zhCN locale、周一起始。容器复用 BottomSheet 单档 [.65]（表单抽屉同款档位）。
 */
import { useEffect, useRef, useState } from "react";
import { DayPicker } from "react-day-picker";
import { zhCN } from "date-fns/locale";

import { BottomSheet } from "./bottom-sheet";
import { MaterialIcon } from "./material-icon";

export interface WaitDatePickerSheetProps {
  open: boolean;
  /** date=纯日期；datetime=日格下方追加 HH:mm 时间行 */
  mode?: "date" | "datetime";
  /** 预选毫秒时间戳（打开时重置草稿） */
  initial?: number | null;
  /** 清除恒传 null；确认传所选 Date（未选日期时亦为 null） */
  onConfirm: (date: Date | null) => void;
  onClose: () => void;
}

type ViewKind = "day" | "month" | "year";

/** 年份范围与桌面 wait-calendar 同口径：1900–2100 */
const YEARS_MIN = 1900;
const YEARS_MAX = 2100;

/** yyyy-MM-dd 本地时区 */
function formatYmd(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 头部相对日期副标题（05 §五）：今天/明天/yyyy-MM-dd */
function relativeDayLabel(d: Date): string {
  const startOf = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((startOf(d) - startOf(new Date())) / 86_400_000);
  if (diff === 0) return "今天";
  if (diff === 1) return "明天";
  return formatYmd(d);
}

export function WaitDatePickerSheet({
  open,
  mode = "date",
  initial = null,
  onConfirm,
  onClose,
}: WaitDatePickerSheetProps) {
  const [view, setView] = useState<ViewKind>("day");
  const [draft, setDraft] = useState<Date | null>(null);
  // 日视图受控游标月 / 年月视图年份基准
  const [cursor, setCursor] = useState(() => new Date());
  const [timeStr, setTimeStr] = useState("09:00");
  const yearScrollRef = useRef<HTMLDivElement>(null);

  // 打开时按 initial 重置草稿/游标/时间，并回到日视图
  useEffect(() => {
    if (!open) return;
    const d = initial != null ? new Date(initial) : null;
    setDraft(d);
    setCursor(d ?? new Date());
    const p = (n: number) => String(n).padStart(2, "0");
    setTimeStr(
      d
        ? `${p(d.getHours())}:${p(d.getMinutes())}`
        : `${p(new Date().getHours())}:00`,
    );
    setView("day");
  }, [open, initial]);

  // 年视图展开时滚动定位到当前游标年
  useEffect(() => {
    if (view !== "year") return;
    const el = yearScrollRef.current;
    if (!el) return;
    el.querySelector(`[data-year="${cursor.getFullYear()}"]`)?.scrollIntoView({ block: "center" });
  }, [view, cursor]);

  const shiftMonth = (delta: number) => {
    setCursor((c) => new Date(c.getFullYear(), c.getMonth() + delta, 1));
  };

  /** 确认：date 模式归零时分秒（与列表 today 过滤/逾期判断的零点口径一致）；未选日期恒 null */
  const confirm = () => {
    if (!draft) {
      onConfirm(null);
      onClose();
      return;
    }
    if (mode === "datetime") {
      const [h, m] = timeStr.split(":").map(Number);
      onConfirm(new Date(draft.getFullYear(), draft.getMonth(), draft.getDate(), h || 0, m || 0));
    } else {
      onConfirm(new Date(draft.getFullYear(), draft.getMonth(), draft.getDate()));
    }
    onClose();
  };

  /** 清除 → onConfirm(null)（05 §五 双钮语义） */
  const clear = () => {
    onConfirm(null);
    onClose();
  };

  if (!open) return null;

  const headerCenter =
    view === "day"
      ? `${cursor.getFullYear()}年${cursor.getMonth() + 1}月`
      : view === "month"
        ? `${cursor.getFullYear()}年`
        : "选择年份";

  return (
    <BottomSheet open={open} onClose={onClose} snapPoints={[0.65]}>
      {/* 头部：相对日期副标题 + 三视图中枢按钮 + 日视图左右翻月（05 §五） */}
      <div className="px-2">
        <div className="flex items-center justify-between">
          <span className="w-10 shrink-0" aria-hidden />
          <div className="flex min-w-0 flex-col items-center">
            <span className="text-xs text-[var(--m-sub)]">
              {draft ? relativeDayLabel(draft) : "未选择"}
            </span>
            <button
              type="button"
              className="-mt-0.5 flex items-center gap-0.5 rounded-lg px-2 py-1 text-[17px] font-medium text-[var(--m-text)] active:bg-black/[.04] dark:active:bg-white/[.04]"
              onClick={() => setView(view === "day" ? "month" : view === "month" ? "year" : "day")}
            >
              {headerCenter}
              {view !== "year" && (
                <MaterialIcon name="expand_less_rounded" size={18} color="var(--m-sub)" />
              )}
            </button>
          </div>
          <div className="flex w-10 shrink-0 items-center justify-end">
            {view === "day" ? (
              <>
                <button type="button" aria-label="上个月" className="grid h-10 w-5 place-items-center text-[var(--m-sub)]" onClick={() => shiftMonth(-1)}>
                  <MaterialIcon name="chevron_left_rounded" size={22} />
                </button>
                <button type="button" aria-label="下个月" className="grid h-10 w-5 place-items-center text-[var(--m-sub)]" onClick={() => shiftMonth(1)}>
                  <MaterialIcon name="chevron_right_rounded" size={22} />
                </button>
              </>
            ) : null}
          </div>
        </div>

        {view === "day" && (
          /* 36×36 圆格日历：h-9 w-9 rounded-full；选中实底 accent 白字；今天 1.5px 描边。
             默认文字色由容器继承（day_button 不设色），selected 类才能同权重覆盖 */
          <div className="text-[var(--m-text)]">
            <DayPicker
            mode="single"
            locale={zhCN}
            weekStartsOn={1}
            showOutsideDays={false}
            hideNavigation
            month={cursor}
            onMonthChange={(m) => setCursor(new Date(m.getFullYear(), m.getMonth(), 1))}
            selected={draft ?? undefined}
            onSelect={(d) =>
              setDraft(d ? new Date(d.getFullYear(), d.getMonth(), d.getDate()) : null)
            }
            classNames={{
              months: "w-full",
              month: "w-full",
              month_caption: "hidden",
              month_grid: "mt-1 w-full border-collapse table-fixed",
              weekdays: "w-full",
              weekday: "py-1 text-center text-xs font-normal text-[var(--m-sub)]",
              week: "w-full",
              day: "p-0 text-center align-middle",
              day_button:
                "mx-auto flex h-9 w-9 items-center justify-center rounded-full text-[15px]",
              selected: "bg-[#3B82F6] text-white",
              today: "ring-[1.5px] ring-inset ring-[#3B82F6]",
              outside: "text-[var(--m-sub)] opacity-40",
              disabled: "opacity-40",
              hidden: "invisible",
            }}
          />
          </div>
        )}

        {view === "month" && (
          /* 年月视图：12 月 3 列网格，选中当前游标月高亮 */
          <div className="mx-auto mt-2 grid max-w-sm grid-cols-3 gap-1 px-1 pb-3">
            {Array.from({ length: 12 }, (_, m) => {
              const active = cursor.getFullYear() === (draft?.getFullYear() ?? -1) && m === (draft?.getMonth() ?? -1);
              return (
                <button
                  key={m}
                  type="button"
                  className="h-11 rounded-xl text-[15px] active:bg-black/[.04] dark:active:bg-white/[.04]"
                  style={
                    active
                      ? { background: "color-mix(in srgb, #3B82F6 15%, transparent)", color: "#3B82F6", fontWeight: 500 }
                      : { color: "var(--m-text)" }
                  }
                  onClick={() => {
                    setCursor(new Date(cursor.getFullYear(), m, 1));
                    setView("day");
                  }}
                >
                  {m + 1}月
                </button>
              );
            })}
          </div>
        )}

        {view === "year" && (
          /* 年视图：1900–2100 四列可滚列表，选中当前游标年高亮 */
          <div ref={yearScrollRef} className="mx-auto mt-2 grid max-h-[320px] max-w-sm grid-cols-4 gap-1 overflow-y-auto overscroll-contain px-1 pb-3">
            {Array.from({ length: YEARS_MAX - YEARS_MIN + 1 }, (_, i) => YEARS_MIN + i).map((y) => {
              const active = y === (draft?.getFullYear() ?? -1);
              return (
                <button
                  key={y}
                  type="button"
                  data-year={y}
                  className="h-10 rounded-xl text-[15px] tabular-nums active:bg-black/[.04] dark:active:bg-white/[.04]"
                  style={
                    active
                      ? { background: "color-mix(in srgb, #3B82F6 15%, transparent)", color: "#3B82F6", fontWeight: 500 }
                      : { color: "var(--m-text)" }
                  }
                  onClick={() => {
                    setCursor(new Date(y, cursor.getMonth(), 1));
                    setView("month");
                  }}
                >
                  {y}
                </button>
              );
            })}
          </div>
        )}

        {/* datetime 模式：HH:mm 时间行（原生 input[type=time] 样式化，05 §四 Task 15 约定） */}
        {mode === "datetime" && (
          <div className="mx-2 mt-2 flex items-center justify-between rounded-xl border border-black/[.08] px-3.5 py-2.5 dark:border-white/[.10]">
            <span className="flex items-center gap-2 text-sm text-[var(--m-sub)]">
              <MaterialIcon name="schedule_rounded" size={18} />
              时间
            </span>
            <input
              type="time"
              value={timeStr}
              onChange={(e) => setTimeStr(e.target.value)}
              className="bg-transparent text-right text-[15px] text-[var(--m-text)] outline-none"
            />
          </div>
        )}
      </div>

      {/* 清除/确认双钮 r10（05 §五）：清除→onConfirm(null)；确认→onConfirm(Date|null) */}
      <div className="flex gap-3 px-4 pb-2 pt-4">
        <button
          type="button"
          className="h-10 flex-1 rounded-[10px] border border-black/[.08] text-sm text-[var(--m-sub)] active:bg-black/[.04] dark:border-white/[.10] dark:active:bg-white/[.04]"
          onClick={clear}
        >
          清除
        </button>
        <button
          type="button"
          className="h-10 flex-1 rounded-[10px] text-sm font-medium text-white active:opacity-90"
          style={{ background: "#3B82F6" }}
          onClick={confirm}
        >
          确认
        </button>
      </div>
      {/* 底部安全区/手势条兜底（05 §五） */}
      <div className="m-safe-bottom" aria-hidden />
    </BottomSheet>
  );
}
