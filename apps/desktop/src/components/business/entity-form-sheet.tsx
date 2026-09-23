/**
 * 通用实体表单 Sheet
 *
 * 所有业务模块的新增/编辑共用此组件。
 * 调用方传入 fields 定义 + onSubmit 回调，组件负责渲染表单、收集值、提交。
 */
import { Fragment, useState, useEffect, type FormEvent, type ReactNode } from "react";

/** 从各类错误对象（含 Tauri invoke 抛出的字符串/InvokeError）中取出可读信息 */
function extractErrorMessage(err: unknown): string {
  if (typeof err === "string") return err;
  if (err instanceof Error) return err.message;
  if (err && typeof err === "object") {
    const maybe = err as Record<string, unknown>;
    if (typeof maybe.message === "string" && maybe.message) return maybe.message;
    if (typeof maybe.description === "string" && maybe.description) return maybe.description;
  }
  try {
    return JSON.stringify(err);
  } catch {
    return String(err);
  }
}
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { ErrorState } from "@/components/business/error-state";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetDescription,
  SheetFooter,
} from "@/components/ui/sheet";
import { Switch } from "@/components/ui/switch";
import { ColorPickerDialog } from "@/components/ui/color-picker-dialog";
import { LucideIconPickerDialog } from "@/components/ui/lucide-icon-picker-dialog";
import { getIcon } from "@/lib/icon-map";
import { DatePicker, DateTimePicker, DateMonthPicker } from "@/components/business/date-picker";
import {
  collectFormValues,
  extractInitialValues,
  type FieldDef,
  type FormValues,
} from "@/lib/form-types";

interface EntityFormSheetProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description?: string;
  fields: FieldDef[];
  /** 编辑模式时传入的已有记录，null/undefined 表示新增模式 */
  initialRecord?: Record<string, unknown> | null;
  /** 提交回调，返回 Promise。成功后由调用方关闭 Sheet */
  onSubmit: (values: FormValues) => Promise<void>;
  submitText?: string;
  /** 在表单字段之前插入的自定义内容（如豆瓣抓取区） */
  children?: ReactNode;
  /** 在表单字段之后、提交按钮之前插入的自定义内容（如标签选择器） */
  footerContent?: ReactNode;
  /**
   * 在指定字段之后插入自定义节点（如把「观看人」选择器放到「只看过解说」下方）。
   * 需提供该字段的 name 作为锚点。
   * 支持单个对象或数组（同一/多个字段多处插入）。
   */
  insertAfter?:
    | { fieldName: string; node: ReactNode }
    | { fieldName: string; node: ReactNode }[];
  /**
   * 在指定字段的输入框右侧插入自定义节点（如「智能抓取」按钮）。
   * node 可为函数，接收该字段当前值，用于按钮需要读取输入值（如标题）的场景。
   * 需提供该字段的 name 作为锚点。
   */
  fieldAction?: {
    fieldName: string;
    node: ReactNode | ((value: unknown) => ReactNode);
  };
  /**
   * 表单值变更回调（初始装载与每次 setField 均通知）。
   * 供 footerContent 区域需要响应表单字段值的场景
   * （如重复规则预览锚定截止日期——编辑既有记录时初始值也须可见）。
   */
  onValuesChange?: (values: FormValues) => void;
  /**
   * 分区标题强调色。传入时分区标题文字使用此色，不传则回退到默认前景色。
   */
  accent?: string;
}

