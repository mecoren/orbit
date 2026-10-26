//! business — Orbit 业务表数据模型（MVP 所需段落）
//!
//! 平移自 wait-home wait_core models/business.rs（02 文档 §四 A 类），仅保留：
//! FlexibleI64 / ListFilter / todo 8 表全部 struct。
//! 字段与 0001_init.sql 一一对应；DateTime 统一 i64 毫秒时间戳；可空字段 Option<T>。

use serde::{Deserialize, Serialize};
use sqlx::Type;
use sqlx::TypeInfo;
use sqlx::ValueRef;
use sqlx::decode::Decode;
use sqlx::sqlite::{Sqlite, SqliteTypeInfo, SqliteValueRef};

/// 兼容 INTEGER 与「数字文本」(TEXT) 的整型包装。
///
/// 背景：rec_devices 等表历史上部分数值列（acquired_at 等）
/// 被以 TEXT 形式写入，而 Rust 模型声明为 INTEGER，SQLx 在 `SELECT *` 反序列化时
/// 会因「Rust i64 与 SQL TEXT 不兼容」直接报错，导致整张表列表/详情查询失败。
///
/// 该类型在 Decode 阶段同时接受 INTEGER 与数字 TEXT（空串/非数字则视为 None），
/// Serde 透明序列化为 `Option<i64>`，对前端无感知、无需改动数据库 schema。
#[derive(Debug, Clone, Copy, Default)]
pub struct FlexibleI64(pub Option<i64>);

impl<'r> Decode<'r, Sqlite> for FlexibleI64 {
    fn decode(value: SqliteValueRef<'r>) -> Result<Self, sqlx::error::BoxDynError> {
        if value.is_null() {
            return Ok(FlexibleI64(None));
        }
        match value.type_info().name() {
            "INTEGER" => {
                let v = <i64 as Decode<Sqlite>>::decode(value)?;
                Ok(FlexibleI64(Some(v)))
            }
            "TEXT" | "REAL" => {
                let s = <String as Decode<Sqlite>>::decode(value)?;
                let trimmed = s.trim();
                if trimmed.is_empty() {
                    Ok(FlexibleI64(None))
                } else {
                    Ok(FlexibleI64(trimmed.parse::<i64>().ok()))
                }
            }
            _ => Ok(FlexibleI64(None)),
        }
    }
}

impl Serialize for FlexibleI64 {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.0 {
            Some(v) => serializer.serialize_some(&v),
            None => serializer.serialize_none(),
        }
    }
}

impl Type<Sqlite> for FlexibleI64 {
    fn type_info() -> SqliteTypeInfo {
        <i64 as Type<Sqlite>>::type_info()
    }
}

impl<'de> Deserialize<'de> for FlexibleI64 {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let opt = Option::<i64>::deserialize(deserializer)?;
        Ok(FlexibleI64(opt))
    }
}

// ========== 通用过滤条件 ==========

