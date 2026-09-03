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
}

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
 * 返回 db_key_hex 供 dbInitEncrypted() 使用。
 *
 * 典型流程：用户首次设置开屏密码 → masterAuthInit(pw) → dbInitEncrypted(dbKeyHex)
 */
export async function masterAuthInit(password: string): Promise<string> {
  return invoke<string>("master_auth_init", { password });
}

/**
 * 解锁主密码
 *
 * 验证密码并解密 DB Key。成功返回 db_key_hex。
 *
 * 典型流程：masterAuthUnlock(pw) → dbInitEncrypted(dbKeyHex)
 * @throws 密码错误时抛出异常
 */
export async function masterAuthUnlock(password: string): Promise<string> {
  return invoke<string>("master_auth_unlock", { password });
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
 * 使用 masterAuthUnlock 返回的 db_key_hex 打开 SQLCipher 加密数据库。
 */
export async function dbInitEncrypted(dbKeyHex: string): Promise<void> {
  return invoke<void>("db_init_encrypted", { dbKeyHex });
}

/**
 * 查询数据库是否已初始化
 *
 * 前端据此判断是否需要显示解锁页面。
 */
export async function dbIsReady(): Promise<boolean> {
  return invoke<boolean>("db_is_ready");
}

/** 明文→加密迁移（设置主密码场景；随后需 dbInitEncrypted 重开连接池） */
export async function dbMigrateToEncrypted(dbKeyHex: string): Promise<void> {
  return invoke<void>("db_migrate_to_encrypted", { dbKeyHex });
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
}
export interface TodoProjectUpdateInput {
  title?: string;
  description?: string | null;
  hex_color?: string;
  sort_order?: number;
}
export const todoProjectList = (filter: ListFilter) => invoke<TodoProject[]>("todo_projects_list", { filter });
export const todoProjectGet = (id: number) => invoke<TodoProject>("todo_projects_get", { id });
export const todoProjectCreate = (input: TodoProjectCreateInput) => invoke<TodoProject>("todo_projects_create", { input });
export const todoProjectUpdate = (id: number, input: TodoProjectUpdateInput) => invoke<TodoProject>("todo_projects_update", { id, input });
export const todoProjectDelete = (id: number) => invoke<void>("todo_projects_delete", { id });
export const todoProjectGetByUuid = (uuid: string) => invoke<TodoProject | null>("todo_projects_get_by_uuid", { uuid });
export const todoProjectUpdateSortOrder = (id: number, sortOrder: number) => invoke<void>("todo_projects_update_sort_order", { id, sortOrder });

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
  end_date: number | null;
  repeat_after: number;
  repeat_mode: number;
  percent_done: number;
  position: number;
  is_favorite: number;
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
  end_date?: number | null;
  repeat_after?: number;
  repeat_mode?: number;
  position?: number;
  is_favorite?: number;
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
  end_date?: number | null;
  repeat_after?: number;
  repeat_mode?: number;
  percent_done?: number;
  position?: number;
  is_favorite?: number;
}
export const todoTaskList = (filter: ListFilter) => invoke<TodoTask[]>("todo_tasks_list", { filter });
export const todoTaskGet = (id: number) => invoke<TodoTask>("todo_tasks_get", { id });
export const todoTaskCreate = (input: TodoTaskCreateInput) => invoke<TodoTask>("todo_tasks_create", { input });
export const todoTaskUpdate = (id: number, input: TodoTaskUpdateInput) => invoke<TodoTask>("todo_tasks_update", { id, input });
export const todoTaskDelete = (id: number) => invoke<void>("todo_tasks_delete", { id });
export const todoTaskGetByUuid = (uuid: string) => invoke<TodoTask | null>("todo_tasks_get_by_uuid", { uuid });
export const todoTaskUpdatePosition = (id: number, position: number) => invoke<void>("todo_tasks_update_position", { id, position });

// ========== todo_subtasks ==========
export interface TodoSubtask {
  id: number;
  uuid: string;
  task_id: number;
  title: string;
  done: number;
  done_at: number | null;
  position: number;
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
}
export interface TodoSubtaskUpdateInput {
  title?: string;
  done?: number;
  done_at?: number | null;
  position?: number;
}
export const todoSubtaskList = (filter: ListFilter) => invoke<TodoSubtask[]>("todo_subtasks_list", { filter });
export const todoSubtaskGet = (id: number) => invoke<TodoSubtask>("todo_subtasks_get", { id });
export const todoSubtaskCreate = (input: TodoSubtaskCreateInput) => invoke<TodoSubtask>("todo_subtasks_create", { input });
export const todoSubtaskUpdate = (id: number, input: TodoSubtaskUpdateInput) => invoke<TodoSubtask>("todo_subtasks_update", { id, input });
export const todoSubtaskDelete = (id: number) => invoke<void>("todo_subtasks_delete", { id });
export const todoSubtaskToggleDone = (subtaskId: number, done: boolean) => invoke<void>("todo_subtasks_toggle_done", { subtaskId, done });

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
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}
export interface TodoReminderCreateInput {
  task_id: number;
  remind_at: number;
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
export const todoTasksKanbanByProject = () => invoke<[number | null, TodoTask[]][]>("todo_tasks_kanban_by_project", {});
export const todoTasksKanbanByStatus = () => invoke<[string, TodoTask[]][]>("todo_tasks_kanban_by_status", {});
export const todoTaskRecalcPercent = (taskId: number) => invoke<void>("todo_tasks_recalc_percent", { taskId });

// ========== M3 安全与同步 ==========

/**
 * 同步域错误通道约定（Rust 侧 `[tag] message` 前缀）：
 * - key_mismatch → 引导恢复页；wrong_password / not_unlocked → 解锁入口
 * - local_meta_exists → Fix-10 确认覆盖；config → 表单校验提示
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
export const syncCryptoInit = (password: string, remember: boolean) =>
  invoke<void>("sync_crypto_init", { password, remember });
export const syncCryptoUnlock = (password: string, remember: boolean) =>
  invoke<void>("sync_crypto_unlock", { password, remember });
export const syncCryptoLock = () => invoke<void>("sync_crypto_lock");
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
  duration_ms: number;
  skipped: boolean;
  errors: string[];
}

const parseResult = (json: string): SyncResultJson => JSON.parse(json);

export const cloudSyncNow = (origin: "manual" | "background" | "exit" = "manual") =>
  invoke<string>("cloud_sync_now", { origin }).then(parseResult);
export const cloudSyncPushOnly = (origin: "manual" | "background" | "exit" = "manual") =>
  invoke<string>("cloud_sync_push_only", { origin }).then(parseResult);
export const cloudSyncPullThenPush = (origin: "manual" | "background" | "exit" = "manual") =>
  invoke<string>("cloud_sync_pull_then_push", { origin }).then(parseResult);
export const cloudSyncGetState = () =>
  invoke<string>("cloud_sync_get_state").then((s) => JSON.parse(s));
export const cloudSyncIsRunning = () => invoke<boolean>("cloud_sync_is_running");
export const syncDisconnect = () => invoke<void>("sync_disconnect");

// ---------- 全量备份 .orsync（full_sync_cmd） ----------

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

export const fullBackupExport = (password: string, uploadCloud: boolean) =>
  invoke<ExportResult>("full_backup_export", { password, uploadCloud });
export const fullBackupImport = (
  path: string,
  password: string,
  ignoreSchemaMismatch: boolean,
) =>
  invoke<ImportResult>("full_backup_import", {
    path,
    password,
    ignoreSchemaMismatch,
  });
export const fullBackupListLocal = () => invoke<BackupEntryView[]>("full_backup_list_local");

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
