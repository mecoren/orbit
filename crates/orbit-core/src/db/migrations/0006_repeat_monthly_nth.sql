-- 0006 重复规则每月第 N 个星期 X（docs/07 #72）
-- 月重复的高级语义：按日号推进之外，支持「每月第 N 个星期 X」
-- （如每月第 2 个周二、每月最后一个周五）。
ALTER TABLE todo_tasks ADD COLUMN repeat_month_mode INTEGER NOT NULL DEFAULT 0; -- 重复月模式：0按日号 1按第N个星期X（仅MONTHLY生效）
ALTER TABLE todo_tasks ADD COLUMN repeat_nth_week INTEGER NOT NULL DEFAULT 0; -- 月内第几个星期：1-5/6=末，0=未指定回落日号