/// 通用列表过滤条件（所有业务表共用）。
///
/// 谓词下推（2026-09-12 F5）：`done`/`status`/`priority_min`/`project_id`/
/// `project_ids`/`favorite_only`/`my_day_today` 仅 `todo_tasks` 表消费
/// （其他表忽略），语义与前端 `shared/task-filters.ts` 的 filterTasks 对齐
/// ——面板主查询把视图/工具栏筛选下推到 SQL，替代万行全量拉取后内存过滤。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ListFilter {
    pub keyword: Option<String>,
    pub page: u32,
    pub page_size: u32,
    /// 完成态过滤：Some(true)=仅已完成，Some(false)=仅未完成，None=不过滤
    pub done: Option<bool>,
    /// 状态等值（pending/doing/done）
    pub status: Option<String>,
    /// 优先级下限（priority >= 此值）
    pub priority_min: Option<i32>,
    /// 项目 id 等值（软删行已由基线谓词排除）
    pub project_id: Option<i64>,
    /// 项目 id **集合**（`project_id IN (...)`）：清单文件夹聚合——
    /// 选中父清单时客户端把「自身 + 全部后代项目 id」算好传入。非空集合时
    /// 优先于 [Self::project_id]（二者不叠加）；空集合 = 空结果（不是不过滤）。
    pub project_ids: Option<Vec<i64>>,
    /// 仅收藏（is_favorite = 1）
    pub favorite_only: Option<bool>,
    /// 我的一天：仅 my_day_date = 今天本地零点（调用方算好零点传入；
    /// Rust 侧不做本地日界换算以免时区口径分裂）
    pub my_day_today: Option<i64>,
    /// 未分组视图：Some(true) = `project_id IS NULL`（与前端 ungrouped 分支同义）
    pub ungrouped: Option<bool>,
    /// 优先级等值（工具栏优先级筛选是单值档，不是区间）
    pub priority_eq: Option<i32>,
    /// 排除早于此时刻的截止（毫秒）：逾期置顶段由独立查询取走后，主列表用
    /// `(due_date IS NULL OR due_date >= ?)` 把逾期行排除，避免同一行渲染两次。
    /// 与 [Self::due_from] 的区别：本项**保留无截止行**，due_from 是严格区间。
    pub exclude_due_before: Option<i64>,
    /// 是否有截止日期：`Some(false)` = `due_date IS NULL`（日历「未排期」区），
    /// `Some(true)` = 有截止；None 不限。与 [Self::due_from] 的严格区间互补。
    pub has_due: Option<bool>,
    /// 排序键（仅 todo_tasks 的分页通道消费）：`manual` / `due` / `priority` /
    /// `created` / `done_at`（Logbook 完成时间倒序）；None = `manual`（与桌面
    /// `TaskSortKey` 默认值一致）。
    ///
    /// `title` 档**不在此列**：前端按 `localeCompare("zh-Hans-CN")` 排中文拼音序，
    /// SQLite 的 BINARY collation 复刻不了（多音字与声调都会分叉），强行下推会让
    /// 分页边界与用户看到的顺序不一致。该档继续走旧的全量单页通道。
    pub sort_key: Option<String>,
    /// 排序方向 `asc` / `desc`；None = 各档默认方向（manual 恒升序、due 升序、
    /// priority 降序、created 降序），与前端 `BASE_SORT_DIR` 同口径。
    pub sort_dir: Option<String>,
    /// 截止时间下界（毫秒，含）。日历视图按可见范围取数用（P1 窗口化）。
    pub due_from: Option<i64>,
    /// 截止时间上界（毫秒，不含）。与 [Self::due_from] 组成半开区间。
    pub due_to: Option<i64>,
}

/// 键集分页游标（P1 50k 规模档）。
///
/// 键集（keyset）而非 offset：offset 在数据变动时会跳过/重复行，且 `OFFSET N`
/// 让 SQLite 先扫过前 N 行（50k 档翻到尾部是 O(N)）。游标取「上一页最后一行的
/// 排序键值 + 主键 id」，下一页从该位置严格向后取。
///
/// 三个值共同描述边界，缺一不可：
/// - `sort_key` / `dir`：防止换排序档后误用旧游标（换档即作废，返回空页由
///   前端重置）；
/// - `key` / `key2`：排序主键与次键（`priority` 档的 `position` 回落）；
/// - `id`：唯一 tiebreaker（`todo_tasks.id` 是 rowid 别名，单调且唯一）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ListCursor {
    /// 生成游标时的排序键（manual/due/priority/created）
    pub sort_key: String,
    /// 生成游标时的方向（asc/desc）
    pub dir: String,
    /// 排序主键值（position / priority / created_at / due_date）。
    /// `due` 档为 None 表示已进入「无截止」尾段。
    pub key: Option<f64>,
    /// 次排序键（仅 `priority` 档使用：同优先级按 `position` 升序）
    pub key2: Option<f64>,
    /// 唯一 tiebreaker（todo_tasks.id）
    pub id: i64,
}

/// 任务分页结果（[crate::db::repository::generic_repo::list_tasks_page]）。
///
/// 不返回 `total`：每次翻页都 `COUNT(*)` 会把 50k 档的首屏成本翻倍。总数由
/// [TodoTaskOverview] 的独立聚合接口给（前端「已加载 X / 共 Y」用）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskPage {
    pub items: Vec<TodoTaskListItem>,
    /// 下一页游标；None = 已到末页
    pub next_cursor: Option<ListCursor>,
    /// 是否还有下一页（比 `next_cursor.is_some()` 更直白，供桥层直接用）
    pub has_more: bool,
}

