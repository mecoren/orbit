/**
 * tauri.ts - typed invoke 包装层（Orbit M1）
 *
 * 平移自 wait-home lib/tauri.ts 的 todo 段与主密码/DB 生命周期段（02 文档 §四 C 类：
 *"按新命令面重写 typed invoke 层"）。关键约定：
 * - UpdateInput 全字段可选：缺省键 = 跳过更新（serde Option + skip 三态语义），
 *   前端局部更新依赖此语义，禁止全量回传；
 * - 命令多词参数用 camelCase（Tauri 自动映射 snake_case）；
 * - 模型字段保持 snake_case 直传（与 Rust serde 一致）。
 */
import { invoke } from "@tauri-apps/api/core";

// ---------- 通用列表过滤条件 ----------

export interface ListFilter {
  keyword?: string | null;
  page: number;
  page_size: number;
  /** 谓词下推（F5，仅 todo_tasks 消费；语义对齐 filterTasks） */
  done?: boolean | null;
  status?: string | null;
  priority_min?: number | null;
  project_id?: number | null;
  /**
   * 项目 id 集合（SQL `project_id IN (...)`）：清单文件夹聚合——选中父清单时
   * 传「自身 + 全部后代项目 id」。非空集合优先于 [project_id]；空集合 = 空结果。
   */
  project_ids?: number[] | null;
  favorite_only?: boolean | null;
  /** 我的一天零点毫秒（调用方算好本地零点传入） */
  my_day_today?: number | null;
  /** 未分组视图：true = project_id IS NULL */
  ungrouped?: boolean | null;
  /** 优先级等值（工具栏单值档；priority_min 是区间下限，两者不同） */
  priority_eq?: number | null;
  /**
   * 排除早于此时刻的截止（毫秒），但**保留无截止行**：
   * 逾期置顶段由独立查询取走后，主列表用它把逾期行排除，避免重复渲染。
   */
  exclude_due_before?: number | null;
  /** 是否有截止：false = due_date IS NULL（日历「未排期」区） */
  has_due?: boolean | null;
  /**
   * 排序键下推（P1 键集分页，仅 todo_tasks 分页通道消费）：
   * manual/due/priority/created/done_at。`title` 不支持——中文拼音序无法在 SQL 侧复刻。
   */
  sort_key?: TaskPageSortKey | null;
  /** 排序方向；缺省 = 各档默认方向（与 BASE_SORT_DIR 一致） */
  sort_dir?: TaskSortDir | null;
  /** 截止区间下界（毫秒，含）：日历按可见范围取数 */
  due_from?: number | null;
  /** 截止区间上界（毫秒，不含） */
  due_to?: number | null;
  /** 开始区间下界（毫秒，含）：日历「按开始日期」口径取数（NULL 不命中） */
  start_from?: number | null;
  /** 开始区间上界（毫秒，不含） */
  start_to?: number | null;
  /**
   * 标签集合（**任一命中**，EXISTS 子查询）：保存筛选器 label_ids 与列表内
   * 标签筛选共用。空集合 = 不过滤（≠ 空结果：条件里没选标签就是没限制）。
   */
  label_ids?: number[] | null;
  /** 有提醒（至少一条活提醒行）；null = 不限 */
  has_reminder?: boolean | null;
  /** 有附件（todo_task_attachments 活行）；null = 不限 */
  has_attachment?: boolean | null;
  /** 有未完成子任务；null = 不限 */
  has_open_subtask?: boolean | null;
  /** 创建时间下界（毫秒，含）：保存筛选器 created_from */
  created_from?: number | null;
  /** 完成时间下界（毫秒，含；隐含只看已完成）：保存筛选器 done_from */
  done_from?: number | null;
  /**
   * 状态**集合**（工具栏状态多选档，2026-10-28）：按派生状态判定
   * （脏值回落 pending），`done` 档兼容「done = 1 或 status = 'done'」。
   * 与 [status] 等值互斥，集合优先；空集合 = 不过滤。
   */
  status_in?: string[] | null;
}

/** 键集分页支持的排序档（title 档走旧的全量通道） */
export type TaskPageSortKey = "manual" | "due" | "priority" | "created" | "done_at";
export type TaskSortDir = "asc" | "desc";

/**
 * 键集分页游标：上一页最后一行的排序键值 + 主键。
 *
 * `sort_key`/`dir` 与本次请求不一致时后端返回空页——换档后沿用旧游标属于
 * 正常的 UI 竞态（用户快速切排序），让它自然收敛比报错好。
 */
export interface ListCursor {
  sort_key: string;
  dir: string;
  /** 主排序键值（position/priority/created_at/due_date）；due 档 null = 无截止尾段 */
  key: number | null;
  /** 次排序键（仅 priority 档：同优先级按 position 升序） */
  key2: number | null;
  id: number;
}

/** 任务分页结果：`total` 不在这里（由 todoTaskOverview 独立聚合给） */
export interface TodoTaskPage {
  items: TodoTaskListItem[];
  next_cursor: ListCursor | null;
  has_more: boolean;
}

/** 单个项目的未完成计数 */
export interface TodoProjectUndone {
  project_id: number | null;
  count: number;
}

/** 任务总览：总数 + 侧栏未完成计数（全局口径，不受当前视图谓词影响） */
export interface TodoTaskOverview {
  total: number;
  undone_by_project: TodoProjectUndone[];
}

/**
 * todo_tasks 谓词下推参数（F5）：ListFilter 里去掉 keyword/分页的那一组。
 * 壳层全量查询与面板搜索查询共用同一份对象——两处各自拼一遍迟早口径漂移。
 */
export type TaskListPredicate = Pick<
  ListFilter,
  "done" | "project_id" | "project_ids" | "favorite_only" | "my_day_today"
>;

// ---------- 通用业务 ----------

/** 通用业务表记录数（列表页计数角标） */
export async function businessCount(table: string): Promise<number> {
  return invoke<number>("business_count", { table });
}

// ---------- 主密码认证（Phase 6C）----------

/**
 * 查询是否已设置主密码
 *
 * 前端启动流程第一步：
 * - true → 显示解锁页，用户输入密码 → masterAuthUnlock()
 * - false → 直接 dbInitPlaintext() 进入明文模式
 */
export async function masterAuthHas(): Promise<boolean> {
  return invoke<boolean>("master_auth_has");
}

/**
 * 初始化主密码（首次设置）
 *
 * 生成 salt + DB Key，持久化到 master_auth.json。
 * F80：DB Key hex 不再返回给 webview——Rust 侧暂存（PendingDbKey），
 * dbInitEncrypted / dbMigrateToEncrypted 直接从进程内状态取用。
 *
 * 典型流程：用户首次设置开屏密码 → masterAuthInit(pw) → dbMigrateToEncrypted() → dbInitEncrypted()
 */
export async function masterAuthInit(password: string): Promise<void> {
  return invoke<void>("master_auth_init", { password });
}

/**
 * 解锁主密码
 *
 * 验证密码并解密 DB Key。F80：解出的 hex 不再返回给 webview，
 * Rust 侧暂存（PendingDbKey），随后 dbInitEncrypted() 直接取用。
 *
 * @throws 密码错误时抛出异常
 */
export async function masterAuthUnlock(password: string): Promise<void> {
  return invoke<void>("master_auth_unlock", { password });
}

/**
 * 仅验证主密码是否正确（不解锁，不返回 db_key）
 *
 * 用于敏感操作前的二次确认。
 */
export async function masterAuthVerify(password: string): Promise<boolean> {
  return invoke<boolean>("master_auth_verify", { password });
}

/**
 * 修改主密码
 *
 * 验证旧密码后用新密码重新包装 DB Key。DB Key 本身不变，无需重新加密数据库。
 * 注意：修改后需要重启应用以重新初始化数据库连接。
 */
export async function masterAuthChangePassword(
  oldPassword: string,
  newPassword: string,
): Promise<void> {
  return invoke<void>("master_auth_change_password", {
    oldPassword,
    newPassword,
  });
}

/**
 * 清除主密码（取消开屏密码）
 *
 * 删除 master_auth.json。此后数据库将以明文模式打开。
 * 注意：调用前应已完成加密→明文的数据库迁移。
 */
export async function masterAuthClear(): Promise<void> {
  return invoke<void>("master_auth_clear");
}

// ---------- 数据库生命周期（Phase 6C）----------

/**
 * 初始化明文数据库（未设置主密码时使用）
 *
 * 在 app_data_dir 下创建/打开 orbit.db，不加密。
 */
export async function dbInitPlaintext(): Promise<void> {
  return invoke<void>("db_init_plaintext");
}

/**
 * 初始化加密数据库（已解锁主密码后使用）
 *
 * F80：不接收 db_key_hex——Rust 侧从 PendingDbKey 暂存取用，
 * 密钥材料全程不过 webview。
 */
export async function dbInitEncrypted(): Promise<void> {
  return invoke<void>("db_init_encrypted");
}

/**
 * 查询数据库是否已初始化
 *
 * 前端据此判断是否需要显示解锁页面。
 */
export async function dbIsReady(): Promise<boolean> {
  return invoke<boolean>("db_is_ready");
}

/** 明文→加密迁移（设置主密码场景；随后需 dbInitEncrypted 重开连接池）。
 * F80：key 从 Rust 侧暂存读取，不经过本函数参数。 */
export async function dbMigrateToEncrypted(): Promise<void> {
  return invoke<void>("db_migrate_to_encrypted");
}

