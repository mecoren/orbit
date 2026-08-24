/**
 * RemindersSection —— 详情提醒区（05 §4.3 后半；M4 Task 14/15）
 *
 * 行 = notifications_outlined(20) + yyyy-MM-dd HH:mm + close(18) 删除
 * （无确认直删，对齐桌面 RemindersSection）；"添加提醒" TextButton.icon(add_rounded 20)。
 *
 * 日期时间选择（Task 15）：WaitDatePickerSheet mode="datetime"、initial=now+1h，
 * 确认后 todoReminderCreate({task_id, remind_at}) → refreshDetail 统一失效；
 * 清除/null 不落库。落库即生效：到期拾取由 notification_scheduler 前台轮询守护
 * 承担（R2 兜底基线），tauri 层无 scheduleTodoReminder 命令（以 lib/tauri.ts 现状为准）。
 */
import { useState } from "react";
import { MaterialIcon } from "@/components/mobile/material-icon";
import { WaitDatePickerSheet } from "@/components/mobile/wait-date-picker-sheet";
import { waitToast } from "@/components/mobile/wait-toast";
import {
  todoReminderCreate,
  todoReminderDelete,
  type TodoTaskDetail,
} from "@/lib/tauri";
import { formatDateTime } from "../../shared/time";
import { TODO_ACCENT } from "../../shared/constants";
import { SectionCard } from "../section-card";

interface RemindersSectionProps {
  task: TodoTaskDetail;
  /** 统一失效出口：["todo-task-detail", id] + ["todo_tasks"] */
  refreshDetail: () => Promise<void>;
}

export function RemindersSection({ task, refreshDetail }: RemindersSectionProps) {
  // datetime 选择器状态：initial 在点按时刻取 now+1h（05 §四 Task 15 约定）
  const [pickerOpen, setPickerOpen] = useState(false);
  const [pickerInitial, setPickerInitial] = useState(() => Date.now() + 3_600_000);

  /** 添加提醒：WaitDatePickerSheet(initial=now+1h) → 创建 → 统一失效（05 §4.3 提醒行） */
  const addReminder = () => {
    setPickerInitial(Date.now() + 3_600_000);
    setPickerOpen(true);
  };

  const confirmPick = async (ms: number | null) => {
    if (ms == null) return;
    try {
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
    <>
      <SectionCard
        title="提醒"
        trailing={
          <button
            type="button"
            onClick={addReminder}
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

      {/* datetime 选择器（Task 15）：initial=now+1h；确认创建提醒，清除不落库 */}
      <WaitDatePickerSheet
        open={pickerOpen}
        mode="datetime"
        initial={pickerInitial}
        onConfirm={(d) => void confirmPick(d ? d.getTime() : null)}
        onClose={() => setPickerOpen(false)}
      />
    </>
  );
}
