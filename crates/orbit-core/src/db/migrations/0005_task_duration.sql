-- 0005_task_duration.sql
-- M9 阶段一「任务预计时长」（docs/10 B-2 / docs/11 Timeline 挂接项）：
-- 任务可记录预计耗时（分钟），行内徽标 + 表单/详情编辑可见；
-- 后续时间轴/时间块视图（周/日档 + 拖拽时段）以该列为数据地基。
--
-- 语义：NULL = 未设置（存量行语义零变化，靠 DEFAULT 原地回填）；
-- 分钟取正整数，上层 UI 负责下限（0 与负数视同未设置，不写库）。
-- 可空而非 NOT NULL DEFAULT 0：同步 merge 对老版本设备的载荷缺失字段绑 NULL
-- （列驱动合并，见 merge.rs），NULL = 未设置与「清空时长」语义一致，无回填歧义。
ALTER TABLE todo_tasks ADD COLUMN duration_minutes INTEGER DEFAULT NULL; -- 预计时长（分钟）；NULL = 未设置
