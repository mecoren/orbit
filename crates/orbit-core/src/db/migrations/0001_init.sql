-- ============================================================================
-- Orbit（循迹）0001_init.sql —— 全新库初始化（单文件迁移）
-- 来源：wait-home wait_core 0001/0003 指定行段平移重组（03 文档 §一/§二）；
--       0002_my_day（my_day_date）、0003_holidays（cfg_holidays/cfg_kv）、
--       0004_remove_end_date（end_date 删列）已按 2026-09-07 决策并回本文件。
-- 内容：sync 基础设施 2 表 + todo 业务 8 表 + cfg 必需表 + 节假日缓存 2 表
--       + 种子（模块行/收件箱/选项，选项用 category_key NOT EXISTS 幂等写法）
--       + uuid UNIQUE 索引治理段（原 0003 todo 8 表段并入）
-- 维护约定：结构变更直接改本文件（不考虑增量迁移），改动后需删除本地
--       库文件重新初始化；已发布版本的存量库升级需删库重初始化，
--       数据经云同步/备份（.orsync）恢复。
--       字段备注为建表语句行尾 -- 注释，随 DDL 原样落库 sqlite_master
--       （GUI 工具打开库即见）；新增/变更字段须同步补写行尾备注。
-- ============================================================================

-- =============================================================================
-- 一、同步基础设施表（sync_ 前缀，2 张：sync_history + sync_configs）
-- =============================================================================

-- 同步历史记录
CREATE TABLE IF NOT EXISTS sync_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键
  sync_type TEXT NOT NULL DEFAULT '',  -- 同步类型：full | incremental | pull_only | push_only
  status TEXT NOT NULL DEFAULT '',  -- 状态：running 进行中 | success 成功 | failed 失败 | cancelled 取消
  started_at INTEGER NOT NULL DEFAULT 0,  -- 开始时间（ms 时间戳）
  finished_at INTEGER,  -- 结束时间（ms）；NULL = 尚未结束
  pulled_count INTEGER NOT NULL DEFAULT 0,  -- 本次拉取行数
  pushed_count INTEGER NOT NULL DEFAULT 0,  -- 本次推送行数
  conflict_count INTEGER NOT NULL DEFAULT 0,  -- 本次冲突行数（LWW 裁决次数）
  error_message TEXT  -- 失败原因（成功为 NULL）
);

