/**
 * use-todo-reminder-listener — 提醒兜底通道（03 文档 §五）
 *
 * 监听 Rust 轮询守护 emit 的 "todo_reminder:due"，以自定义 sonner
 * toast 展示（含推迟 10 分钟 / 30 分钟 / 1 小时操作，删旧建新语义见
 * reminder-snooze.ts）；系统通知失败时此通道保证用户必达。
 *
 * 另监听两条系统通知动作的落地事件：
 * - "todo_reminder:snoozed"（推迟按钮）→ 关 toast + 确认提示 + 失效详情缓存；
 * - "todo_reminder:completed"（G2 持续提醒的「完成」按钮）→ 关 toast +
 *   确认提示 + 失效任务列表/计数/详情缓存。
 *
 * 到期处置（重复任务续排/僵尸清理）已下沉 Rust 轮询守护
 * （orbit-core advance_fired_reminder，窗口隐藏也照常执行），
 * 本 hook 只负责呈现，不再操作 todo_reminders 数据。
 *
 * 桌面端无运行时通知权限概念（移动端已拆分为 Flutter 应用，
 * 其权限流程由 apps/mobile 自行实现）。
 */
import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { router } from "@/router";
import { remindAtClockLabel, snoozeReminder } from "@/features/todo/shared/reminder-snooze";
import { ReminderToast } from "@/features/todo/shared/reminder-toast";
import { openTaskFromReminder } from "@/features/todo/shared/reminder-nav";

interface ReminderDuePayload {
  id: number;
  task_id: number;
  title: string;
  remind_at: number;
  /** 持续提醒标记（1 = 响到完成为止）——正文标注用 */
  is_constant: number;
}

/** Rust 系统通知推迟完成事件（notify-rust action → 删旧建新后 emit） */
interface ReminderSnoozedPayload {
  reminder_id: number;
  task_id: number;
  remind_at: number;
  title: string;
}

/** Rust 系统通知「完成」按钮落地事件（G2 持续提醒：完成即停） */
interface ReminderCompletedPayload {
  reminder_id: number;
  task_id: number;
  title: string;
}

/** 系统通知正文点击路由事件（Rust 唤起主窗后 emit） */
interface ReminderOpenPayload {
  task_id: number;
  title: string;
}

/**
 * reminder.id → in-app toast id（snoozed/completed 事件到达时按源 id 关对应 toast）
 *
 * 删除路径三条：snoozed/completed 事件、onDone 按钮、onDismiss（手动划掉）。
 * 前两条自初始版在位；手动划掉路径 2026-10-12 补齐（docs/09 §五 复核结论，
 * 此前每手动划掉一个常驻 toast 残留一项）。
 */
// bounded-by-data: 键为提醒行 id，同一提醒重复响只覆盖同键；三条删除路径覆盖后不残留
const reminderToastIds = new Map<number, number | string>();

