/**
 * activity-format — 详情抽屉「历史」行文案格式化（纯函数，F6 历史区块口径）
 *
 * detail JSON 三代并存，渲染按优先级回退：
 * - {"changes":[{field,from,to},…]}  新行：写入端已快照前后值
 *   （project_id→项目名、due_date→本地 yyyy-MM-dd HH:mm、日期→本地
 *    yyyy-MM-dd 串、长文本 60 字截断；枚举/数值留原值，此处按共享常量
 *    口径格式化——单口径不双写）
 * - {"fields":["priority",…]}        旧行（2026-09-18 前）：只有字段名
 * - {"label":"工作"} + action label_add/label_remove：标签挂/摘
 * - {"target":"子任务甲"} + action subtask·comment·link·reminder·attachment
 *   前缀动作：从属对象增删改（提醒 target=格式化时刻串、改名 target=「旧 → 新」）
 */
import { PRIORITY_LABELS, STATUS_LABELS } from "./constants";
import { repeatLabel } from "./repeat";

/** action → 中文动作文案 */
export const ACTIVITY_ACTION_LABELS: Record<string, string> = {
  create: "创建了任务",
  update: "更新",
  complete: "标记为完成",
  uncomplete: "恢复为未完成",
  delete: "移入回收站",
  restore: "从回收站恢复",
  label_add: "添加标签",
  label_remove: "移除标签",
  subtask_add: "添加子任务",
  subtask_delete: "删除子任务",
  subtask_done: "完成子任务",
  subtask_undone: "取消完成子任务",
  subtask_rename: "子任务改名",
  subtask_promote: "子任务转为独立任务",
  comment_add: "添加评论",
  comment_delete: "删除评论",
  link_add: "添加关联任务",
  link_remove: "移除关联任务",
  reminder_add: "添加提醒",
  reminder_delete: "移除提醒",
  attachment_add: "添加附件",
  attachment_delete: "移除附件",
  repeat_rollover: "已滚动下一周期",
};

/** detail 带 {"target"} 的从属对象动作：文案统一拼「target」 */
const TARGET_ACTIONS = new Set([
  "subtask_add",
  "subtask_delete",
  "subtask_done",
  "subtask_undone",
  "subtask_rename",
  "subtask_promote",
  "comment_add",
  "comment_delete",
  "link_add",
  "link_remove",
  "reminder_add",
  "reminder_delete",
  "attachment_add",
  "attachment_delete",
  "repeat_rollover",
]);

/** update detail 里的字段名 → 中文（与属性行文案对齐；未映射字段原样展示） */
export const ACTIVITY_FIELD_LABELS: Record<string, string> = {
  title: "标题",
  description: "描述",
  project_id: "所属项目",
  priority: "优先级",
  status: "状态",
  done: "完成标记",
  done_at: "完成时间",
  due_date: "截止日期",
  start_date: "开始日期",
  repeat_rule: "重复规则",
  percent_done: "进度",
  position: "顺序",
  is_favorite: "收藏",
  my_day_date: "我的一天",
};

/** 重复规则六字段快照（repeat_rule 伪字段的 from/to 值，写入端整体快照） */
export interface RepeatRuleSnapshot {
  mode: number;
  after: number;
  weekdays: number;
  end_type: number;
  end_param: number;
  from_done: number;
}

/** 变更快照单条（值类型随字段：数字/字符串/规则对象/null） */
export interface ActivityChange {
  field: string;
  from: string | number | RepeatRuleSnapshot | null;
  to: string | number | RepeatRuleSnapshot | null;
}

interface ActivityDetail {
  fields?: string[];
  changes?: ActivityChange[];
  label?: string;
  target?: string;
}

/** 字段值 → 可读文案（null=无；枚举走共享常量；position 浮点无意义只报"已调整"） */
function fmtValue(field: string, v: string | number | RepeatRuleSnapshot | null): string {
  if (v === null || v === undefined) return "无";
  switch (field) {
    case "priority":
      return PRIORITY_LABELS[v as number] ?? String(v);
    case "status":
      return STATUS_LABELS[v as string] ?? String(v);
    case "done":
      return v === 1 ? "已完成" : "未完成";
    case "is_favorite":
      return v === 1 ? "是" : "否";
    case "repeat_rule": {
      const r = v as RepeatRuleSnapshot;
      return repeatLabel(r.mode, r.after, {
        weekdays: r.weekdays,
        endType: r.end_type,
        endParam: r.end_param,
        fromDone: r.from_done,
      });
    }
    case "percent_done":
      return `${v}%`;
    case "position":
      return "已调整";
    default: {
      const s = String(v);
      return s.length > 30 ? `${s.slice(0, 30)}…` : s;
    }
  }
}

/**
 * 历史行动作文案：update 优先渲染前后值（changes），旧行回退字段名（fields）；
 * 标签动作拼标签名；detail 非法 JSON 回退动作文案
 */
export function describeActivity(action: string, detail: string): string {
  const base = ACTIVITY_ACTION_LABELS[action] ?? action;
  let d: ActivityDetail;
  try {
    d = JSON.parse(detail) as ActivityDetail;
  } catch {
    return base;
  }
  if (action === "label_add" || action === "label_remove") {
    return d.label ? `${base}「${d.label}」` : base;
  }
  if (TARGET_ACTIONS.has(action)) {
    return d.target ? `${base}「${d.target}」` : base;
  }
  if (action !== "update") return base;
  const changes = d.changes ?? [];
  if (changes.length > 0) {
    const parts = changes.map((c) => {
      const name = ACTIVITY_FIELD_LABELS[c.field] ?? c.field;
      return `${name}：${fmtValue(c.field, c.from)} → ${fmtValue(c.field, c.to)}`;
    });
    return `${base}（${parts.join("、")}）`;
  }
  const fields = d.fields ?? [];
  if (fields.length === 0) return base;
  const names = fields.map((f) => ACTIVITY_FIELD_LABELS[f] ?? f).join("、");
  return `${base}（${names}）`;
}