-- 同步配置表（含 V3 周期同步字段）
CREATE TABLE IF NOT EXISTS sync_configs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键
    protocol TEXT NOT NULL,  -- 协议类型：webdav | s3（引擎按此分发适配器）
    endpoint TEXT NOT NULL,  -- 服务器地址（URL）
    bucket TEXT NOT NULL DEFAULT '',  -- S3 存储桶（WebDAV 为空）
    region TEXT NOT NULL DEFAULT '',  -- S3 地域（OSS/MinIO 签名用；WebDAV 为空）
    path TEXT NOT NULL DEFAULT '',  -- 远端 base_path（orbit/ 同步根下的子路径）
    device_id TEXT NOT NULL,  -- 设备标识：WebDAV 用户名 / S3 access_key（移动端复用为凭据）
    credential TEXT NOT NULL DEFAULT '',  -- 凭据：WebDAV 密码 / S3 secret_key（存证不回显）
    encryption_key_id TEXT NOT NULL DEFAULT '',  -- E2E 同步密钥 id（当前实现恒空串：密钥体系走 crypto/config 通道）
    merge_strategy TEXT NOT NULL DEFAULT 'last_write_wins',  -- 合并策略：last_write_wins（LWW 唯一实现；写侧填 lww 同义）
    sync_mode TEXT NOT NULL DEFAULT 'full',  -- 同步模式（写侧恒 two_way；协议字段 0x02 Incremental 预留未用）
    max_update_age_hours INTEGER NOT NULL DEFAULT 720,  -- 远端更新最大容忍时限（小时，0=不限；当前两端写 0）
    is_encrypted INTEGER NOT NULL DEFAULT 1,  -- 云同步 E2E 加密开关：0 关 1 开（默认 1）
    is_active INTEGER NOT NULL DEFAULT 0,  -- 激活标记：同库仅一档配置激活（互斥由仓储层保证）
    is_auto_sync INTEGER NOT NULL DEFAULT 0,  -- 自动同步总开关：0 关 1 开（60s tick 判据之一）
    sync_interval INTEGER NOT NULL DEFAULT 30,  -- 定时同步间隔（分钟，0=关；tick 判据：距上次 ≥ interval）
    sync_on_change INTEGER NOT NULL DEFAULT 0,  -- 数据变更即同步开关：0 关 1 开
    concurrent_reqs INTEGER NOT NULL DEFAULT 1,  -- 并发请求数（Pull buffer_unordered 并行度，两端写 8）
    timeout INTEGER NOT NULL DEFAULT 60,  -- 请求超时（秒，0=默认 30s）
    skip_tls_verify INTEGER NOT NULL DEFAULT 0,  -- 跳过 TLS 证书校验（自签名场景）：0 关 1 开
    last_synced_at INTEGER,  -- 上次同步成功时间（ms，调度判据）；NULL = 从未同步
    last_gc_at INTEGER,  -- 上次云空间垃圾回收时间（ms）；预留字段暂无写入方
    created_at INTEGER NOT NULL,  -- 创建时间（ms 时间戳）
    updated_at INTEGER NOT NULL,  -- 更新时间（ms）——同步 LWW 合并的主依据
    deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
    version INTEGER NOT NULL DEFAULT 1,  -- 乐观锁版本号，每次写 +1；LWW 同毫秒平局时的大者胜
    -- V3 周期同步字段
    targets TEXT NOT NULL DEFAULT '["local"]',  -- V3 周期同步：目标模块（JSON 数组字符串；两端实际写 ["local"]/"todo"）
    local_path TEXT,  -- V3：本地备份目录（None 回退 app_data_dir/backups/）；NULL = 默认
    schedule_type TEXT NOT NULL DEFAULT 'off',  -- V3：调度类型（V3 谱系 off/interval/daily…；当前两端写 off/interval）
    schedule_time TEXT,  -- V3：调度时刻 HH:mm（daily+ 档用）；NULL = 未设置
    schedule_weekday INTEGER,  -- V3：周几 0=周日…6=周六（weekly 档用）；NULL = 未设置
    sync_scope TEXT NOT NULL DEFAULT 'auto',  -- V3：同步范围（当前两端写 all）
    full_sync_interval INTEGER NOT NULL DEFAULT 7,  -- V3：全量同步间隔（天，0=每次全量）；当前两端写 0
    history_keep_count INTEGER NOT NULL DEFAULT 5,  -- V3：sync_history 保留条数（TTL 清理阈值）
    notify_progress INTEGER NOT NULL DEFAULT 1  -- V3：同步进度通知开关：0 关 1 开（默认 1）
);

CREATE INDEX IF NOT EXISTS idx_sync_configs_is_active ON sync_configs(is_active);

-- -----------------------------------------------------------------------------
-- 3.1 待办功能（todo_ 前缀，Vikunja 化：项目/任务/子任务/标签/评论/提醒/关系）
-- -----------------------------------------------------------------------------

-- 待办项目表
CREATE TABLE IF NOT EXISTS todo_projects (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  title TEXT NOT NULL DEFAULT '',  -- 名称
  description TEXT,  -- 描述（可空）
  hex_color TEXT NOT NULL DEFAULT '#3B82F6',  -- 颜色（#RRGGBB，默认蓝 #3B82F6；侧栏圆点+项目名着色）
  sort_order REAL NOT NULL DEFAULT 0,  -- 侧栏排序键（拖拽取中值）
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
);
CREATE INDEX IF NOT EXISTS idx_todo_projects_is_deleted ON todo_projects(is_deleted);
CREATE INDEX IF NOT EXISTS idx_todo_projects_uuid ON todo_projects(uuid);
CREATE INDEX IF NOT EXISTS idx_todo_projects_sort ON todo_projects(is_deleted, sort_order);

