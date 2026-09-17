-- ============================================================================
-- 0002_sync_conflicts.sql —— 冲突败方副本（03 文档 §八 遗留项兑现）
-- 来源：docs/03_数据模型与同步.md §八「冲突败方副本：冲突时败方字段仍被覆盖
--      丢弃（仅计数可见），需新增本地副本表 + 查看/恢复 UI」。
--
-- 语义：merge 做 LWW 裁决时，把**败方**整行字段快照留档，用户可在
--       设置 → 同步与备份 → 冲突记录 里查看并「恢复为我方版本」
--       （恢复 = 以败方内容发起一次新的本地写入，因而会赢得下一轮同步）。
--
-- 落库判据（为避免把「他端正常顺延更新」误记为冲突，只记**真并发**）：
--   本地记录与远端记录都晚于「上次同步成功时的逻辑时钟」才留档；
--   从未同步过（基线为 0）时不留档——两端独立数据集合并不是冲突。
--
-- 本表为**纯本地表**：不进 SYNCABLE_TABLES（各端各自记录各自的裁决现场，
-- 跨端混看无意义），也不进全量备份白名单，口径同 notification_log /
-- todo_activity_log。写作方：cloud_sync/merge.rs（同一事务内落库，
-- 与合并结果原子）。
-- ============================================================================

CREATE TABLE IF NOT EXISTS sync_conflicts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- 主键（本地自增）
  table_name TEXT NOT NULL DEFAULT '',  -- 冲突所在业务表（白名单表名）
  record_uuid TEXT NOT NULL DEFAULT '',  -- 冲突记录 uuid（恢复时按此定位原行）
  record_title TEXT NOT NULL DEFAULT '',  -- 记录标题快照（便于列表展示；原行被删后仍可读）
  decision TEXT NOT NULL DEFAULT 'lww',  -- 裁决类型：lww=时间戳裁决 / tie_version=同毫秒按 version 裁决
  loser_side TEXT NOT NULL DEFAULT 'remote',  -- 败方归属：local 本地被覆盖 / remote 远端被丢弃
  winner_side TEXT NOT NULL DEFAULT 'local',  -- 胜方归属：local / remote（与败方相反）
  loser_payload TEXT NOT NULL DEFAULT '{}',  -- 败方整行字段快照 JSON（不含 id/uuid；恢复即回放它）
  winner_payload TEXT NOT NULL DEFAULT '{}',  -- 胜方整行字段快照 JSON（对比展示用）
  loser_updated_at INTEGER NOT NULL DEFAULT 0,  -- 败方逻辑时钟时间戳（ms）
  winner_updated_at INTEGER NOT NULL DEFAULT 0,  -- 胜方逻辑时钟时间戳（ms）
  resolution TEXT NOT NULL DEFAULT 'unresolved',  -- 处置状态：unresolved 未处理 / restored 已恢复 / dismissed 已忽略
  created_at INTEGER NOT NULL DEFAULT 0,  -- 冲突留档时间（ms；列表按其倒序）
  resolved_at INTEGER NOT NULL DEFAULT 0  -- 处置时间（ms）；0 = 未处置
);

-- 待处理列表（设置页默认视图：未处理 + 时间倒序）
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_resolution
  ON sync_conflicts(resolution, created_at DESC);
-- 同一条记录的多次冲突归并查询
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_record
  ON sync_conflicts(table_name, record_uuid);