/// 任务总览聚合（P1 窗口化后替代「壳层拉全量再内存聚合」）。
///
/// 侧栏未完成计数原先从壳层万行数组 `GROUP BY` 得来，窗口化后列表只装已加载
/// 窗口，必须由 SQL 直接聚合。口径与旧的内存聚合一致：
/// - 只算 `is_deleted = 0` 的活行；
/// - 只算 `done = 0`；
/// - 归档项目的任务不计入（对齐旧壳层查询的归档排除子句）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TodoTaskOverview {
    /// 当前筛选下的任务总数（不含分页，`done`/项目等谓词照常生效）
    pub total: i64,
    /// 各项目的未完成计数（含 project_id = None 的「未分组」桶）
    pub undone_by_project: Vec<TodoProjectUndone>,
}

/// 单个项目的未完成计数（[TodoTaskOverview] 的行）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoProjectUndone {
    pub project_id: Option<i64>,
    pub count: i64,
}

/// 看板/四象限分组维度（P1 窗口化：列内只取前 N 条 + 组总数）
///
/// 列键与桌面 `shared/kanban-group.ts` 的 `kanbanColumnKey` 逐字一致
/// （`"ungrouped"` / `"pri:3"` / `"due:today"` / `"urgentImportant"`…），
/// 前端拿 key 直接对列，不需要二次映射。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BoardGroupBy {
    Project,
    Status,
    Priority,
    Due,
    /// 四象限（艾森豪威尔）：截止 < 今日 24:00 = 紧急，priority ≥ 3 = 重要
    Quadrant,
}

/// 看板单列：组键 + 该组总条数（不受 limit 影响）+ 前 N 条
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskBoardGroup {
    pub key: String,
    pub total: i64,
    pub items: Vec<TodoTaskListItem>,
}

/// 看板/四象限一次往返（groups 只含实际有任务的组）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskBoard {
    pub groups: Vec<TodoTaskBoardGroup>,
    /// 各组合计（= 当前筛选下命中总数，供「共 Y 条」条幅）
    pub total: i64,
}

// ---------- todo_projects ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoProject {
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub description: Option<String>,
    pub hex_color: String,
    pub sort_order: f64,
    /// 上级文件夹（父项目）的**同步主键 uuid**；None = 顶层（M8 清单文件夹分组）
    ///
    /// 存 uuid 而非本表 id：云同步的整数外键翻译只支持表间引用（父表先于子表定序 +
    /// 从本端已落库行建映射），自引用会让父行未到即整表合并失败并永久卡住。
    /// 详见 `db/migrations/0003_project_parent.sql` 头注释。
    pub parent_uuid: Option<String>,
    /// 项目回顾节奏（F1，0008 迁移）：回顾周期天数；None/0 = 关闭
    /// （7=每周 14=每两周 30=每月；到期判定与归集见 project_review_api）
    pub review_interval_days: Option<i64>,
    /// 上次回顾时间（毫秒）；None = 从未回顾（开启周期即视为到期，最需要被看见）
    pub review_last_at: Option<i64>,
    /// 回顾暂缓截止（毫秒，本地零点口径）；None = 未暂缓。
    /// 到期取 max(周期到期, 暂缓日)——暂缓只推迟不重置周期
    pub review_snooze_until: Option<i64>,
    pub is_archived: i32,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_projects 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoProjectCreateInput {
    pub title: String,
    pub description: Option<String>,
    pub hex_color: Option<String>,
    pub sort_order: Option<f64>,
    /// 上级文件夹 uuid（M8）；None / 空串 = 顶层
    #[serde(default)]
    pub parent_uuid: Option<String>,
}

/// todo_projects 更新输入（Option<Option<T>> 模式）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TodoProjectUpdateInput {
    pub title: Option<String>,
    pub description: Option<Option<String>>,
    pub hex_color: Option<String>,
    pub sort_order: Option<f64>,
    /// 归档切换：Some(1)=归档（侧栏折叠区+不进默认任务列表），Some(0)=恢复
    pub is_archived: Option<i32>,
    /// 上级文件夹 uuid（M8）：外层 Some = 本次要改，内层 None = 移到顶层
    ///
    /// `nullable::deserialize`：JSON `null` / 缺键在这一层才能分开——
    /// 缺键 → 外层 None（不改）；`null` → `Some(None)`（移到顶层）。
    /// 空白串同样按「顶层」处理（见 `normalize_parent_uuid`），前端清空控件时
    /// 无论提交 null 还是 "" 语义一致。
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub parent_uuid: Option<Option<String>>,
    /// 项目回顾节奏（F1）：外层 Some = 本次要改，内层 None/0 = 关闭回顾。
    /// 常规写路径走 project_review_api 的语义化入口（开启时补 last_at 起算、
    /// 关闭时清残留暂缓），直写本字段仅同步合并与导入链路
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub review_interval_days: Option<Option<i64>>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub review_last_at: Option<Option<i64>>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub review_snooze_until: Option<Option<i64>>,
}

