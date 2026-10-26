-- 0012_task_done_at_index.sql
-- P1 规模档：Logbook（已完成列表）键集分页的排序索引。
--
-- Logbook 查询恒为 `done = 1 ORDER BY done_at DESC, id DESC`，历史数据里
-- done_at 可能为空（早期完成未记时间），分页 SQL 用
-- `ORDER BY (done_at IS NULL) ASC, done_at DESC, id DESC` 把空值沉底——
-- 故用表达式索引，让「过滤 + 有序扫 + LIMIT 提前终止」走同一棵树。
--
-- 注意 done 列放在 is_deleted 之后：Logbook 只查完成态，其余列表只查
-- 未完成（done = 0），两档都能命中该索引前缀。

CREATE INDEX IF NOT EXISTS idx_todo_tasks_done_at
  ON todo_tasks(is_deleted, done, (done_at IS NULL), done_at, id);
