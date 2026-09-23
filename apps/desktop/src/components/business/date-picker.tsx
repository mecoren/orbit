import { useState, useMemo, useEffect } from "react";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Button } from "@/components/ui/button";
import { TimeHMSelect } from "@/components/business/time-hm-select";
import { PickerCalendar } from "@/components/business/picker-calendar";
import { QuickDateMenu } from "@/components/business/quick-date-options";
import { CalendarIcon, ChevronLeft, ChevronRight, X } from "lucide-react";
import { format, parse, isValid } from "date-fns";
import { cn } from "@/lib/utils";

interface DatePickerProps {
  value: string; // YYYY-MM-DD 或空字符串
  onChange: (v: string) => void;
  placeholder?: string;
  disabled?: boolean;
  /** 弹层首选快捷选项（今天/明天/下周）；false 直接展示日历（如年月精度复合选择器） */
  quick?: boolean;
  /** 触发钮附加类（行内小尺寸场景，如 h-7 px-2 text-xs） */
  className?: string;
}

export function DatePicker({
  value,
  onChange,
  placeholder = "选择日期",
  disabled,
  quick = true,
  className,
}: DatePickerProps) {
  const [open, setOpen] = useState(false);
  // 快捷菜单 ⇄ 完整日历视图切换；关闭弹层时复位为快捷视图
  const [showCalendar, setShowCalendar] = useState(false);
  useEffect(() => {
    if (!open) setShowCalendar(false);
  }, [open]);
  const selectedDate = useMemo(() => {
    if (!value) return undefined;
    const d = parse(value, "yyyy-MM-dd", new Date());
    return isValid(d) ? d : undefined;
  }, [value]);

  const handleSelect = (d: Date | undefined) => {
    if (d && isValid(d)) {
      onChange(format(d, "yyyy-MM-dd"));
    } else {
      onChange("");
    }
    setOpen(false);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <div className="relative w-full">
        <PopoverTrigger asChild>
          <Button
            variant="outline"
            disabled={disabled}
            className={cn(
              "w-full justify-start text-left font-normal",
              value && "pr-8",
              !value && "text-muted-foreground",
              className,
            )}
          >
            <CalendarIcon className="size-4" />
            {value || <span>{placeholder}</span>}
          </Button>
        </PopoverTrigger>
        {value && !disabled && (
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="absolute right-1 top-1/2 size-6 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onChange("");
            }}
            aria-label="清空"
          >
            <X className="size-3" />
          </Button>
        )}
      </div>
      <PopoverContent
        className="w-auto min-w-[var(--radix-popover-trigger-width)] p-0"
        align="start"
      >
        {quick && !showCalendar ? (
          <QuickDateMenu
            kind="date"
            value={value}
            onSelect={(d) => {
              onChange(format(d, "yyyy-MM-dd"));
              setOpen(false);
            }}
            customLabel="选择日期"
            onCustom={() => setShowCalendar(true)}
          />
        ) : (
          <div className="p-3">
            <PickerCalendar selected={selectedDate} onSelect={handleSelect} />
          </div>
        )}
      </PopoverContent>
    </Popover>
  );
}

interface DateTimePickerProps {
  value: string; // YYYY-MM-DDTHH:MM 或空字符串
  onChange: (v: string) => void;
  placeholder?: string;
  disabled?: boolean;
  /** 弹层首选快捷选项（一小时后/今天晚些时候/明天/下周）；false 直接展示日历+时间 */
  quick?: boolean;
  /**
   * 任务截止日期（ms）：仅**提醒时间**字段传，弹层多给一组「相对截止」档
   * （截止当天 09:00 / 前推 1 小时·30·15 分钟）；截止日期字段自身不要传
   */
  dueDateMs?: number | null;
}

