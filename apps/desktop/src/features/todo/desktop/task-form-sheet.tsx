/**
 * TaskFormSheet — 新增/编辑任务表单（04 文档 §3.6 复刻）
 *
 * 包装通用 EntityFormSheet；九字段规格照抄 + 虚拟字段 remind_at：
 * title(必填) / description(5000) / project_id / priority(0–5) / status(pending|doing|done)
 * / due_date / start_date / end_date（提交转毫秒时间戳）/ hex_color(⚖ 正则校验)。
 * remind_at 不是任务列：编辑载入既有提醒回填，提交时按"清除删 / 变更删旧建新"同步。
 */
import { useEffect, useMemo, useState } from "react";
import { format } from "date-fns";
import { toast } from "sonner";

import { EntityFormSheet } from "@/components/business/entity-form-sheet";
import type { FieldDef } from "@/lib/form-types";
import {
  todoReminderCreate,
  todoReminderDelete,
  todoReminderList,
  todoTaskCreate,
  todoTaskUpdate,
  type TodoProject,
  type TodoReminder,
  type TodoTask,
} from "@/lib/tauri";
import { TODO_ACCENT } from "../shared/constants";

const PRIORITY_LABELS = ["无", "低", "中", "高", "紧急", "立即处理"];

/** ⚖ §7-②：hex_color MVP 保留文本 + 正则校验（色板控件记 M6+） */
const HEX_COLOR_RE = /^#[0-9a-fA-F]{6}$/;

/** ms → DateTimePicker 值格式（YYYY-MM-DDTHH:MM） */
const tsToInputValue = (ms: number) => format(new Date(ms), "yyyy-MM-dd'T'HH:mm");

export function buildTaskFields(projects: TodoProject[]): FieldDef[] {
  return [
    { name: "title", label: "标题", type: "text", required: true, placeholder: "输入任务标题" },
    { name: "description", label: "描述", type: "textarea", maxLength: 5000 },
    {
      name: "project_id",
      label: "所属项目",
      type: "select",
      options: [
        { label: "未分组", value: "" },
        ...projects.map((p) => ({ label: p.title, value: String(p.id) })),
      ],
    },
    {
      name: "priority",
      label: "优先级",
      type: "select",
      defaultValue: 0,
      options: PRIORITY_LABELS.map((label, value) => ({ label, value })),
    },
    {
      name: "status",
      label: "状态",
      type: "select",
      defaultValue: "pending",
      options: [
        { label: "待办", value: "pending" },
        { label: "进行中", value: "doing" },
        { label: "已完成", value: "done" },
      ],
    },
    { name: "due_date", label: "截止日期", type: "date" },
    { name: "remind_at", label: "提醒时间", type: "datetime" },
    { name: "start_date", label: "开始日期", type: "date" },
    { name: "end_date", label: "结束日期", type: "date" },
    { name: "hex_color", label: "颜色", type: "text", placeholder: "#3B82F6" },
  ];
}

/** 日期字符串 → 毫秒时间戳；空值转 null */
function toDateMs(v: unknown): number | null {
  if (typeof v !== "string" || !v) return null;
  const ms = new Date(`${v}T00:00:00`).getTime();
  return Number.isNaN(ms) ? null : ms;
}

interface TaskFormSheetProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 编辑模式传入任务；null/undefined 为新增 */
  task?: TodoTask | null;
  projects: TodoProject[];
  /** 新增时的默认项目（当前选中项目，04 §3.6） */
  defaultProjectId?: number | null;
}

export function TaskFormSheet({
  open,
  onOpenChange,
  task,
  projects,
  defaultProjectId,
}: TaskFormSheetProps) {
  // 编辑模式载入该任务既有提醒（取第一条未删除），用于回填与变更比对
  const [existingReminder, setExistingReminder] = useState<TodoReminder | null>(null);

  useEffect(() => {
    if (!open || !task) {
      setExistingReminder(null);
      return;
    }
    let cancelled = false;
    todoReminderList({ page: 1, page_size: 1000 })
      .then((rows) => {
        if (!cancelled) {
          setExistingReminder(
            rows.find((r) => r.task_id === task.id && !r.is_deleted) ?? null,
          );
        }
      })
      .catch(() => {
        /* 载入失败按无提醒处理 */
      });
    return () => {
      cancelled = true;
    };
  }, [open, task]);

  // 稳定引用：避免父级重渲染（后台 refetch 等）触发 EntityFormSheet 重置表单
  const fields = useMemo(() => buildTaskFields(projects), [projects]);

  const initialRecord = useMemo(() => {
    if (task) {
      return {
        ...task,
        // select 组件以字符串值工作，数字键需字符串化
        project_id: task.project_id != null ? String(task.project_id) : "",
        priority: String(task.priority),
        status: task.status,
        remind_at: existingReminder ? tsToInputValue(existingReminder.remind_at) : "",
      };
    }
    return defaultProjectId != null
      ? { project_id: String(defaultProjectId), priority: "0", status: "pending" }
      : undefined;
  }, [task, defaultProjectId, existingReminder]);

  const handleSubmit = async (values: Record<string, unknown>) => {
    // ⚖ hex_color 正则校验：非法时抛错使 Sheet 保持打开
    const hex = values.hex_color;
    if (typeof hex === "string" && hex.trim() && !HEX_COLOR_RE.test(hex.trim())) {
      toast.error("颜色格式不正确，应为 #RRGGBB");
      throw new Error("invalid hex_color");
    }

    const payload = {
      title: String(values.title ?? "").trim(),
      description: (values.description as string) || null,
      project_id:
        values.project_id === "" || values.project_id == null
          ? null
          : Number(values.project_id),
      priority: Number(values.priority ?? 0),
      status: String(values.status ?? "pending"),
      due_date: toDateMs(values.due_date),
      start_date: toDateMs(values.start_date),
      end_date: toDateMs(values.end_date),
      // Input 类型为 string | undefined（空 = 跳过更新语义）
      hex_color: typeof hex === "string" && hex.trim() ? hex.trim() : undefined,
    };

    // 提醒时间（values 已过滤 null：undefined = 用户清空或未填）
    const remindRaw = typeof values.remind_at === "string" ? values.remind_at : "";
    const remindMs = remindRaw ? new Date(remindRaw).getTime() : null;

    if (task) {
      await todoTaskUpdate(task.id, payload);
      // 同步提醒实体：清空→删；变更→删旧建新；未动→跳过
      const old = existingReminder;
      if (remindMs == null || Number.isNaN(remindMs)) {
        if (old) await todoReminderDelete(old.id);
      } else if (!old || tsToInputValue(old.remind_at) !== remindRaw) {
        if (old) await todoReminderDelete(old.id);
        await todoReminderCreate({ task_id: task.id, remind_at: remindMs });
      }
    } else {
      const created = await todoTaskCreate(payload);
      if (remindMs != null && !Number.isNaN(remindMs)) {
        await todoReminderCreate({ task_id: created.id, remind_at: remindMs });
      }
    }
  };

  return (
    <EntityFormSheet
      open={open}
      onOpenChange={onOpenChange}
      title={task ? "编辑待办" : "新增待办"}
      fields={fields}
      accent={TODO_ACCENT}
      initialRecord={initialRecord}
      onSubmit={handleSubmit}
      submitText={task ? "保存" : "创建"}
    />
  );
}

