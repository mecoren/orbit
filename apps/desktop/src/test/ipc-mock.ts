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
  end_date: number | null;
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

export interface MockDb {
  projects: MockProject[];
  tasks: MockTask[];
  labels: MockLabel[];
  taskLabels: MockTaskLabel[];
  reminders: MockReminder[];
  comments: MockComment[];
  relations: MockRelation[];
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
    reminders: [],
    comments: [],
    relations: [],
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
    end_date: null,
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

// ---------- 命令实现 ----------

const notImplemented = (cmd: string) => {
  throw new Error(`[browser-ipc-mock] 命令未实现: ${cmd}`);
};

type Ctx = { db: MockDb };

/** IPC 值语义克隆：读命令出参与 db 内部活引用彻底隔离（见 filterByKeyword 注释） */
const ipcClone = <T>(v: T): T => JSON.parse(JSON.stringify(v));

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
const commands: Record<string, (args: any, ctx: Ctx) => unknown> = {
  // ---- 启动链（App.tsx：master_auth_has=false → db_init_plaintext）----
  master_auth_has: () => false,
  db_init_plaintext: () => undefined,
  db_set_device_id: () => undefined,

  // ---- projects ----
  todo_projects_list: (_a, { db }) => ipcClone(db.projects),
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
  // 对齐 Rust generic_repo::list 的 WHERE is_deleted = 0（删除走软删，墓碑进回收站）
  todo_tasks_list: ({ filter }, { db }) =>
    filterByKeyword(
      db.tasks.filter((t) => !t.is_deleted),
      filter?.keyword,
    ),
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
      end_date: input.end_date ?? null,
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
    return ipcClone(t);
  },
  todo_tasks_update: ({ id, input }, { db }) => {
    const t = db.tasks.find((x) => x.id === id);
    if (!t) throw new Error(`task ${id} 不存在`);
    Object.assign(t, input, { updated_at: Date.now(), version: t.version + 1 });
    return ipcClone(t);
  },
  todo_tasks_update_position: ({ id, position }, { db }) => {
    const t = db.tasks.find((x) => x.id === id);
    if (!t) throw new Error(`task ${id} 不存在`);
    t.position = position;
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
      subtasks: [],
      labels,
      comments: [...db.comments.filter((c) => c.task_id === id)],
      relations: [...db.relations.filter((r) => r.task_id === id)],
      reminders: [...db.reminders.filter((r) => r.task_id === id)],
    });
  },

  // ---- subtasks（详情抽屉八区块之一；冒烟不建子任务，给空实现）----
  todo_subtasks_list: () => [],

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
    return ipcClone(r);
  },
  todo_task_relations_delete: ({ id }, { db }) => {
    const idx = db.relations.findIndex((r) => r.id === id);
    if (idx < 0) throw new Error(`relation ${id} not found`);
    db.relations.splice(idx, 1);
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
    return link;
  },
  todo_task_labels_delete: ({ id }, { db }) => {
    db.taskLabels = db.taskLabels.filter((l) => l.id !== id);
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
    return ipcClone(r);
  },
  todo_reminders_delete: ({ id }, { db }) => {
    db.reminders = db.reminders.filter((r) => r.id !== id);
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
    return c;
  },
  todo_comments_delete: ({ id }, { db }) => {
    db.comments = db.comments.filter((c) => c.id !== id);
  },

  // ---- 全局搜索 / 看板（list-page 查询、命令面板 Ctrl+P 用）----
  global_search: ({ keyword }, { db }) => {
    const kw = (keyword ?? "").toLowerCase();
    return {
      tasks: kw ? db.tasks.filter((t) => t.title.toLowerCase().includes(kw)) : [],
      projects: kw ? db.projects.filter((p) => p.title.toLowerCase().includes(kw)) : [],
    };
  },
  todo_tasks_kanban_by_project: (_a, { db }) => {
    const byProject = new Map<number | null, MockTask[]>();
    for (const t of db.tasks) {
      if (!byProject.has(t.project_id)) byProject.set(t.project_id, []);
      byProject.get(t.project_id)!.push(t);
    }
    return [...byProject.entries()];
  },
  todo_tasks_kanban_by_status: (_a, { db }) => {
    const byStatus = new Map<string, MockTask[]>();
    for (const t of db.tasks) {
      if (!byStatus.has(t.status)) byStatus.set(t.status, []);
      byStatus.get(t.status)!.push(t);
    }
    return [...byStatus.entries()];
  },

  // ---- Mica（use-mica-effect 挂载即调；浏览器返回不支持）----
  mica_diagnostics: () => ({
    platform: "browser",
    micaSupported: false,
    applyResult: "skipped-browser",
  }),
  apply_mica: () => undefined,
  disable_mica: () => undefined,

  // ---- 同步链（use-startup-sync / SyncIndicator；「未配置」走静默路径）----
  sync_config_get: () => null,
  cloud_sync_is_running: () => false,
  cloud_sync_get_state: () => JSON.stringify({ phase: "idle" }),
  sync_crypto_status: () => JSON.stringify({ locked: true }),

  // ---- 备份/导出（设置页打开才拉取；给空态安全值）----
  backup_prefs_get: () => null,
  full_backup_list_local: () => [],

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
  //      浏览器 mock 用端侧 Date 分桶，语义与 Rust chrono Local 一致）----
  stats_aggregate: (_a: { days?: number }, { db }) => {
    const days = Math.min(371, Math.max(35, _a.days ?? 182));
    const live = db.tasks.filter((t) => !t.is_deleted);
    const doneTasks = live.filter((t) => t.done && t.done_at != null);
    const dayKey = (ts: number) => {
      const d = new Date(ts);
      return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    };
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const startMs = today.getTime() - (days - 1) * 86_400_000;
    const todayKey = dayKey(today.getTime());

    const byDay = new Map<string, number>();
    for (const t of doneTasks) {
      if (t.done_at! >= startMs) {
        const k = dayKey(t.done_at!);
        byDay.set(k, (byDay.get(k) ?? 0) + 1);
      }
    }
    const cells: { date: string; count: number }[] = [];
    for (let i = 0; i < days; i++) {
      const d = new Date(startMs + i * 86_400_000);
      const k = dayKey(d.getTime());
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

    const byProjectMap = new Map<number | "none", { id: number | null; title: string | null; done: number; pending: number }>();
    for (const t of live) {
      const key = t.project_id ?? "none";
      const row =
        byProjectMap.get(key) ??
        {
          id: t.project_id ?? null,
          title: t.project_id != null ? db.projects.find((p) => p.id === t.project_id)?.title ?? "未知项目" : null,
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
      heatmap: { start_date: cells[0].date, end_date: cells[cells.length - 1].date, cells },
      streak: { current, best, done_today: doneToday },
      by_project: [...byProjectMap.values()]
        .map((r) => ({ project_id: r.id, project_title: r.title, done_count: r.done, pending_count: r.pending }))
        .sort((a, b) => b.done_count - a.done_count),
      by_priority: [...byPriorityMap.entries()]
        .map(([priority, r]) => ({ priority, done_count: r.done, pending_count: r.pending }))
        .sort((a, b) => a.priority - b.priority),
      by_weekday: byWeekday.map((count, weekday) => ({ weekday, done_count: count })),
    };
  },

  // ---- 计数（旧基座命令；保守返回 0）----
  business_count: () => 0,
};

/** 写类命令完成后应广播 db-change 的判定（对齐 Rust EVENT_BUS 语义；
 *  trash 恢复/彻底删除/清空写后同样要失效列表缓存） */
const isWriteCommand = (cmd: string) =>
  /_(create|update|update_position|delete|toggle_done|recalc_percent|restore|purge)$/.test(cmd) ||
  cmd === "trash_purge_all";

// ---------- 安装 ----------

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown;
    /** 冒烟调试句柄：e2e seed / 断言用 */
    __orbitMock?: {
      db: MockDb;
      seed: () => void;
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
  };

  // transformCallback 注册的回调表：id → cb。
  // listen 的 handler 即经此通道入表（event.js 的实现），
  // mock 的 plugin:event|listen 拿到 id 后按事件名分组保存。
  const callbacks = new Map<number, Function>();
  let callbackSeq = 1;
  // 事件名 → { id, cb }（同一事件只保留最后一个 listener——冒烟场景
  // 同名事件总是单订阅（db-change 由 events 层集中注册一次））
  const eventListeners = new Map<string, { id: number; cb: Function }>();

  /** 模拟 Rust EVENT_BUS 的 db-change 广播：写命令后触发 events 层失效 */
  function emitDbChange() {
    const entry = eventListeners.get("db-change");
    if (entry) {
      entry.cb({
        table: "mock",
        op: "mock",
        timestamp: Date.now(),
      });
    }
  }

  const internals = {
    invoke(cmd: string, args?: Record<string, unknown>) {
      // ---- 事件插件命令（listen/unlisten）----
      if (cmd === "plugin:event|listen") {
        const { event, handler } = args as { event: string; handler: number };
        const cb = callbacks.get(handler);
        if (cb) eventListeners.set(event, { id: handler, cb });
        return Promise.resolve(handler);
      }
      if (cmd === "plugin:event|unlisten") return Promise.resolve();

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