export function DateTimePicker({
  value,
  onChange,
  placeholder = "选择日期时间",
  disabled,
  quick = true,
  dueDateMs,
}: DateTimePickerProps) {
  const [open, setOpen] = useState(false);
  // 快捷菜单 ⇄ 完整日历+时间视图切换；关闭弹层时复位为快捷视图
  const [showCalendar, setShowCalendar] = useState(false);
  useEffect(() => {
    if (!open) setShowCalendar(false);
  }, [open]);

  const { datePart, hourPart, minutePart } = useMemo(() => {
    if (!value) return { datePart: "", hourPart: "0", minutePart: "0" };
    // 兼容 YYYY-MM-DDTHH:MM 与 YYYY-MM-DD HH:MM 两种分隔
    const normalized = value.replace(" ", "T");
    const [d, t] = normalized.split("T");
    const [h, m] = (t ?? "0:0").split(":");
    return { datePart: d ?? "", hourPart: h ?? "0", minutePart: m ?? "0" };
  }, [value]);

  const selectedDate = useMemo(() => {
    if (!datePart) return undefined;
    const d = parse(datePart, "yyyy-MM-dd", new Date());
    return isValid(d) ? d : undefined;
  }, [datePart]);

  const updateValue = (newDate: string, newHour: string, newMinute: string) => {
    if (!newDate) {
      onChange("");
      return;
    }
    const h = newHour.padStart(2, "0");
    const m = newMinute.padStart(2, "0");
    onChange(`${newDate}T${h}:${m}`);
  };

  const handleSelect = (d: Date | undefined) => {
    if (d && isValid(d)) {
      updateValue(format(d, "yyyy-MM-dd"), hourPart, minutePart);
    } else {
      onChange("");
    }
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <div className="relative w-full min-w-[13rem]">
        <PopoverTrigger asChild>
          <Button
            variant="outline"
            disabled={disabled}
            className={cn(
              "w-full justify-start text-left font-normal",
              value && "pr-9",
              !value && "text-muted-foreground"
            )}
          >
            <CalendarIcon className="size-4" />
            {value ? value.replace("T", " ") : <span>{placeholder}</span>}
          </Button>
        </PopoverTrigger>
        {value && !disabled && (
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="absolute right-1 top-1/2 size-6 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onChange("");
            }}
            aria-label="清空"
          >
            <X className="size-3" />
          </Button>
        )}
      </div>
      <PopoverContent
        className="w-auto min-w-[var(--radix-popover-trigger-width)] p-0"
        align="start"
      >
        {quick && !showCalendar ? (
          <QuickDateMenu
            kind="datetime"
            value={value}
            dueDateMs={dueDateMs}
            onSelect={(d) => {
              onChange(format(d, "yyyy-MM-dd'T'HH:mm"));
              setOpen(false);
            }}
            customLabel="选择日期和时间"
            onCustom={() => setShowCalendar(true)}
          />
        ) : (
          <>
            <div className="p-3 pb-0">
              <PickerCalendar selected={selectedDate} onSelect={handleSelect} />
            </div>
            <div className="flex items-center gap-2 border-t p-3">
              <span className="text-xs text-muted-foreground">时间</span>
              {/* 手输 + 下拉二合一（内联列表无 portal，可驻 PopoverContent 内） */}
              <TimeHMSelect
                hour={hourPart.padStart(2, "0")}
                minute={minutePart.padStart(2, "0")}
                onHourChange={(h) => updateValue(datePart, h, minutePart.padStart(2, "0"))}
                onMinuteChange={(m) => updateValue(datePart, hourPart.padStart(2, "0"), m)}
              />
            </div>
          </>
        )}
      </PopoverContent>
    </Popover>
  );
}

interface MonthPickerProps {
  value: string; // YYYY-MM 或空字符串
  onChange: (v: string) => void;
  placeholder?: string;
  disabled?: boolean;
}

/**
 * 仅精确到「年-月」的日期选择器（我们的自有组件，非原生 input）。
 *
 * 弹出面板内展示年份切换 + 12 个月网格，选中即确认，返回格式固定为 "YYYY-MM"，
 * 与移动端 WaitDatePicker(month) 存储格式一致。
 */
