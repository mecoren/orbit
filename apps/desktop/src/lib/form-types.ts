/**
 * 表单字段类型定义
 *
 * 所有业务模块的 EntityFormSheet 共用此类型描述表单字段，
 * 避免每个模块重复实现表单 UI。
 */

import { normalizeCommaList } from "./utils";

export type FieldType =
  | "text"
  | "number"
  | "textarea"
  | "date"
  | "datetime"
  | "date-month"
  | "select"
  | "checkbox"
  | "color"
  | "icon";

export interface FieldOption {
  label: string;
  value: string | number;
  /** 选项语义色点（可选，如优先级 0–5 语义色），渲染在选项文字前 */
  color?: string;
  /** 是否为默认选项（新增记录时自动选中） */
  isDefault?: boolean;
}

export interface FieldDef {
  /** snake_case 字段名，对应 Rust 侧业务字段 */
  name: string;
  /** 中文显示标签 */
  label: string;
  type: FieldType;
  /** 所属分区标题；相邻字段 section 变化时，组件自动渲染分区标题分隔 */
  section?: string;
  required?: boolean;
  placeholder?: string;
  options?: FieldOption[];
  defaultValue?: unknown;
  min?: number;
  max?: number;
  step?: number;
  /** 字符串最大长度（text/textarea） */
  maxLength?: number;
  /** 是否为逗号分隔的多值字段（如 director/genre），收集时自动归一化全角逗号 */
  multi?: boolean;
}

export type FormValues = Record<string, unknown>;

/**
 * 将表单值转换为 fieldsJson 所需的 snake_case JSON 对象。
 *
 * - checkbox → 0/1 (i32)
 * - number → number | null（空字符串转 null）
 * - date/datetime → string | null
 * - text/textarea/select → string | null
 *
 * 空字符串统一转为 null，避免 Rust 侧插入空串。
 */
export function collectFormValues(
  fields: FieldDef[],
  raw: FormValues,
): FormValues {
  const result: FormValues = {};
  for (const field of fields) {
    const v = raw[field.name];
    if (field.type === "checkbox") {
      result[field.name] = v ? 1 : 0;
    } else if (field.type === "number") {
      if (v === "" || v === undefined || v === null) {
        result[field.name] = null;
      } else {
        const n = Number(v);
        result[field.name] = Number.isNaN(n) ? null : n;
      }
    } else if (field.type === "select") {
      result[field.name] = v === undefined || v === "" ? null : v;
    } else {
      // text / textarea / date / datetime
      // 多值字段（multi）归一化全角逗号为英文逗号
      if (field.multi && typeof v === "string") {
        const normalized = normalizeCommaList(v);
        result[field.name] = normalized === "" ? null : normalized;
      } else {
        result[field.name] = v === undefined || v === "" ? null : v;
      }
    }
  }
  return result;
}

/**
 * 从已有记录中提取表单初始值（用于编辑模式）。
 *
 * 将 null/undefined 转为空字符串（text 类）或保持 null（number 类），
 * 以便 Input 组件正常渲染。
 *
 * 新增模式（record 为 null）时，select 类型字段自动应用选项表中
 * isDefault=true 的默认值；无默认选项则为空字符串。
 */
export function extractInitialValues(
  fields: FieldDef[],
  record: Record<string, unknown> | null | undefined,
): FormValues {
  if (!record) {
    // 新增模式：仅应用 select 字段的默认选项值
    const result: FormValues = {};
    for (const field of fields) {
      if (field.type === "select") {
        const defaultOpt = field.options?.find((o) => o.isDefault);
        result[field.name] = defaultOpt ? defaultOpt.value : "";
      } else {
        result[field.name] = "";
      }
    }
    return result;
  }
  const result: FormValues = {};
  for (const field of fields) {
    const v = record[field.name];
    if (field.type === "checkbox") {
      result[field.name] = v === 1 || v === true;
    } else if (field.type === "number") {
      result[field.name] = v === null || v === undefined ? "" : v;
    } else if (field.type === "select") {
      result[field.name] = v === null || v === undefined ? "" : v;
    } else {
      result[field.name] = v === null || v === undefined ? "" : String(v);
    }
  }
  return result;
}

/**
 * 列元数据描述清洗规则
 *
 * 移除技术性后缀（如 "（JSON 数组）"、"（Unix 时间戳）"），
 * 这些信息对终端用户无意义，不应出现在表单标签中。
 * 业务有意义的括号说明（如 "时长（分钟）/集数"）保持原样。
 */
const TECHNICAL_SUFFIX_PATTERNS: RegExp[] = [
  /（JSON\s*数组）$/,
  /（Unix\s*时间戳）$/,
  /（Unix\s*时间戳，NULL=未删除）$/,
  /（movie\/tv）$/,
  /（0=活跃，1=已删除）$/,
  /（来源设备）$/,
  /（最近一次同步时间）$/,
  /（乐观锁版本号）$/,
  /（Lamport\s*逻辑时钟版本号）$/,
];

/**
 * 清洗列元数据描述
 *
 * 1. 去除技术性后缀（如 "（JSON 数组）"）
 * 2. 去除首尾空白
 * 3. 清洗后若为空字符串则返回 null，由调用方回退到原始 label
 */
function cleanDescription(desc: string | null | undefined): string | null {
  if (!desc) return null;
  let cleaned = desc.trim();
  for (const pattern of TECHNICAL_SUFFIX_PATTERNS) {
    cleaned = cleaned.replace(pattern, "").trim();
  }
  return cleaned || null;
}

/**
 * 列元数据 Map 类型（column_name → description）
 */
export type ColumnMetaMap = Map<string, { description: string | null }>;

/**
 * 将字段定义数组与列元数据合并，统一表单标签文案
 *
 * - 对每个 field，若 metaMap 中存在同名列且描述非空，则用清洗后的描述覆盖 label
 * - 否则保留 field 原始 label
 * - 不修改、不新增字段，仅更新 label
 *
 * 这样保证表单标签与数据库列描述一致，同时过滤技术性后缀。
 */
export function mergeFieldsWithMeta(
  fields: FieldDef[],
  metaMap: ColumnMetaMap,
): FieldDef[] {
  return fields.map((field) => {
    const meta = metaMap.get(field.name);
    const cleaned = cleanDescription(meta?.description);
    if (cleaned) {
      return { ...field, label: cleaned };
    }
    return field;
  });
}

