/**
 * RemindersSection —— 详情提醒区（05 §4.3 后半；M4 Task 14）
 *
 * 行 = notifications_outlined(20) + yyyy-MM-dd HH:mm + close(18) 删除
 * （无确认直删，对齐桌面 RemindersSection）；"添加提醒" TextButton.icon(add_rounded 20)。
 *
 * 日期时间选择：本任务定义 onPickDateTime 回调钩子（Task 15 以 WaitDatePickerSheet
 * 注入替换）；缺省实现为 window.prompt 占位。拿到毫秒后
 * todoReminderCreate({task_id, remind_at}) → refreshDetail 统一失效。
 * 落库即生效：到期拾取由 notification_scheduler 前台轮询守护承担（R2 兜底基线），
 * tauri 层无 scheduleTodoReminder 命令（以 lib/tauri.ts 现状为准）。
 */
import { MaterialIcon } from "@/components/mobile/material-icon";
import { waitToast } from "@/components/mobile/wait-toast";
import {
  todoReminderCreate,
  todoReminderDelete,
  type TodoTaskDetail,
} from "@/lib/tauri";
import { formatDateTime } from "../../shared/time";
import { TODO_ACCENT } from "../../shared/constants";
import { SectionCard } from "../section-card";

/**
 * 缺省日期时间选择实现：window.prompt 占位（Task 15 WaitDatePickerSheet 注入后整体替换）。
 * 输入 yyyy-MM-dd HH:mm，解析失败/取消返回 null 不落库。
 */
const promptPickDateTime = async (initialMs: number): Promise<number | null> => {
  const raw = window.prompt("设置提醒时间（格式 yyyy-MM-dd HH:mm）", formatDateTime(initialMs));
  if (!raw) return null;
  const ms = new Date(raw.trim().replace(" ", "T")).getTime();
  return Number.isNaN(ms) ? null : ms;
};

interface RemindersSectionProps {
  task: TodoTaskDetail;
  /** 统一失效出口：["todo-task-detail", id] + ["todo_tasks"] */
  refreshDetail: () => Promise<void>;
  /** 日期时间选择钩子（Task 15 注入 WaitDatePickerSheet）；缺省 window.prompt 占位 */
  onPickDateTime?: (initialMs: number) => Promise<number | null> | number | null;
}

export function RemindersSection({ task, refreshDetail, onPickDateTime }: RemindersSectionProps) {
  /** 添加提醒：picker(initial=now+1h) → 创建 → 统一失效（05 §4.3 提醒行） */
  const addReminder = async () => {
    try {
      const ms = await (onPickDateTime ?? promptPickDateTime)(Date.now() + 3_600_000);
      if (ms == null) return;
      await todoReminderCreate({ task_id: task.id, remind_at: ms });
      await refreshDetail();
    } catch {
      waitToast.destructive("操作失败");
    }
  };

  const remove = async (id: number) => {
    try {
      await todoReminderDelete(id);
      await refreshDetail();
    } catch {
      waitToast.destructive("操作失败");
    }
  };

  return (
    <SectionCard
      title="提醒"
      trailing={
        <button
          type="button"
          onClick={() => void addReminder()}
          className="-mr-2 flex items-center gap-1 rounded-lg px-2 py-1 text-sm font-medium active:bg-black/[.04] dark:active:bg-white/[.04]"
          style={{ color: TODO_ACCENT }}
        >
          <MaterialIcon name="add_rounded" size={20} />
          添加提醒
        </button>
      }
    >
      <div className="space-y-0.5">
        {task.reminders.map((r) => (
          <div key={r.id} className="flex items-center gap-2 py-1">
            <MaterialIcon name="notifications_outlined" size={20} color="var(--m-sub)" />
            <span className="min-w-0 flex-1 truncate text-[15px] text-[var(--m-text)]">
              {formatDateTime(r.remind_at)}
            </span>
            <button
              type="button"
              aria-label="删除提醒"
              className="shrink-0 active:opacity-60"
              onClick={() => void remove(r.id)}
            >
              <MaterialIcon name="close" size={18} color="var(--m-sub)" />
            </button>
          </div>
        ))}
        {task.reminders.length === 0 && (
          <p className="py-1 text-[13px]" style={{ color: "var(--m-sub)", opacity: 0.5 }}>
            暂无提醒
          </p>
        )}
      </div>
    </SectionCard>
  );
}