/** 加密→明文迁移（清除主密码场景；随后需 dbInitPlaintext 重开连接池） */
export async function dbMigrateToPlaintext(): Promise<void> {
  return invoke<void>("db_migrate_to_plaintext");
}

/** 写入当前设备 ID（进程级 OnceCell，DB 初始化后调用一次） */
export async function dbSetDeviceId(deviceId: string): Promise<void> {
  return invoke<void>("db_set_device_id", { deviceId });
}

// ========== todo_projects ==========
export interface TodoProject {
  id: number;
  uuid: string;
  title: string;
  description: string | null;
  hex_color: string;
  sort_order: number;
  /** M8 上级文件夹（父项目）的同步主键 uuid；null = 顶层 */
  parent_uuid: string | null;
  /** F1 回顾周期（天）；null/0 = 关闭（7=每周 14=每两周 30=每月） */
  review_interval_days: number | null;
  /** 上次回顾时间（毫秒）；null = 从未回顾 */
  review_last_at: number | null;
  /** 回顾暂缓截止（毫秒，本地零点口径）；null = 未暂缓 */
  review_snooze_until: number | null;
  is_archived: number;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoProjectCreateInput {
  title: string;
  description?: string | null;
  hex_color?: string;
  sort_order?: number;
  /** M8 上级文件夹 uuid；省略 / null / "" 均为顶层 */
  parent_uuid?: string | null;
}
export interface TodoProjectUpdateInput {
  title?: string;
  description?: string | null;
  hex_color?: string;
  sort_order?: number;
  /** 归档切换：1=归档（默认列表收起）0=恢复 */
  is_archived?: number;
  /** M8 上级文件夹 uuid：省略=不改；null / ""=移到顶层 */
  parent_uuid?: string | null;
  /** F1 回顾周期（天）：省略=不改；null=关闭（常规写路径建议走 setReviewInterval 保起算/清暂缓语义） */
  review_interval_days?: number | null;
  /** 上次回顾时间：省略=不改；null=清空（标记已回顾走 markReviewed） */
  review_last_at?: number | null;
  /** 回顾暂缓截止：省略=不改；null=清空 */
  review_snooze_until?: number | null;
}
/** F1 回顾状态行（core project_review_api::ProjectReviewStatus 的前端镜像） */
export interface ProjectReviewStatus {
  project: TodoProject;
  /** 到期日序号（days since epoch，本地时区日界） */
  due_day_index: number;
  /** 已逾期天数（0 = 今天到期） */
  overdue_days: number;
  /** 项目内未完成且未软删的任务数 */
  open_task_count: number;
}
export const todoProjectList = (filter: ListFilter) => invoke<TodoProject[]>("todo_projects_list", { filter });
export const todoProjectGet = (id: number) => invoke<TodoProject>("todo_projects_get", { id });
export const todoProjectCreate = (input: TodoProjectCreateInput) => invoke<TodoProject>("todo_projects_create", { input });
export const todoProjectUpdate = (id: number, input: TodoProjectUpdateInput) => invoke<TodoProject>("todo_projects_update", { id, input });
export const todoProjectDelete = (id: number) => invoke<void>("todo_projects_delete", { id });
export const todoProjectGetByUuid = (uuid: string) => invoke<TodoProject | null>("todo_projects_get_by_uuid", { uuid });
export const todoProjectUpdateSortOrder = (id: number, sortOrder: number) => invoke<void>("todo_projects_update_sort_order", { id, sortOrder });
/** 归档项目列表（侧栏「已归档」折叠区数据源） */
export const todoProjectListArchived = () => invoke<TodoProject[]>("todo_projects_list_archived");
/** 待回顾项目清单（F1 回顾中心/侧栏徽标共用） */
export const todoProjectsDueForReview = (nowMs: number) => invoke<ProjectReviewStatus[]>("todo_projects_due_for_review", { nowMs: nowMs });
/** 标记项目已回顾 */
export const todoProjectMarkReviewed = (projectId: number) => invoke<TodoProject>("todo_project_mark_reviewed", { projectId });
/** 设置项目回顾周期（null = 关闭） */
export const todoProjectSetReviewInterval = (projectId: number, days: number | null) => invoke<TodoProject>("todo_project_set_review_interval", { projectId, days });
/** 暂缓项目回顾 days 天 */
export const todoProjectSnoozeReview = (projectId: number, days: number, nowMs: number) => invoke<TodoProject>("todo_project_snooze_review", { projectId, days, nowMs: nowMs });

// ========== todo_tasks ==========
export interface TodoTask {
  id: number;
  uuid: string;
  title: string;
  description: string | null;
  project_id: number | null;
  priority: number;
  status: string;
  done: number;
  done_at: number | null;
  due_date: number | null;
  start_date: number | null;
  repeat_after: number;
  repeat_mode: number;
  /** #34 重复规则扩展：星期几位掩码 bit0=周一…bit6=周日（仅周档生效） */
  repeat_weekdays: number;
  /** 结束条件 0=永不 1=按日期 2=按次数 */
  repeat_end_type: number;
  /** 结束参数：日期型=结束日 ms / 次数型=剩余次数 */
  repeat_end_param: number;
  /** when done：0=锚定原 due 推进 1=按完成日推进 */
  repeat_from_done: number;
  /** 月重复模式（#72）：0=按日号 1=按第N个星期X（仅 MONTHLY 生效） */
  repeat_month_mode: number;
  /** 月内第几个星期（#72）：1-5/6=末，0=未指定回落日号；星期几复用 repeat_weekdays 单 bit */
  repeat_nth_week: number;
  percent_done: number;
  position: number;
  is_favorite: number;
  /** My Day「我的一天」：加入当天本地零点 ms；null = 不在任何一天的 My Day */
  my_day_date: number | null;
  /** 任务预计时长（分钟，M9 阶段一）；null = 未设置 */
  duration_minutes: number | null;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoTaskCreateInput {
  title: string;
  description?: string | null;
  project_id?: number | null;
  priority?: number;
  status?: string;
  done?: number;
  done_at?: number | null;
  due_date?: number | null;
  start_date?: number | null;
  repeat_after?: number;
  repeat_mode?: number;
  repeat_weekdays?: number;
  repeat_end_type?: number;
  repeat_end_param?: number;
  repeat_from_done?: number;
  repeat_month_mode?: number;
  repeat_nth_week?: number;
  position?: number;
  is_favorite?: number;
  my_day_date?: number | null;
  /** 预计时长（分钟）；省略/null = 不设置 */
  duration_minutes?: number | null;
}
export interface TodoTaskUpdateInput {
  title?: string;
  description?: string | null;
  project_id?: number | null;
  priority?: number;
  status?: string;
  done?: number;
  done_at?: number | null;
  due_date?: number | null;
  start_date?: number | null;
  repeat_after?: number;
  repeat_mode?: number;
  repeat_weekdays?: number;
  repeat_end_type?: number;
  repeat_end_param?: number;
  repeat_from_done?: number;
  repeat_month_mode?: number;
  repeat_nth_week?: number;
  percent_done?: number;
  position?: number;
  is_favorite?: number;
  my_day_date?: number | null;
  /** 预计时长（分钟）；null = 清除（不传 = 不改） */
  duration_minutes?: number | null;
}
/**
 * 列表通道瘦行类型（内存治理 A2）：`todoTaskList` 的实际返回形状。
 *
 * 10 个「列表通道零消费」列整体不在其中（uuid / repeat_after / 六个更细的
 * repeat_* / deleted_at / version）——core 侧 `TodoTaskListItem` 不序列化它们，
 * 因此这里读这些字段会直接 tsc 报错（比运行时 undefined 早一步拦下）。
 * 需要这些列时走单行全列路径：`todoTaskGet` / `todoTaskGetDetail` / 回收站。
 * 保留的有消费列：start_date（右键菜单提醒档）、description（搜索通道本地
 * 收敛）、created_at（排序与 Logbook 分组）、repeat_mode（移动端徽标）。
 */
export type TodoTaskListItem = Omit<
  TodoTask,
  | "uuid"
  | "repeat_after"
  | "repeat_weekdays"
  | "repeat_end_type"
  | "repeat_end_param"
  | "repeat_from_done"
  | "repeat_month_mode"
  | "repeat_nth_week"
  | "deleted_at"
  | "version"
>;
export const todoTaskList = (filter: ListFilter) =>
  invoke<TodoTaskListItem[]>("todo_tasks_list", { filter });

/**
 * 任务键集分页（P1 50k 规模档）：列表/表格窗口化的唯一读通道。
 *
 * 与 `todoTaskList` 的分工：`title` 排序档需要 `localeCompare` 的中文拼音序，
 * SQL 侧复刻不了，仍走旧的全量通道；其余四档一律走本通道。
 */
export const todoTaskPage = (
  filter: ListFilter,
  cursor: ListCursor | null,
  limit: number,
) => invoke<TodoTaskPage>("todo_tasks_page", { filter, cursor, limit });

/** 任务总览：总数（「已加载 X / 共 Y」）+ 侧栏未完成计数 */
export const todoTaskOverview = (filter: ListFilter) =>
  invoke<TodoTaskOverview>("todo_task_overview", { filter });

/** 看板/四象限分组维度（列键与 shared/kanban-group 的 kanbanColumnKey 同形） */
export type BoardGroupBy = "project" | "status" | "priority" | "due" | "quadrant";

/** 看板单列：组键 + 组总数（不受 limit 影响）+ 前 N 条 */
export interface TodoTaskBoardGroup {
  key: string;
  total: number;
  items: TodoTaskListItem[];
}

/** 看板/四象限一次往返（groups 只含实际有任务的组） */
export interface TodoTaskBoard {
  groups: TodoTaskBoardGroup[];
  total: number;
}

/**
 * 看板/四象限窗口化：每列前 `limitPerGroup` 条 + 每列总数。
 *
 * `dayStart`/`dayEnd` 由调用方按本地时区算好传入（due 五分桶与四象限
 * 「今天以内到期 = 紧急」的界）；Rust 侧不重复做日界换算。
 */
export const todoTaskBoard = (
  filter: ListFilter,
  groupBy: BoardGroupBy,
  limitPerGroup: number,
  dayStart: number,
  dayEnd: number,
) =>
  invoke<TodoTaskBoard>("todo_tasks_board", {
    filter,
    groupBy,
    limitPerGroup,
    dayStart,
    dayEnd,
  });
export const todoTaskGet = (id: number) => invoke<TodoTask>("todo_tasks_get", { id });
export const todoTaskCreate = (input: TodoTaskCreateInput) => invoke<TodoTask>("todo_tasks_create", { input });
export const todoTaskUpdate = (id: number, input: TodoTaskUpdateInput) => invoke<TodoTask>("todo_tasks_update", { id, input });
export const todoTaskDelete = (id: number) => invoke<void>("todo_tasks_delete", { id });
export const todoTaskGetByUuid = (uuid: string) => invoke<TodoTask | null>("todo_tasks_get_by_uuid", { uuid });
export const todoTaskUpdatePosition = (id: number, position: number) => invoke<void>("todo_tasks_update_position", { id, position });

/** 统一完成命令结果（引擎下沉 orbit-core，三端唯一完成入口） */
export interface CompleteTaskResult {
  task: TodoTask;
  next_instance: TodoTask | null;
}
export const todoTaskComplete = (id: number) => invoke<CompleteTaskResult>("todo_tasks_complete", { id });

// ========== todo_subtasks ==========
export interface TodoSubtask {
  id: number;
  uuid: string;
  task_id: number;
  title: string;
  done: number;
  done_at: number | null;
  position: number;
  /** 上级子任务（父）uuid；null = 顶层（M10 多层嵌套，同任务内） */
  parent_uuid: string | null;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoSubtaskCreateInput {
  task_id: number;
  title: string;
  position?: number;
  /** 挂到哪个子任务下；省略 = 顶层 */
  parent_uuid?: string | null;
}
export interface TodoSubtaskUpdateInput {
  title?: string;
  done?: number;
  done_at?: number | null;
  position?: number;
  /** 三态：省略不动 / null 提到顶层 / string 挂到该 uuid 下（core 校验同任务与环） */
  parent_uuid?: string | null;
}
export const todoSubtaskList = (filter: ListFilter) => invoke<TodoSubtask[]>("todo_subtasks_list", { filter });
export const todoSubtaskGet = (id: number) => invoke<TodoSubtask>("todo_subtasks_get", { id });
export const todoSubtaskCreate = (input: TodoSubtaskCreateInput) => invoke<TodoSubtask>("todo_subtasks_create", { input });
export const todoSubtaskUpdate = (id: number, input: TodoSubtaskUpdateInput) => invoke<TodoSubtask>("todo_subtasks_update", { id, input });
export const todoSubtaskDelete = (id: number) => invoke<void>("todo_subtasks_delete", { id });
export const todoSubtaskToggleDone = (subtaskId: number, done: boolean) => invoke<void>("todo_subtasks_toggle_done", { subtaskId, done });
/** 子任务转独立任务（承接父任务 project/priority/due 上下文；返回新任务） */
export const todoSubtaskPromote = (subtaskId: number) => invoke<TodoTask>("todo_subtasks_promote", { subtaskId });

// ========== todo_labels ==========
export interface TodoLabel {
  id: number;
  uuid: string;
  title: string;
  hex_color: string;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoLabelCreateInput {
  title: string;
  hex_color?: string;
}
export interface TodoLabelUpdateInput {
  title?: string;
  hex_color?: string;
}
export const todoLabelList = (filter: ListFilter) => invoke<TodoLabel[]>("todo_labels_list", { filter });
export const todoLabelGet = (id: number) => invoke<TodoLabel>("todo_labels_get", { id });
export const todoLabelCreate = (input: TodoLabelCreateInput) => invoke<TodoLabel>("todo_labels_create", { input });
export const todoLabelUpdate = (id: number, input: TodoLabelUpdateInput) => invoke<TodoLabel>("todo_labels_update", { id, input });
export const todoLabelDelete = (id: number) => invoke<void>("todo_labels_delete", { id });

// ========== todo_task_labels ==========
export interface TodoTaskLabel {
  id: number;
  uuid: string;
  task_id: number;
  label_id: number;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoTaskLabelCreateInput {
  task_id: number;
  label_id: number;
}
export const todoTaskLabelList = (filter: ListFilter) => invoke<TodoTaskLabel[]>("todo_task_labels_list", { filter });
export const todoTaskLabelGet = (id: number) => invoke<TodoTaskLabel>("todo_task_labels_get", { id });
export const todoTaskLabelCreate = (input: TodoTaskLabelCreateInput) => invoke<TodoTaskLabel>("todo_task_labels_create", { input });
export const todoTaskLabelDelete = (id: number) => invoke<void>("todo_task_labels_delete", { id });

// ========== todo_comments ==========
export interface TodoComment {
  id: number;
  uuid: string;
  task_id: number;
  content: string;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoCommentCreateInput {
  task_id: number;
  content: string;
}
export const todoCommentList = (filter: ListFilter) => invoke<TodoComment[]>("todo_comments_list", { filter });
export const todoCommentGet = (id: number) => invoke<TodoComment>("todo_comments_get", { id });
export const todoCommentCreate = (input: TodoCommentCreateInput) => invoke<TodoComment>("todo_comments_create", { input });
export const todoCommentDelete = (id: number) => invoke<void>("todo_comments_delete", { id });

// ========== global_search（07 报告 §五-P1#9）==========
export interface CommentSearchHit {
  comment_id: number;
  task_id: number;
  task_title: string;
  content: string;
  created_at: number;
}
export interface GlobalSearchResult {
  tasks: TodoTask[];
  projects: TodoProject[];
  comments: CommentSearchHit[];
}
export const globalSearch = (keyword: string, limit = 20) =>
  invoke<GlobalSearchResult>("global_search", { keyword, limit });

// ========== todo_task_relations ==========
export interface TodoTaskRelation {
  id: number;
  uuid: string;
  task_id: number;
  other_task_id: number;
  relation_type: string;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoTaskRelationCreateInput {
  task_id: number;
  other_task_id: number;
  relation_type: string;
}
export const todoTaskRelationList = (filter: ListFilter) => invoke<TodoTaskRelation[]>("todo_task_relations_list", { filter });
export const todoTaskRelationGet = (id: number) => invoke<TodoTaskRelation>("todo_task_relations_get", { id });
export const todoTaskRelationCreate = (input: TodoTaskRelationCreateInput) => invoke<TodoTaskRelation>("todo_task_relations_create", { input });
export const todoTaskRelationDelete = (id: number) => invoke<void>("todo_task_relations_delete", { id });

// ========== todo_reminders ==========
export interface TodoReminder {
  id: number;
  uuid: string;
  task_id: number;
  remind_at: number;
  /** 持续提醒标记（G2）：1 = 未完成则按间隔顺延重排（响到完成为止），0 = 一次性 */
  is_constant: number;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoReminderCreateInput {
  task_id: number;
  remind_at: number;
  /** 省略 = 0（一次性）；老调用方 JSON 不带该字段由 core serde default 兜底 */
  is_constant?: number;
}
export const todoReminderList = (filter: ListFilter) => invoke<TodoReminder[]>("todo_reminders_list", { filter });
export const todoReminderGet = (id: number) => invoke<TodoReminder>("todo_reminders_get", { id });
export const todoReminderCreate = (input: TodoReminderCreateInput) => invoke<TodoReminder>("todo_reminders_create", { input });
export const todoReminderDelete = (id: number) => invoke<void>("todo_reminders_delete", { id });

// ========== todo_api 复杂查询 ==========
export interface TaskLabelWithId extends TodoLabel {
  task_label_id: number;
}
export interface TodoTaskDetail extends TodoTask {
  subtasks: TodoSubtask[];
  labels: TaskLabelWithId[];
  comments: TodoComment[];
  relations: TodoTaskRelation[];
  reminders: TodoReminder[];
}
export const todoTaskGetDetail = (id: number) => invoke<TodoTaskDetail>("todo_tasks_get_detail", { id });
export const todoTaskRecalcPercent = (taskId: number) => invoke<void>("todo_tasks_recalc_percent", { taskId });

// ========== 任务列表投影聚合（A4，只读：一次往返替代万行整表+前端 join） ==========
/** 行内标签 chip 最小载荷（core ProjectedTaskLabel 镜像：展示三列） */
export interface ProjectedTaskLabel {
  id: number;
  title: string;
  hex_color: string;
}
export interface TaskLabelsProjection {
  task_id: number;
  labels: ProjectedTaskLabel[];
}
/** 行内提醒最小载荷（core ProjectedReminder 镜像） */
export interface ProjectedReminder {
  id: number;
  remind_at: number;
}
export interface TaskRemindersProjection {
  task_id: number;
  reminders: ProjectedReminder[];
}
/** 关联计数旗标（core TaskDependencyFlags 镜像；C7 行内关联徽标消费） */
export interface TaskDependencyFlags {
  task_id: number;
  /** 出边存活行总数（> 0 即「有关联」） */
  relation_count: number;
}
/** 任务存在旗标一位（core TaskExistenceFlag 镜像；#71 筛选器存在键数据源） */
export interface TaskExistenceFlag {
  task_id: number;
}
export const taskLabelsProjection = () => invoke<TaskLabelsProjection[]>("task_labels_projection");
export const taskRemindersProjection = () => invoke<TaskRemindersProjection[]>("task_reminders_projection");
export const taskDependencyFlags = () => invoke<TaskDependencyFlags[]>("task_dependency_flags");
export const taskAttachmentFlags = () => invoke<TaskExistenceFlag[]>("task_attachment_flags");
export const taskOpenSubtaskFlags = () => invoke<TaskExistenceFlag[]>("task_open_subtask_flags");
/** 任务→「有描述」旗标（列表通道裁剪 description，行内只取有无） */
export const taskDescriptionFlags = () => invoke<TaskExistenceFlag[]>("task_description_flags");

// ========== M3 安全与同步 ==========

/**
 * 同步域错误通道约定（Rust 侧 `[tag] message` 前缀）：
 * - key_mismatch → 引导恢复页；wrong_password / not_unlocked → 解锁入口
 * - local_meta_exists → Fix-10 确认覆盖；config → 表单校验提示
 * - payload_version → 云端数据由**更新版本**的客户端写出（ADR 0010 两拍升级），
 *   处置动作是「升级应用」：既不跳恢复页也不跳解锁页，toast 直给 message
 */
export function syncErrorTag(err: unknown): string | null {
  const m = /^\[(\w+)\]/.exec(err instanceof Error ? err.message : String(err));
  return m ? m[1] : null;
}

// ---------- 同步密码 / Data Key（sync_crypto_cmd） ----------

export interface SyncCryptoStatus {
  has_password: boolean;
  is_unlocked: boolean;
}
/** crypto bundle（SyncCryptoMeta，全 Base64 字段） */
export interface SyncCryptoBundle {
  salt: string;
  encrypted_data_key: string;
  data_key_nonce: string;
  iterations: number;
}

export const syncCryptoStatus = () => invoke<SyncCryptoStatus>("sync_crypto_status");
/** 本机密钥方案版本（"v1" | "v2"；未设置密码为 null） */
export const syncCryptoMetaVersion = () =>
  invoke<{ version: string | null }>("sync_crypto_meta_version");
export const syncCryptoInit = (password: string, remember: boolean) =>
  invoke<void>("sync_crypto_init", { password, remember });
export const syncCryptoUnlock = (password: string, remember: boolean) =>
  invoke<void>("sync_crypto_unlock", { password, remember });
export const syncCryptoLock = () => invoke<void>("sync_crypto_lock");
/** v2 下改密会触发云端全量重传（命令内部编排），失败自动回滚本机密码 */
export const syncCryptoChangePassword = (oldPassword: string, newPassword: string) =>
  invoke<void>("sync_crypto_change_password", { oldPassword, newPassword });
// 注：不提供 rotate_key 命令——多设备同步场景下轮换 Data Key 会令其他设备
// 全部失效，产品决策不做（core 库层能力保留，壳层不暴露）。
export const syncCryptoExportBundle = () => invoke<SyncCryptoBundle>("sync_crypto_export_bundle");
/** `[local_meta_exists]` 时前端确认后以 force=true 重试 */
export const syncCryptoImportBundle = (bundle: SyncCryptoBundle, password: string, force: boolean) =>
  invoke<string>("sync_crypto_import_bundle", { bundle, password, force });
/** 启动静默恢复会话（钥匙串缓存密码） */
export const syncCryptoRestoreSession = () => invoke<boolean>("sync_crypto_restore_session");
export const syncCryptoForgetSession = () => invoke<void>("sync_crypto_forget_session");
/** v1→v2 密钥方案迁移（同密码确定性派生 + 云端全量重传；UI 二次确认后调用） */
export const syncCryptoUpgradeV2 = (syncPassword: string) =>
  invoke<void>("sync_crypto_upgrade_v2", { syncPassword });

// ---------- 连接配置（sync_cmd） ----------

export type SyncEngineKind = "webdav" | "s3";
export interface SyncConfigInput {
  engine: SyncEngineKind;
  endpoint: string;
  bucket?: string;
  region?: string;
  username?: string;
  password?: string;
  base_path?: string;
  /** 定时同步间隔分钟；0 = 关闭定时 */
  interval_minutes?: number;
  auto_sync_enabled?: boolean;
  /** 修改后立即同步（5s 防抖） */
  sync_on_change?: boolean;
  /** 跳过 TLS 证书校验（自签名证书场景） */
  skip_tls_verify?: boolean;
  /** 请求超时秒数；0 = 默认 30 */
  timeout_seconds?: number;
  /** F80：S3 STS 会话令牌（空串/缺省 = 沿用已存令牌；WebDAV 忽略） */
  session_token?: string;
}
export interface SyncConfigView {
  id: number;
  engine: string;
  endpoint: string;
  bucket: string;
  region: string;
  username: string;
  password_set: boolean;
  base_path: string;
  interval_minutes: number;
  auto_sync_enabled: boolean;
  sync_on_change: boolean;
  skip_tls_verify: boolean;
  timeout_seconds: number;
  /** F80：仅提示已设置（令牌本身打码不下发） */
  session_token_set: boolean;
  last_synced_at: number | null;
}

export const syncConfigGet = () => invoke<SyncConfigView | null>("sync_config_get");
export const syncConfigSave = (input: SyncConfigInput) =>
  invoke<SyncConfigView>("sync_config_save", { input });
/** 测试连接：返回云端根目录条目数 */
export const syncTestConnection = (input: SyncConfigInput) =>
  invoke<number>("sync_test_connection", { input });

// ---------- 云同步执行（cloud_sync_cmd） ----------

/** SyncResult JSON 字符串（Rust 侧 result_to_json 序列化） */
export interface SyncResultJson {
  pushed_modules: number;
  pulled_modules: number;
  uploaded_attachments: number;
  downloaded_attachments: number;
  /** S28：冲突裁决数（merge LWW/复活裁决计数透传，多设备并发编辑的可见度）。
   * F77：补声明——core 一直下发，此前两端壳都未解析。 */
  conflicts?: number;
  duration_ms: number;
  skipped: boolean;
  errors: string[];
  /** F42：本轮 pull 真正写入的表集合（按表精确失效缓存的依据） */
  changed_tables?: string[];
}

const parseResult = (json: string): SyncResultJson => JSON.parse(json);

export const cloudSyncNow = (origin: "manual" | "background" | "exit" = "manual") =>
  invoke<string>("cloud_sync_now", { origin }).then(parseResult);
export const cloudSyncPushOnly = (origin: "manual" | "background" | "exit" = "manual") =>
  invoke<string>("cloud_sync_push_only", { origin }).then(parseResult);
export const cloudSyncPullThenPush = (origin: "manual" | "background" | "exit" = "manual") =>
  invoke<string>("cloud_sync_pull_then_push", { origin }).then(parseResult);
/**
 * 本地同步账本（core `SyncState` 镜像；`sync_state.json`，只有指纹元数据）
 *
 * 只读诊断口径：水位线是逻辑时钟毫秒（`db::clock`），0 = 从未推进；
 * 指纹是桶内容（按 uuid 排序、排除 updated_at/自增 id 后）的 sha256。
 */
export interface SyncStateJson {
  /** 最后一次同步完成时间（Unix 毫秒，墙上时钟） */
  last_synced_at: number;
  /** 最后一次同步完成时的逻辑时钟（pull 侧「真并发」判据基线） */
  last_synced_clock_ms: number;
  /** 最后一次 push 成功时的逻辑时钟上界（增量 push 水位线；0 = 首轮全量） */
  last_pushed_clock_ms: number;
  device_id: string;
  /** 远端清单 epoch（0 = 从未成功同步） */
  manifest_epoch: number;
  /** 远端数据桶快照：表 → 桶号 → 指纹 */
  remote_tables: Record<string, Record<string, string>>;
  /** 远端墓碑桶快照：表 → 桶键（YYYY-MM）→ 指纹 */
  remote_tombstones: Record<string, Record<string, string>>;
}
export const cloudSyncGetState = (): Promise<SyncStateJson> =>
  invoke<string>("cloud_sync_get_state").then((s) => JSON.parse(s) as SyncStateJson);
/**
 * 强制同步（进入 / 退出应用生命周期钩子专用）
 *
 * 与 `cloudSyncPullThenPush` 的差别只在**前提判定**：内核不检查自动同步开关、
 * 同步间隔、修改后立即同步等设置——「是否该同步」由调用方判定。
 * `waitForIdleMs`：引擎正忙时最多等待多久再执行（进入 ~3s / 退出 ~5s）。
 */
export const cloudSyncForce = (
  origin: "manual" | "background" | "exit" = "background",
  // F77：与移动端 OrbitBridge 默认（3000）对齐——两端壳的桥接默认必须一致，
  // 调用方（启动同步 3000 / BootGate 同款）始终显式传参，默认值只是契约口径
  waitForIdleMs = 3000,
) =>
  invoke<string>("cloud_sync_force", { origin, waitForIdleMs }).then(parseResult);
export const cloudSyncIsRunning = () => invoke<boolean>("cloud_sync_is_running");
/**
 * 请求取消正在进行的增量同步（N33 协作式分片取消）
 *
 * 返回 true = 已向运行中的同步下达取消；false = 当前没有同步在跑。
 * 取消是「不再发起新的远端调用」：在途的那一片会自然完成（最坏 ~5MiB），
 * 随后 `cloudSyncNow` 以 `[cancelled]` 错误 reject——调用方应特判为中性
 * 提示（「已取消同步」），而不是红色故障。
 */
export const cloudSyncCancel = () => invoke<boolean>("cloud_sync_cancel");
/**
 * rekey 全量重传：以本机为准，用当前 Data Key 重加密覆盖云端全部数据。
 * 危险操作（恢复页「以本机为准」），UI 二次确认后调用。
 */
export const cloudSyncRekey = () => invoke<string>("cloud_sync_rekey").then(parseResult);
export const syncDisconnect = () => invoke<void>("sync_disconnect");

// ---------- 增量同步历史（P1-17：设置页同步历史卡） ----------

export interface SyncHistoryEntry {
  id: number;
  sync_type: string;
  status: string;
  started_at: number;
  finished_at: number | null;
  pulled_count: number;
  pushed_count: number;
  conflict_count: number;
  error_message: string | null;
}

export type SyncHistoryScope = "all" | "incremental" | "push_only" | "pull_only";

// F77：limit 默认与移动端 OrbitBridge（20）对齐；桌面历史卡显式传 50 不变
export const cloudSyncHistory = (scope: SyncHistoryScope = "all", limit = 20) =>
  invoke<SyncHistoryEntry[]>("cloud_sync_history", { scope, limit });

// ---------- 冲突败方副本（03 文档 §八 遗留项：查看 / 恢复 / 忽略 / 清空） ----------

/** 冲突败方副本记录（payload 为整行字段快照 JSON 字符串） */
export interface SyncConflictEntry {
  id: number;
  table_name: string;
  record_uuid: string;
  record_title: string;
  /** lww 时间戳裁决 / tie_version 同毫秒按 version 裁决 */
  decision: string;
  loser_side: "local" | "remote" | string;
  winner_side: "local" | "remote" | string;
  loser_payload: string;
  winner_payload: string;
  loser_updated_at: number;
  winner_updated_at: number;
  /** unresolved 未处理 / restored 已恢复 / dismissed 已忽略 */
  resolution: string;
  created_at: number;
  resolved_at: number;
}

export type SyncConflictResolution = "unresolved" | "restored" | "dismissed";

export const syncConflictList = (
  resolution: SyncConflictResolution | null = "unresolved",
  limit = 100,
  offset = 0,
) => invoke<SyncConflictEntry[]>("sync_conflict_list", { resolution, limit, offset });

/** 待处理冲突数（设置页角标） */
export const syncConflictCount = (resolution: SyncConflictResolution | null = "unresolved") =>
  invoke<number>("sync_conflict_count", { resolution });

export const syncConflictRestore = (id: number) =>
  invoke<number>("sync_conflict_restore", { id });

export const syncConflictDismiss = (id: number) => invoke<void>("sync_conflict_dismiss", { id });

export const syncConflictClear = (resolution: SyncConflictResolution | null = null) =>
  invoke<number>("sync_conflict_clear", { resolution });

// ---------- 全量备份 .orfullsync（full_sync_cmd，兼容遗留 .waitfullsync/.orsync） ----------

export interface ExportResult {
  file_path: string;
  file_size: number;
  table_counts: Record<string, number>;
  cloud_path: string | null;
  cloud_uploaded: boolean;
  cloud_error: string | null;
  local_path: string | null;
  local_error: string | null;
}
export interface ImportResult {
  success_count: number;
  error_count: number;
  errors: string[];
  needs_restart: boolean;
}
export interface BackupEntryView {
  filename: string;
  file_path: string;
  modified_at: number;
  size_bytes: number;
}

export const fullBackupExport = (uploadCloud: boolean) =>
  invoke<ExportResult>("full_backup_export", { uploadCloud });
export const fullBackupImport = (path: string, ignoreSchemaMismatch: boolean) =>
  invoke<ImportResult>("full_backup_import", {
    path,
    ignoreSchemaMismatch,
  });
export const fullBackupListLocal = () => invoke<BackupEntryView[]>("full_backup_list_local");

/** 云端备份条目（备份恢复选源列表） */
export interface CloudBackupEntryView {
  name: string;
  cloud_path: string;
  size_bytes: number;
  modified_at: number;
}

export const fullBackupListCloud = () => invoke<CloudBackupEntryView[]>("full_backup_list_cloud");
export const fullBackupRestoreCloud = (cloudPath: string, ignoreSchemaMismatch: boolean) =>
  invoke<ImportResult>("full_backup_restore_cloud", {
    cloudPath,
    ignoreSchemaMismatch,
  });

/** 备份清单（恢复预览元信息；时间戳为 Unix 秒） */
export interface BackupManifestView {
  format_version: number;
  created_at: string;
  created_at_ts: number;
  app_version: string;
  device_id: string;
  device_name: string | null;
  schema_version: number;
  table_counts: Record<string, number>;
}

/** 备份中的单条任务预览 */
export interface PreviewTaskView {
  title: string;
  status: string;
  done: boolean;
  due_date: number | null;
  priority: number;
  project: string | null;
  is_deleted: boolean;
}

/** 备份内任务统计 */
export interface TaskPreviewStatsView {
  total: number;
  alive: number;
  done: number;
  deleted: number;
}

/** 备份恢复预览（只读：解密 + 抽样，不写库） */
export interface BackupPreviewView {
  manifest: BackupManifestView;
  sample_tasks: PreviewTaskView[];
  task_stats: TaskPreviewStatsView;
  schema_mismatch: boolean;
  current_schema_version: number;
}

export const fullBackupPeekLocal = (path: string) =>
  invoke<BackupPreviewView>("full_backup_peek_local", { path });
export const fullBackupPeekCloud = (cloudPath: string) =>
  invoke<BackupPreviewView>("full_backup_peek_cloud", { cloudPath });

/** 本机设备标识（导出区展示；与备份清单 `device_id` 同源，未初始化返回空串） */
export interface FullBackupDeviceInfo {
  device_id: string;
}
export const fullBackupDeviceInfo = () =>
  invoke<FullBackupDeviceInfo>("full_backup_device_info");

// ---------- 定时自动备份（backup_scheduler） ----------

export type BackupScheduleType =
  | "off"
  | "hourly"
  | "daily"
  | "weekly"
  | "monthly"
  | "yearly";

/** BackupPrefs（full_sync_backup_prefs，snake_case 直传；时间戳为 Unix 秒） */
export interface BackupPrefs {
  local_path: string | null;
  keep_latest: boolean;
  /** 云端备份开关：关闭时定时/同步前自动备份均不上传云端 */
  cloud_backup_enabled: boolean;
  /** 本地备份开关：关闭时不写入 backups 目录 */
  local_backup_enabled: boolean;
  schedule_type: BackupScheduleType;
  /** "HH:mm"（UTC），用于 daily/weekly/monthly/yearly */
  schedule_time: string;
  /** 0-59，用于 hourly */
  schedule_minute: number;
  /** 0-6（0=周日），用于 weekly */
  schedule_weekday: number;
  /** 1-28，用于 monthly/yearly */
  schedule_day_of_month: number;
  /** 1-12，用于 yearly */
  schedule_month: number;
  last_backup_at: number;
  next_backup_at: number;
}

/** 读取备份偏好（返回值含服务端回填的 next_backup_at） */
export const backupPrefsGet = () => invoke<BackupPrefs>("backup_prefs_get");
export const backupPrefsSave = (prefs: BackupPrefs) =>
  invoke<BackupPrefs>("backup_prefs_save", { prefs });

/** 自动备份完成事件载荷（auto-backup-finished） */
export interface AutoBackupFinishedEvent {
  ok: boolean;
  local_path?: string | null;
  local_error?: string | null;
  cloud_uploaded?: boolean;
  cloud_error?: string | null;
  error?: string;
}


// ---------- 明文数据导出（07 报告 #15；PRIVACY.md §七口径） ----------
export interface PlaintextExportView {
  content: string;
  table_counts: Record<string, number>;
  suggested_filename: string;
}

/** 导出全部待办数据为结构化 JSON（默认排除墓碑行） */
export const plaintextExportJson = (excludeDeleted = true) =>
  invoke<PlaintextExportView>("plaintext_export_json", { excludeDeleted });

/** 导出任务主视图 CSV（UTF-8 with BOM；默认排除墓碑行） */
export const plaintextExportCsv = (excludeDeleted = true) =>
  invoke<PlaintextExportView>("plaintext_export_csv", { excludeDeleted });

// ---------- CSV 导入（迁移路径：orbit / Todoist / TickTick） ----------

/** CSV 导入预设档位 key（Rust CsvImportPreset::from_key 同口径） */
export type CsvImportPresetKey = "orbit" | "todoist" | "ticktick" | "ics";

/** 一条映射后的待导入行（预览载荷；Rust CsvImportRow 镜像） */
export interface CsvImportRowView {
  source_line: number;
  project_title: string | null;
  input: {
    title: string;
    description: string | null;
    priority: number | null;
    status: string | null;
    done: number | null;
    done_at: number | null;
    due_date: number | null;
    start_date: number | null;
  };
  skip_reason: string | null;
}

export interface CsvImportStats {
  success: number;
  skipped: number;
  failed: number;
  notes: string[];
}

export interface CsvImportPreviewView {
  preset: string;
  rows: CsvImportRowView[];
  stats: CsvImportStats;
}

/** 预览导入（不写库）：解析 + 映射 + 统计 */
export const csvImportPreview = (content: string, preset: CsvImportPresetKey, previewLimit = 20) =>
  invoke<CsvImportPreviewView>("csv_import_preview", { content, preset, previewLimit });

// 旧的 `csvImportExecute`（一次性阻塞执行）包装已删除：现网只走下方可取消的
// job 通道（进度 + 取消，docs/13 §6.2 M2）。保留包装只会诱导回退到「大文件
// 静默卡住、用户无法中止」的老路径——Rust 命令本身仍在，删的是前端入口。

/** 导入限额（字节 / 行数）：选文件后先比对大小，超限即拦（docs/13 §6.2 M2） */
export interface ImportLimits {
  max_bytes: number;
  max_rows: number;
}

export const csvImportLimits = () => invoke<ImportLimits>("csv_import_limits");

// ── 可取消导入（进度 + 取消；docs/13 §6.2 M2 第 3/5 点）──

/** 导入任务状态快照（Rust ImportJobStatus 镜像） */
export interface ImportJobStatus {
  job_id: string;
  processed: number;
  total: number | null;
  finished: boolean;
  cancelled: boolean;
  stats: CsvImportStats | null;
  error: string | null;
}

/** 启动可取消导入：同步预检限额后返回 job_id（后台执行） */
export const csvImportJobStart = (content: string, preset: CsvImportPresetKey) =>
  invoke<string>("csv_import_job_start", { content, preset });

/** 轮询导入任务状态 */
export const csvImportJobStatus = (jobId: string) =>
  invoke<ImportJobStatus>("csv_import_job_status", { jobId });

/** 请求取消导入（行边界生效；已写入的行保留） */
export const csvImportJobCancel = (jobId: string) =>
  invoke<void>("csv_import_job_cancel", { jobId });

/** 释放任务条目（拿到终态后调用） */
export const csvImportJobDrop = (jobId: string) =>
  invoke<void>("csv_import_job_drop", { jobId });


// ---------- 节假日数据（日历视图；用户需求：联网更新节假日） ----------

/** 节假日行（cfg_holidays 缓存；date YYYY-MM-DD） */
export interface HolidayInfo {
  date: string;
  year: number;
  /** true = 放假日；false = 调休补班日（要上班的周末） */
  is_holiday: boolean;
  /** 节假日名称（如「春节」「春节前补班」） */
  name: string;
}

/** 节假日更新记账（日历工具栏「上次更新」+ 设置页自动开关用） */
export interface HolidayMeta {
  /** 上次「自动更新范围内年份」成功更新（ms；0 = 从未成功） */
  last_update_ms: number;
  /** 上次尝试（ms；0 = 从未尝试） */
  last_attempt_ms: number;
  /** 连续失败次数（成功后清零） */
  failure_count: number;
  /** 自动更新总开关（关闭后仅手动 / 按年补写） */
  auto_enabled: boolean;
}

/** 按年范围补写结果汇总 */
export interface HolidayRangeSummary {
  /** 成功写入（含空响应）的年份数 */
  ok: number;
  /** 获取失败的年份数（含熔断后未尝试的年份） */
  failed: number;
  /** 成功但线上无数据的年份数 */
  empty: number;
  /** 是否被中途取消 */
  cancelled: boolean;
}

/** 范围补写进度（`holiday-progress` 事件载荷；serde 内部标签 `phase`） */
export type HolidayProgress =
  | { phase: "starting"; total: number }
  | {
      phase: "year";
      year: number;
      done: number;
      total: number;
      ok: boolean;
      empty: boolean;
    }
  | { phase: "done"; ok: number; failed: number; cancelled: boolean }
  | { phase: "error"; message: string };

/** 按单年补写结果（记账 + 该年实际行数；`row_count == 0` = 该年线上无数据） */
export interface HolidayYearOutcome {
  meta: HolidayMeta;
  row_count: number;
}

/** 按年补写的可选年份下界（timor.tech 实测有数据的最早年份） */
export const HOLIDAY_FETCH_YEAR_MIN = 2013;

/** 按年补写的可选年份上界 = 明年（与 core `holiday_fetch_year_max` 同口径） */
export const holidayFetchYearMax = (now = new Date()) => now.getFullYear() + 1;

/** 全部节假日（date 升序；按年合并：DB 已覆盖年份为准，预置表兜底其余年份） */
export const holidaysList = () => invoke<HolidayInfo[]>("holidays_list");

/** 判定某日期：Some(true) 放假 / Some(false) 补班 / null 普通日（按星期） */
export const holidayIsOn = (date: string) =>
  invoke<boolean | null>("holiday_is_on", { date });

/** 手动更新（强制拉取；失败抛错误文案，旧缓存保留） */
export const holidaysUpdate = () => invoke<HolidayMeta>("holidays_update");

/** 更新记账 */
export const holidayMeta = () => invoke<HolidayMeta>("holiday_meta");

/** 按单年补写（年份需在 2013 ~ 明年；整年替换，历史年份不写自动更新记账） */
export const holidayFetchYear = (year: number) =>
  invoke<HolidayYearOutcome>("holiday_fetch_year", { year });

/** 按年份范围补写（并发 + 熔断；进度经 `holiday-progress` 事件） */
export const holidayFetchRange = (start: number, end: number) =>
  invoke<HolidayRangeSummary>("holiday_fetch_range", { start, end });

/** 请求取消进行中的范围补写（幂等） */
export const holidayCancelFetch = () => invoke<void>("holiday_cancel_fetch");

/** 设置自动更新总开关 */
export const holidaySetAutoEnabled = (enabled: boolean) =>
  invoke<void>("holiday_set_auto_enabled", { enabled });


// ---------- 回收站（删除的任务可恢复；保留时间可配） ----------

/** TTL 清理执行统计（守护 tick 与手动触发的共用返回） */
export interface TrashPurgeStats {
  /** 物理删除的墓碑行数 */
  purged: number;
  /** 因同步守卫跳过的行数（删除尚未 push 到云端，清了有复活风险） */
  guarded: number;
  /** 本次是否实际执行了清理 */
  ran: boolean;
}

/** 回收站元数据（保留档位 + 上次自动清理时间） */
export interface TrashMeta {
  /** 保留天数（0 = 永久；默认 30，档位 7/30/90/0） */
  retention_days: number;
  /** 上次 TTL 自动清理时间（ms；0 = 从未执行） */
  last_purge_ms: number;
}

/** 回收站任务列表（最近删除排最前） */
export const trashTasksList = () => invoke<TodoTask[]>("trash_tasks_list");

/** 恢复任务（原项目已删则落入未分组） */
export const trashTaskRestore = (id: number) =>
  invoke<TodoTask>("trash_task_restore", { id });

/** 彻底删除单个回收站任务（不可恢复） */
export const trashTaskPurge = (id: number) =>
  invoke<void>("trash_task_purge", { id });

/** 清空回收站，返回删除的任务数 */
export const trashPurgeAll = () => invoke<number>("trash_purge_all");

/** TTL 过期清理一次（通常由后台守护触发；也可手动） */
export const trashPurgeExpired = () =>
  invoke<TrashPurgeStats>("trash_purge_expired");

/** 回收站元数据 */
export const trashMeta = () => invoke<TrashMeta>("trash_meta");

/** 设置保留天数（档位 7/30/90/0=永久；默认 30） */
export const trashSetRetentionDays = (days: number) =>
  invoke<void>("trash_set_retention_days", { days });

// ---------- 每日摘要提醒（G3：每日固定时刻汇总通知） ----------

/** 摘要偏好（存 cfg_kv，本机设置不随云同步） */
export interface DigestPrefs {
  /** 总开关（默认 false：打扰型功能需显式开启） */
  enabled: boolean;
  /** 目标小时（0–23） */
  hour: number;
  /** 目标分钟（0–59） */
  minute: number;
}

/** 摘要计数（今日截止 / 逾期 / 今日完成） */
export interface DigestSummary {
  due_today: number;
  overdue: number;
  done_today: number;
}

/** 读摘要偏好 */
export const digestPrefs = () => invoke<DigestPrefs>("digest_prefs");

/** 设置摘要偏好（enabled + hour 0–23 + minute 0–59） */
export const digestSetPrefs = (enabled: boolean, hour: number, minute: number) =>
  invoke<void>("digest_set_prefs", { enabled, hour, minute });

/** 当前时刻摘要计数（设置页预览；只读，不消耗每日记账） */
export const digestSummary = () => invoke<DigestSummary>("digest_summary");

// ========== stats（backlog #25：统计仪表盘） ==========
export interface StatsOverview {
  total: number;
  pending: number;
  done: number;
  done_last_7d: number;
  done_last_30d: number;
}
export interface StatsHeatmapCell {
  /** 本地日期 YYYY-MM-DD */
  date: string;
  count: number;
}
export interface StatsHeatmap {
  /** 热力图年份（入参回显） */
  year: number;
  start_date: string;
  end_date: string;
  cells: StatsHeatmapCell[];
}
export interface StatsStreak {
  current: number;
  best: number;
  done_today: boolean;
}
export interface StatsProjectRow {
  project_id: number | null;
  /** null = 未分组 */
  project_title: string | null;
  /** 项目自选色（null = 未分组；空串/缺失回落待办强调色） */
  project_hex_color: string | null;
  done_count: number;
  pending_count: number;
}
export interface StatsPriorityRow {
  priority: number;
  done_count: number;
  pending_count: number;
}
export interface StatsWeekdayRow {
  /** 0=周一 … 6=周日 */
  weekday: number;
  done_count: number;
}
export interface StatsAggregate {
  overview: StatsOverview;
  heatmap: StatsHeatmap;
  streak: StatsStreak;
  by_project: StatsProjectRow[];
  by_priority: StatsPriorityRow[];
  by_weekday: StatsWeekdayRow[];
  /** 热力图可选年份（升序；有完成记录的年份，空则 [当前年]） */
  available_years: number[];
}
/** 统计聚合（year 为热力图年份；缺省当前年 = 滚动 365 天窗口） */
export const statsAggregate = (year?: number) =>
  invoke<StatsAggregate>("stats_aggregate", { year });

// ========== day_planner（F3 日排程：阶段一只读预览，ADR 0013）==========
/** 排程偏好（相对今天零点的分钟；阶段一双端传默认值，阶段三落 cfg_kv 可编辑） */
export interface DayPlanPrefs {
  work_start_minute: number;
  work_end_minute: number;
  lunch_start_minute: number;
  lunch_end_minute: number;
  granularity_minutes: number;
  default_task_minutes: number;
  include_overdue: boolean;
}
/** 默认作息：09:00-18:00，午休 12:00-13:00，15 分钟粒度，无时长兜底 30 分钟 */
export const DAY_PLAN_DEFAULT_PREFS: DayPlanPrefs = {
  work_start_minute: 9 * 60,
  work_end_minute: 18 * 60,
  lunch_start_minute: 12 * 60,
  lunch_end_minute: 13 * 60,
  granularity_minutes: 15,
  default_task_minutes: 30,
  include_overdue: true,
};
/** 单个排程建议（时段 + 任务 + 可解释理由） */
export interface PlanSlot {
  task_id: number;
  title: string;
  start_ms: number;
  end_ms: number;
  duration_minutes: number;
  /** 「已逾期 N 天」「截止 HH:mm」「高优先级」「我的一天」「填充空档」「顺序安排」 */
  reason: string;
}
/** 未排入任务与原因 */
export interface UnscheduledTask {
  task_id: number;
  title: string;
  /** 「晚于截止 HH:mm」「今日时段已满」「已过工作时间」 */
  reason: string;
}
/** 日排程预览（只读） */
export interface DayPlan {
  slots: PlanSlot[];
  unscheduled: UnscheduledTask[];
  /** 今天剩余可排容量（分钟，已扣午休与已过时段） */
  capacity_minutes: number;
  /** 候选任务总时长（分钟） */
  load_minutes: number;
  overloaded: boolean;
  day_start_ms: number;
}
/** 规划今天：排程预览 */
export const dayPlanPreview = (prefs: DayPlanPrefs, nowMs: number) =>
  invoke<DayPlan>("day_plan_preview", { prefs, nowMs: nowMs });

/** 应用输入：预览结果中勾选的单条 */
export interface ApplySlotInput {
  task_id: number;
  /** 应用后的开始时间（今天内的墙钟毫秒） */
  start_ms: number;
}
/** 单行应用结果（撤销快照：prev 值经既有更新通道写回） */
export interface AppliedRow {
  task_id: number;
  prev_start_date: number | null;
  prev_my_day_date: number | null;
}
export interface ApplyResult {
  applied: AppliedRow[];
}
/** 应用排程（阶段二）：写 my_day_date + start_date（不改 due_date，单事务） */
export const dayPlanApply = (dayStartMs: number, slots: ApplySlotInput[]) =>
  invoke<ApplyResult>("day_plan_apply", { dayStartMs, slots });
/** 读取排程偏好（cfg_kv，缺键回落默认；编辑区初值） */
export const dayPlanPrefsGet = () => invoke<DayPlanPrefs>("day_plan_prefs_get");
/** 保存排程偏好（校验钳制后落库，返回存后生效值供 UI 回显） */
export const dayPlanPrefsSet = (prefs: DayPlanPrefs) =>
  invoke<DayPlanPrefs>("day_plan_prefs_set", { prefs });

/** 一键复制任务（#37：克隆字段+子任务，副本标题后缀） */
export const todoTaskDuplicate = (id: number) =>
  invoke<TodoTask>("todo_tasks_duplicate", { id });

// ========== task_attachments（任务附件：07 排查报告后续批次）==========
export interface TaskAttachmentView {
  link_id: number;
  link_uuid: string;
  hash: string;
  original_name: string;
  mime_type: string;
  size_bytes: number;
  /** 0 = 尚未从云端拉回，暂不可打开 */
  is_local_cached: number;
}
export const taskAttachmentAdd = (
  taskId: number,
  fileName: string,
  mimeType: string,
  data: number[],
) =>
  invoke<TaskAttachmentView>("task_attachment_add", {
    taskId,
    fileName,
    mimeType,
    data,
  });
/** 从本地路径流式写入附件（文件选择器主路径；M3 起不再经 IPC 搬运整份字节） */
export const taskAttachmentAddFromPath = (
  taskId: number,
  fileName: string,
  mimeType: string,
  sourcePath: string,
) =>
  invoke<TaskAttachmentView>("task_attachment_add_from_path", {
    taskId,
    fileName,
    mimeType,
    sourcePath,
  });
export const taskAttachmentsList = (taskId: number) =>
  invoke<TaskAttachmentView[]>("task_attachments_list", { taskId });
export const taskAttachmentRead = (hash: string) =>
  invoke<number[]>("task_attachment_read", { hash });
/** 流式导出附件到指定路径（大文件/系统程序打开；返回写入字节数） */
export const taskAttachmentExport = (hash: string, targetPath: string) =>
  invoke<number>("task_attachment_export", { hash, targetPath });
export const taskAttachmentRemove = (linkId: number) =>
  invoke<void>("task_attachment_remove", { linkId });
// 旧的 `attachmentsGc`（无参数、无返回值语义的裸 GC）包装已删除：附件 GC 现由
// `db_maintenance` 三件套统一承载（启动期 `spawn_idle_maintenance` 轻维护 + 手动
// 「立即维护」+ 缓存上限），单独调它会让「账本/关联/缓存上限」这三步错拍。
// Rust 命令本身保留（维护链内部调用），删的是前端旁路入口。
/** 未使用附件（无任何存活任务引用的账本行；诊断页清理入口的清单行） */
export interface UnusedAttachmentView {
  hash: string;
  original_name: string;
  mime_type: string;
  size_bytes: number;
  /** 0 = 尚未上传云端（删除后无法从其他设备找回） */
  is_uploaded: number;
  is_local_cached: number;
  created_at: number;
}
export const attachmentsUnusedList = () =>
  invoke<UnusedAttachmentView[]>("attachments_unused_list");
/** 按 hash 批量清除未使用附件（本地文件+账本行；云端对象保留），返回清理数 */
export const attachmentsUnusedDelete = (hashes: string[]) =>
  invoke<number>("attachments_unused_delete", { hashes });

/** 云端孤儿附件行（docs/15；诊断页「云端存储」清理入口） */
export interface CloudUnusedAttachmentView {
  hash: string;
  /** 密文体积；WebDAV 分片形态为 0（目录条目没有长度），展示用 size_bytes 兜底 */
  cipher_bytes: number;
  /** 服务端最后修改时间（Unix 秒） */
  last_modified: number;
  /** 云端形态：整包 / 分片 / 两者并存 */
  kind: "whole" | "chunked" | "both";
  original_name: string;
  /** 本地账本明文体积（0 = 账本无该行） */
  size_bytes: number;
  is_local_cached: number;
  is_uploaded: number;
}

export interface CloudUnusedScanResult {
  items: CloudUnusedAttachmentView[];
  /** 清单 epoch：删除时原样回传做 CAS（不一致要求重扫） */
  epoch: number;
  /** 年龄窗口（秒），UI 文案用「仅含 N 天前的对象」 */
  min_age_secs: number;
}

export interface CloudUnusedDeleteResult {
  deleted_assets: number;
  deleted_objects: number;
  skipped_referenced: number;
  local_rows_cleaned: number;
  stale_manifest: boolean;
  errors: string[];
}

/** 孤儿数据分桶回收结果（#96 尾款入口；只动 tables/，不碰附件对象） */
export interface OrphanChunkGcResult {
  deleted_buckets: number;
  errors: string[];
}

/** 只读扫描云端孤儿附件（需已配置同步且已解锁） */
export const cloudUnusedAttachmentsScan = () =>
  invoke<CloudUnusedScanResult>("cloud_unused_attachments_scan");

/** 删除勾选的云端孤儿附件（整包+分片；本地账本按无引用复核收尾） */
export const cloudUnusedAttachmentsDelete = (
  hashes: string[],
  expectedEpoch: number,
) =>
  invoke<CloudUnusedDeleteResult>("cloud_unused_attachments_delete", {
    hashes,
    expectedEpoch,
  });

/** 回收孤儿数据分桶（清单无引用 + 24h 窗口；#96 尾款入口） */
export const cloudOrphanChunksGc = () =>
  invoke<OrphanChunkGcResult>("cloud_orphan_chunks_gc");

// ========== 数据库维护（性能批次：WAL checkpoint / 附件 GC / 日志 TTL / 查询统计 / VACUUM）==========
export interface DbMaintenanceResult {
  /** WAL checkpoint 后 -wal 文件剩余大小（字节） */
  wal_bytes_after_checkpoint: number;
  /** 附件 GC 清理的孤立文件数 */
  attachments_cleaned: number;
  /** 日志 TTL 清理的行数（通知历史 + 活动日志，30 天口径） */
  log_rows_pruned: number;
  /** VACUUM 前空闲页数（碎片页） */
  freelist_before: number;
  /** VACUUM 后空闲页数（应为 0） */
  freelist_after: number;
  /** VACUUM 实际回收的页数 */
  pages_reclaimed: number;
}
/** 一键数据库维护：WAL checkpoint → 附件 GC → 附件缓存上限 → 日志 TTL → 全量 ANALYZE（查询计划统计） → VACUUM */
export const dbMaintenance = () => invoke<DbMaintenanceResult>("db_maintenance");

// ========== 主窗唤起（托盘驻留内存优化：窗口可能被超时回收）==========
/**
 * 唤起主窗：窗口在（隐藏驻留态）则显示聚焦；已被超时回收销毁则按
 * tauri.conf 配置重建。前端 getCurrentWindow().show() 在窗口销毁后
 * 无兜底，全局热键等「窗口可能不在」的路径必须走本命令。
 */
export const showMainWindow = () => invoke<void>("show_main_window_cmd");

// ========== 启动形态（开机自启拉起：--hidden 静默驻留）==========
/**
 * 本次进程是否由开机自启拉起：为真时启动流程跳过主窗 show，静默驻留
 * 托盘（壳层已同步接上隐藏回收链，常驻内存回落宿主档）。
 * 判定源是 autostart 注册项注入的 `--hidden` 参数（startup_cmd）。
 */
export const startupLaunchedHidden = () => invoke<boolean>("startup_launched_hidden");

// ========== saved_filters（保存的筛选器：#35）==========
export interface TodoSavedFilter {
  id: number;
  uuid: string;
  name: string;
  /** 条件 JSON：{status?, priority_min?, project_ids?, label_ids?, due_within_days?, due_overdue?, favorite_only?} */
  conditions: string;
  sort_order: number;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoSavedFilterCreateInput {
  name: string;
  conditions: string;
  sort_order?: number;
}
export interface TodoSavedFilterUpdateInput {
  name?: string;
  conditions?: string;
  sort_order?: number;
}
export const savedFiltersList = () => invoke<TodoSavedFilter[]>("saved_filters_list");
export const savedFilterCreate = (input: TodoSavedFilterCreateInput) =>
  invoke<TodoSavedFilter>("saved_filter_create", { input });
export const savedFilterUpdate = (id: number, input: TodoSavedFilterUpdateInput) =>
  invoke<TodoSavedFilter>("saved_filter_update", { id, input });
export const savedFilterDelete = (id: number) => invoke<void>("saved_filter_delete", { id });

// ========== ICS 日历导出（#4：VTODO 日历，日历软件导入/订阅）==========
export interface IcsExportResult {
  content: string;
  table_counts: Record<string, number>;
  suggested_filename: string;
}
export const icsExport = () => invoke<IcsExportResult>("ics_export");

// ========== 通知历史（#5：呈现轨迹回看；只读本地表不进同步）==========
export interface NotificationLogRow {
  id: number;
  kind: string; // reminder_due / snooze / complete / boot_skip
  task_id: number | null;
  task_title: string;
  reminder_id: number | null;
  payload: string;
  created_at: number;
}
export const notificationLogList = (kind?: string, limit?: number) =>
  invoke<NotificationLogRow[]>("notification_log_list", { kind: kind ?? null, limit: limit ?? null });
export const notificationLogClear = () => invoke<number>("notification_log_clear");

// ========== 任务活动日志（F6：操作轨迹回看；只读本地表不进同步）==========
export interface ActivityLogRow {
  id: number;
  task_id: number | null;
  task_title: string;
  /** create / update / complete / uncomplete / delete / restore */
  action: string;
  /** 附加 JSON：{"fields":[变更字段名,…]}（update）/ {}（其他） */
  detail: string;
  created_at: number;
}
export const taskActivityList = (taskId: number, limit?: number) =>
  invoke<ActivityLogRow[]>("task_activity_list", { taskId, limit: limit ?? null });

// ========== templates（任务模板：竞品矩阵高价值缺口）==========
export interface TodoTemplate {
  id: number;
  uuid: string;
  name: string;
  /** 模板内容 JSON：{title?, notes?, priority?, due_offset_days?, subtasks?}——套用时按存在键预填 */
  payload: string;
  sort_order: number;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoTemplateCreateInput {
  name: string;
  payload: string;
  sort_order?: number;
}
export interface TodoTemplateUpdateInput {
  name?: string;
  payload?: string;
  sort_order?: number;
}
export const templatesList = () => invoke<TodoTemplate[]>("templates_list");
export const templateCreate = (input: TodoTemplateCreateInput) =>
  invoke<TodoTemplate>("template_create", { input });
export const templateUpdate = (id: number, input: TodoTemplateUpdateInput) =>
  invoke<TodoTemplate>("template_update", { id, input });
export const templateDelete = (id: number) => invoke<void>("template_delete", { id });

// ========== 冷启动度量（docs/09 §六；ORBIT_PERF_MARKER 未设置时 Rust 侧 no-op）==========
/** 上报「首屏就绪」时刻到 ORBIT_PERF_MARKER 指定文件（perf-metrics/cold-start.mjs 消费） */
export const perfFirstScreenMark = () => invoke<void>("perf_first_screen_mark");

// ========== 应用内诊断分区（docs/09 内存专项；只读读数，不进同步白名单）==========
/** 单表活行数（`is_deleted = 0`） */
export interface TableRowCount {
  table: string;
  rows: number;
}
/** 应用内诊断快照（镜像 orbit_core::api::diagnostics_api::DiagnosticsSnapshot） */
export interface DiagnosticsSnapshot {
  /** 本地库体积（字节，SQLite page_count × page_size；不含 WAL 与附件目录） */
  db_size_bytes: number;
  /** 各表活行数（顺序 = 同步白名单顺序） */
  table_rows: TableRowCount[];
  /** 全部可同步表的墓碑行数合计 */
  tombstone_rows: number;
  /** 附件本地缓存体积（字节） */
  attachment_cache_bytes: number;
  /** 附件本地缓存文件数 */
  attachment_cache_files: number;
}
/** 采集诊断快照（只读聚合，不触发 db-change） */
export const diagnosticsSnapshot = () =>
  invoke<DiagnosticsSnapshot>("diagnostics_snapshot");

/**
 * 日志目录读数（镜像 `log_cmd::LogOverview`）。
 *
 * 只报目录路径与文件清单，**不读日志内容**——日志可达数十 MB，整份读进前端
 * 只会让设置页变卡；用户真正要做的是「找到它、发给我」。打开动作由前端用
 * `plugin-shell` 的 `open` 完成（与「非图片附件用系统程序打开」同一通道）。
 */
export interface LogFileView {
  name: string;
  /** 字节数（读取失败为 0，不阻断整份清单） */
  size_bytes: number;
  /** 最后修改时间（Unix 毫秒；不可得为 0） */
  modified_ms: number;
}

export interface LogOverview {
  /** 日志目录绝对路径 */
  dir: string;
  /** 目录是否可读；false 时 files 恒空、reason 说明原因 */
  readable: boolean;
  reason: string | null;
  /** 按修改时间倒序，最多 20 条 */
  files: LogFileView[];
}

export const logOverview = () => invoke<LogOverview>("log_overview");

/**
 * Mica 云母材质诊断读数（镜像 `mica_cmd::MicaDiagnostics`，serde camelCase）。
 *
 * 命令本身会顺带重新断言一次材质（幂等），故只在诊断分区挂载/点刷新时调用。
 */
export interface MicaDiagnostics {
  platform: string;
  windowsBuild?: number;
  windowsMajor?: number;
  windowsMinor?: number;
  micaSupported: boolean;
  /** 系统「个性化 → 颜色 → 透明效果」开关；false 时 Mica 不会渲染 */
  transparencyEnabled?: boolean;
  topHwnd?: string;
  hasNoRedirectionBitmap?: boolean;
  backdropBefore?: number;
  backdropAfter?: number;
  applyResult: string;
}
export const micaDiagnostics = () => invoke<MicaDiagnostics>("mica_diagnostics");

// ========== 测试数据（仅开发构建；release 命令返回不可用，前端入口 DEV 门禁）==========
/** 生成规模（镜像 orbit_core::api::dev_seed_api::DevSeedPlan；只暴露任务条数） */
export interface DevSeedPlan {
  /** 任务条数（含约 2% 回收站行） */
  tasks: number;
}
/** 各表写入/清除条数（镜像 orbit_core::api::dev_seed_api::DevSeedCounts） */
export interface DevSeedCounts {
  projects: number;
  labels: number;
  tasks: number;
  subtasks: number;
  reminders: number;
  comments: number;
  task_labels: number;
  task_relations: number;
}
/** 生成结果（`cleared` = 生成前清掉的上一批） */
export interface DevSeedResult {
  created: DevSeedCounts;
  cleared: DevSeedCounts;
  elapsed_ms: number;
}
/** 清理结果 */
export interface DevSeedClearResult {
  removed: DevSeedCounts;
  elapsed_ms: number;
}
/** 一键生成示例数据（先清上一批，不碰手工数据） */
export const devSeedDemoData = (plan: DevSeedPlan) =>
  invoke<DevSeedResult>("dev_seed_demo_data", { plan });
/** 清除示例数据（按 uuid 前缀物理删除） */
export const devSeedClear = () => invoke<DevSeedClearResult>("dev_seed_clear");
