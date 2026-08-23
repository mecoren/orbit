import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

// shadcn-ui 标准类名合并工具
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * 将多值字段字符串中的全角逗号归一化为英文逗号。
 *
 * 多值字段（如 director、genre、participant_ids）统一以英文逗号 `,` 分隔存储。
 * 用户在 UI 或 Excel 中可能输入全角逗号 `，`（U+FF0C），本函数将其转换为英文逗号，
 * 并去除每项前后空白、过滤空项后重新拼接。
 *
 * 仅应对「使用逗号分隔的多值字段」，其他字段不应调用此函数。
 */
export function normalizeCommaList(input: string | null | undefined): string {
  if (!input) return "";
  return input
    .replace(/\uFF0C/g, ",")
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0)
    .join(",");
}

/**
 * 多值字段的「展示层」格式化：将存储用的英文逗号分隔符转换为 ` / `（前后各一个空格）。
 *
 * 约定与边界：
 * - 数据层（DB / API）始终以英文逗号 `,` 存储多值字段（见 normalizeCommaList），本函数不改写任何数据。
 * - 本函数仅在「展示层」调用：详情页字段、表格列渲染。请勿用于表单输入或存储逻辑。
 * - 空值 / 纯空白内容回落为 `empty`（默认 "—"）。
 *
 * @param value 原始逗号分隔字符串（各项允许含前后空白）
 * @param empty 无有效内容时的占位符，默认 "—"
 */
export function formatListField(
  value: string | null | undefined,
  empty = "—",
): string {
  if (!value) return empty;
  const items = value
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
  return items.length > 0 ? items.join(" / ") : empty;
}
