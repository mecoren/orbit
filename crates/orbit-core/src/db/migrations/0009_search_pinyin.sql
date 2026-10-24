-- 0009_search_pinyin.sql
-- F5 拼音/首字母搜索（docs/13 §五 F5，docs/07 #101）：
-- 本地派生索引（方案 A）——「gzs → 工作总结」「gz → 工作」的首字母/全拼检索。
--
-- 三条关键口径：
-- 1. **不同步、不备份**：search_pinyin 是可整表重建的派生索引（非业务数据），
--    不进 SYNCABLE_TABLES / FULL_BACKUP_TABLES（白名单零变更）；
-- 2. **uuid 为 PRIMARY KEY**：task/project/comment 三类源行的同步主键全局唯一，
--    一行一索引（kind 记录来源表）；title 原文随索引落库——reconcile 对账
--    （补缺失/清幽灵/更新不一致）以 title 相等为准，无需比较拼音串；
-- 3. **写入双通道**：业务写路径（generic_repo create/update/软删 + trash
--    restore）实时维护；同步合并/CSV 导入等直写路径由查询入口 reconcile
--    幂等兜底（缺失即补、不一致即重建）。
-- 拼音由 pinyin crate（MIT）在 Rust 侧计算（spike 实测 10k 回填 2.7ms，
-- 见 docs/13 §五 F5 落地记录），SQLite 内不引入自定义函数。
CREATE TABLE IF NOT EXISTS search_pinyin (
  uuid TEXT PRIMARY KEY,  -- 被索引源行的同步主键（task/project/comment）
  kind TEXT NOT NULL,  -- 来源表：'task' | 'project' | 'comment'
  title TEXT NOT NULL DEFAULT '',  -- 被索引文本原版（对账基准）
  pinyin_full TEXT NOT NULL DEFAULT '',  -- 全拼串（无声调小写；非汉字原样保留）
  initials TEXT NOT NULL DEFAULT '',  -- 首字母串（与 pinyin_full 逐字符对应）
  updated_at INTEGER NOT NULL DEFAULT 0  -- 索引写入时间（毫秒；对账调试用）
);
CREATE INDEX IF NOT EXISTS idx_search_pinyin_kind ON search_pinyin(kind, uuid);