export function useTodoReminderListener() {
  const qc = useQueryClient();
  useEffect(() => {
    // 系统通知（右下角弹窗）点推迟按钮后：Rust 已删旧建新并广播。
    // 前端三件事：按 reminder_id 关闭对应 in-app toast（duration Infinity
    // 常驻，不关会一直挂着，且其引用的提醒行已被删——再点它会建出
    // 平行提醒）+ 弹与站内推迟同款确认 + 失效详情缓存刷新提醒区块
    const unlistenSnoozed = listen<ReminderSnoozedPayload>(
      "todo_reminder:snoozed",
      (event) => {
        const { reminder_id, task_id, remind_at, title } = event.payload;
        const toastId = reminderToastIds.get(reminder_id);
        if (toastId != null) {
          toast.dismiss(toastId);
          reminderToastIds.delete(reminder_id);
        }
        toast.success(`已推迟到 ${remindAtClockLabel(remind_at)}`, {
          description: title,
          duration: 4_000,
        });
        void qc.invalidateQueries({ queryKey: ["todo-task-detail", task_id] });
      },
    );
    // 系统通知「完成」按钮（G2 持续提醒专属）：Rust 已完成任务并广播。
    // 前端关闭对应常驻 in-app toast（其引用的提醒行已被完成命令软删）
    // + 确认提示 + 失效任务列表/详情缓存（行内勾选态、提醒区块即时同步）
    const unlistenCompleted = listen<ReminderCompletedPayload>(
      "todo_reminder:completed",
      (event) => {
        const { reminder_id, task_id, title } = event.payload;
        const toastId = reminderToastIds.get(reminder_id);
        if (toastId != null) {
          toast.dismiss(toastId);
          reminderToastIds.delete(reminder_id);
        }
        toast.success("已完成", { description: title, duration: 4_000 });
        void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
        void qc.invalidateQueries({ queryKey: ["count"] });
        void qc.invalidateQueries({ queryKey: ["todo-task-detail", task_id] });
      },
    );
    const unlistenPromise = listen<ReminderDuePayload>("todo_reminder:due", (event) => {
      const r = event.payload;
      // 窗口隐藏（驻留托盘）期间不弹 in-app toast：系统通知才是后台
      // 提醒通道；隐藏期弹的 Infinity toast 会在恢复窗口时堆积成
      // 一片过期卡片（「8 点的提醒 12 点打开还在」的另一半根因）。
      // WebView 隐藏时 visibilityState=hidden（Win/mac 实测语义）
      if (document.visibilityState !== "visible") return;
      // 持续提醒顺延后同一 id 会再次到期（G2）：先关上一轮常驻卡再挂新的。
      // 不关则 Infinity toast 逐轮堆积；更糟的是旧卡的 onDismiss 闭包里
      // 持有同一个 r.id，用户划掉旧卡会把新卡的映射一并删掉，
      // 后续 snoozed/completed 事件再也关不掉新卡。
      const prevToastId = reminderToastIds.get(r.id);
      if (prevToastId != null) {
        toast.dismiss(prevToastId);
        reminderToastIds.delete(r.id);
      }
      // toast.custom 支持 jsx 内容（sonner 单 action 按钮装不下三个推迟档）
      toast.custom(
        (id) => {
          reminderToastIds.set(r.id, id);
          return (
            <ReminderToast
              title={r.title}
              remindAt={r.remind_at}
              isConstant={r.is_constant !== 0}
              onSnooze={(minutes) =>
                snoozeReminder(
                  r.id,
                  r.task_id,
                  r.remind_at,
                  minutes,
                  qc,
                  r.is_constant,
                )
              }
              onViewTask={() => {
                // §7-③：与全局搜索/命令面板同范式——写 selectedTaskId 打开
                // 详情抽屉（跨面板常驻）。本 hook 挂在 ReadyShell
                // （RouterProvider 外），不能 useNavigate——直接用 router
                // 单例实例导航（等效 imperative navigate("/todo")）
                const dest = openTaskFromReminder(r.task_id);
                void router.navigate(dest);
              }}
              onDone={() => {
                reminderToastIds.delete(r.id);
                toast.dismiss(id);
              }}
            />
          );
        },
        // 不自动消失：推迟/关闭都由按钮驱动；避免超时关闭后用户失去入口
        {
          duration: Infinity,
          // 覆盖最后一条删除路径：用户手动划掉 toast（sonner 的 dismiss
          // 与按钮关闭都会回调 onDismiss），避免登记表残留
          onDismiss: () => reminderToastIds.delete(r.id),
        },
      );
      // 到期处置（重复任务续排/已完成实例清理）由 Rust 轮询守护在 emit
      // 前后异步执行（orbit-core advance_fired_reminder），本监听器只呈现
    });
    // 系统通知正文点击 → 打开任务详情抽屉（Rust 已唤起主窗；窗口隐藏/
    // 回收态由 Rust show_or_create 兜底，事件延迟 2s 到达保证监听已挂载）
    const unlistenOpen = listen<ReminderOpenPayload>("todo_reminder:open", (event) => {
      const { task_id } = event.payload;
      const dest = openTaskFromReminder(task_id);
      void router.navigate(dest);
    });
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
      unlistenSnoozed.then((unlisten) => unlisten());
      unlistenCompleted.then((unlisten) => unlisten());
      unlistenOpen.then((unlisten) => unlisten());
    };
  }, [qc]);
}
