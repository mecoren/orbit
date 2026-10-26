-- 0011_task_keyset_indexes.sql
-- P1 50k 规模档：任务列表键集分页的排序索引。
--
-- 分页 SQL 恒带 `is_deleted = 0` 基线与 `ORDER BY <排序键>, id`（id 是 rowid
-- 别名，单调唯一，作为 tiebreaker）；索引把 `is_deleted` 放首列，让
-- 「过滤 + 有序扫 + LIMIT 提前终止」走同一棵索引树，避免 50k 档的临时 B 树排序。
--
-- manual 档复用既有 idx_todo_tasks_position(is_deleted, position)：SQLite 二级
-- 索引隐式带 rowid，`position, id` 序无需另建。due 档既有
-- idx_todo_tasks_alive_due(is_deleted, due_date) 不含「无截止沉底」表达式，
-- 故补一条表达式索引。
--
-- 三档的默认方向按前端 BASE_SORT_DIR：priority/created 降序，due 升序；
-- 索引方向与默认方向一致，反方向查询 SQLite 可反向扫（代价是同量级）。

-- 优先级档：priority DESC, position ASC, id ASC
CREATE INDEX IF NOT EXISTS idx_todo_tasks_keyset_priority
  ON todo_tasks(is_deleted, priority DESC, position, id);

-- 创建时间档：created_at（默认 DESC）, id
CREATE INDEX IF NOT EXISTS idx_todo_tasks_keyset_created
  ON todo_tasks(is_deleted, created_at, id);

-- 截止时间档：无截止恒沉底（表达式索引）+ due_date + id
CREATE INDEX IF NOT EXISTS idx_todo_tasks_keyset_due
  ON todo_tasks(is_deleted, (due_date IS NULL), due_date, id);
