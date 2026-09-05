-- My Day「我的一天」（07 竞品报告 §五新增项，对标微软 To Do 每日聚焦视图）
--
-- 语义：my_day_date 存「加入当天」的本地零点时间戳（ms）；NULL = 不在任何一天的 My Day。
-- 次日「自动清空」是视图侧按日判断（my_day_date == 今天零点），不改数据——
-- 与微软 To Do 一致：昨天加入但没完成的任务会回到原项目，可再次「加入我的一天」。
-- 列随行同步（todo_tasks 在 SYNCABLE_TABLES 白名单内，行级 _table 路由 + LWW，
-- 旧版本客户端忽略未知列，schema 前向兼容）。
ALTER TABLE todo_tasks ADD COLUMN my_day_date INTEGER;
CREATE INDEX IF NOT EXISTS idx_todo_tasks_my_day ON todo_tasks(my_day_date) WHERE my_day_date IS NOT NULL;