-- 待办任务表
CREATE TABLE IF NOT EXISTS todo_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  title TEXT NOT NULL DEFAULT '',  -- 名称
  description TEXT,  -- 描述（可空）
  project_id INTEGER,  -- 所属项目 id → todo_projects.id（ON DELETE SET NULL：删项目不删任务）
  priority INTEGER NOT NULL DEFAULT 0,  -- 优先级：0 无 / 1 低 / 2 中 / 3 高 / 4 紧急 / 5 立即处理
  status TEXT NOT NULL DEFAULT 'pending',  -- 状态：pending 待办 | doing 进行中 | done 已完成（done 时 done/done_at 联动写入）
  done INTEGER NOT NULL DEFAULT 0,  -- 完成标记：0 未完成 1 已完成（与 status=done 联动）
  done_at INTEGER,  -- 完成时间（ms）；NULL = 未完成
  due_date INTEGER,  -- 截止日期（ms 时间戳）；NULL = 无
  start_date INTEGER,  -- 开始日期（ms 时间戳）；NULL = 无
  repeat_after INTEGER NOT NULL DEFAULT 0,  -- 重复间隔数（≥1；0 = 不重复，配合 repeat_mode）
  repeat_mode INTEGER NOT NULL DEFAULT 0,  -- 重复模式：0 不重复 / 1 按天 / 2 按周 / 3 按月 / 4 按年
  -- 重复规则扩展（07 竞品矩阵批次 #34，四款参考产品全有）：
  -- repeat_weekdays：星期几位掩码（bit0=周一 … bit6=周日；仅 WEEKLY 生效，
  --   0 = 未指定回落旧语义"每 N 周的今天"；多选时 due 推进到掩码内的下一个星期几）
  -- repeat_end_type：结束条件 0=永不 1=按日期 2=按次数
  -- repeat_end_param：日期型=结束日 ms 时间戳 / 次数型=剩余次数
  -- repeat_from_done：0=锚定原 due 推进（默认，节奏恒定）
  --   1=when done 按完成日推进（理发式：迟到三周完成，下次仍四周后）
  repeat_weekdays INTEGER NOT NULL DEFAULT 0,
  repeat_end_type INTEGER NOT NULL DEFAULT 0,
  repeat_end_param INTEGER NOT NULL DEFAULT 0,
  repeat_from_done INTEGER NOT NULL DEFAULT 0,
  percent_done REAL NOT NULL DEFAULT 0,  -- 完成百分比 0–100：由后端按子任务勾选自动回算，无手动滑块
  position REAL NOT NULL DEFAULT 0,  -- 列表/看板排序键：拖拽取中值 ((prev??0)+(next??100000))/2
  is_favorite INTEGER NOT NULL DEFAULT 0,  -- 收藏标记：0 普通 1 收藏（星标）
  -- My Day「我的一天」（原 0002_my_day 并入；07 竞品报告 §五新增项，
  -- 对标微软 To Do 每日聚焦视图）：my_day_date 存「加入当天」的本地零点
  -- 时间戳（ms）；NULL = 不在任何一天的 My Day。次日「自动清空」是视图
  -- 侧按日判断（my_day_date == 今天零点），不改数据——与微软 To Do 一致：
  -- 昨天加入但没完成的任务会回到原项目，可再次「加入我的一天」。
  my_day_date INTEGER,
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1,  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
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
CREATE INDEX IF NOT EXISTS idx_todo_tasks_my_day ON todo_tasks(my_day_date) WHERE my_day_date IS NOT NULL;
-- 回收站墓碑过滤+排序（list_trashed 的 is_deleted+deleted_at DESC 与 TTL purge 的 deleted_at 谓词共用）
CREATE INDEX IF NOT EXISTS idx_todo_tasks_trash ON todo_tasks(is_deleted, deleted_at DESC);

