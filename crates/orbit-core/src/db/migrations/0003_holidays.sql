-- 节假日数据层（用户需求：日历视图联网更新节假日，定时每天固定时间更新一次 +
-- 手动更新 + 错过更新时间下次开启自动补更）
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
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,
  year INTEGER NOT NULL,
  is_holiday INTEGER NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cfg_holidays_date ON cfg_holidays(date);

CREATE TABLE IF NOT EXISTS cfg_kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL DEFAULT 0
);