export function MonthPicker({
  value,
  onChange,
  placeholder = "选择月份",
  disabled,
}: MonthPickerProps) {
  const [open, setOpen] = useState(false);
  const selected = useMemo(() => {
    if (!value || !/^\d{4}-\d{2}$/.test(value)) return null;
    const [y, m] = value.split("-").map(Number);
    return { year: y, month: m };
  }, [value]);
  const [viewYear, setViewYear] = useState<number>(
    selected?.year ?? new Date().getFullYear(),
  );

  const handleSelect = (month: number) => {
    const mm = String(month).padStart(2, "0");
    onChange(`${viewYear}-${mm}`);
    setOpen(false);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <div className="relative w-full">
        <PopoverTrigger asChild>
          <Button
            variant="outline"
            disabled={disabled}
            className={cn(
              "w-full justify-start text-left font-normal",
              value && "pr-8",
              !value && "text-muted-foreground",
            )}
          >
            <CalendarIcon className="size-4" />
            {value || <span>{placeholder}</span>}
          </Button>
        </PopoverTrigger>
        {value && !disabled && (
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="absolute right-1 top-1/2 size-6 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onChange("");
            }}
            aria-label="清空"
          >
            <X className="size-3" />
          </Button>
        )}
      </div>
      <PopoverContent
        className="w-[var(--radix-popover-trigger-width)] p-3"
        align="start"
      >
        <div className="mb-2 flex items-center justify-between">
          <Button
            variant="ghost"
            size="icon"
            className="size-7"
            onClick={() => setViewYear((y) => y - 1)}
            aria-label="上一年"
          >
            <ChevronLeft className="size-4" />
          </Button>
          <span className="text-sm font-medium">{viewYear} 年</span>
          <Button
            variant="ghost"
            size="icon"
            className="size-7"
            onClick={() => setViewYear((y) => y + 1)}
            aria-label="下一年"
          >
            <ChevronRight className="size-4" />
          </Button>
        </div>
        <div className="grid grid-cols-3 gap-1.5">
          {Array.from({ length: 12 }, (_, i) => i + 1).map((m) => {
            const isSel =
              selected?.year === viewYear && selected?.month === m;
            return (
              <Button
                key={m}
                variant={isSel ? "secondary" : "outline"}
                className="h-9"
                onClick={() => handleSelect(m)}
              >
                {m}月
              </Button>
            );
          })}
        </div>
      </PopoverContent>
    </Popover>
  );
}

interface YearPickerProps {
  value: string; // YYYY 或空字符串
  onChange: (v: string) => void;
  placeholder?: string;
  disabled?: boolean;
}

/**
 * 仅精确到「年」的日期选择器（我们的自有组件，非原生 input）。
 *
 * 弹出面板内展示 12 年网格（跨度为 viewStart..viewStart+11），前后翻页步进 12，
 * 选中即确认，返回格式固定为 "YYYY"，与移动端 WaitDatePicker(year) 存储格式一致。
 */
export function YearPicker({
  value,
  onChange,
  placeholder = "选择年份",
  disabled,
}: YearPickerProps) {
  const [open, setOpen] = useState(false);
  const selectedYear = useMemo(() => {
    if (!value || !/^\d{4}$/.test(value)) return null;
    return Number(value);
  }, [value]);
  const [viewStart, setViewStart] = useState<number>(
    selectedYear != null
      ? Math.floor(selectedYear / 12) * 12
      : Math.floor(new Date().getFullYear() / 12) * 12,
  );

  const handleSelect = (year: number) => {
    onChange(String(year));
    setOpen(false);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <div className="relative w-full">
        <PopoverTrigger asChild>
          <Button
            variant="outline"
            disabled={disabled}
            className={cn(
              "w-full justify-start text-left font-normal",
              value && "pr-8",
              !value && "text-muted-foreground",
            )}
          >
            <CalendarIcon className="size-4" />
            {value || <span>{placeholder}</span>}
          </Button>
        </PopoverTrigger>
        {value && !disabled && (
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="absolute right-1 top-1/2 size-6 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onChange("");
            }}
            aria-label="清空"
          >
            <X className="size-3" />
          </Button>
        )}
      </div>
      <PopoverContent
        className="w-[var(--radix-popover-trigger-width)] p-3"
        align="start"
      >
        <div className="mb-2 flex items-center justify-between">
          <Button
            variant="ghost"
            size="icon"
            className="size-7"
            onClick={() => setViewStart((y) => y - 12)}
            aria-label="前 12 年"
          >
            <ChevronLeft className="size-4" />
          </Button>
          <span className="text-sm font-medium">
            {viewStart} - {viewStart + 11} 年
          </span>
          <Button
            variant="ghost"
            size="icon"
            className="size-7"
            onClick={() => setViewStart((y) => y + 12)}
            aria-label="后 12 年"
          >
            <ChevronRight className="size-4" />
          </Button>
        </div>
        <div className="grid grid-cols-4 gap-1.5">
          {Array.from({ length: 12 }, (_, i) => viewStart + i).map((year) => {
            const isSel = selectedYear === year;
            return (
              <Button
                key={year}
                variant={isSel ? "secondary" : "outline"}
                className="h-9"
                onClick={() => handleSelect(year)}
              >
                {year}
              </Button>
            );
          })}
        </div>
      </PopoverContent>
    </Popover>
  );
}

