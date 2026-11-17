-- 持续提醒间隔可配置（2026-11-17）
--
-- 0001 基线里持续提醒的顺延间隔写死为 core 常量 5 分钟（响到完成为止），
-- 用户无法按提醒的重要程度调整节奏。本迁移把间隔落成行级列：
--   * is_constant = 1 时，到期未完成按本列毫秒数原地顺延（不再读常量）；
--   * DEFAULT 300000（5 分钟）——存量行升级后行为与升级前完全一致；
--   * 写入侧按 [1 分钟, 24 小时] 钳制（models::business::clamp_constant_interval_ms），
--     0/负值视为未设置回落默认，老壳 JSON 不带该字段由 serde default 兜底。
ALTER TABLE todo_reminders
  ADD COLUMN constant_interval_ms INTEGER NOT NULL DEFAULT 300000;  -- 持续提醒间隔（毫秒）：is_constant=1 时到期未完成按此间隔原地顺延，默认 5 分钟