// ---------- todo_tasks ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoTask {
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub description: Option<String>,
    pub project_id: Option<i64>,
    pub priority: i32,
    pub status: String,
    pub done: i32,
    pub done_at: Option<i64>,
    pub due_date: Option<i64>,
    pub start_date: Option<i64>,
    pub repeat_after: i64,
    pub repeat_mode: i32,
    /// 重复规则扩展（#34）：星期几位掩码（bit0=周一…bit6=周日；仅 WEEKLY 生效）
    pub repeat_weekdays: i32,
    /// 结束条件 0=永不 1=按日期 2=按次数
    pub repeat_end_type: i32,
    /// 结束参数：日期型=结束日 ms / 次数型=剩余次数
    pub repeat_end_param: i64,
    /// when done 语义：0=锚定原 due 推进 1=按完成日推进
    pub repeat_from_done: i32,
    /// 月重复模式（#72）：0=按日号 1=按第N个星期X（仅 MONTHLY 生效）
    pub repeat_month_mode: i32,
    /// 月内第几个星期（#72）：1-5/6=末，0=未指定回落日号；星期几复用 repeat_weekdays 单 bit
    pub repeat_nth_week: i32,
    pub percent_done: f64,
    pub position: f64,
    pub is_favorite: i32,
    /// My Day「我的一天」：加入当天本地零点 ms；NULL = 不在任何一天的 My Day
    /// （07 报告新增项，对标微软 To Do；次日自动清空为视图侧按日判断，不改数据）
    pub my_day_date: Option<i64>,
    /// 任务预计时长（M9 阶段一）：分钟数；NULL = 未设置
    pub duration_minutes: Option<i64>,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// 列表通道瘦行 DTO（内存治理 A2）：`list_todo_tasks` 的返回形状。
///
/// 与 [TodoTask] 的差别只在**列表通道零消费**的 10 列被整体移除——
/// `uuid`、`repeat_after`、六个更细的 `repeat_*`（weekdays/end_type/
/// end_param/from_done/month_mode/nth_week）、`deleted_at`、`version`。
/// 移除的是**键本身**（`"repeat_end_type":0,` 一行 20 字节，万行即 1.98MB）：
/// 占位表达式只能省值、省不掉键名，故这里走独立 DTO 而不是 `NULL AS ...`。
///
/// 消费边界（2026-10-14 全仓复核，新增列表消费点前必须重新核实）：
/// - **保留**的有消费列：`start_date`（桌面右键菜单提醒档
///   `task-context-menu.tsx`、移动时间轴 `logic/time_block.dart`）、
///   `repeat_mode`（移动列表/日历重复徽标判 `> 0`）、`created_at`
///   （桌面 `sortTasks` 排序与 Logbook 分组、保存筛选器 `created_from`）、
///   `description`（桌面搜索通道的本地收敛分支，见
///   `generic_repo::LIST_COLUMNS_TASKS`）；
/// - 被移除的 10 列只在**单行全列**路径消费：`get_todo_task` /
///   `todo_task_get_detail` / 回收站列表 / 同步 push-pull / 活动日志 /
///   事件载荷，那些路径仍返回 [TodoTask] 全列。
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoTaskListItem {
    pub id: i64,
    pub title: String,
    pub description: Option<String>,
    pub project_id: Option<i64>,
    pub priority: i32,
    pub status: String,
    pub done: i32,
    pub done_at: Option<i64>,
    pub due_date: Option<i64>,
    pub start_date: Option<i64>,
    pub repeat_mode: i32,
    pub percent_done: f64,
    pub position: f64,
    pub is_favorite: i32,
    pub my_day_date: Option<i64>,
    pub duration_minutes: Option<i64>,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
}