-- 待办子任务表
CREATE TABLE IF NOT EXISTS todo_subtasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  task_id INTEGER NOT NULL,  -- 所属任务 id → todo_tasks.id（ON DELETE CASCADE）
  title TEXT NOT NULL DEFAULT '',  -- 名称
  done INTEGER NOT NULL DEFAULT 0,  -- 完成标记：0 未完成 1 已完成
  done_at INTEGER,  -- 完成时间（ms）；NULL = 未完成
  position REAL NOT NULL DEFAULT 0,  -- 排序键：手动档拖拽取中值
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1,  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_subtasks_task_id ON todo_subtasks(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_subtasks_uuid ON todo_subtasks(uuid);

-- 待办标签表
CREATE TABLE IF NOT EXISTS todo_labels (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  title TEXT NOT NULL DEFAULT '',  -- 名称
  hex_color TEXT NOT NULL DEFAULT '#6B7280',  -- 颜色（#RRGGBB，默认灰 #6B7280；列表行标签色点）
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
);
CREATE INDEX IF NOT EXISTS idx_todo_labels_uuid ON todo_labels(uuid);

-- 任务-标签关联表
CREATE TABLE IF NOT EXISTS todo_task_labels (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  task_id INTEGER NOT NULL,  -- 任务 id → todo_tasks.id（ON DELETE CASCADE）
  label_id INTEGER NOT NULL,  -- 标签 id → todo_labels.id（ON DELETE CASCADE）
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1,  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE,
  FOREIGN KEY (label_id) REFERENCES todo_labels(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_task_labels_uuid ON todo_task_labels(uuid);
CREATE INDEX IF NOT EXISTS idx_todo_task_labels_task_id ON todo_task_labels(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_task_labels_label_id ON todo_task_labels(label_id);

-- 任务评论表
CREATE TABLE IF NOT EXISTS todo_comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  task_id INTEGER NOT NULL,  -- 任务 id → todo_tasks.id（ON DELETE CASCADE）
  content TEXT NOT NULL DEFAULT '',  -- 评论正文
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1,  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_comments_task_id ON todo_comments(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_comments_uuid ON todo_comments(uuid);

-- 任务关系表
CREATE TABLE IF NOT EXISTS todo_task_relations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  task_id INTEGER NOT NULL,  -- 本任务 id → todo_tasks.id（ON DELETE CASCADE）
  other_task_id INTEGER NOT NULL,  -- 对方任务 id → todo_tasks.id（ON DELETE CASCADE）
  relation_type TEXT NOT NULL DEFAULT 'related',  -- 关系类型：subtask 子任务 / blocks 阻塞 / blocked_by 被阻塞 / relates_to 关联 / duplicates 重复于 / duplicated_by 重复项
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1,  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE,
  FOREIGN KEY (other_task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_task_relations_uuid ON todo_task_relations(uuid);
CREATE INDEX IF NOT EXISTS idx_todo_task_relations_task_id ON todo_task_relations(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_task_relations_other_task_id ON todo_task_relations(other_task_id);

-- 任务提醒表
CREATE TABLE IF NOT EXISTS todo_reminders (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  task_id INTEGER NOT NULL,  -- 任务 id → todo_tasks.id（ON DELETE CASCADE）
  remind_at INTEGER NOT NULL,  -- 提醒触发时间（ms）；轮询扫描窗口：已到且 ≤24h
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1,  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_reminders_task_id ON todo_reminders(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_reminders_remind_at ON todo_reminders(remind_at);
CREATE INDEX IF NOT EXISTS idx_todo_reminders_uuid ON todo_reminders(uuid);

-- 任务-附件关联表（07 排查报告后续批次：任务附件功能）
-- 引用 sys_attachments 的内容寻址 hash（不复制行）：
-- 附件二进制走 assets/{hash}.waitsync 内容寻址通道（cloud_sync/attachments.rs），
-- 本表只同步「哪个任务挂了哪个 hash」的关联关系，随 todos 模块同步。
CREATE TABLE IF NOT EXISTS todo_task_attachments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  task_id INTEGER NOT NULL,  -- 任务 id → todo_tasks.id（ON DELETE CASCADE）
  hash TEXT NOT NULL,  -- 附件内容寻址 hash → sys_attachments.hash（不复制行）
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1,  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
  FOREIGN KEY (task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_todo_task_attachments_uuid ON todo_task_attachments(uuid);
CREATE INDEX IF NOT EXISTS idx_todo_task_attachments_task_id ON todo_task_attachments(task_id);
CREATE INDEX IF NOT EXISTS idx_todo_task_attachments_hash ON todo_task_attachments(hash);

-- 保存的筛选器（07 竞品矩阵批次 #35；对标 Apple Smart List / Tasks.org
-- 可保存过滤器 / Obsidian Presets 四款参考产品全有）
-- conditions 为 JSON：{status, priority_min, project_ids, label_ids, due_within_days,
-- due_overdue, favorite_only}——查询侧按存在键过滤，缺键 = 不过滤
CREATE TABLE IF NOT EXISTS todo_saved_filters (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  name TEXT NOT NULL DEFAULT '',  -- 筛选器名称（侧栏显示）
  conditions TEXT NOT NULL DEFAULT '{}',  -- 条件 JSON：{status, priority_min, project_ids, label_ids, due_within_days, due_overdue, favorite_only}——按存在键过滤，缺键 = 不过滤
  sort_order INTEGER NOT NULL DEFAULT 0,  -- 侧栏排序键
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
);
CREATE INDEX IF NOT EXISTS idx_todo_saved_filters_uuid ON todo_saved_filters(uuid);

-- 任务模板（竞品矩阵高价值缺口；对标 MS To Do 步骤列表可复用 / Vikunja Templates /
-- Snippets：周报、报销单、差旅检查清单等多字段任务免从零搭建）
-- payload 为 JSON：{title?, notes?, priority?, due_offset_days?, subtasks?: [string]}
-- 套用 = 按 payload 预填任务表单（前端行为）；模板本体仅存字段，不引用项目/标签实体
-- （跨设备实体 id 不稳定，模板内容自包含保证同步语义稳定）
CREATE TABLE IF NOT EXISTS todo_templates (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  uuid TEXT NOT NULL DEFAULT '',  -- 同步主键：跨设备行标识，UNIQUE 索引兜底防僵尸行复活
  name TEXT NOT NULL DEFAULT '',  -- 模板名称（模板选择列表显示）
  payload TEXT NOT NULL DEFAULT '{}',  -- 模板内容 JSON：{title?, notes?, priority?, due_offset_days?, subtasks?}——套用时按存在键预填，缺键 = 不预填
  sort_order INTEGER NOT NULL DEFAULT 0,  -- 模板列表排序键
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  version INTEGER NOT NULL DEFAULT 1  -- 乐观锁版本号，每次写更新 +1；LWW 同毫秒平局时的大者胜
);
CREATE INDEX IF NOT EXISTS idx_todo_templates_uuid ON todo_templates(uuid);

CREATE TABLE IF NOT EXISTS cfg_option_categories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  category_key TEXT NOT NULL DEFAULT '',  -- 分组键（如 todo_priority / todo_status；唯一索引兜底）
  label TEXT NOT NULL DEFAULT '',  -- 分组显示名（如「优先级」）
  description TEXT NOT NULL DEFAULT '',  -- 分组说明
  is_active INTEGER NOT NULL DEFAULT 1,  -- 启用标记：0 停用 1 启用
  sort_order INTEGER NOT NULL DEFAULT 0,  -- 分组排序键
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER  -- 软删时间（ms，墓碑）；NULL = 未删
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_cfg_option_categories_key_active
  ON cfg_option_categories(category_key) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_cfg_option_categories_is_active
  ON cfg_option_categories(is_active);

CREATE TABLE IF NOT EXISTS cfg_option_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增，非同步键）
  category_id INTEGER NOT NULL,  -- 所属分组 id → cfg_option_categories.id
  value TEXT NOT NULL DEFAULT '',  -- 选项存值（如 high / pending；业务实际引用此类字符串）
  label TEXT NOT NULL DEFAULT '',  -- 选项显示名（如「高」「待办」）
  sort_order INTEGER NOT NULL DEFAULT 0,  -- 组内排序键
  is_default INTEGER NOT NULL DEFAULT 0,  -- 默认选中标记：0 否 1 是（如优先级默认 medium）
  is_active INTEGER NOT NULL DEFAULT 1,  -- 启用标记：0 停用 1 启用
  color TEXT NOT NULL DEFAULT '',  -- 选项色（可空；未消费）
  is_deleted INTEGER NOT NULL DEFAULT 0,  -- 软删标记：0 活 1 已删（回收站/墓碑，物理清除走 TTL）
  created_at INTEGER NOT NULL DEFAULT 0,  -- 创建时间（ms 时间戳）
  updated_at INTEGER NOT NULL DEFAULT 0,  -- 更新时间（ms）——同步 LWW 合并的主依据
  deleted_at INTEGER,  -- 软删时间（ms，墓碑）；NULL = 未删
  FOREIGN KEY (category_id) REFERENCES cfg_option_categories(id)
);

CREATE INDEX IF NOT EXISTS idx_cfg_option_items_category_id
  ON cfg_option_items(category_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cfg_option_items_category_value_active
  ON cfg_option_items(category_id, value) WHERE deleted_at IS NULL;

-- 节假日数据层（原 0003_holidays 并入；用户需求：日历视图联网更新节假日，
-- 定时每天固定时间更新一次 + 手动更新 + 错过更新时间下次开启自动补更）
--
-- cfg_holidays：节假日缓存表（只存中国法定节假日的放假/调休补班日；非节假日
-- 不落行，查不到 = 普通工作日/周末按星期判定）。is_holiday=1 放假、0 调休补班。
-- 数据源 timor.tech /api/holiday/year/{y}（详见 api/holiday_api.rs）。
--
-- cfg_kv：本地 KV 元数据表（节假日更新记账：last_update_ms / last_attempt_ms /
-- fixed_time / failure_count 等）。两表均为**本地配置缓存**，不进 SYNCABLE_TABLES
-- 白名单（节假日数据可由各端自行拉取，无需云同步；旧版本客户端同步包中无此表
-- 亦无影响——行级 _table 路由只分发白名单内的表）。
CREATE TABLE IF NOT EXISTS cfg_holidays (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键
  date TEXT NOT NULL,  -- 日期（YYYY-MM-DD；UNIQUE）
  year INTEGER NOT NULL,  -- 年份（定时更新/补更的按年记账维度）
  is_holiday INTEGER NOT NULL,  -- 1 放假 0 调休补班（非节假日不落行）
  name TEXT NOT NULL DEFAULT '',  -- 节假日名称（如「国庆节」）
  created_at INTEGER NOT NULL DEFAULT 0  -- 写入时间（ms；每年节假日批量刷新时按年重写）
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cfg_holidays_date ON cfg_holidays(date);

CREATE TABLE IF NOT EXISTS cfg_kv (
  key TEXT PRIMARY KEY,  -- 键（主键）
  value TEXT NOT NULL DEFAULT '',  -- 值（JSON/字符串）
  updated_at INTEGER NOT NULL DEFAULT 0  -- 更新时间（ms）
);

-- ============================================================================
-- 附件元数据表（MVP 不接附件；表结构随库初始化预留）
-- ============================================================================

-- 附件元数据表（PK: hash）
-- 通知历史（#5 通知历史中心；Todoist 同款专门通知页）
-- 桌面 Windows Toast / 移动端系统通知一旦错过或清掉即无处回看——本表
-- 记录提醒到期呈现轨迹（reminder 到期/通知 action），供设置页回看。
-- **只读本地日志表**：不进 SYNCABLE_TABLES 白名单（各端各自记录各自的
-- 呈现轨迹，跨端混看无意义），口径同统计类聚合表。
CREATE TABLE IF NOT EXISTS notification_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增）
  kind TEXT NOT NULL DEFAULT '',  -- 记录类型：reminder_due=提醒到期 / snooze=推迟 / complete=通知上完成 / boot_skip=启动跳过（防补弹轰炸的静默跳过也留痕）
  task_id INTEGER,  -- 关联任务 id（可空——任务可能后续被删）
  task_title TEXT NOT NULL DEFAULT '',  -- 任务标题快照（删除后仍可读）
  reminder_id INTEGER,  -- 关联提醒行 id（可空——完成 action 无提醒行）
  payload TEXT NOT NULL DEFAULT '{}',  -- 附加 JSON：{remind_at, snooze_until, source} 等快照
  created_at INTEGER NOT NULL DEFAULT 0  -- 记录时间（ms；查询按其倒序）
);
CREATE INDEX IF NOT EXISTS idx_notification_log_created ON notification_log(created_at);
CREATE INDEX IF NOT EXISTS idx_notification_log_task ON notification_log(task_id);

-- 任务操作活动日志（2026-09-12 F6：对标 Todoist Activity log / Things 历史区）
-- 本地只读轨迹：各端各自记录，不进 SYNCABLE_TABLES（口径同 notification_log）；
-- 任务删除后仍可读（title 快照 + detail JSON 存变更字段集）
CREATE TABLE IF NOT EXISTS todo_activity_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增）
  task_id INTEGER,  -- 关联任务 id（可空——任务可能后续进回收站/彻底删除）
  task_title TEXT NOT NULL DEFAULT '',  -- 任务标题快照（删除后仍可读）
  action TEXT NOT NULL DEFAULT '',  -- 操作类型：create=创建 / update=字段变更 / complete=完成 / uncomplete=恢复未完成 / delete=删除(软删入回收站) / restore=从回收站恢复
  detail TEXT NOT NULL DEFAULT '{}',  -- 附加 JSON：{fields:[变更字段名], from, to} 等（update 记变更字段集）
  created_at INTEGER NOT NULL DEFAULT 0  -- 记录时间（ms；查询按其倒序）
);
CREATE INDEX IF NOT EXISTS idx_todo_activity_log_created ON todo_activity_log(created_at);
CREATE INDEX IF NOT EXISTS idx_todo_activity_log_task ON todo_activity_log(task_id);

CREATE TABLE IF NOT EXISTS sys_attachments (
  hash TEXT PRIMARY KEY,  -- 内容寻址主键：附件二进制的 sha256（同 hash 复用即去重）
  original_name TEXT NOT NULL DEFAULT '',  -- 原始文件名
  mime_type TEXT NOT NULL DEFAULT '',  -- MIME 类型（如 image/png）
  size_bytes INTEGER NOT NULL DEFAULT 0,  -- 文件字节数
  local_path TEXT,  -- 本地缓存路径（assets/{hash}）；NULL = 未缓存
  is_uploaded INTEGER NOT NULL DEFAULT 0,  -- 已上传标记：0 否 1 是
  is_local_cached INTEGER NOT NULL DEFAULT 0,  -- 本地缓存标记：0 否 1 是
  created_at INTEGER NOT NULL DEFAULT 0  -- 入库时间（ms）
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
