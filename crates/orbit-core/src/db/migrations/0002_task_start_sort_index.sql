-- 开始时间档键集分页索引（2026-10-29）：与截止时间档（idx_todo_tasks_keyset_due）同构。
-- 分页 SQL 恒带 is_deleted = 0，并按 (start_date IS NULL) 把无开始的行整体沉底；
-- 表达式列承载 NULL 尾段，升/降序共用一棵索引树（反方向可反向扫）。
CREATE INDEX IF NOT EXISTS idx_todo_tasks_keyset_start
  ON todo_tasks(is_deleted, (start_date IS NULL), start_date, id);