/// todo_tasks 创建输入
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TodoTaskCreateInput {
    pub title: String,
    pub description: Option<String>,
    pub project_id: Option<i64>,
    pub priority: Option<i32>,
    pub status: Option<String>,
    pub done: Option<i32>,
    pub done_at: Option<i64>,
    pub due_date: Option<i64>,
    pub start_date: Option<i64>,
    pub repeat_after: Option<i64>,
    pub repeat_mode: Option<i32>,
    #[serde(default)]
    pub repeat_weekdays: Option<i32>,
    #[serde(default)]
    pub repeat_end_type: Option<i32>,
    #[serde(default)]
    pub repeat_end_param: Option<i64>,
    #[serde(default)]
    pub repeat_from_done: Option<i32>,
    #[serde(default)]
    pub repeat_month_mode: Option<i32>,
    #[serde(default)]
    pub repeat_nth_week: Option<i32>,
    pub position: Option<f64>,
    pub is_favorite: Option<i32>,
    pub my_day_date: Option<i64>,
    #[serde(default)]
    pub duration_minutes: Option<i64>,
}

/// 反序列化 `Option<Option<T>>` 的可空字段。
///
/// 约定：
/// - 字段**缺失** → `None`（表示「不更新该列」）
/// - 字段**存在且为 null** → `Some(None)`（表示「将该列清空为 NULL」）
/// - 字段**存在且有值** → `Some(Some(v))`（表示「更新为 v」）
///
/// 标准 serde 对 `Option<Option<T>>` 反序列化 JSON `null` 会得到 `None`（外层 Option 短路），
/// 导致前端传 `project_id: null` 等「清空」意图被误判为「不更新」。此函数修正该行为。
mod nullable {
    use serde::de::{self, Visitor};
    use serde::{Deserialize, Deserializer};
    use std::fmt;
    use std::marker::PhantomData;

    pub fn deserialize<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
    where
        D: Deserializer<'de>,
        T: Deserialize<'de>,
    {
        struct OptOptVisitor<T>(PhantomData<T>);
        impl<'de, T: Deserialize<'de>> Visitor<'de> for OptOptVisitor<T> {
            type Value = Option<Option<T>>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("optional value (null clears)")
            }
            fn visit_none<E: de::Error>(self) -> Result<Self::Value, E> {
                Ok(Some(None))
            }
            fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
                Ok(Some(None))
            }
            fn visit_some<D2>(self, d: D2) -> Result<Self::Value, D2::Error>
            where
                D2: Deserializer<'de>,
            {
                Ok(Some(Some(T::deserialize(d)?)))
            }
        }
        deserializer.deserialize_option(OptOptVisitor(PhantomData))
    }
}

/// todo_tasks 更新输入（Option<Option<T>> 模式）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskUpdateInput {
    pub title: Option<String>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub description: Option<Option<String>>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub project_id: Option<Option<i64>>,
    pub priority: Option<i32>,
    pub status: Option<String>,
    pub done: Option<i32>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub done_at: Option<Option<i64>>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub due_date: Option<Option<i64>>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub start_date: Option<Option<i64>>,
    pub repeat_after: Option<i64>,
    pub repeat_mode: Option<i32>,
    #[serde(default)]
    pub repeat_weekdays: Option<i32>,
    #[serde(default)]
    pub repeat_end_type: Option<i32>,
    #[serde(default)]
    pub repeat_end_param: Option<i64>,
    #[serde(default)]
    pub repeat_from_done: Option<i32>,
    #[serde(default)]
    pub repeat_month_mode: Option<i32>,
    #[serde(default)]
    pub repeat_nth_week: Option<i32>,
    pub percent_done: Option<f64>,
    pub position: Option<f64>,
    pub is_favorite: Option<i32>,
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub my_day_date: Option<Option<i64>>,
    /// 预计时长（分钟，可空）：外层 Some = 本次要改，内层 None = 清除时长
    #[serde(default, deserialize_with = "nullable::deserialize")]
    pub duration_minutes: Option<Option<i64>>,
}

// ---------- todo_subtasks ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoSubtask {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub title: String,
    pub done: i32,
    pub done_at: Option<i64>,
    pub position: f64,
    /// 上级子任务（父）的 uuid；NULL = 顶层（0007：多层嵌套，限定同任务内）
    pub parent_uuid: Option<String>,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_subtasks 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoSubtaskCreateInput {
    pub task_id: i64,
    pub title: String,
    pub position: Option<f64>,
    /// 挂到哪个子任务下（父的 uuid）；None = 顶层。须与 task_id 同任务
    pub parent_uuid: Option<String>,
}

/// todo_subtasks 更新输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoSubtaskUpdateInput {
    pub title: Option<String>,
    pub done: Option<i32>,
    pub done_at: Option<Option<i64>>,
    pub position: Option<f64>,
    /// 三态：None 不动 / Some(None) 提到顶层 / Some(Some(uuid)) 挂到父下
    /// （父须同任务且不是自身后代——环防护在 business_api 校验）
    pub parent_uuid: Option<Option<String>>,
}