export function EntityFormSheet({
  open,
  onOpenChange,
  title,
  description,
  fields,
  initialRecord,
  onSubmit,
  submitText = "保存",
  children,
  footerContent,
  insertAfter,
  fieldAction,
  accent,
  onValuesChange,
}: EntityFormSheetProps) {
  const [values, setValues] = useState<FormValues>({});
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 打开时或 initialRecord 变化时重置表单（装载值也走 onValuesChange，
  // 让 footerContent 预览类区域在编辑既有记录时拿到初始锚点）
  useEffect(() => {
    if (open) {
      const initial = extractInitialValues(fields, initialRecord);
      setValues(initial);
      onValuesChange?.(initial);
      setError(null);
    }
    // onValuesChange 由调用方行内传入（每渲染新引用），只按表单生命周期触发
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, initialRecord, fields]);

  const setField = (name: string, value: unknown) => {
    setValues((prev) => {
      const next = { ...prev, [name]: value };
      onValuesChange?.(next);
      return next;
    });
  };

  // 归一化 insertAfter：兼容单个对象或数组
  const insertAfterList = insertAfter
    ? Array.isArray(insertAfter)
      ? insertAfter
      : [insertAfter]
    : [];

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      const collected = collectFormValues(fields, values);

      // v7: 必填字段校验
      // collectFormValues 已将空字符串/undefined 统一转为 null（checkbox 类型恒为 0/1 不算空）
      // 必填字段为 null 时阻止提交，避免依赖后端 NOT NULL 约束兜底（提示不友好）
      const missingLabels: string[] = [];
      for (const field of fields) {
        if (!field.required) continue;
        if (field.type === "checkbox") continue; // checkbox 必填无意义
        const v = collected[field.name];
        if (v === null || v === undefined || v === "") {
          missingLabels.push(field.label);
        }
      }
      if (missingLabels.length > 0) {
        setError(`请填写必填项：${missingLabels.join("、")}`);
        return;
      }

      // 过滤 null 值：避免 NOT NULL DEFAULT 列约束冲突（让 DB DEFAULT 生效）；
      // 同时让 typed update API 跳过未修改字段（缺失 key = None = 跳过）
      const filtered = Object.fromEntries(
        Object.entries(collected).filter(([, v]) => v !== null)
      );
      await onSubmit(filtered);
      onOpenChange(false);
    } catch (err) {
      console.error("保存失败:", err);
      setError(`保存失败：${extractErrorMessage(err)}`);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="w-full sm:max-w-md">
        <SheetHeader>
          <SheetTitle>{title}</SheetTitle>
          {description && <SheetDescription>{description}</SheetDescription>}
        </SheetHeader>

        <form
          onSubmit={handleSubmit}
          className="flex flex-1 flex-col overflow-hidden"
        >
          <div className="flex-1 space-y-4 overflow-y-auto p-4">
            {children}
            {fields.map((field, idx) => {
              // 分区标题：当前字段所属分区与前一个不同时，插入分隔标题
              const prevSection = idx > 0 ? fields[idx - 1].section : undefined;
              const showSection =
                field.section && field.section !== prevSection;
              return (
                <Fragment key={field.name}>
                  {showSection && (
                    <div className="flex items-center gap-2.5 pt-2 first:pt-0">
                      {/* 左侧 3px 强调色竖条：与移动端 SectionHeader 视觉对齐 */}
                      <span
                        className="h-4 w-[3px] shrink-0 rounded-sm"
                        style={{
                          backgroundColor: accent ?? "currentColor",
                        }}
                        aria-hidden
                      />
                      <span
                        className="text-sm font-semibold"
                        style={accent ? { color: accent } : undefined}
                      >
                        {field.section}
                      </span>
                      {/* 右侧渐变细线：强调色淡出到透明，比纯实线更优雅 */}
                      <span
                        className="h-px flex-1"
                        style={
                          accent
                            ? {
                                backgroundImage: `linear-gradient(to right, ${accent}40, transparent)`,
                              }
                            : undefined
                        }
                        aria-hidden
                      />
                    </div>
                  )}
                  <div className="flex flex-col gap-1.5">
                    <Label htmlFor={field.name}>
                      {field.label}
                      {field.required && (
                        <span className="ml-0.5 text-destructive">*</span>
                      )}
                    </Label>
                    {fieldAction?.fieldName === field.name ? (
                      <div className="flex items-start gap-2">
                        <div className="min-w-0 flex-1">
                          <FieldRenderer
                            field={field}
                            value={values[field.name]}
                            relativeDateMs={relativeDateMsOf(field, values)}
                            onChange={(v) => setField(field.name, v)}
                          />
                        </div>
                        {typeof fieldAction.node === "function"
                          ? fieldAction.node(values[field.name])
                          : fieldAction.node}
                      </div>
                    ) : (
                      <FieldRenderer
                        field={field}
                        value={values[field.name]}
                        relativeDateMs={relativeDateMsOf(field, values)}
                        onChange={(v) => setField(field.name, v)}
                      />
                    )}
                  </div>
                  {insertAfterList.map(
                    (item) =>
                      item.fieldName === field.name &&
                      <Fragment key={`insert-${item.fieldName}`}>{item.node}</Fragment>,
                  )}
                </Fragment>
              );
            })}
            {footerContent}
          </div>

          {error && <ErrorState message={error} />}

          <SheetFooter>
            <Button
              variant="outline"
              type="button"
              onClick={() => onOpenChange(false)}
              disabled={submitting}
            >
              取消
            </Button>
            <Button type="submit" disabled={submitting}>
              {submitting ? (
                <>
                  <EqualizerLoader size={16} inline />
                  保存中…
                </>
              ) : (
                submitText
              )}
            </Button>
          </SheetFooter>
        </form>
      </SheetContent>
    </Sheet>
  );
}

/**
 * 字段声明的相对锚点日期 → ms（供 datetime 字段的「相对截止」档用）。
 * 锚点值形如 `YYYY-MM-DD`（date 字段统一形态）；无声明/空值/非法值 → null。
 */
