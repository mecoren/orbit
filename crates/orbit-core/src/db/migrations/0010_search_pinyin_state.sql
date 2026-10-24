-- 0010_search_pinyin_state.sql
-- F5 拼音索引对账状态（docs/07 #104，docs/13 §七 P3 50k 实测）：
-- 把全量对账（`search_pinyin::reconcile`：3 条 DELETE + 3 条 LEFT JOIN 比对，
-- 合计 6 次全表扫描）搬离**只读查询路径**——50k 行下每次纯字母查询都白付
-- 316ms 对账，使搜索 p95 达 337ms，远超 P1 验收线 150ms。
--
-- 三条口径：
-- 1. **单行哨兵**：id 恒为 1。`dirty = 1` 表示「源表存在绕过 generic_repo 钩子
--    的直写行，索引需对账」。业务写路径（generic_repo 五点 / trash restore）
--    实时维护索引、不置脏；直写路径（云同步合并 / 全量备份恢复 / 批量导入 /
--    冲突副本恢复 / 子任务转出等裸 INSERT）在提交后置脏或直接补索引。
-- 2. **gen 单调递增**：每次置脏 +1。对账结束时只有「gen 仍等于开始读到的那一版」
--    才清零——并发的置脏不会被慢对账误清（宁可多对账一次，绝不少对账）。
-- 3. **不同步、不备份**：与 search_pinyin 同为可整表重建的本地派生状态，不进
--    SYNCABLE_TABLES / FULL_BACKUP_TABLES。**缺行等价于「需对账」**——老库升级
--    与备份恢复后的首查会自动补一次，与迁移前的行为一致。
CREATE TABLE IF NOT EXISTS search_pinyin_state (
  id INTEGER PRIMARY KEY,  -- 恒为 1（单行哨兵）
  dirty INTEGER NOT NULL DEFAULT 1,  -- 1 = 索引需对账 0 = 索引新鲜
  gen INTEGER NOT NULL DEFAULT 1,  -- 置脏代数（清零时的乐观锁）
  reconciled_at INTEGER NOT NULL DEFAULT 0  -- 上次完成对账的时刻（毫秒）
);
-- 种子行：存量库升级后首次拼音查询对账一次（与迁移前「每查必对账」的首查等价）
INSERT OR IGNORE INTO search_pinyin_state (id, dirty, gen, reconciled_at) VALUES (1, 1, 1, 0);