// ---------- todo_labels ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoLabel {
    pub id: i64,
    pub uuid: String,
    pub title: String,
    pub hex_color: String,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_labels 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoLabelCreateInput {
    pub title: String,
    pub hex_color: Option<String>,
}

/// todo_labels 更新输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoLabelUpdateInput {
    pub title: Option<String>,
    pub hex_color: Option<String>,
}

// ---------- todo_task_labels ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoTaskLabel {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub label_id: i64,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_task_labels 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskLabelCreateInput {
    pub task_id: i64,
    pub label_id: i64,
}

// ---------- todo_comments ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoComment {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub content: String,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_comments 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoCommentCreateInput {
    pub task_id: i64,
    pub content: String,
}

// ---------- todo_task_relations ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoTaskRelation {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub other_task_id: i64,
    pub relation_type: String,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_task_relations 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTaskRelationCreateInput {
    pub task_id: i64,
    pub other_task_id: i64,
    pub relation_type: String,
}

// ---------- todo_reminders ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoReminder {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub remind_at: i64,
    /// 持续提醒标记（G2）：1 = 未完成则按间隔顺延重排（响到完成为止），0 = 一次性
    pub is_constant: i32,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_reminders 创建输入
///
/// `is_constant` 带 `#[serde(default)]`：老壳（未升级的桌面/移动端调用方）
/// 传旧 JSON 时按 0（一次性）落地，不因缺字段反序列化失败。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoReminderCreateInput {
    pub task_id: i64,
    pub remind_at: i64,
    #[serde(default)]
    pub is_constant: i32,
}

// ---------- todo_task_attachments（任务-附件关联，引用 sys_attachments.hash）----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoTaskAttachment {
    pub id: i64,
    pub uuid: String,
    pub task_id: i64,
    pub hash: String,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

// ---------- todo_saved_filters（保存的筛选器，#35）----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoSavedFilter {
    pub id: i64,
    pub uuid: String,
    pub name: String,
    /// 条件 JSON：{status?, priority_min?, project_ids?, label_ids?,
    /// due_within_days?, due_overdue?, favorite_only?}——缺键 = 不过滤
    pub conditions: String,
    pub sort_order: i64,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_saved_filters 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoSavedFilterCreateInput {
    pub name: String,
    pub conditions: String,
    pub sort_order: Option<i64>,
}

/// todo_saved_filters 更新输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoSavedFilterUpdateInput {
    pub name: Option<String>,
    pub conditions: Option<String>,
    pub sort_order: Option<i64>,
}

// ---------- todo_templates（任务模板）----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoTemplate {
    pub id: i64,
    pub uuid: String,
    pub name: String,
    /// 模板内容 JSON：{title?, notes?, priority?, due_offset_days?,
    /// subtasks?: [string]}——套用时按存在键预填，缺键 = 不预填。
    /// 自包含设计：不引用项目/标签实体 id（跨设备不稳定）
    pub payload: String,
    pub sort_order: i64,
    pub is_deleted: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub deleted_at: Option<i64>,
    pub version: i32,
}

/// todo_templates 创建输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTemplateCreateInput {
    pub name: String,
    pub payload: String,
    pub sort_order: Option<i64>,
}

/// todo_templates 更新输入
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoTemplateUpdateInput {
    pub name: Option<String>,
    pub payload: Option<String>,
    pub sort_order: Option<i64>,
}

// ---------- sys_attachments（PK: hash）----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Attachment {
    pub hash: String,
    pub original_name: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub local_path: Option<String>,
    pub is_uploaded: i32,
    pub is_local_cached: i32,
    /// 创建时间（ms 时间戳；迁移 0001 原为 TEXT 属笔误，随附件功能落地对齐 i64）
    pub created_at: i64,
    /// 最近访问时间（ms；磁盘缓存 LRU 逐出的排序键——内容寻址文件不可变，
    /// 入库与读取都视为一次访问）
    pub last_accessed_at: i64,
}

// ---------- sync_history ----------
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct SyncHistory {
    pub id: i64,
    pub sync_type: String,
    pub status: String,
    pub started_at: i64,
    pub finished_at: Option<i64>,
    pub pulled_count: i64,
    pub pushed_count: i64,
    pub conflict_count: i64,
    pub error_message: Option<String>,
}
