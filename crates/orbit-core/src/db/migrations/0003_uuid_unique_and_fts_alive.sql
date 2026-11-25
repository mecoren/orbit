-- =============================================================================
-- 0003：可同步表 uuid 唯一索引补齐 + FTS INSERT 触发器只索引活行
--      （2026-11-25，对应 docs/03 §一「uuid 必须建 UNIQUE 索引」与 §六 白名单）
--
-- 1) 三张同步表缺 UNIQUE(uuid)：
--    `todo_task_attachments` / `todo_saved_filters` / `todo_templates` 都在
--    SYNCABLE_TABLES 内，但 0001 只给了普通 `idx_*_uuid`。缺唯一索引就丢了
--    「同步主键防僵尸行复活」的兜底（列注释与 docs/03 都写了 UNIQUE）。
--    老库可能已有空/重复 uuid（手工 SQLite 写入、早期 bug），直接 CREATE
--    UNIQUE INDEX 会让启动迁移失败 → 先回填、再去重，最后建索引。
--    uuid 是**不透明同步键**，回填值用 32 位 hex 即可（与 v4 串并存无碍）。
--
-- 2) FTS 的 AFTER INSERT 触发器缺 `is_deleted = 0` 谓词（AFTER UPDATE 一直有）：
--    云同步合并/备份恢复写墓碑行时会绕过业务层直接 INSERT，墓碑被索引进去；
--    `search_all` 的 FTS 首查不 join 源表（只靠 MATCH + kind 分流），墓碑会
--    占掉 LIMIT 名额导致存活结果少返回（不会泄漏，但会漏命中）。本迁移重建
--    四个 AI 触发器并清掉已进索引的墓碑。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. uuid 回填 + 去重 + 唯一索引
-- ---------------------------------------------------------------------------
UPDATE todo_task_attachments SET uuid = lower(hex(randomblob(16)))
  WHERE uuid IS NULL OR uuid = '';
UPDATE todo_task_attachments SET uuid = lower(hex(randomblob(16)))
  WHERE rowid NOT IN (SELECT MIN(rowid) FROM todo_task_attachments GROUP BY uuid);

UPDATE todo_saved_filters SET uuid = lower(hex(randomblob(16)))
  WHERE uuid IS NULL OR uuid = '';
UPDATE todo_saved_filters SET uuid = lower(hex(randomblob(16)))
  WHERE rowid NOT IN (SELECT MIN(rowid) FROM todo_saved_filters GROUP BY uuid);

UPDATE todo_templates SET uuid = lower(hex(randomblob(16)))
  WHERE uuid IS NULL OR uuid = '';
UPDATE todo_templates SET uuid = lower(hex(randomblob(16)))
  WHERE rowid NOT IN (SELECT MIN(rowid) FROM todo_templates GROUP BY uuid);

CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_task_attachments_uuid ON todo_task_attachments(uuid);
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_saved_filters_uuid ON todo_saved_filters(uuid);
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_templates_uuid ON todo_templates(uuid);

-- ---------------------------------------------------------------------------
-- 2. FTS：INSERT 只索引活行（与既有 AU 触发器同构）
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS fts_task_ai;
CREATE TRIGGER fts_task_ai AFTER INSERT ON todo_tasks
BEGIN
  INSERT INTO fts_todo(kind, ref_id, ref_uuid, task_id, title, body)
  SELECT 'task', NEW.id, NEW.uuid, NEW.id, NEW.title, COALESCE(NEW.description, '')
  WHERE NEW.is_deleted = 0;
END;

DROP TRIGGER IF EXISTS fts_subtask_ai;
CREATE TRIGGER fts_subtask_ai AFTER INSERT ON todo_subtasks
BEGIN
  INSERT INTO fts_todo(kind, ref_id, ref_uuid, task_id, title, body)
  SELECT 'subtask', NEW.id, NEW.uuid, NEW.task_id, NEW.title, ''
  WHERE NEW.is_deleted = 0;
END;

DROP TRIGGER IF EXISTS fts_comment_ai;
CREATE TRIGGER fts_comment_ai AFTER INSERT ON todo_comments
BEGIN
  INSERT INTO fts_todo(kind, ref_id, ref_uuid, task_id, title, body)
  SELECT 'comment', NEW.id, NEW.uuid, NEW.task_id, NEW.content, ''
  WHERE NEW.is_deleted = 0;
END;

DROP TRIGGER IF EXISTS fts_project_ai;
CREATE TRIGGER fts_project_ai AFTER INSERT ON todo_projects
BEGIN
  INSERT INTO fts_todo(kind, ref_id, ref_uuid, task_id, title, body)
  SELECT 'project', NEW.id, NEW.uuid, NEW.id, NEW.title, COALESCE(NEW.description, '')
  WHERE NEW.is_deleted = 0;
END;

-- 清掉本迁移前已进索引的墓碑行（幂等：删不到就空跑）
DELETE FROM fts_todo WHERE kind = 'task'
  AND ref_id IN (SELECT id FROM todo_tasks WHERE is_deleted = 1);
DELETE FROM fts_todo WHERE kind = 'subtask'
  AND ref_id IN (SELECT id FROM todo_subtasks WHERE is_deleted = 1);
DELETE FROM fts_todo WHERE kind = 'comment'
  AND ref_id IN (SELECT id FROM todo_comments WHERE is_deleted = 1);
DELETE FROM fts_todo WHERE kind = 'project'
  AND ref_id IN (SELECT id FROM todo_projects WHERE is_deleted = 1);
