/**
 * BackupPreviewBody — 恢复确认框内的备份预览体
 *
 * 恢复是全量覆盖，不可撤销：用户点「恢复」后先解密读取备份，
 * 在时停确认框内展示「备份里有什么」再做决定。
 *
 * 三态：loading（解密中）/ error（未解锁或密码不对，直接展示后端可读错误，
 * 预览失败不阻塞确认——预览只是决策辅助）/ ready（统计 + 前 10 条任务）。
 */

import { AlertTriangle, Loader2 } from "lucide-react";

import { cn } from "@/lib/utils";
import type { BackupPreviewView } from "@/lib/tauri";

/** 备份表名 → 中文标签（11 张业务表全集，未知表回落原名） */
export const BACKUP_TABLE_LABELS: Record<string, string> = {
  todo_projects: "项目",
  todo_tasks: "任务",
  todo_subtasks: "子任务",
  todo_labels: "标签",
  todo_task_labels: "标签关联",
  todo_comments: "评论",
  todo_task_relations: "任务关联",
  todo_reminders: "提醒",
  todo_task_attachments: "附件",
  todo_saved_filters: "筛选器",
  todo_templates: "模板",
};

/** 统计 chips 展示顺序（任务域优先，其余按标签表顺序） */
const BACKUP_TABLE_ORDER = [
  "todo_tasks",
  "todo_projects",
  "todo_subtasks",
  "todo_labels",
  "todo_task_labels",
  "todo_comments",
  "todo_task_relations",
  "todo_reminders",
  "todo_task_attachments",
  "todo_saved_filters",
  "todo_templates",
];

export function tableLabel(table: string): string {
  return BACKUP_TABLE_LABELS[table] ?? table;
}

/**
 * 有序计数行：只收录条数 > 0 的表（空表不占位），
 * 已知表按固定顺序，未知表追加在后。
 */
export function orderedTableCounts(counts: Record<string, number>): Array<[string, number]> {
  const entries = Object.entries(counts).filter(([, n]) => n > 0);
  const rank = (t: string) => {
    const i = BACKUP_TABLE_ORDER.indexOf(t);
    return i === -1 ? BACKUP_TABLE_ORDER.length : i;
  };
  return entries.sort(([a], [b]) => rank(a) - rank(b));
}

export function statusLabel(status: string, done: boolean): string {
  if (done || status === "done") return "已完成";
  if (status === "doing") return "进行中";
  return "待办";
}

/** 优先级 0–5 → 中文（对齐 todo_tasks.priority 列语义） */
export function priorityLabel(priority: number): string | null {
  switch (priority) {
    case 1:
      return "低";
    case 2:
      return "中";
    case 3:
      return "高";
    case 4:
      return "紧急";
    case 5:
      return "立即处理";
    default:
      return null;
  }
}

/** 截止时间展示：ms 时间戳 → M/D，无则“无截止” */
export function formatPreviewDate(dueDate: number | null): string {
  if (dueDate == null) return "无截止";
  const d = new Date(dueDate);
  return `${d.getMonth() + 1}/${d.getDate()}`;
}

export type BackupPreviewState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready"; preview: BackupPreviewView };

export function BackupPreviewBody({ state }: { state: BackupPreviewState }) {
  if (state.status === "loading") {
    return (
      <div className="flex items-center gap-2 rounded-md border bg-muted/20 px-3 py-4 text-xs text-muted-foreground">
        <Loader2 className="size-3.5 animate-spin" />
        正在解密并读取备份预览…
      </div>
    );
  }

  if (state.status === "error") {
    return (
      <div className="flex items-start gap-2 rounded-md border border-warning/40 bg-warning/10 p-3">
        <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
        <p className="text-xs text-warning">
          预览读取失败：{state.message}
          （预览仅供决策参考，不影响恢复；也可取消后先解锁同步密码再试）
        </p>
      </div>
    );
  }

  const { preview } = state;
  const { manifest, task_stats: stats } = preview;
  const counts = orderedTableCounts(manifest.table_counts);
  const created = new Date(manifest.created_at_ts * 1000).toLocaleString();

  return (
    <div className="space-y-2.5">
      {/* 元信息：备份时间 / 来源 / 版本 / schema 预警 */}
      <div className="space-y-0.5 rounded-md border bg-muted/20 px-3 py-2 text-xs text-muted-foreground">
        <p>
          备份时间：{created}
          {manifest.device_name ? ` · 来自 ${manifest.device_name}` : ""}
          {manifest.app_version ? ` · v${manifest.app_version}` : ""}
        </p>
        {preview.schema_mismatch && (
          <p className="flex items-center gap-1 text-warning">
            <AlertTriangle className="size-3 shrink-0" />
            该备份 schema（{manifest.schema_version}）与当前应用（
            {preview.current_schema_version}）不一致，恢复后需二次确认强制继续
          </p>
        )}
      </div>

      {/* 统计：任务存活/完成/墓碑 + 各表计数 */}
      <div className="space-y-1.5">
        <p className="text-xs">
          任务共 {stats.total} 条
          <span className="text-muted-foreground">
            {" "}
            · 存活 {stats.alive} · 已完成 {stats.done}
            {stats.deleted > 0 ? ` · 墓碑 ${stats.deleted}` : ""}
          </span>
        </p>
        {counts.length > 0 ? (
          <div className="flex flex-wrap gap-1">
            {counts.map(([table, n]) => (
              <span
                key={table}
                className="rounded-full border px-2 py-0.5 text-[11px] text-muted-foreground"
              >
                {tableLabel(table)} {n}
              </span>
            ))}
          </div>
        ) : (
          <p className="text-xs text-muted-foreground">空备份：各表均无记录</p>
        )}
      </div>

      {/* 前 10 条任务抽样（存活行，备份存储顺序） */}
      {preview.sample_tasks.length > 0 ? (
        <div>
          <p className="mb-1 text-xs text-muted-foreground">
            前 {preview.sample_tasks.length} 条任务预览
          </p>
          <div className="max-h-48 divide-y overflow-auto rounded-md border">
            {preview.sample_tasks.map((t, i) => {
              const prio = priorityLabel(t.priority);
              return (
                <div key={i} className="flex items-center gap-2 px-2.5 py-1.5">
                  <p
                    className={cn(
                      "min-w-0 flex-1 truncate text-xs",
                      t.done && "text-muted-foreground line-through",
                    )}
                  >
                    {t.title}
                  </p>
                  {t.project && (
                    <span className="max-w-24 shrink-0 truncate text-[11px] text-muted-foreground">
                      {t.project}
                    </span>
                  )}
                  <span className="shrink-0 text-[11px] text-muted-foreground">
                    {statusLabel(t.status, t.done)}
                  </span>
                  {prio && (
                    <span className="shrink-0 text-[11px] text-muted-foreground">
                      {prio}
                    </span>
                  )}
                  <span className="shrink-0 text-[11px] text-muted-foreground">
                    {formatPreviewDate(t.due_date)}
                  </span>
                </div>
              );
            })}
          </div>
        </div>
      ) : (
        <p className="text-xs text-muted-foreground">备份中无存活任务</p>
      )}
    </div>
  );
}
