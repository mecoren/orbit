-- ============================================================================
-- Orbit（循迹）0001_init.sql —— 全新库初始化
-- 注意：v0.1.1 起迁移为增量演进（0002 起），本文件 DDL 不可改动
--（sqlx migrate 校验 checksum，改 0001 会让存量库打开失败）；
-- 结构变更一律新增序号迁移文件（见 0002/0003/0004）。
-- 来源：wait-home wait_core 0001/0003 指定行段平移重组（03 文档 §一/§二）。
-- 内容：sync 基础设施 2 表 + todo 业务 8 表 + cfg 必需 3 表
--       + 种子（模块行/收件箱/选项，选项用 category_key NOT EXISTS 幂等写法）
--       + uuid UNIQUE 索引治理段（原 0003 todo 8 表段并入）
-- ============================================================================

-- =============================================================================
-- 一、同步基础设施表（sync_ 前缀，2 张：sync_history + sync_configs）
-- =============================================================================

-- 同步历史记录
CREATE TABLE IF NOT EXISTS sync_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_type TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT '',
  started_at INTEGER NOT NULL DEFAULT 0,
  finished_at INTEGER,
  pulled_count INTEGER NOT NULL DEFAULT 0,
  pushed_count INTEGER NOT NULL DEFAULT 0,
  conflict_count INTEGER NOT NULL DEFAULT 0,
  error_message TEXT
);

-- 同步配置表（含 V3 周期同步字段）
CREATE TABLE IF NOT EXISTS sync_configs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    protocol TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    bucket TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL DEFAULT '',
    path TEXT NOT NULL DEFAULT '',
    device_id TEXT NOT NULL,
    credential TEXT NOT NULL DEFAULT '',
    encryption_key_id TEXT NOT NULL DEFAULT '',
    merge_strategy TEXT NOT NULL DEFAULT 'last_write_wins',
    sync_mode TEXT NOT NULL DEFAULT 'full',
    max_update_age_hours INTEGER NOT NULL DEFAULT 720,
    is_encrypted INTEGER NOT NULL DEFAULT 1,
    is_active INTEGER NOT NULL DEFAULT 0,
    is_auto_sync INTEGER NOT NULL DEFAULT 0,
    sync_interval INTEGER NOT NULL DEFAULT 30,
    sync_on_change INTEGER NOT NULL DEFAULT 0,
    concurrent_reqs INTEGER NOT NULL DEFAULT 1,
    timeout INTEGER NOT NULL DEFAULT 60,
    skip_tls_verify INTEGER NOT NULL DEFAULT 0,
    last_synced_at INTEGER,
    last_gc_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    version INTEGER NOT NULL DEFAULT 1,
    -- V3 周期同步字段
    targets TEXT NOT NULL DEFAULT '["local"]',
    local_path TEXT,
    schedule_type TEXT NOT NULL DEFAULT 'off',
    schedule_time TEXT,
    schedule_weekday INTEGER,
    sync_scope TEXT NOT NULL DEFAULT 'auto',
    full_sync_interval INTEGER NOT NULL DEFAULT 7,
    history_keep_count INTEGER NOT NULL DEFAULT 5,
    notify_progress INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_sync_configs_is_active ON sync_configs(is_active);

-- -----------------------------------------------------------------------------
-- 3.1 待办功能（todo_ 前缀，Vikunja 化：项目/任务/子任务/标签/评论/提醒/关系）
-- -----------------------------------------------------------------------------