type DatePrecision = "day" | "month" | "year";

/** 按存储值推导当前精度：YYYY=年、YYYY-MM=月、其余(YYYY-MM-DD)=日 */
function detectPrecision(value: string | null | undefined): DatePrecision {
  const s = (value ?? "").trim();
  if (/^\d{4}$/.test(s)) return "year";
  if (/^\d{4}-\d{2}$/.test(s)) return "month";
  return "day";
}

interface DateMonthPickerProps {
  value: string; // YYYY / YYYY-MM / YYYY-MM-DD 或空字符串
  onChange: (v: string) => void;
  placeholder?: string;
  disabled?: boolean;
}

/**
 * 复合日期选择器（我们的自有组件）：支持「年月日 / 年月 / 年」三种精度。
 *
 * 顶部三个切换按钮选择精度，下方分别渲染 DatePicker（日，弹出自有日历）、
 * MonthPicker（月，弹出年-月网格）或 YearPicker（年，弹出 12 年网格）。
 * 存储值随之取 "YYYY-MM-DD" / "YYYY-MM" / "YYYY"，与移动端 WaitDatePicker 三种模式完全对齐。
 */
export function DateMonthPicker({
  value,
  onChange,
  placeholder = "选择日期",
  disabled,
}: DateMonthPickerProps) {
  // 精度独立为 state：新增模式 value 为空时也能先切换「年月日 / 年月 / 年」再选日期
  const [precision, setPrecision] = useState<DatePrecision>(() =>
    detectPrecision(value),
  );

  // 外部值变化（编辑回填 / 清空 / 表单重置）时重新推导精度
  useEffect(() => {
    setPrecision(detectPrecision(value));
  }, [value]);

  const handlePrecisionChange = (target: DatePrecision) => {
    // 先更新精度 state：空值下仅切换精度，不转换值
    setPrecision(target);
    if (!value) return;
    if (target === precision) return;
    // 降精度：截断；升精度：补零（日默认 1 号，月默认 1 月）
    if (target === "year") {
      onChange(value.substring(0, 4));
      return;
    }
    if (target === "month") {
      onChange(precision === "day" ? value.substring(0, 7) : `${value}-01`);
      return;
    }
    // target === "day"
    onChange(
      precision === "year" ? `${value}-01-01` : `${value}-01`,
    );
  };

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-1.5">
        <Button
          type="button"
          variant={precision === "day" ? "secondary" : "outline"}
          size="sm"
          disabled={disabled}
          onClick={() => handlePrecisionChange("day")}
        >
          年月日
        </Button>
        <Button
          type="button"
          variant={precision === "month" ? "secondary" : "outline"}
          size="sm"
          disabled={disabled}
          onClick={() => handlePrecisionChange("month")}
        >
          年月
        </Button>
        <Button
          type="button"
          variant={precision === "year" ? "secondary" : "outline"}
          size="sm"
          disabled={disabled}
          onClick={() => handlePrecisionChange("year")}
        >
          年
        </Button>
      </div>
      {precision === "year" ? (
        <YearPicker
          value={value}
          onChange={onChange}
          placeholder={placeholder}
          disabled={disabled}
        />
      ) : precision === "month" ? (
        <MonthPicker
          value={value}
          onChange={onChange}
          placeholder={placeholder}
          disabled={disabled}
        />
      ) : (
        <DatePicker
          value={value}
          onChange={onChange}
          placeholder={placeholder}
          disabled={disabled}
          quick={false}
        />
      )}
    </div>
  );
}