function relativeDateMsOf(field: FieldDef, values: FormValues): number | null {
  if (!field.relativeDateField) return null;
  const raw = values[field.relativeDateField];
  if (typeof raw !== "string" || !raw) return null;
  const ms = new Date(`${raw}T00:00:00`).getTime();
  return Number.isNaN(ms) ? null : ms;
}

/** 根据字段类型渲染对应的输入控件 */
function FieldRenderer({
  field,
  value,
  onChange,
  relativeDateMs,
}: {
  field: FieldDef;
  value: unknown;
  onChange: (value: unknown) => void;
  /** 「相对截止」档锚点（仅 datetime 用；见 [FieldDef.relativeDateField]） */
  relativeDateMs?: number | null;
}) {
  switch (field.type) {
    case "textarea":
      return (
        <Textarea
          id={field.name}
          placeholder={field.placeholder}
          value={(value as string) ?? ""}
          maxLength={field.maxLength}
          onChange={(e) => onChange(e.target.value)}
          className="min-h-[80px] max-h-64 field-sizing-content"
        />
      );

    case "number":
      return (
        <Input
          id={field.name}
          type="number"
          placeholder={field.placeholder}
          value={(value as string | number) ?? ""}
          min={field.min}
          max={field.max}
          step={field.step}
          onChange={(e) => onChange(e.target.value)}
        />
      );

    case "date":
      return (
        <DatePicker
          value={(value as string) ?? ""}
          onChange={onChange}
          placeholder={field.placeholder}
        />
      );

    case "datetime":
      return (
        <DateTimePicker
          value={(value as string) ?? ""}
          onChange={onChange}
          placeholder={field.placeholder}
          dueDateMs={relativeDateMs}
        />
      );

    case "date-month":
      return (
        <DateMonthPicker
          value={(value as string) ?? ""}
          onChange={onChange}
          placeholder={field.placeholder}
        />
      );

    case "checkbox":
      return (
        <Switch
          id={field.name}
          checked={Boolean(value)}
          onCheckedChange={onChange}
        />
      );

    case "color": {
      const current = (value as string) || "#0EA5E9";
      const [open, setOpen] = useState(false);
      return (
        <>
          <button
            type="button"
            onClick={() => setOpen(true)}
            className="flex h-9 w-full items-center gap-2 rounded-md border border-input bg-background px-2 text-left text-sm hover:bg-accent/50"
          >
            <span
              className="h-5 w-5 shrink-0 rounded border"
              style={{ backgroundColor: current }}
            />
            <span className="font-mono text-muted-foreground">{current}</span>
          </button>
          <ColorPickerDialog
            open={open}
            onOpenChange={setOpen}
            initialColor={current}
            title={`选择${field.label}`}
            onConfirm={(color) => onChange(color)}
          />
        </>
      );
    }

    case "icon": {
      const current = (value as string) || "";
      const [open, setOpen] = useState(false);
      const SelectedIcon = getIcon(current || "");
      return (
        <>
          <button
            type="button"
            onClick={() => setOpen(true)}
            className="flex h-9 w-full items-center gap-2 rounded-md border border-input bg-background px-2 text-left text-sm hover:bg-accent/50"
          >
            <span className="flex size-6 shrink-0 items-center justify-center rounded text-muted-foreground">
              <SelectedIcon className="size-5" />
            </span>
            <span className="text-muted-foreground">{current ? current : "选择图标"}</span>
          </button>
          <LucideIconPickerDialog
            open={open}
            onOpenChange={setOpen}
            title={`选择${field.label}`}
            currentIcon={current}
            onConfirm={(name) => onChange(name)}
          />
        </>
      );
    }

    case "select":
      return (
        <Select
          value={value != null ? String(value) : ""}
          onValueChange={(v) => onChange(v)}
        >
          <SelectTrigger id={field.name}>
            <SelectValue placeholder={field.placeholder ?? "请选择"} />
          </SelectTrigger>
          <SelectContent>
            {field.options?.map((opt) => (
              <SelectItem key={String(opt.value)} value={String(opt.value)}>
                <span
                  className="flex items-center gap-2"
                  style={opt.textColor ? { color: opt.textColor } : undefined}
                >
                  {opt.color && (
                    <span
                      className="size-2.5 shrink-0 rounded-full"
                      style={{ backgroundColor: opt.color }}
                      aria-hidden
                    />
                  )}
                  {opt.label}
                </span>
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      );

    default:
      return (
        <Input
          id={field.name}
          type="text"
          placeholder={field.placeholder}
          value={(value as string) ?? ""}
          maxLength={field.maxLength}
          onChange={(e) => onChange(e.target.value)}
        />
      );
  }
}