-- 待办项目表
CREATE TABLE IF NOT EXISTS todo_projects (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  description TEXT,
  hex_color TEXT NOT NULL DEFAULT '#3B82F6',
  sort_order REAL NOT NULL DEFAULT 0,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_todo_projects_is_deleted ON todo_projects(is_deleted);
CREATE INDEX IF NOT EXISTS idx_todo_projects_uuid ON todo_projects(uuid);
CREATE INDEX IF NOT EXISTS idx_todo_projects_sort ON todo_projects(is_deleted, sort_order);

-- 待办任务表
CREATE TABLE IF NOT EXISTS todo_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  description TEXT,
  project_id INTEGER,
  priority INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending',
  done INTEGER NOT NULL DEFAULT 0,
  done_at INTEGER,
  due_date INTEGER,
  start_date INTEGER,
  end_date INTEGER,
  repeat_after INTEGER NOT NULL DEFAULT 0,
  repeat_mode INTEGER NOT NULL DEFAULT 0,
  percent_done REAL NOT NULL DEFAULT 0,
  position REAL NOT NULL DEFAULT 0,
  is_favorite INTEGER NOT NULL DEFAULT 0,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY (project_id) REFERENCES todo_projects(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_todo_tasks_is_deleted ON todo_tasks(is_deleted);
CREATE INDEX IF NOT EXISTS idx_todo_tasks_updated_at ON todo_tasks(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_todo_tasks_uuid ON todo_tasks(uuid);
CREATE INDEX IF NOT EXISTS idx_todo_tasks_project ON todo_tasks(project_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_todo_tasks_position ON todo_tasks(is_deleted, position);
CREATE INDEX IF NOT EXISTS idx_todo_tasks_done ON todo_tasks(done);
CREATE INDEX IF NOT EXISTS idx_todo_tasks_due_date ON todo_tasks(due_date);
CREATE INDEX IF NOT EXISTS idx_todo_tasks_is_favorite ON todo_tasks(is_favorite);

-- 待办子任务表
CREATE TABLE IF NOT EXISTS todo_subtasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT NOT NULL DEFAULT '',
  task_id INTEGER NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  done INTEGER NOT NULL DEFAULT 0,
  done_at INTEGER,
  position REAL NOT NULL DEFAULT 0,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_subtasks_task_id ON todo_subtasks(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_subtasks_uuid ON todo_subtasks(uuid);

-- 待办标签表
CREATE TABLE IF NOT EXISTS todo_labels (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  hex_color TEXT NOT NULL DEFAULT '#6B7280',
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_todo_labels_uuid ON todo_labels(uuid);

-- 任务-标签关联表
CREATE TABLE IF NOT EXISTS todo_task_labels (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT NOT NULL DEFAULT '',
  task_id INTEGER NOT NULL,
  label_id INTEGER NOT NULL,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE,
  FOREIGN KEY (label_id) REFERENCES todo_labels(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_task_labels_uuid ON todo_task_labels(uuid);
CREATE INDEX IF NOT EXISTS idx_todo_task_labels_task_id ON todo_task_labels(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_task_labels_label_id ON todo_task_labels(label_id);

-- 任务评论表
CREATE TABLE IF NOT EXISTS todo_comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT NOT NULL DEFAULT '',
  task_id INTEGER NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_comments_task_id ON todo_comments(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_comments_uuid ON todo_comments(uuid);

-- 任务关系表
CREATE TABLE IF NOT EXISTS todo_task_relations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT NOT NULL DEFAULT '',
  task_id INTEGER NOT NULL,
  other_task_id INTEGER NOT NULL,
  relation_type TEXT NOT NULL DEFAULT 'related',
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE,
  FOREIGN KEY (other_task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_task_relations_uuid ON todo_task_relations(uuid);
CREATE INDEX IF NOT EXISTS idx_todo_task_relations_task_id ON todo_task_relations(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_task_relations_other_task_id ON todo_task_relations(other_task_id);

-- 任务提醒表
CREATE TABLE IF NOT EXISTS todo_reminders (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT NOT NULL DEFAULT '',
  task_id INTEGER NOT NULL,
  remind_at INTEGER NOT NULL,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_reminders_task_id ON todo_reminders(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_reminders_remind_at ON todo_reminders(remind_at);
CREATE INDEX IF NOT EXISTS idx_todo_reminders_uuid ON todo_reminders(uuid);

CREATE TABLE IF NOT EXISTS cfg_option_categories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_key TEXT NOT NULL DEFAULT '',
  label TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  is_active INTEGER NOT NULL DEFAULT 1,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_cfg_option_categories_key_active
  ON cfg_option_categories(category_key) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_cfg_option_categories_is_active
  ON cfg_option_categories(is_active);

CREATE TABLE IF NOT EXISTS cfg_option_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id INTEGER NOT NULL,
  value TEXT NOT NULL DEFAULT '',
  label TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_default INTEGER NOT NULL DEFAULT 0,
  is_active INTEGER NOT NULL DEFAULT 1,
  color TEXT NOT NULL DEFAULT '',
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  FOREIGN KEY (category_id) REFERENCES cfg_option_categories(id)
);

CREATE INDEX IF NOT EXISTS idx_cfg_option_items_category_id
  ON cfg_option_items(category_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cfg_option_items_category_value_active
  ON cfg_option_items(category_id, value) WHERE deleted_at IS NULL;

-- ============================================================================
-- 附件元数据表（MVP 不接附件；表结构随库初始化预留）
-- ============================================================================

-- 附件元数据表（PK: hash）
CREATE TABLE IF NOT EXISTS sys_attachments (
  hash TEXT PRIMARY KEY,
  original_name TEXT NOT NULL DEFAULT '',
  mime_type TEXT NOT NULL DEFAULT '',
  size_bytes INTEGER NOT NULL DEFAULT 0,
  local_path TEXT,
  is_uploaded INTEGER NOT NULL DEFAULT 0,
  is_local_cached INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT ''
);
-- ============================================================================
-- 种子数据
-- ============================================================================

-- 2.1 待办默认项目"收件箱"（id=1，原 0004_todo_vikunja_refactor 迁移种子）
INSERT OR IGNORE INTO todo_projects (id, uuid, title, description, hex_color, sort_order, is_deleted, created_at, updated_at, version)
VALUES (1, '00000000-0000-0000-0000-000000000001', '收件箱', '默认项目', '#3B82F6', 0, 0, 0, 0, 1);

-- 选项分组（幂等：category_key 唯一索引兜底）
INSERT OR IGNORE INTO cfg_option_categories (category_key, label, description, is_active, sort_order, is_deleted, created_at, updated_at)
VALUES
  ('todo_priority', '优先级', '待办事项的优先级', 1, 1, 0, 0, 0),
  ('todo_status', '待办状态', '待办事项的状态', 1, 2, 0, 0, 0);

-- todo_priority 选项（五档；按 03 文档 §三 规格补齐 urgent/immediate 两档）
-- 幂等写法：category_key 子查询定位 + NOT EXISTS 防重（B 类改写规则，禁用裸 category_id）

INSERT INTO cfg_option_items (category_id, value, label, sort_order, is_default, is_active, color, is_deleted, created_at, updated_at)
SELECT c.id, 'low', '低', 1, 0, 1, '', 0, 0, 0
FROM cfg_option_categories c
WHERE c.category_key = 'todo_priority'
  AND NOT EXISTS (SELECT 1 FROM cfg_option_items i JOIN cfg_option_categories c2 ON i.category_id = c2.id
                 WHERE c2.category_key = 'todo_priority' AND i.value = 'low');

INSERT INTO cfg_option_items (category_id, value, label, sort_order, is_default, is_active, color, is_deleted, created_at, updated_at)
SELECT c.id, 'medium', '中', 2, 1, 1, '', 0, 0, 0
FROM cfg_option_categories c
WHERE c.category_key = 'todo_priority'
  AND NOT EXISTS (SELECT 1 FROM cfg_option_items i JOIN cfg_option_categories c2 ON i.category_id = c2.id
                 WHERE c2.category_key = 'todo_priority' AND i.value = 'medium');

INSERT INTO cfg_option_items (category_id, value, label, sort_order, is_default, is_active, color, is_deleted, created_at, updated_at)
SELECT c.id, 'high', '高', 3, 0, 1, '', 0, 0, 0
FROM cfg_option_categories c
WHERE c.category_key = 'todo_priority'
  AND NOT EXISTS (SELECT 1 FROM cfg_option_items i JOIN cfg_option_categories c2 ON i.category_id = c2.id
                 WHERE c2.category_key = 'todo_priority' AND i.value = 'high');

INSERT INTO cfg_option_items (category_id, value, label, sort_order, is_default, is_active, color, is_deleted, created_at, updated_at)
SELECT c.id, 'urgent', '紧急', 4, 0, 1, '', 0, 0, 0
FROM cfg_option_categories c
WHERE c.category_key = 'todo_priority'
  AND NOT EXISTS (SELECT 1 FROM cfg_option_items i JOIN cfg_option_categories c2 ON i.category_id = c2.id
                 WHERE c2.category_key = 'todo_priority' AND i.value = 'urgent');

INSERT INTO cfg_option_items (category_id, value, label, sort_order, is_default, is_active, color, is_deleted, created_at, updated_at)
SELECT c.id, 'immediate', '立即处理', 5, 0, 1, '', 0, 0, 0
FROM cfg_option_categories c
WHERE c.category_key = 'todo_priority'
  AND NOT EXISTS (SELECT 1 FROM cfg_option_items i JOIN cfg_option_categories c2 ON i.category_id = c2.id
                 WHERE c2.category_key = 'todo_priority' AND i.value = 'immediate');

INSERT INTO cfg_option_items (category_id, value, label, sort_order, is_default, is_active, color, is_deleted, created_at, updated_at)
SELECT c.id, 'pending', '待办', 1, 1, 1, '', 0, 0, 0
FROM cfg_option_categories c
WHERE c.category_key = 'todo_status'
  AND NOT EXISTS (SELECT 1 FROM cfg_option_items i JOIN cfg_option_categories c2 ON i.category_id = c2.id
                 WHERE c2.category_key = 'todo_status' AND i.value = 'pending');

INSERT INTO cfg_option_items (category_id, value, label, sort_order, is_default, is_active, color, is_deleted, created_at, updated_at)
SELECT c.id, 'doing', '进行中', 2, 0, 1, '', 0, 0, 0
FROM cfg_option_categories c
WHERE c.category_key = 'todo_status'
  AND NOT EXISTS (SELECT 1 FROM cfg_option_items i JOIN cfg_option_categories c2 ON i.category_id = c2.id
                 WHERE c2.category_key = 'todo_status' AND i.value = 'doing');

INSERT INTO cfg_option_items (category_id, value, label, sort_order, is_default, is_active, color, is_deleted, created_at, updated_at)
SELECT c.id, 'done', '已完成', 3, 0, 1, '', 0, 0, 0
FROM cfg_option_categories c
WHERE c.category_key = 'todo_status'
  AND NOT EXISTS (SELECT 1 FROM cfg_option_items i JOIN cfg_option_categories c2 ON i.category_id = c2.id
                 WHERE c2.category_key = 'todo_status' AND i.value = 'done');


-- ============================================================================
-- uuid 唯一索引治理（平移自 0003_sync_uuid_unique.sql todo 8 表段）
-- 防僵尸行复活的根措施：先去重历史重复 uuid，再建 UNIQUE 索引
-- ============================================================================

-- ============================================================================
-- todo_projects
-- ============================================================================
UPDATE todo_projects SET uuid = uuid || '#dup' || rowid
WHERE uuid IS NOT NULL AND uuid != '' AND rowid NOT IN (
  SELECT w FROM (
    SELECT rowid AS w, ROW_NUMBER() OVER (
      PARTITION BY uuid ORDER BY is_deleted ASC, updated_at DESC, rowid DESC
    ) AS rn FROM todo_projects WHERE uuid IS NOT NULL AND uuid != ''
  ) WHERE rn = 1
);
DROP INDEX IF EXISTS idx_todo_projects_uuid;
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_projects_uuid ON todo_projects(uuid);

-- ============================================================================
-- todo_tasks
-- ============================================================================
UPDATE todo_tasks SET uuid = uuid || '#dup' || rowid
WHERE uuid IS NOT NULL AND uuid != '' AND rowid NOT IN (
  SELECT w FROM (
    SELECT rowid AS w, ROW_NUMBER() OVER (
      PARTITION BY uuid ORDER BY is_deleted ASC, updated_at DESC, rowid DESC
    ) AS rn FROM todo_tasks WHERE uuid IS NOT NULL AND uuid != ''
  ) WHERE rn = 1
);
DROP INDEX IF EXISTS idx_todo_tasks_uuid;
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_tasks_uuid ON todo_tasks(uuid);

-- ============================================================================
-- todo_subtasks
-- ============================================================================
UPDATE todo_subtasks SET uuid = uuid || '#dup' || rowid
WHERE uuid IS NOT NULL AND uuid != '' AND rowid NOT IN (
  SELECT w FROM (
    SELECT rowid AS w, ROW_NUMBER() OVER (
      PARTITION BY uuid ORDER BY is_deleted ASC, updated_at DESC, rowid DESC
    ) AS rn FROM todo_subtasks WHERE uuid IS NOT NULL AND uuid != ''
  ) WHERE rn = 1
);
DROP INDEX IF EXISTS idx_todo_subtasks_uuid;
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_subtasks_uuid ON todo_subtasks(uuid);

-- ============================================================================
-- todo_labels
-- ============================================================================
UPDATE todo_labels SET uuid = uuid || '#dup' || rowid
WHERE uuid IS NOT NULL AND uuid != '' AND rowid NOT IN (
  SELECT w FROM (
    SELECT rowid AS w, ROW_NUMBER() OVER (
      PARTITION BY uuid ORDER BY is_deleted ASC, updated_at DESC, rowid DESC
    ) AS rn FROM todo_labels WHERE uuid IS NOT NULL AND uuid != ''
  ) WHERE rn = 1
);
DROP INDEX IF EXISTS idx_todo_labels_uuid;
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_labels_uuid ON todo_labels(uuid);

-- ============================================================================
-- todo_task_labels
-- ============================================================================
UPDATE todo_task_labels SET uuid = uuid || '#dup' || rowid
WHERE uuid IS NOT NULL AND uuid != '' AND rowid NOT IN (
  SELECT w FROM (
    SELECT rowid AS w, ROW_NUMBER() OVER (
      PARTITION BY uuid ORDER BY is_deleted ASC, updated_at DESC, rowid DESC
    ) AS rn FROM todo_task_labels WHERE uuid IS NOT NULL AND uuid != ''
  ) WHERE rn = 1
);
DROP INDEX IF EXISTS idx_todo_task_labels_uuid;
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_task_labels_uuid ON todo_task_labels(uuid);

-- ============================================================================
-- todo_comments
-- ============================================================================
UPDATE todo_comments SET uuid = uuid || '#dup' || rowid
WHERE uuid IS NOT NULL AND uuid != '' AND rowid NOT IN (
  SELECT w FROM (
    SELECT rowid AS w, ROW_NUMBER() OVER (
      PARTITION BY uuid ORDER BY is_deleted ASC, updated_at DESC, rowid DESC
    ) AS rn FROM todo_comments WHERE uuid IS NOT NULL AND uuid != ''
  ) WHERE rn = 1
);
DROP INDEX IF EXISTS idx_todo_comments_uuid;
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_comments_uuid ON todo_comments(uuid);

-- ============================================================================
-- todo_task_relations
-- ============================================================================
UPDATE todo_task_relations SET uuid = uuid || '#dup' || rowid
WHERE uuid IS NOT NULL AND uuid != '' AND rowid NOT IN (
  SELECT w FROM (
    SELECT rowid AS w, ROW_NUMBER() OVER (
      PARTITION BY uuid ORDER BY is_deleted ASC, updated_at DESC, rowid DESC
    ) AS rn FROM todo_task_relations WHERE uuid IS NOT NULL AND uuid != ''
  ) WHERE rn = 1
);
DROP INDEX IF EXISTS idx_todo_task_relations_uuid;
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_task_relations_uuid ON todo_task_relations(uuid);

-- ============================================================================
-- todo_reminders
-- ============================================================================
UPDATE todo_reminders SET uuid = uuid || '#dup' || rowid
WHERE uuid IS NOT NULL AND uuid != '' AND rowid NOT IN (
  SELECT w FROM (
    SELECT rowid AS w, ROW_NUMBER() OVER (
      PARTITION BY uuid ORDER BY is_deleted ASC, updated_at DESC, rowid DESC
    ) AS rn FROM todo_reminders WHERE uuid IS NOT NULL AND uuid != ''
  ) WHERE rn = 1
);
DROP INDEX IF EXISTS idx_todo_reminders_uuid;
CREATE UNIQUE INDEX IF NOT EXISTS ux_todo_reminders_uuid ON todo_reminders(uuid);
