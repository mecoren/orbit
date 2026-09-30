-- 0002_reminder_constant.sql
-- G2 持续提醒（对标 TickTick Constant Reminder）：「响到完成为止」。
--
-- 语义：到期触发后若任务仍未完成，同一提醒行按固定间隔顺延重排
-- （core 常量 CONSTANT_REARM_INTERVAL_MS = 5 分钟），直至任务完成或提醒被删；
-- 完成后由 list_due_reminders 的 done 过滤 + 完成命令软删存活行双重收口。
--
-- 0 = 一次性提醒（默认；存量行语义零变化，靠 DEFAULT 原地回填）
ALTER TABLE todo_reminders ADD COLUMN is_constant INTEGER NOT NULL DEFAULT 0; -- 持续提醒标记：1=未完成则按间隔顺延重排，0=一次性
