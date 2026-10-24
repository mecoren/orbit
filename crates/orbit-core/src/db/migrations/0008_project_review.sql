-- 0008_project_review.sql
-- F1 项目回顾节奏（docs/13 §五 F1，对标 OmniFocus Review）：
-- 每个项目可自带回顾周期，回顾中心按「到期 + 逾期天数」归集待回顾项目；
-- 不新增同步表：todo_projects 已在 SYNCABLE_TABLES，三列随整行同步，白名单零变更。
--
-- 语义：review_interval_days NULL/0 = 关闭回顾（7=每周 14=每两周 30=每月）；
-- review_snooze_until 为「暂缓到某日」（本地零点毫秒），到期判定取
-- max(周期到期, 暂缓日)——「稍后一周」只推迟，不重置周期。
-- 可空而非 NOT NULL DEFAULT 0：同步 merge 对老版本设备的载荷缺失字段绑 NULL
-- （列驱动合并，见 merge.rs），NULL = 未设置与「关闭」语义一致，无回填歧义
-- （与 0005_task_duration.sql 同款决策）。
ALTER TABLE todo_projects ADD COLUMN review_interval_days INTEGER DEFAULT NULL; -- 回顾周期（天）；NULL/0 = 关闭
ALTER TABLE todo_projects ADD COLUMN review_last_at INTEGER DEFAULT NULL; -- 上次回顾时间（毫秒）；NULL = 从未回顾
ALTER TABLE todo_projects ADD COLUMN review_snooze_until INTEGER DEFAULT NULL; -- 回顾暂缓截止（毫秒，本地零点口径）；NULL = 未暂缓
