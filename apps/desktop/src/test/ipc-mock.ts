/**
 * 浏览器冒烟环境（#19）——在无 Tauri WebView 的纯浏览器中伪造最小 IPC 面，
 * 供 Playwright 冒烟走「新建→完成→删除」等主链路。
 *
 * 设计：
 * - main.tsx 渲染前先 installBrowserIpc()（仅非 Tauri 环境生效）。
 *   @tauri-apps/api v2 的 invoke/listen 最终都走
 *   window.__TAURI_INTERNALS__，伪造该全局对象即可同时接管两者；
 *   真实 Tauri 运行时零改动（已注入 internals 时直接跳过）。
 * - listen 走 invoke('plugin:event|listen')，handler 经
 *   transformCallback 注册为 id 后传给后端——桩侧保存 id→cb 映射，
 *   写命令完成后按事件名派发（模拟 Rust EVENT_BUS 的 db-change 广播，
 *   events 层收到后 invalidateQueries，UI 与真实链路同构）。
 * - 内存库只覆盖主链路用到的命令（五张表 CRUD + 启动三命令 +
 *   sync/mica/backup 静默路径）；未覆盖命令统一 reject，
 *   避免静默假绿。
 * - 数据模型字段与 lib/tauri.ts 的 TS 接口一致（snake_case 直传）。
 * - e2e 可经 window.__orbitMock 拿 db / seed 预置数据。
 */

// ---------- 最小模型（与 lib/tauri.ts 接口对齐） ----------

interface MockProject {
  id: number;
  uuid: string;
  title: string;
  description: string | null;
  hex_color: string;
  sort_order: number;
  is_archived: number;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}

interface MockTask {
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
  percent_done: number;
  position: number;
  is_favorite: number;
  my_day_date: number | null;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}

interface MockLabel {
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

interface MockTaskLabel {
  id: number;
  task_id: number;
  label_id: number;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  version: number;
}

interface MockSubtask {
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

interface MockReminder {
  id: number;
  task_id: number;
  remind_at: number;
  is_deleted: number;
  created_at: number;
  updated_at: number;
  version: number;
}

interface MockComment {
  id: number;
  task_id: number;
  content: string;
  created_at: number;
  updated_at: number;
  is_deleted: number;
}

export interface MockRelation {
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

export interface MockAttachmentLink {
  link_id: number;
  link_uuid: string;
  task_id: number;
  hash: string;
  original_name: string;
  mime_type: string;
  size_bytes: number;
  is_local_cached: number;
}

export interface MockDb {
  projects: MockProject[];
  tasks: MockTask[];
  labels: MockLabel[];
  taskLabels: MockTaskLabel[];
  subtasks: MockSubtask[];
  reminders: MockReminder[];
  comments: MockComment[];
  relations: MockRelation[];
  attachments: MockAttachmentLink[];
  savedFilters: { id: number; uuid: string; name: string; conditions: string; sort_order: number }[];
  templates: { id: number; uuid: string; name: string; payload: string; sort_order: number }[];
  notificationLog: { id: number; kind: string; task_id: number | null; task_title: string; reminder_id: number | null; payload: string; created_at: number }[];
  activityLog: { id: number; task_id: number | null; task_title: string; action: string; detail: string; created_at: number }[];
  seq: number;
}

const uuid = () =>
  globalThis.crypto?.randomUUID?.() ?? `mock-${Date.now()}-${Math.random()}`;

function createDb(): MockDb {
  return {
    projects: [],
    tasks: [],
    labels: [],
    taskLabels: [],
    subtasks: [],
    reminders: [],
    comments: [],
    relations: [],
    attachments: [],
    savedFilters: [],
    templates: [],
    notificationLog: [
      { id: 1, kind: "reminder_due", task_id: 1, task_title: "回复合作方邮件（逾期）", reminder_id: 1, payload: "{\"remind_at\":1757400000000}", created_at: Date.now() - 3_600_000 },
      { id: 2, kind: "snooze", task_id: 1, task_title: "回复合作方邮件（逾期）", reminder_id: 1, payload: "{\"snooze_until\":1757403600000}", created_at: Date.now() - 3_500_000 },
      { id: 3, kind: "reminder_due", task_id: 2, task_title: "完成移动端重构方案评审", reminder_id: 2, payload: "{\"remind_at\":1757410000000}", created_at: Date.now() - 1_800_000 },
    ],
    activityLog: [],
    seq: 1,
  };
}

/** 冒烟用 seed：预置项目「测试项目」+ 一条今天截止任务（日历/列表用例共用） */
export function seedDefault(db: MockDb) {
  const now = Date.now();
  const project: MockProject = {
    id: db.seq++,
    uuid: uuid(),
    title: "测试项目",
    description: null,
    hex_color: "#3B82F6",
    sort_order: 0,
    is_archived: 0,
    is_deleted: 0,
    created_at: now,
    updated_at: now,
    deleted_at: null,
    version: 1,
  };
  db.projects.push(project);

  const today = new Date();
  today.setHours(10, 0, 0, 0);
  db.tasks.push({
    id: db.seq++,
    uuid: uuid(),
    title: "既有任务-今天截止",
    description: null,
    project_id: project.id,
    priority: 2,
    status: "pending",
    done: 0,
    done_at: null,
    due_date: today.getTime(),
    start_date: null,
    repeat_after: 0,
    repeat_mode: 0,
    percent_done: 0,
    position: 1000,
    is_favorite: 0,
    my_day_date: null,
    is_deleted: 0,
    created_at: now,
    updated_at: now,
    deleted_at: null,
    version: 1,
  });
  return project;
}

/** 冒烟用节假日样例（形状对齐 Rust HolidayInfo；2026 年真实数据节选） */
const MOCK_HOLIDAYS = [
  { date: "2026-01-01", year: 2026, is_holiday: true, name: "元旦" },
  { date: "2026-01-04", year: 2026, is_holiday: false, name: "元旦后补班" },
  { date: "2026-02-17", year: 2026, is_holiday: true, name: "初一" },
] as const;

/** 恢复预览样例（形状对齐 Rust BackupPreview；确认框 ready 分支可渲染） */
const MOCK_BACKUP_PREVIEW = {
  manifest: {
    format_version: 1,
    created_at: "2026-09-17T00:00:00+00:00",
    created_at_ts: 1758067200,
    app_version: "0.1.0",
    device_id: "mock-device",
    device_name: "Mock 设备",
    schema_version: 1,
    table_counts: { todo_projects: 1, todo_tasks: 2 },
  },
  sample_tasks: [
    {
      title: "示例任务一",
      status: "pending",
      done: false,
      due_date: null,
      priority: 0,
      project: "示例项目",
      is_deleted: false,
    },
    {
      title: "示例任务二",
      status: "done",
      done: true,
      due_date: null,
      priority: 3,
      project: null,
      is_deleted: false,
    },
  ],
  task_stats: { total: 2, alive: 2, done: 1, deleted: 0 },
  schema_mismatch: false,
  current_schema_version: 1,
};

// ---------- 云同步造态（#19 冒烟 / 目检） ----------

/**
 * 同步造态开关：默认「未配置」——与真实环境未配置时启动同步静默跳过的路径一致。
 * 验证左上角云图标（SyncStatusButton）的待命/同步中/成功/失败态时：
 *   1. 先在 localStorage 写入 `orbit.mock.sync-state`（模块级状态过不了刷新）；
 *   2. reload 后经 `window.__orbitMock.emitSyncProgress/emitSyncFinished` 推事件。
 */
const SYNC_STATE_KEY = "orbit.mock.sync-state";

function loadSyncState() {
  const defaults = { configured: false, unlocked: false, lastSyncedAt: null as number | null };
  try {
    const raw = localStorage.getItem(SYNC_STATE_KEY);
    return raw ? { ...defaults, ...(JSON.parse(raw) as Partial<typeof defaults>) } : defaults;
  } catch {
    return defaults;
  }
}

const syncState = loadSyncState();

/** 造态下的激活配置体（字段与 lib/tauri.ts SyncConfigView 对齐） */
const mockSyncConfig = () => ({
  id: 1,
  engine: "webdav",
  endpoint: "https://dav.example.com/dav",
  bucket: "",
  region: "",
  username: "demo",
  password_set: true,
  base_path: "orbit",
  interval_minutes: 60,
  auto_sync_enabled: true,
  sync_on_change: false,
  skip_tls_verify: false,
  timeout_seconds: 30,
  last_synced_at: syncState.lastSyncedAt,
});

// ---------- 冲突败方副本造态（03 文档 §八 遗留项） ----------

/** 内存冲突副本表（形状与 lib/tauri.ts SyncConflictEntry 一致） */
interface MockConflict {
  id: number;
  table_name: string;
  record_uuid: string;
  record_title: string;
  decision: string;
  loser_side: string;
  winner_side: string;
  loser_payload: string;
  winner_payload: string;
  loser_updated_at: number;
  winner_updated_at: number;
  resolution: string;
  created_at: number;
  resolved_at: number;
}

/** 两条造态：① 本地被远端覆盖 ② 远端被本地丢弃（覆盖「查看 + 恢复」两条主路径） */
function createMockConflicts(): MockConflict[] {
  const now = Date.now();
  return [
    {
      id: 2,
      table_name: "todo_tasks",
      record_uuid: "conflict-task-2",
      record_title: "写周报",
      decision: "lww",
      loser_side: "local",
      winner_side: "remote",
      loser_payload: JSON.stringify({ title: "写周报", priority: 1, status: "pending" }),
      winner_payload: JSON.stringify({ title: "写周报（本周）", priority: 3, status: "doing" }),
      loser_updated_at: now - 5_400_000,
      winner_updated_at: now - 3_600_000,
      resolution: "unresolved",
      created_at: now - 3_500_000,
      resolved_at: 0,
    },
    {
      id: 1,
      table_name: "todo_projects",
      record_uuid: "conflict-project-1",
      record_title: "季度目标",
      decision: "tie_version",
      loser_side: "remote",
      winner_side: "local",
      loser_payload: JSON.stringify({ title: "季度目标", hex_color: "#EF4444" }),
      winner_payload: JSON.stringify({ title: "季度目标", hex_color: "#3B82F6" }),
      loser_updated_at: now - 90_000_000,
      winner_updated_at: now - 90_000_000,
      resolution: "unresolved",
      created_at: now - 89_000_000,
      resolved_at: 0,
    },
  ];
}

const mockConflicts = createMockConflicts();

// ---------- 命令实现 ----------

const notImplemented = (cmd: string) => {
  throw new Error(`[browser-ipc-mock] 命令未实现: ${cmd}`);
};

type Ctx = { db: MockDb };

/** IPC 值语义克隆：读命令出参与 db 内部活引用彻底隔离（见 filterByKeyword 注释） */
const ipcClone = <T>(v: T): T => JSON.parse(JSON.stringify(v));

/** 活动日志埋点（F6；与 Rust activity_log_api::log_activity 同口径） */
function logActivity(
  db: MockDb,
  taskId: number,
  taskTitle: string,
  action: string,
  detail: string,
) {
  db.activityLog.push({
    id: db.seq++,
    task_id: taskId,
    task_title: taskTitle,
    action,
    detail,
    created_at: Date.now(),
  });
}

/** 从属对象轨迹（子任务/评论/关联/提醒）——与 Rust log_target_activity
 *  同口径：detail 统一 {"target": 可读名}；任务行查不到则跳过 */
function logTarget(db: MockDb, taskId: number, action: string, target: string) {
  const task = db.tasks.find((x) => x.id === taskId);
  if (task) logActivity(db, task.id, task.title, action, JSON.stringify({ target }));
}

/** 长文本快照截断（与 Rust snapshot_text 同口径：60 字外折叠为 …） */
const truncText = (s: string) => (s.length > 60 ? `${s.slice(0, 60)}…` : s);

const pad2 = (n: number) => String(n).padStart(2, "0");
const localDay = (ms: unknown): string | null => {
  if (ms == null) return null;
  const d = new Date(ms as number);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
};
const localDt = (ms: unknown): string | null => {
  if (ms == null) return null;
  const d = new Date(ms as number);
  return `${localDay(ms)} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
};

/** 变更字段快照（与 Rust changed_task_values 同口径：声明序 + 可读值——
 *  截止/完成→本地时刻串、纯日期→本地日串、项目 id→名称、长文本 60 字截断；
 *  枚举/数值留原值） */
function changedTaskValues(
  db: MockDb,
  before: Record<string, unknown>,
  after: Record<string, unknown>,
): { field: string; from: unknown; to: unknown }[] {
  const trunc = (v: unknown) => {
    const s = String(v);
    return s.length > 60 ? `${s.slice(0, 60)}…` : s;
  };
  const proj = (v: unknown) =>
    v == null ? null : db.projects.find((p) => p.id === v)?.title ?? null;
  const raw = (v: unknown) => v;
  const specs: [string, (v: unknown) => unknown][] = [
    ["title", trunc],
    ["description", (v) => (v == null ? null : trunc(v))],
    ["project_id", proj],
    ["priority", raw],
    ["status", raw],
    ["done", raw],
    ["done_at", localDt],
    ["due_date", localDt],
    ["start_date", localDay],
    ["repeat_rule", raw],
    ["percent_done", raw],
    ["position", raw],
    ["is_favorite", raw],
    ["my_day_date", localDay],
  ];
  // 重复规则六字段合并为一条 repeat_rule 伪字段（与 Rust changed_task_values
  // 同口径）：值为整体快照对象，任一子字段变化即记一条
  const repeatSnap = (r: Record<string, unknown>) => ({
    mode: (r.repeat_mode as number) ?? 0,
    after: (r.repeat_after as number) ?? 0,
    weekdays: (r.repeat_weekdays as number) ?? 0,
    end_type: (r.repeat_end_type as number) ?? 0,
    end_param: (r.repeat_end_param as number) ?? 0,
    from_done: (r.repeat_from_done as number) ?? 0,
  });
  const out: { field: string; from: unknown; to: unknown }[] = [];
  for (const [f, fmt] of specs) {
    if (f === "repeat_rule") {
      const from = repeatSnap(before);
      const to = repeatSnap(after);
      if (JSON.stringify(from) !== JSON.stringify(to)) out.push({ field: f, from, to });
      continue;
    }
    if (before[f] !== after[f]) out.push({ field: f, from: fmt(before[f]), to: fmt(after[f]) });
  }
  return out;
}

/** keyword 过滤（title/description 大小写不敏感包含，对齐后端列表语义）。
 *  返回值必须与 db 内部完全【引用隔离】——真实 Tauri IPC 每次 JSON 序列化
 *  生成全新对象图；react-query 的 structuralSharing（replaceEqualDeep）在
 *  新旧数据【深度相等】时保留旧引用以驱动 useMemo deps 更新。mock 若回传
 *  db 的活引用（数组或元素对象），db 原地变更后深比较恒等，data 引用不变，
 *  UI 将永不刷新（#19 排查实录：数组浅拷贝不够，元素也须隔离）。 */
function filterByKeyword<T extends { title: string; description: string | null }>(
  rows: T[],
  keyword?: string | null,
): T[] {
  const clone = (r: T): T => JSON.parse(JSON.stringify(r));
  const kw = keyword?.trim().toLowerCase();
  if (!kw) return rows.map(clone);
  return rows
    .filter(
      (r) =>
        r.title.toLowerCase().includes(kw) ||
        (r.description ?? "").toLowerCase().includes(kw),
    )
    .map(clone);
}

/** 冒烟主链路所需的命令集（未列出的命令走 notImplemented） */
/** 模板 payload 白名单校验（与 Rust ALLOWED_PAYLOAD_KEYS 同口径） */
const TEMPLATE_PAYLOAD_KEYS = ["title", "notes", "priority", "due_offset_days", "subtasks"];
function validateTemplatePayload(payload: string): void {
  let parsed: unknown;
  try {
    parsed = JSON.parse(payload);
  } catch {
    throw new Error("模板内容不是合法 JSON");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("模板内容必须是 JSON 对象");
  }
  for (const key of Object.keys(parsed)) {
    if (!TEMPLATE_PAYLOAD_KEYS.includes(key)) {
      throw new Error(`模板内容含未知键 ${key}`);
    }
  }
  const subtasks = (parsed as Record<string, unknown>).subtasks;
  if (
    subtasks != null &&
    (!Array.isArray(subtasks) || subtasks.some((x) => typeof x !== "string"))
  ) {
    throw new Error("subtasks 必须是字符串数组");
  }
}

const commands: Record<string, (args: any, ctx: Ctx) => unknown> = {
  // ---- 启动链（App.tsx：master_auth_has=false → db_init_plaintext）----
  master_auth_has: () => false,
  db_init_plaintext: () => undefined,
  db_set_device_id: () => undefined,
  // 冷启动首屏标记（真桥 ORBIT_PERF_MARKER 未设置时 no-op，mock 恒成功）
  perf_first_screen_mark: () => undefined,

  // ---- projects ----
  // 对齐 Rust list_todo_projects：默认排除已归档（is_archived=1）
  todo_projects_list: (_a, { db }) => ipcClone(db.projects.filter((p) => !p.is_archived)),
  // 归档项目列表（is_archived=1，最近归档在前——对齐 Rust updated_at DESC）
  todo_projects_list_archived: (_a, { db }) =>
    ipcClone(
      db.projects
        .filter((p) => p.is_archived && !p.is_deleted)
        .sort((a, b) => b.updated_at - a.updated_at),
    ),
  todo_projects_get: ({ id }, { db }) => ipcClone(db.projects.find((p) => p.id === id) ?? null),
  todo_projects_create: ({ input }, { db }) => {
    const now = Date.now();
    const p: MockProject = {
      id: db.seq++,
      uuid: uuid(),
      title: input.title,
      description: input.description ?? null,
      hex_color: input.hex_color ?? "#3B82F6",
      sort_order: input.sort_order ?? 0,
      is_archived: 0,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      deleted_at: null,
      version: 1,
    };
    db.projects.push(p);
    return ipcClone(p);
  },
  todo_projects_update: ({ id, input }, { db }) => {
    const p = db.projects.find((x) => x.id === id);
    if (!p) throw new Error(`project ${id} 不存在`);
    Object.assign(p, input, { updated_at: Date.now(), version: p.version + 1 });
    return ipcClone(p);
  },
  todo_projects_delete: ({ id }, { db }) => {
    const idx = db.projects.findIndex((p) => p.id === id);
    if (idx >= 0) db.projects.splice(idx, 1);
  },

  // ---- tasks ----
  // 对齐 Rust generic_repo::list 的 WHERE is_deleted = 0（删除走软删，墓碑进回收站）。
  // 谓词下推（F5）：六键与 Rust build_task_predicate_clause 同口径（仅本命令消费）
  todo_tasks_list: ({ filter }, { db }) => {
    let rows = db.tasks.filter((t) => !t.is_deleted);
    // 列裁剪（批2 + A2 对齐 Rust）：keyword 空时 description 与 uuid 都不传输
    // （NULL / 空串占位保形状）；keyword 非空保留全列（SQL LIKE 依赖）
    const pruneListColumns = !filter?.keyword?.trim();
    // 归档项目任务排除（聚合视图；project_id 谓词=用户主动选中该归档项目时放行）
    if (filter?.project_id == null) {
      const archivedIds = new Set(db.projects.filter((p) => p.is_archived && !p.is_deleted).map((p) => p.id));
      rows = rows.filter((t) => t.project_id == null || !archivedIds.has(t.project_id));
    }
    if (filter?.done === true) rows = rows.filter((t) => t.done === 1);
    if (filter?.done === false) rows = rows.filter((t) => t.done !== 1);
    if (filter?.status != null) rows = rows.filter((t) => t.status === filter.status);
    if (filter?.priority_min != null) rows = rows.filter((t) => t.priority >= filter.priority_min);
    if (filter?.project_id != null) rows = rows.filter((t) => t.project_id === filter.project_id);
    if (filter?.favorite_only === true) rows = rows.filter((t) => t.is_favorite === 1);
    if (filter?.my_day_today != null) rows = rows.filter((t) => t.my_day_date === filter.my_day_today);
    // 排序（对齐 Rust generic_repo ORDER BY updated_at DESC）：插入序≠更新序，
    // 贴近上限截断时它决定哪些行可见；mock 此前返回插入序，不可复现截断行为
    rows = [...rows].sort((a, b) => b.updated_at - a.updated_at);
    const keyworded = filterByKeyword(rows, filter?.keyword);
    // 分页（对齐 Rust LIMIT/OFFSET；调用方恒传 page:1/page_size:10000，
    // 现有链路恰一整页，行为不变；第五轮 A5/A6 真分页后门禁才有意义）
    const paged = paginateRows(keyworded, filter?.page, filter?.page_size);
    return pruneListColumns
      ? paged.map((t) => ({ ...t, description: null, uuid: "" }))
      : paged;
  },
  todo_tasks_get: ({ id }, { db }) => ipcClone(db.tasks.find((t) => t.id === id) ?? null),
  todo_tasks_get_by_uuid: ({ uuid: u }, { db }) => ipcClone(db.tasks.find((t) => t.uuid === u) ?? null),
  todo_tasks_create: ({ input }, { db }) => {
    const now = Date.now();
    const t: MockTask = {
      id: db.seq++,
      uuid: uuid(),
      title: input.title,
      description: input.description ?? null,
      project_id: input.project_id ?? null,
      priority: input.priority ?? 0,
      status: input.status ?? "pending",
      done: input.done ?? 0,
      done_at: input.done_at ?? null,
      due_date: input.due_date ?? null,
      start_date: input.start_date ?? null,
      repeat_after: input.repeat_after ?? 0,
      repeat_mode: input.repeat_mode ?? 0,
      percent_done: 0,
      position: input.position ?? 100000,
      is_favorite: input.is_favorite ?? 0,
      my_day_date: input.my_day_date ?? null,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      deleted_at: null,
      version: 1,
    };
    db.tasks.push(t);
    // 活动日志埋点（F6，与 Rust 写路径同口径）
    logActivity(db, t.id, t.title, "create", "{}");
    return ipcClone(t);
  },
  todo_tasks_update: ({ id, input }, { db }) => {
    const t = db.tasks.find((x) => x.id === id);
    if (!t) throw new Error(`task ${id} 不存在`);
    const before = { ...t } as Record<string, unknown>;
    Object.assign(t, input, { updated_at: Date.now(), version: t.version + 1 });
    // 活动日志埋点（F6）：变更字段集 + 前后值快照（与 changed_task_values 同口径）
    const after = t as unknown as Record<string, unknown>;
    const changes = changedTaskValues(db, before, after);
    if (changes.length > 0) {
      const fields = changes.map((c) => c.field);
      logActivity(db, t.id, t.title, "update", JSON.stringify({ fields, changes }));
    }
    return ipcClone(t);
  },
  todo_tasks_update_position: ({ id, position }, { db }) => {
    const t = db.tasks.find((x) => x.id === id);
    if (!t) throw new Error(`task ${id} 不存在`);
    t.position = position;
  },
  // 对齐 Rust complete_todo_task：普通任务标记完成；重复任务（repeat_mode>0
  // 且有 due_date）先克隆下一实例（due 平移一步、子任务复制标题、不复制提醒）
  // 再标记本实例——与核心单事务语义同构（mock 无事务，但步骤顺序一致）
  todo_tasks_complete: ({ id }, { db }) => {
    const t = db.tasks.find((x) => x.id === id);
    if (!t) throw new Error(`task ${id} 不存在`);
    if (t.is_deleted) throw new Error(`task ${id} 已在回收站`);
    const now = Date.now();
    let next: MockTask | null = null;
    if (!t.done && t.repeat_mode > 0 && t.due_date != null) {
      // 快进到 now 之后最近的序列点（与 next_repeat_at 同口径：逐步推进）
      const stepMs =
        t.repeat_mode === 1 ? 86_400_000 * t.repeat_after
        : t.repeat_mode === 2 ? 7 * 86_400_000 * t.repeat_after
        : null; // 月/年在 e2e mock 走近似：按 30/365 天（冒烟用例不覆盖月年语义）
      if (stepMs) {
        let due = t.due_date;
        let guard = 0;
        while (due <= now && guard++ < 5000) due += stepMs;
        next = {
          id: db.seq++,
          uuid: uuid(),
          title: t.title,
          description: t.description,
          project_id: t.project_id,
          priority: t.priority,
          status: "pending",
          done: 0,
          done_at: null,
          due_date: due,
          start_date: t.start_date != null ? t.start_date + (due - t.due_date) : null,
          repeat_after: t.repeat_after,
          repeat_mode: t.repeat_mode,
          percent_done: 0,
          position: 100000,
          is_favorite: t.is_favorite,
          my_day_date: null,
          is_deleted: 0,
          created_at: now,
          updated_at: now,
          deleted_at: null,
          version: 1,
        };
        db.tasks.push(next);
        for (const s of db.subtasks.filter((s) => s.task_id === id && !s.is_deleted)) {
          db.subtasks.push({
            id: db.seq++,
            uuid: uuid(),
            task_id: next.id,
            title: s.title,
            done: 0,
            done_at: null,
            position: s.position,
            is_deleted: 0,
            created_at: now,
            updated_at: now,
            deleted_at: null,
            version: 1,
          });
        }
      }
    }
    t.done = 1;
    t.done_at = now;
    t.status = "done";
    t.updated_at = now;
    t.version += 1;
    // 活动日志埋点（F6，与 Rust complete 埋点同口径）
    logActivity(db, t.id, t.title, "complete", "{}");
    // 重复滚周期双埋点（与 Rust 同口径）：原实例记「已滚动下一周期」
    // （target=新实例截止串），新实例记 create(from=repeat)
    if (next) {
      logTarget(db, t.id, "repeat_rollover", localDt(next.due_date) ?? "下一周期");
      logActivity(
        db,
        next.id,
        next.title,
        "create",
        JSON.stringify({ from: "repeat", parent_id: t.id }),
      );
    }
    return ipcClone({ task: t, next_instance: next });
  },
  todo_tasks_delete: ({ id }, { db }) => {
    // 对齐 Rust 软删语义：墓碑行留在库中（回收站可见），挂载关系不动
    const t = db.tasks.find((x) => x.id === id);
    if (!t) return;
    const now = Date.now();
    t.is_deleted = 1;
    t.deleted_at = now;
    t.updated_at = now;
    t.version += 1;
    logActivity(db, t.id, t.title, "delete", "{}");
  },
  todo_tasks_get_detail: ({ id }, { db }) => {
    const t = db.tasks.find((x) => x.id === id);
    if (!t) throw new Error(`task ${id} not found`);
    const labels = db.taskLabels
      .filter((l) => l.task_id === id)
      .map((l) => {
        const label = db.labels.find((x) => x.id === l.label_id);
        return label ? { ...label, task_label_id: l.id } : null;
      })
      .filter(Boolean);
    return ipcClone({
      ...t,
      subtasks: [...db.subtasks.filter((s) => s.task_id === id && !s.is_deleted)],
      labels,
      comments: [...db.comments.filter((c) => c.task_id === id)],
      relations: [...db.relations.filter((r) => r.task_id === id)],
      reminders: [...db.reminders.filter((r) => r.task_id === id)],
    });
  },

  // ---- subtasks（详情抽屉八区块之一；删除确认 Popover e2e 用）----
  todo_subtasks_list: (_a, { db }) =>
    ipcClone(db.subtasks.filter((s) => !s.is_deleted)),
  todo_subtasks_create: (
    { input }: { input: { task_id: number; title: string } },
    { db },
  ) => {
    if (db.tasks.every((t) => t.id !== input.task_id)) {
      throw new Error(`task ${input.task_id} not found`);
    }
    const now = Date.now();
    const row: MockSubtask = {
      id: db.seq++,
      uuid: uuid(),
      task_id: input.task_id,
      title: input.title,
      done: 0,
      done_at: null,
      position: db.subtasks.filter((s) => s.task_id === input.task_id).length,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      deleted_at: null,
      version: 1,
    };
    db.subtasks.push(row);
    logTarget(db, row.task_id, "subtask_add", row.title);
    return ipcClone(row);
  },
  todo_subtasks_update: (
    { id, input }: { id: number; input: { title?: string } },
    { db },
  ) => {
    const s = db.subtasks.find((x) => x.id === id);
    if (!s) throw new Error(`subtask ${id} 不存在`);
    const before = s.title;
    if (input.title != null) s.title = input.title;
    s.updated_at = Date.now();
    s.version += 1;
    // 改名轨迹（与 Rust update_todo_subtask 同口径）：target=「旧 → 新」对照串
    if (before !== s.title) {
      logTarget(db, s.task_id, "subtask_rename", `${before} → ${s.title}`);
    }
    return ipcClone(s);
  },
  // 对齐 Rust toggle_todo_subtask_done：翻完成后按完成度回算父任务 percent_done
  // （参数名随 tauri.ts 调用方：subtaskId）
  todo_subtasks_toggle_done: ({ subtaskId, done }, { db }) => {
    const s = db.subtasks.find((x) => x.id === subtaskId);
    if (!s) throw new Error(`subtask ${subtaskId} 不存在`);
    const now = Date.now();
    s.done = done ? 1 : 0;
    s.done_at = done ? now : null;
    s.updated_at = now;
    s.version += 1;
    const live = db.subtasks.filter((x) => x.task_id === s.task_id && !x.is_deleted);
    const doneCount = live.filter((x) => x.done === 1).length;
    const task = db.tasks.find((t) => t.id === s.task_id);
    if (task) {
      task.percent_done = live.length === 0 ? 0 : (doneCount / live.length) * 100;
      task.updated_at = now;
    }
    logTarget(db, s.task_id, done ? "subtask_done" : "subtask_undone", s.title);
  },
  todo_subtasks_delete: ({ id }, { db }) => {
    const s = db.subtasks.find((x) => x.id === id);
    if (!s) return;
    const now = Date.now();
    s.is_deleted = 1;
    s.deleted_at = now;
    s.updated_at = now;
    s.version += 1;
    const live = db.subtasks.filter((x) => x.task_id === s.task_id && !x.is_deleted);
    const doneCount = live.filter((x) => x.done === 1).length;
    const task = db.tasks.find((t) => t.id === s.task_id);
    if (task) {
      task.percent_done = live.length === 0 ? 0 : (doneCount / live.length) * 100;
      task.updated_at = now;
    }
    logTarget(db, s.task_id, "subtask_delete", s.title);
  },
  // 子任务转独立任务（对齐 Rust promote_todo_subtask：软删行 + 承接父任务
  // project/priority/due 建尾位新任务；percent_done 随软删重算）
  todo_subtasks_promote: ({ subtaskId }, { db }) => {
    const s = db.subtasks.find((x) => x.id === subtaskId);
    if (!s) throw new Error(`subtask ${subtaskId} 不存在`);
    const parent = db.tasks.find((t) => t.id === s.task_id);
    if (!parent) throw new Error(`task ${s.task_id} 不存在`);
    const now = Date.now();
    s.is_deleted = 1;
    s.deleted_at = now;
    s.updated_at = now;
    s.version += 1;
    const live = db.subtasks.filter((x) => x.task_id === s.task_id && !x.is_deleted);
    const doneCount = live.filter((x) => x.done === 1).length;
    parent.percent_done = live.length === 0 ? 0 : (doneCount / live.length) * 100;
    parent.updated_at = now;
    const sibling = db.tasks.filter(
      (t) => !t.is_deleted && (t.project_id ?? null) === (parent.project_id ?? null),
    );
    const maxPos = sibling.reduce((m, t) => Math.max(m, t.position), -1);
    const t: MockTask = {
      id: db.seq++,
      uuid: uuid(),
      title: s.title,
      description: null,
      project_id: parent.project_id,
      priority: parent.priority,
      status: s.done === 1 ? "done" : "pending",
      done: s.done,
      done_at: s.done_at,
      due_date: parent.due_date,
      start_date: parent.start_date,
      repeat_after: 0,
      repeat_mode: 0,
      percent_done: 0,
      position: maxPos + 1,
      is_favorite: 0,
      my_day_date: null,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      deleted_at: null,
      version: 1,
    };
    db.tasks.push(t);
    // 与 Rust 同口径双埋点：新任务侧 create（from=subtask）+ 父任务侧 promote
    logActivity(db, t.id, t.title, "create", JSON.stringify({ from: "subtask", parent_id: parent.id }));
    logTarget(db, parent.id, "subtask_promote", s.title);
    return ipcClone(t);
  },

  // ---- task_relations（#28：详情抽屉关联区完整命令面）----
  todo_task_relations_list: (_a, { db }) =>
    ipcClone(db.relations.filter((r) => !r.is_deleted)),
  todo_task_relations_create: (
    { input }: { input: { task_id: number; other_task_id: number; relation_type: string } },
    { db },
  ) => {
    if (db.tasks.every((t) => t.id !== input.other_task_id)) {
      throw new Error(`task ${input.other_task_id} not found`);
    }
    const now = Date.now();
    const r = {
      id: db.seq++,
      uuid: uuid(),
      task_id: input.task_id,
      other_task_id: input.other_task_id,
      relation_type: input.relation_type,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      deleted_at: null,
      version: 1,
    };
    db.relations.push(r);
    // 关联双向各记一条（与 Rust log_relation_change 同口径）
    const ta = db.tasks.find((t) => t.id === r.task_id);
    const tb = db.tasks.find((t) => t.id === r.other_task_id);
    if (ta && tb) {
      logTarget(db, ta.id, "link_add", tb.title);
      logTarget(db, tb.id, "link_add", ta.title);
    }
    return ipcClone(r);
  },
  todo_task_relations_delete: ({ id }, { db }) => {
    const idx = db.relations.findIndex((r) => r.id === id);
    if (idx < 0) throw new Error(`relation ${id} not found`);
    const r = db.relations[idx];
    db.relations.splice(idx, 1);
    const ta = db.tasks.find((t) => t.id === r.task_id);
    const tb = db.tasks.find((t) => t.id === r.other_task_id);
    if (ta && tb) {
      logTarget(db, ta.id, "link_remove", tb.title);
      logTarget(db, tb.id, "link_remove", ta.title);
    }
  },
  // 任务→关联计数旗标（A4：与 Rust task_dependency_flags 同口径——仅出边存活行
  // GROUP BY task_id；C7 列表行「有关联」徽标消费）
  task_dependency_flags: (_a, { db }) => {
    const counts = new Map<number, number>();
    for (const r of db.relations.filter((x) => !x.is_deleted)) {
      counts.set(r.task_id, (counts.get(r.task_id) ?? 0) + 1);
    }
    return ipcClone(
      [...counts]
        .sort((a, b) => a[0] - b[0])
        .map(([task_id, relation_count]) => ({ task_id, relation_count })),
    );
  },

  // ---- labels / task_labels ----
  todo_labels_list: (_a, { db }) => ipcClone(db.labels),
  todo_labels_get: ({ id }, { db }) => ipcClone(db.labels.find((l) => l.id === id) ?? null),
  todo_labels_create: ({ input }, { db }) => {
    const now = Date.now();
    const l: MockLabel = {
      id: db.seq++,
      uuid: uuid(),
      title: input.title,
      hex_color: input.hex_color ?? "#3B82F6",
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      deleted_at: null,
      version: 1,
    };
    db.labels.push(l);
    return ipcClone(l);
  },
  todo_labels_update: ({ id, input }, { db }) => {
    const l = db.labels.find((x) => x.id === id);
    if (!l) throw new Error(`label ${id} 不存在`);
    Object.assign(l, input, { updated_at: Date.now(), version: l.version + 1 });
    return ipcClone(l);
  },
  todo_labels_delete: ({ id }, { db }) => {
    const idx = db.labels.findIndex((l) => l.id === id);
    if (idx >= 0) db.labels.splice(idx, 1);
    db.taskLabels = db.taskLabels.filter((l) => l.label_id !== id);
  },
  todo_task_labels_list: (_a, { db }) => ipcClone(db.taskLabels),
  todo_task_labels_create: ({ input }, { db }) => {
    const now = Date.now();
    const link: MockTaskLabel = {
      id: db.seq++,
      task_id: input.task_id,
      label_id: input.label_id,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      version: 1,
    };
    db.taskLabels.push(link);
    // 标签挂载轨迹（与 Rust log_label_change 同口径）
    const task = db.tasks.find((x) => x.id === input.task_id);
    const label = db.labels.find((x) => x.id === input.label_id);
    if (task && label) {
      logActivity(db, task.id, task.title, "label_add", JSON.stringify({ label: label.title }));
    }
    return link;
  },
  todo_task_labels_delete: ({ id }, { db }) => {
    const link = db.taskLabels.find((l) => l.id === id);
    db.taskLabels = db.taskLabels.filter((l) => l.id !== id);
    // 标签摘除轨迹（同上；行已不在，用删除前快照）
    const task = link && db.tasks.find((x) => x.id === link.task_id);
    const label = link && db.labels.find((x) => x.id === link.label_id);
    if (task && label) {
      logActivity(db, task.id, task.title, "label_remove", JSON.stringify({ label: label.title }));
    }
  },
  // 任务→标签投影（A4：与 Rust task_labels_projection 同口径——存活关联⋈存活标签，
  // 瘦列 {id,title,hex_color}，按 task_id 分组、组内按 label id 升序）
  task_labels_projection: (_a, { db }) => {
    const labelById = new Map(db.labels.filter((l) => !l.is_deleted).map((l) => [l.id, l]));
    const groups = new Map<number, Array<{ id: number; title: string; hex_color: string }>>();
    const links = [...db.taskLabels]
      .filter((r) => !r.is_deleted)
      .sort((a, b) => a.task_id - b.task_id || a.label_id - b.label_id);
    for (const r of links) {
      const l = labelById.get(r.label_id);
      if (!l) continue;
      const list = groups.get(r.task_id) ?? [];
      list.push({ id: l.id, title: l.title, hex_color: l.hex_color });
      groups.set(r.task_id, list);
    }
    return ipcClone([...groups].map(([task_id, labels]) => ({ task_id, labels })));
  },

  // ---- reminders / comments ----
  todo_reminders_list: (_a, { db }) => ipcClone(db.reminders),
  todo_reminders_get: ({ id }, { db }) => ipcClone(db.reminders.find((r) => r.id === id) ?? null),
  todo_reminders_create: ({ input }, { db }) => {
    const now = Date.now();
    const r: MockReminder = {
      id: db.seq++,
      task_id: input.task_id,
      remind_at: input.remind_at,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      version: 1,
    };
    db.reminders.push(r);
    // 提醒轨迹：target=格式化时刻串（与 Rust reminder_add 同口径）
    logTarget(db, r.task_id, "reminder_add", localDt(r.remind_at) ?? "已设置");
    return ipcClone(r);
  },
  todo_reminders_delete: ({ id }, { db }) => {
    const r = db.reminders.find((x) => x.id === id);
    db.reminders = db.reminders.filter((x) => x.id !== id);
    if (r) logTarget(db, r.task_id, "reminder_delete", localDt(r.remind_at) ?? "已设置");
  },
  // 任务→提醒投影（A4：与 Rust task_reminders_projection 同口径——存活行瘦列
  // {id,remind_at}，按 task_id 分组、组内按 remind_at 升序）
  task_reminders_projection: (_a, { db }) => {
    const groups = new Map<number, Array<{ id: number; remind_at: number }>>();
    const rows = [...db.reminders]
      .filter((r) => !r.is_deleted)
      .sort((a, b) => a.task_id - b.task_id || a.remind_at - b.remind_at);
    for (const r of rows) {
      const list = groups.get(r.task_id) ?? [];
      list.push({ id: r.id, remind_at: r.remind_at });
      groups.set(r.task_id, list);
    }
    return ipcClone([...groups].map(([task_id, reminders]) => ({ task_id, reminders })));
  },
  todo_comments_list: ({ filter }, { db }) => {
    const kw = filter?.keyword?.trim().toLowerCase();
    return ipcClone(
      kw ? db.comments.filter((c) => c.content.toLowerCase().includes(kw)) : db.comments,
    );
  },
  todo_comments_create: ({ input }, { db }) => {
    const now = Date.now();
    const c: MockComment = {
      id: db.seq++,
      task_id: input.task_id,
      content: input.content,
      created_at: now,
      updated_at: now,
      is_deleted: 0,
    };
    db.comments.push(c);
    logTarget(db, c.task_id, "comment_add", truncText(c.content));
    return c;
  },
  todo_comments_delete: ({ id }, { db }) => {
    const c = db.comments.find((x) => x.id === id);
    db.comments = db.comments.filter((x) => x.id !== id);
    if (c) logTarget(db, c.task_id, "comment_delete", truncText(c.content));
  },

  // ---- 全局搜索 / 看板（list-page 查询、命令面板 Ctrl+P 用）----
  global_search: ({ keyword }, { db }) => {
    const kw = (keyword ?? "").toLowerCase();
    return {
      tasks: kw ? db.tasks.filter((t) => t.title.toLowerCase().includes(kw)) : [],
      projects: kw ? db.projects.filter((p) => p.title.toLowerCase().includes(kw)) : [],
    };
  },
  // ---- Mica（use-mica-effect 挂载即调；浏览器返回不支持）----
  mica_diagnostics: () => ({
    platform: "browser",
    micaSupported: false,
    applyResult: "skipped-browser",
  }),
  apply_mica: () => undefined,
  disable_mica: () => undefined,

  // ---- 同步链（use-startup-sync / SyncStatusButton；「未配置」走静默路径）----
  sync_config_get: () => (syncState.configured ? ipcClone(mockSyncConfig()) : null),
  // 立即同步：真实返回 SyncResult JSON 字符串（lib/tauri.ts 侧 parseResult）
  cloud_sync_now: () =>
    JSON.stringify({
      pushed_modules: 1,
      pulled_modules: 0,
      uploaded_attachments: 0,
      downloaded_attachments: 0,
      duration_ms: 320,
      skipped: false,
      errors: [],
      // F42：真正写入的表集合（纯推送轮为空）
      changed_tables: [],
    }),
  // 强制同步 / 先拉后推 / 仅推送：mock 统一返回同一结果（e2e 走 mock IPC）
  cloud_sync_force: () =>
    JSON.stringify({
      pushed_modules: 1,
      pulled_modules: 1,
      uploaded_attachments: 0,
      downloaded_attachments: 0,
      duration_ms: 280,
      skipped: false,
      errors: [],
      changed_tables: ["todo_tasks"],
    }),
  cloud_sync_pull_then_push: () =>
    JSON.stringify({
      pushed_modules: 1,
      pulled_modules: 1,
      uploaded_attachments: 0,
      downloaded_attachments: 0,
      duration_ms: 280,
      skipped: false,
      errors: [],
      changed_tables: ["todo_tasks"],
    }),
  cloud_sync_push_only: () =>
    JSON.stringify({
      pushed_modules: 1,
      pulled_modules: 0,
      uploaded_attachments: 0,
      downloaded_attachments: 0,
      duration_ms: 200,
      skipped: false,
      errors: [],
      changed_tables: [],
    }),
  cloud_sync_is_running: () => false,
  // 同步账本（core SyncState 镜像）：种一份「已同步过一轮」的账本，
  // 设置页账本卡可渲染水位线与桶指纹（此前误返回 {phase:"idle"}，与结构不符）
  cloud_sync_get_state: () => {
    const now = Date.now();
    return JSON.stringify({
      last_synced_at: now - 600_000,
      last_synced_clock_ms: now - 600_100,
      last_pushed_clock_ms: now - 600_200,
      device_id: "mock-device-0001",
      manifest_epoch: 7,
      remote_tables: {
        todos: { "0": "a1b2c3d4e5f60718", "1": "9f8e7d6c5b4a3021" },
        projects: { "0": "0011223344556677" },
      },
      remote_tombstones: { todos: { "2026-08": "778899aabbccddee" } },
    });
  },
  // 增量同步历史（P1-17）：种三条同构（成功/失败/推送），设置页历史卡可渲染
  cloud_sync_history: ({ scope, limit }: { scope: string; limit: number }) => {
    const now = Date.now();
    const seed = [
      { id: 3, sync_type: "push_only", status: "success", started_at: now - 3_600_000, finished_at: now - 3_600_000 + 2_400, pulled_count: 0, pushed_count: 2, conflict_count: 0, error_message: null },
      { id: 2, sync_type: "incremental", status: "failed", started_at: now - 7_200_000, finished_at: now - 7_200_000 + 9_800, pulled_count: 0, pushed_count: 0, conflict_count: 0, error_message: "todos 模块上传失败：连接超时" },
      { id: 1, sync_type: "incremental", status: "success", started_at: now - 86_400_000, finished_at: now - 86_400_000 + 5_100, pulled_count: 3, pushed_count: 1, conflict_count: 2, error_message: null },
    ];
    return ipcClone(
      seed.filter((h) => scope === "all" || h.sync_type === scope).slice(0, limit),
    );
  },
  // 冲突败方副本（03 §八）：内存表造两条，restore/dismiss/clear 直改内存
  sync_conflict_list: (
    { resolution, limit, offset }: { resolution: string | null; limit: number; offset: number },
  ) =>
    ipcClone(
      mockConflicts
        .filter((c) => !resolution || c.resolution === resolution)
        .sort((a, b) => b.created_at - a.created_at)
        .slice(offset ?? 0, (offset ?? 0) + (limit ?? 100)),
    ),
  sync_conflict_count: ({ resolution }: { resolution: string | null }) =>
    mockConflicts.filter((c) => !resolution || c.resolution === resolution).length,
  // 恢复：真实实现会把败方内容写回业务表；mock 只标记 resolved（业务行改写不在
  // 浏览器 mock 的目标范围），并借 isWriteCommand 的 restore 后缀触发 db-change
  sync_conflict_restore: ({ id }: { id: number }) => {
    const c = mockConflicts.find((x) => x.id === id);
    if (!c) throw new Error(`sync_conflict ${id} 不存在`);
    c.resolution = "restored";
    c.resolved_at = Date.now();
    return id;
  },
  sync_conflict_dismiss: ({ id }: { id: number }) => {
    const c = mockConflicts.find((x) => x.id === id);
    if (!c) throw new Error(`sync_conflict ${id} 不存在`);
    c.resolution = "dismissed";
    c.resolved_at = Date.now();
    return undefined;
  },
  sync_conflict_clear: ({ resolution }: { resolution: string | null }) => {
    const keep = resolution ? mockConflicts.filter((c) => c.resolution !== resolution) : [];
    const removed = mockConflicts.length - keep.length;
    mockConflicts.length = 0;
    mockConflicts.push(...keep);
    return removed;
  },
  // 字段口径与真实命令一致（has_password / is_unlocked；此前 mock 回 { locked }
  // 与双端契约不符）；造态下随 syncState 变化
  sync_crypto_status: () => ({
    has_password: syncState.configured,
    is_unlocked: syncState.unlocked,
  }),
  // 恢复页挂载即探测密钥方案版本（v1 才显示迁移入口）；mock 回 v2 走主路径
  sync_crypto_meta_version: () => JSON.stringify({ version: "v2" }),

  // ---- 备份/导出（设置页打开才拉取；给空态安全值）----
  backup_prefs_get: () => null,
  full_backup_list_local: () => [],
  // 本机设备标识（导出区展示；mock 回固定同构体，未初始化场景不出现在冒烟链路）
  full_backup_device_info: () => ({ device_id: "mock-device" }),
  // 恢复预览（确认框打开才拉取；mock 回固定同构体，走 ready 分支）
  full_backup_peek_local: () => ipcClone(MOCK_BACKUP_PREVIEW),
  full_backup_peek_cloud: () => ipcClone(MOCK_BACKUP_PREVIEW),

  // ---- 节假日（日历视图挂载即拉取；空表回落 Rust 侧预置 2026 表，
  //      浏览器 mock 回给一小段同构数据让徽标链路可走通；更新命令模拟成功）----
  holidays_list: () => ipcClone(MOCK_HOLIDAYS),
  holiday_is_on: ({ date }: { date: string }) =>
    MOCK_HOLIDAYS.find((h) => h.date === date)?.is_holiday ?? null,
  holidays_update: () => ({ last_update_ms: Date.now(), last_attempt_ms: Date.now(), failure_count: 0, fixed_hour: 8 }),
  holiday_meta: () => ({ last_update_ms: Date.now(), last_attempt_ms: Date.now(), failure_count: 0, fixed_hour: 8 }),
  holiday_set_fixed_hour: () => undefined,

  // ---- 回收站（对齐 trash_cmd 软删/恢复/彻底删除语义；TTL 守卫在 mock 中不模拟）----
  trash_tasks_list: (_a, { db }) =>
    ipcClone(
      db.tasks
        .filter((t) => t.is_deleted && t.deleted_at != null)
        .sort((a, b) => (b.deleted_at ?? 0) - (a.deleted_at ?? 0)),
    ),
  trash_task_restore: ({ id }, { db }) => {
    const t = db.tasks.find((x) => x.id === id);
    if (!t || !t.is_deleted) throw new Error(`task ${id} 不在回收站`);
    const now = Date.now();
    t.is_deleted = 0;
    t.deleted_at = null;
    t.updated_at = now;
    t.version += 1;
    // 对齐 Rust：原项目已删则落未分组
    if (t.project_id != null && !db.projects.some((p) => p.id === t.project_id && !p.is_deleted)) {
      t.project_id = null;
    }
    return ipcClone(t);
  },
  trash_task_purge: ({ id }, { db }) => {
    const idx = db.tasks.findIndex((t) => t.id === id && t.is_deleted);
    if (idx < 0) throw new Error(`task ${id} 不在回收站`);
    db.tasks.splice(idx, 1);
    db.taskLabels = db.taskLabels.filter((l) => l.task_id !== id);
    db.reminders = db.reminders.filter((r) => r.task_id !== id);
    db.comments = db.comments.filter((c) => c.task_id !== id);
  },
  trash_purge_all: (_a, { db }) => {
    let n = 0;
    for (let i = db.tasks.length - 1; i >= 0; i--) {
      if (db.tasks[i].is_deleted) {
        const id = db.tasks[i].id;
        db.taskLabels = db.taskLabels.filter((l) => l.task_id !== id);
        db.reminders = db.reminders.filter((r) => r.task_id !== id);
        db.comments = db.comments.filter((c) => c.task_id !== id);
        db.tasks.splice(i, 1);
        n++;
      }
    }
    return n;
  },
  trash_purge_expired: () => ({ purged: 0, guarded: 0, ran: false }),
  trash_meta: () => ({ retention_days: 30, last_purge_ms: 0 }),
  trash_set_retention_days: () => undefined,

  // ---- 统计（backlog #25；对齐 stats_api 口径：done_at 本地日界，仅存活任务；
  //      浏览器 mock 用端侧 Date 分桶，语义与 Rust chrono Local 一致；
  //      2026-09-10 热力图改按年：当前年滚动 365 天、历史年完整年 + available_years）----
  stats_aggregate: (_a: { year?: number }, { db }) => {
    const year = _a.year ?? new Date().getFullYear();
    const live = db.tasks.filter((t) => !t.is_deleted);
    const doneTasks = live.filter((t) => t.done && t.done_at != null);
    const dayKey = (ts: number) => {
      const d = new Date(ts);
      return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    };
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    // 年份窗口：当前年 = 今天往前 364 天（滚动 365）；历史年 = 1/1 ~ 12/31
    const from = (() => {
      if (year === today.getFullYear()) {
        const f = new Date(today);
        f.setDate(f.getDate() - 364);
        return f;
      }
      return new Date(year, 0, 1);
    })();
    const to = year === today.getFullYear() ? today : new Date(year, 11, 31);
    const startMs = from.getTime();
    const endMs = to.getTime() + 86_400_000 - 1;
    const todayKey = dayKey(today.getTime());

    const byDay = new Map<string, number>();
    for (const t of doneTasks) {
      if (t.done_at! >= startMs && t.done_at! <= endMs) {
        const k = dayKey(t.done_at!);
        byDay.set(k, (byDay.get(k) ?? 0) + 1);
      }
    }
    const cells: { date: string; count: number }[] = [];
    for (let ms = startMs; ms <= endMs; ms += 86_400_000) {
      const k = dayKey(ms);
      cells.push({ date: k, count: byDay.get(k) ?? 0 });
    }

    // streak：today 有 → 从 today 前数；否则从昨天（昨天无 → 0）
    const idxOf = (k: string) => Math.floor(new Date(`${k}T00:00:00`).getTime() / 86_400_000);
    const doneIdx = new Set([...byDay.keys()].map(idxOf));
    const tIdx = idxOf(todayKey);
    const doneToday = doneIdx.has(tIdx);
    let anchor = doneToday ? tIdx : tIdx - 1;
    let current = 0;
    while (doneIdx.has(anchor)) {
      current++;
      anchor--;
    }
    let best = 0;
    let run = 0;
    let prev: number | null = null;
    for (const i of [...doneIdx].sort((a, b) => a - b)) {
      run = prev === i - 1 ? run + 1 : 1;
      best = Math.max(best, run);
      prev = i;
    }

    const inLast = (n: number) => {
      const cutoff = tIdx - (n - 1);
      return doneTasks.filter((t) => idxOf(dayKey(t.done_at!)) >= cutoff).length;
    };

    const byProjectMap = new Map<number | "none", { id: number | null; title: string | null; hex: string | null; done: number; pending: number }>();
    for (const t of live) {
      const key = t.project_id ?? "none";
      const row =
        byProjectMap.get(key) ??
        {
          id: t.project_id ?? null,
          title: t.project_id != null ? db.projects.find((p) => p.id === t.project_id)?.title ?? "未知项目" : null,
          hex: t.project_id != null ? db.projects.find((p) => p.id === t.project_id)?.hex_color ?? null : null,
          done: 0,
          pending: 0,
        };
      if (t.done) row.done++;
      else row.pending++;
      byProjectMap.set(key, row);
    }

    const byPriorityMap = new Map<number, { done: number; pending: number }>();
    for (const t of live) {
      const row = byPriorityMap.get(t.priority) ?? { done: 0, pending: 0 };
      if (t.done) row.done++;
      else row.pending++;
      byPriorityMap.set(t.priority, row);
    }

    const byWeekday = Array.from({ length: 7 }, () => 0);
    for (const t of doneTasks) {
      // 周一=0 基（对齐 Rust num_days_from_monday）
      byWeekday[(new Date(t.done_at!).getDay() + 6) % 7]++;
    }

    return {
      overview: {
        total: live.length,
        pending: live.filter((t) => !t.done).length,
        done: doneTasks.length,
        done_last_7d: inLast(7),
        done_last_30d: inLast(30),
      },
      heatmap: { year, start_date: cells[0].date, end_date: cells[cells.length - 1].date, cells },
      streak: { current, best, done_today: doneToday },
      by_project: [...byProjectMap.values()]
        .map((r) => ({ project_id: r.id, project_title: r.title, project_hex_color: r.hex, done_count: r.done, pending_count: r.pending }))
        .sort((a, b) => b.done_count - a.done_count),
      by_priority: [...byPriorityMap.entries()]
        .map(([priority, r]) => ({ priority, done_count: r.done, pending_count: r.pending }))
        .sort((a, b) => a.priority - b.priority),
      by_weekday: byWeekday.map((count, weekday) => ({ weekday, done_count: count })),
      // 可选年份：全部完成记录的年份（不看窗口）；无完成记录回退 [当前年]
      available_years: (() => {
        const ys = new Set<number>();
        for (const t of doneTasks) ys.add(new Date(t.done_at!).getFullYear());
        if (ys.size === 0) ys.add(new Date().getFullYear());
        return [...ys].sort((a, b) => a - b);
      })(),
    };
  },

  // ---- 计数（旧基座命令；保守返回 0）----
  business_count: () => 0,

  // ---- 任务附件（详情抽屉区块 9；内存模拟内容寻址：hash 简化为内容指纹）----
  task_attachment_add: (
    { taskId, fileName, mimeType, data }: { taskId: number; fileName: string; mimeType: string; data: number[] },
    { db }: Ctx,
  ) => {
    const t = db.tasks.find((x) => x.id === taskId && !x.is_deleted);
    if (!t) throw new Error(`task ${taskId} not found`);
    if (!data?.length) throw new Error("附件内容为空");
    if (data.length > 50 * 1024 * 1024) throw new Error("附件超过单文件上限 50MB");
    // 简化 hash：非加密用途，仅保证同内容同键（djb2）
    let h = 5381;
    for (const b of data) h = ((h << 5) + h + b) >>> 0;
    const hash = h.toString(16).padStart(8, "0");
    const existing = db.attachments.find(
      (a) => a.task_id === taskId && a.hash === hash,
    );
    if (existing) return ipcClone(existing);
    if (db.attachments.filter((a) => a.task_id === taskId).length >= 20) {
      throw new Error("单任务附件数已达上限 20");
    }
    const link: MockAttachmentLink = {
      link_id: db.seq++,
      link_uuid: uuid(),
      task_id: taskId,
      hash,
      original_name: fileName,
      mime_type: mimeType,
      size_bytes: data.length,
      is_local_cached: 1,
    };
    db.attachments.push(link);
    // 附件轨迹仅新挂载记（幂等路径不重复记，与 Rust 同口径）
    logTarget(db, taskId, "attachment_add", fileName);
    return ipcClone(link);
  },
  task_attachments_list: ({ taskId }: { taskId: number }, { db }: Ctx) =>
    ipcClone(db.attachments.filter((a) => a.task_id === taskId)),
  task_attachment_read: ({ hash }: { hash: string }, { db }: Ctx) => {
    const meta = db.attachments.find((a) => a.hash === hash);
    if (!meta) throw new Error(`附件 ${hash} 不存在`);
    if (meta.is_local_cached === 0) throw new Error("附件尚未从云端同步到本机");
    return [];
  },
  task_attachment_remove: ({ linkId }: { linkId: number }, { db }: Ctx) => {
    const idx = db.attachments.findIndex((a) => a.link_id === linkId);
    if (idx >= 0) {
      const link = db.attachments[idx];
      db.attachments.splice(idx, 1);
      logTarget(db, link.task_id, "attachment_delete", link.original_name);
    }
  },
  attachments_gc: () => 0,
  // ---- 数据库维护（性能批次；内存 mock 库无碎片，各步返回零值）----
  // ---- ICS 日历导出（#4；内存 mock 最小语义：头 + 每任务一个 VTODO 段）----
  // ---- 通知历史（#5；内存 mock 最小语义：种子三条 + 倒序/过滤/清空）----
  notification_log_list: (
    { kind, limit }: { kind?: string | null; limit?: number },
    { db }: Ctx,
  ) => {
    let rows = db.notificationLog.slice();
    if (kind) rows = rows.filter((r) => r.kind === kind);
    return ipcClone(rows.slice(0, limit ?? 50));
  },
  notification_log_clear: (_a: unknown, { db }: Ctx) => {
    const n = db.notificationLog.length;
    db.notificationLog.length = 0;
    return n;
  },
  // ---- 任务活动日志（F6；单任务倒序 + detail JSON 透传）----
  task_activity_list: (
    { taskId, limit }: { taskId: number; limit?: number },
    { db }: Ctx,
  ) => {
    const rows = db.activityLog
      .filter((r) => r.task_id === taskId)
      .sort((a, b) => b.created_at - a.created_at || b.id - a.id)
      .slice(0, limit ?? 30);
    return ipcClone(rows);
  },
  ics_export: (_a: unknown, { db }: Ctx): { content: string; table_counts: Record<string, number>; suggested_filename: string } => {
    const tasks = Object.values(db.tasks).filter((t) => (t as { is_deleted?: number }).is_deleted === 0) as Array<{ id: number; title: string }>;
    const content =
      "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Orbit//TODO ICS Export//CN\r\n" +
      tasks.map((t) => `BEGIN:VTODO\r\nUID:${t.id}@orbit\r\nSUMMARY:${t.title}\r\nEND:VTODO\r\n`).join("") +
      "END:VCALENDAR\r\n";
    return {
      content,
      table_counts: { todo_tasks: tasks.length },
      suggested_filename: "orbit_mock.ics",
    };
  },
  db_maintenance: (): { wal_bytes_after_checkpoint: number; attachments_cleaned: number; log_rows_pruned: number; freelist_before: number; freelist_after: number; pages_reclaimed: number } => ({
    wal_bytes_after_checkpoint: 0,
    attachments_cleaned: 0,
    log_rows_pruned: 0,
    freelist_before: 0,
    freelist_after: 0,
    pages_reclaimed: 0,
  }),
  // 唤起主窗：纯浏览器/冒烟环境无窗口概念，静默成功（热键路径不炸即可）
  show_main_window_cmd: (): null => null,
  // 启动形态探针（自启 --hidden 判定）：纯浏览器无自启概念，恒非隐藏
  startup_launched_hidden: (): boolean => false,

  // ---- 保存的筛选器（#35；条件 JSON 白名单键同 Rust）----
  saved_filters_list: (_a: unknown, { db }: Ctx) => ipcClone(db.savedFilters),
  saved_filter_create: (
    { input }: { input: { name: string; conditions: string; sort_order?: number } },
    { db }: Ctx,
  ) => {
    if (!input.name.trim()) throw new Error("筛选器名称不能为空");
    const row = {
      id: db.seq++,
      uuid: `sf-${db.seq}`,
      name: input.name,
      conditions: input.conditions,
      sort_order: input.sort_order ?? Date.now(),
    };
    db.savedFilters.push(row);
    return ipcClone(row);
  },
  saved_filter_update: (
    { id, input }: { id: number; input: { name?: string; conditions?: string; sort_order?: number } },
    { db }: Ctx,
  ) => {
    const row = db.savedFilters.find((f) => f.id === id);
    if (!row) throw new Error(`saved_filter ${id} not found`);
    if (input.name != null) row.name = input.name;
    if (input.conditions != null) row.conditions = input.conditions;
    if (input.sort_order != null) row.sort_order = input.sort_order;
    return ipcClone(row);
  },
  saved_filter_delete: ({ id }: { id: number }, { db }: Ctx) => {
    const idx = db.savedFilters.findIndex((f) => f.id === id);
    if (idx >= 0) db.savedFilters.splice(idx, 1);
  },

  // ---- 任务模板（与 Rust template_api 同构最小语义：白名单键校验 + 软删幂等）----
  templates_list: (_a: unknown, { db }: Ctx) => ipcClone(db.templates),
  template_create: (
    { input }: { input: { name: string; payload: string; sort_order?: number } },
    { db }: Ctx,
  ) => {
    if (!input.name.trim()) throw new Error("模板名称不能为空");
    validateTemplatePayload(input.payload);
    const row = {
      id: db.seq++,
      uuid: `tpl-${db.seq}`,
      name: input.name,
      payload: input.payload,
      sort_order: input.sort_order ?? Date.now(),
    };
    db.templates.push(row);
    return ipcClone(row);
  },
  template_update: (
    { id, input }: { id: number; input: { name?: string; payload?: string; sort_order?: number } },
    { db }: Ctx,
  ) => {
    const row = db.templates.find((t) => t.id === id);
    if (!row) throw new Error(`template ${id} not found`);
    if (input.name != null && !input.name.trim()) throw new Error("模板名称不能为空");
    if (input.payload != null) validateTemplatePayload(input.payload);
    if (input.name != null) row.name = input.name;
    if (input.payload != null) row.payload = input.payload;
    if (input.sort_order != null) row.sort_order = input.sort_order;
    return ipcClone(row);
  },
  template_delete: ({ id }: { id: number }, { db }: Ctx) => {
    const idx = db.templates.findIndex((t) => t.id === id);
    if (idx >= 0) db.templates.splice(idx, 1);
  },

  // ---- CSV 导入（设置页迁移卡；冒烟不覆盖设置页，mock 提供
  //      与 Rust csv_import_api 同构的最小语义：title/content/summary
  //      列识别 + 空标题跳过 + 项目列自动建项目）----
  csv_import_preview: ({ content, preset, previewLimit }: { content: string; preset: string; previewLimit?: number }) => {
    const rows = parseCsvLite(content);
    const mapped = rows.slice(1).map((row, i) => mapImportRowLite(preset, rows[0], row, i + 2));
    const stats = {
      success: mapped.filter((r) => !r.skip_reason).length,
      skipped: mapped.filter((r) => r.skip_reason).length,
      failed: 0,
      notes: [],
    };
    return { preset, rows: mapped.slice(0, previewLimit ?? 20), stats };
  },
  csv_import_execute: ({ content, preset }: { content: string; preset: string }, { db }: Ctx) => {
    const rows = parseCsvLite(content);
    const mapped = rows.slice(1).map((row, i) => mapImportRowLite(preset, rows[0], row, i + 2));
    const stats = { success: 0, skipped: 0, failed: 0, notes: [] as string[] };
    for (const r of mapped) {
      if (r.skip_reason) {
        stats.skipped++;
        stats.notes.push(`第 ${r.source_line} 行跳过：${r.skip_reason}`);
        continue;
      }
      const now = Date.now();
      const t: MockTask = {
        id: db.seq++,
        uuid: uuid(),
        title: r.input.title,
        description: r.input.description,
        project_id: r.project_title
          ? ensureMockProject(db, r.project_title)
          : null,
        priority: r.input.priority ?? 0,
        status: r.input.status ?? (r.input.done === 1 ? "done" : "pending"),
        done: r.input.done ?? 0,
        done_at: r.input.done_at ?? null,
        due_date: r.input.due_date ?? null,
        start_date: r.input.start_date ?? null,
        repeat_after: 0,
        repeat_mode: 0,
        percent_done: 0,
        position: 100000,
        is_favorite: 0,
        my_day_date: null,
        is_deleted: 0,
        created_at: now,
        updated_at: now,
        deleted_at: null,
        version: 1,
      };
      db.tasks.push(t);
      stats.success++;
    }
    return stats;
  },
};

/** 分页切片（对齐 Rust generic_repo::list：page_size 缺省/0→20，page 1 起，offset=(page-1)*page_size） */
export function paginateRows<T>(rows: T[], page?: number, pageSize?: number): T[] {
  const ps = !pageSize || pageSize <= 0 ? 20 : Math.floor(pageSize);
  const p = !page || page < 1 ? 1 : Math.floor(page);
  const start = (p - 1) * ps;
  return rows.slice(start, start + ps);
}

/** mock 命令表（仅测试导入：契约测试直调命令实现断言分页/排序/列裁剪保真） */
export const mockCommands = commands;

/** CSV 轻量解析（RFC 4180 关键子集：引号转义/逗号切分/跳空行；换行在字段内不支持） */
function parseCsvLite(content: string): string[][] {
  const rows: string[][] = [];
  for (const line of content.replace(/^\u{feff}/u, "").split(/\r?\n/)) {
    if (!line.trim()) continue;
    const fields: string[] = [];
    let cur = "";
    let inQ = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (c === '"') {
        if (inQ && line[i + 1] === '"') {
          cur += '"';
          i++;
        } else inQ = !inQ;
      } else if (c === "," && !inQ) {
        fields.push(cur);
        cur = "";
      } else cur += c;
    }
    fields.push(cur);
    rows.push(fields);
  }
  return rows;
}

/** 三档预设轻量映射（与 Rust map_csv_rows 同构；仅设置页交互用） */
function mapImportRowLite(
  preset: string,
  header: string[],
  row: string[],
  sourceLine: number,
): {
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
} {
  const idx = (name: string) => header.findIndex((h) => h.trim().toLowerCase() === name);
  const cellOf = (name: string) => {
    const i = idx(name);
    const v = i >= 0 ? (row[i] ?? "").trim() : "";
    return v || null;
  };
  let title: string | null = null;
  let projectTitle: string | null = null;
  let priority: number | null = null;
  if (preset === "todoist") {
    if (cellOf("type") && cellOf("type")!.toLowerCase() !== "task") {
      return {
        source_line: sourceLine, project_title: null,
        input: { title: "", description: null, priority: null, status: null, done: null, done_at: null, due_date: null, start_date: null },
        skip_reason: `非 Task 类型行（type=${cellOf("type")}）`,
      };
    }
    title = cellOf("content");
    projectTitle = cellOf("list name");
    priority = { p1: 4, p2: 3, p3: 2, p4: 1 }[cellOf("priority")?.toLowerCase() ?? ""] ?? null;
  } else if (preset === "ticktick") {
    title = cellOf("summary");
    projectTitle = cellOf("list name");
    priority = { 高: 3, 中: 2, 低: 1, 无: 0 }[cellOf("priority") ?? ""] ?? null;
  } else {
    title = cellOf("title");
    projectTitle = cellOf("project");
    priority = { 低: 1, 中: 2, 高: 3, 紧急: 4, 立即处理: 5 }[cellOf("priority") ?? ""] ?? null;
  }
  if (!title) {
    return {
      source_line: sourceLine, project_title: null,
      input: { title: "", description: null, priority: null, status: null, done: null, done_at: null, due_date: null, start_date: null },
      skip_reason: "标题为空",
    };
  }
  const doneAt = cellOf("completed date") ?? cellOf("completed time");
  return {
    source_line: sourceLine,
    project_title: projectTitle,
    input: {
      title,
      description: cellOf("description") ?? cellOf("note"),
      priority,
      status: null,
      done: doneAt ? 1 : 0,
      done_at: null, // mock 不做日期解析；完成态按有值即记
      due_date: null,
      start_date: null,
    },
    skip_reason: null,
  };
}

/** 按标题找项目，无则自动创建（对齐 Rust execute_csv_import 项目复用） */
function ensureMockProject(db: MockDb, title: string): number {
  const existing = db.projects.find((p) => p.title.toLowerCase() === title.trim().toLowerCase());
  if (existing) return existing.id;
  const now = Date.now();
  const p: MockProject = {
    id: db.seq++,
    uuid: uuid(),
    title: title.trim(),
    description: null,
    hex_color: "#3B82F6",
    sort_order: 0,
    is_archived: 0,
    is_deleted: 0,
    created_at: now,
    updated_at: now,
    deleted_at: null,
    version: 1,
  };
  db.projects.push(p);
  return p.id;
}

/** 写类命令完成后应广播 db-change 的判定（对齐 Rust EVENT_BUS 语义；
 *  trash 恢复/彻底删除/清空写后同样要失效列表缓存） */
const isWriteCommand = (cmd: string) =>
  /_(create|update|update_position|complete|delete|toggle_done|recalc_percent|restore|purge|execute|add|remove)$/.test(cmd) ||
  cmd === "trash_purge_all";

// ---------- 安装 ----------

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown;
    /** 冒烟调试句柄：e2e seed / 断言用 */
    __orbitMock?: {
      db: MockDb;
      seed: () => void;
      /** 测试直改内存库后手动广播 db-change（同 seed 的刷新通道） */
      emitDbChange: () => void;
      /** 云同步造态开关（改后需手动推事件或重挂组件生效） */
      syncState: { configured: boolean; unlocked: boolean; lastSyncedAt: number | null };
      /** 手动推同步进度事件（真实环境由 Rust TauriProgressSender 推送） */
      emitSyncProgress: (payload: unknown) => void;
      /** 手动推同步完成事件 */
      emitSyncFinished: (payload: unknown) => void;
    };
  }
}

export function installBrowserIpc() {
  // 已是 Tauri WebView（真实 internals 注入）则不装桩
  if (typeof window === "undefined" || window.__TAURI_INTERNALS__) return;

  const db = createDb();
  window.__orbitMock = {
    db,
    // seed 直改内存库后手动广播 db-change（走 seedDefault 而非命令面，
    // 避免 seq 分配差异），events 层收到后 invalidateQueries → UI 刷新
    seed: () => {
      seedDefault(db);
      emitDbChange();
    },
    emitDbChange,
    syncState,
    emitSyncProgress: (payload: unknown) => emitEvent("sync-progress", payload),
    emitSyncFinished: (payload: unknown) => emitEvent("sync-finished", payload),
  };

  // transformCallback 注册的回调表：id → cb。
  // listen 的 handler 即经此通道入表（event.js 的实现），
  // mock 的 plugin:event|listen 拿到 id 后按事件名分组保存。
  const callbacks = new Map<number, Function>();
  let callbackSeq = 1;
  // 事件名 → 订阅者列表（多订阅：同一事件可能被多个组件监听，
  // 如 sync-finished 同时被 ReadyShell 失效层与标题栏云图标监听；
  // 早期实现只保留最后一个 listener，会让先注册者静默收不到事件）
  const eventListeners = new Map<string, Array<{ id: number; cb: Function }>>();

  /** 事件广播（模拟 Rust 侧 emit；同步进度等造态事件也走此处） */
  function emitEvent(event: string, payload: unknown) {
    for (const entry of eventListeners.get(event) ?? []) {
      // 对齐 Tauri 真实契约（event.js listener.rs emit_js_script）：
      // handler 收到 {event, payload} 包装，不是裸 payload——此前 mock
      // 直传裸对象，消费方 evt.payload 解构在 mock 下为 undefined
      entry.cb({ event, id: entry.id, payload });
    }
  }

  /** 模拟 Rust EVENT_BUS 的 db-change 广播：写命令后触发 events 层失效 */
  function emitDbChange() {
    // 与桌面事件泵同口径（只 table + op，无整行 payload）；table="mock" 故意取
    // 一个未登记表名，令 invalidateByTable 未命中而回退全量失效
    emitEvent("db-change", { table: "mock", op: "mock" });
  }

  const internals = {
    invoke(cmd: string, args?: Record<string, unknown>) {
      // ---- 事件插件命令（listen/unlisten）----
      if (cmd === "plugin:event|listen") {
        const { event, handler } = args as { event: string; handler: number };
        const cb = callbacks.get(handler);
        if (cb) {
          const list = eventListeners.get(event) ?? [];
          list.push({ id: handler, cb });
          eventListeners.set(event, list);
        }
        return Promise.resolve(handler);
      }
      // 退订按 eventId 摘除（真实 event.js 契约）：不摘会让 StrictMode
      // 双挂载残留旧订阅，同一事件派发两次（toast/失效链重复触发）
      if (cmd === "plugin:event|unlisten") {
        const { event, eventId } = args as { event: string; eventId?: number };
        const list = eventListeners.get(event);
        if (list) {
          const kept = list.filter((l) => l.id !== eventId);
          if (kept.length) eventListeners.set(event, kept);
          else eventListeners.delete(event);
        }
        return Promise.resolve();
      }

      // ---- 业务命令 ----
      const impl = commands[cmd];
      if (!impl) return Promise.reject(notImplemented(cmd));
      try {
        const result = impl(args ?? {}, { db });
        // 写命令的 db-change 广播【推迟到宏任务】：真实 Tauri 下 Rust 侧
        // EVENT_BUS 转发经 IPC 异步到达，绝不在 invoke 调用栈内同步触发。
        // mock 若在 React 事件 handler 的同步栈里广播（invoke 同步 resolve），
        // invalidateQueries → refetch → 通知链被 React 19 事件批处理吞掉，
        // UI 不刷新（#19 排查实录：收藏/删除等所有事件内写命令全部复现；
        // 微任务仍属 React 离散事件批处理窗口，必须宏任务）。
        if (isWriteCommand(cmd)) setTimeout(() => emitDbChange(), 0);
        return Promise.resolve(result);
      } catch (e) {
        return Promise.reject(e);
      }
    },
    transformCallback(cb: Function) {
      const id = callbackSeq++;
      callbacks.set(id, cb);
      return id;
    },
    metadata: {
      currentWindow: { label: "main" },
      currentWebview: { label: "main", windowLabel: "main" },
    },
    plugins: {},
  };

  window.__TAURI_INTERNALS__ = internals;
  // event.js 的 _unlisten 直接调它（v2.9+）；给个 no-op 防 TypeError
  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
}
