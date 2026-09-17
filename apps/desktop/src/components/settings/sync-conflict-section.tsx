/**
 * 冲突记录分区（03 文档 §八 遗留项兑现）
 *
 * 云同步 LWW 裁决只会留下一个「冲突数」，败方字段过去被静默覆盖丢弃。
 * 本面板回看裁决现场：谁覆盖了谁、被覆盖的那一版长什么样，并可一键把
 * 败方内容**恢复为我方版本**（恢复会发起一次新的本地写入，下一轮同步胜出）。
 *
 * 数据源 sync_conflicts 为纯本地表（各端各自记录各自的裁决现场，不随同步、
 * 不进备份），口径同「通知历史」。
 */
import { useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, GitCompare, RotateCcw, Trash2, X } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { cn } from "@/lib/utils";
import {
  syncConflictClear,
  syncConflictDismiss,
  syncConflictList,
  syncConflictRestore,
  type SyncConflictEntry,
} from "@/lib/tauri";

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

/** 表名 → 中文（列表里让用户认出冲突发生在哪类数据上） */
const TABLE_LABELS: Record<string, string> = {
  todo_projects: "项目",
  todo_tasks: "任务",
  todo_subtasks: "子任务",
  todo_labels: "标签",
  todo_task_labels: "任务标签",
  todo_comments: "评论",
  todo_task_relations: "任务关系",
  todo_reminders: "提醒",
  todo_task_attachments: "附件关联",
  todo_saved_filters: "筛选器",
  todo_templates: "任务模板",
};

/** 常见字段 → 中文（未收录的字段回落原始列名，不隐藏信息） */
const FIELD_LABELS: Record<string, string> = {
  title: "标题",
  name: "名称",
  content: "内容",
  description: "描述",
  priority: "优先级",
  status: "状态",
  done: "已完成",
  done_at: "完成时间",
  due_date: "截止日期",
  start_date: "开始日期",
  my_day_date: "我的一天",
  is_favorite: "收藏",
  percent_done: "完成度",
  hex_color: "颜色",
  is_archived: "已归档",
  project_id: "所属项目",
  sort_order: "排序",
  position: "排序",
  payload: "模板内容",
  conditions: "筛选条件",
  remind_at: "提醒时间",
  relation_type: "关系类型",
  hash: "附件",
  repeat_mode: "重复模式",
  repeat_after: "重复间隔",
};

function fmtWhen(ms: number): string {
  if (!ms) return "—";
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** 值渲染：时间戳类列转本地时间，字符串截断，其余原样 */
export function fmtValue(key: string, v: unknown): string {
  if (v === null || v === undefined) return "（空）";
  if (typeof v === "number" && (key.endsWith("_at") || key.endsWith("_date")) && v > 1e11) {
    return fmtWhen(v);
  }
  if (typeof v === "object") return JSON.stringify(v);
  const s = String(v);
  return s.length > 120 ? `${s.slice(0, 120)}…` : s;
}

/** 解析载荷为字段表（解析失败时回落为空对象，不吞掉整条记录） */
export function parsePayload(raw: string): Record<string, unknown> {
  try {
    const v = JSON.parse(raw) as unknown;
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/**
 * 计算「胜方 / 败方」的差异字段
 *
 * 只看两侧都存在的业务字段（缺键=该侧没有这个字段，不作差异展示，避免把
 * 列裁剪差异当成用户可见改动）；同步元字段（uuid/updated_at/version）不展示。
 */
export function diffFields(
  loser: Record<string, unknown>,
  winner: Record<string, unknown>,
) {
  const skip = new Set(["uuid", "updated_at", "version", "deleted_at", "is_deleted", "id"]);
  const keys = new Set([...Object.keys(loser), ...Object.keys(winner)]);
  const out: { key: string; before: unknown; after: unknown }[] = [];
  for (const key of keys) {
    if (skip.has(key)) continue;
    // 单侧缺键说明是 schema 差异（旧版本同步包少一列），不是用户可见改动
    if (!(key in loser) || !(key in winner)) continue;
    if (JSON.stringify(loser[key]) === JSON.stringify(winner[key])) continue;
    out.push({ key, before: loser[key], after: winner[key] });
  }
  return out;
}

export function SyncConflictSection() {
  const queryClient = useQueryClient();
  const [onlyPending, setOnlyPending] = useState(true);
  const [expanded, setExpanded] = useState<number | null>(null);
  // 恢复会覆盖当前数据，需二次确认（保留被覆盖内容已无副本）
  const [restoreTarget, setRestoreTarget] = useState<SyncConflictEntry | null>(null);
  // 清空不可撤销（败方副本是「被覆盖内容」的最后一份留档）
  const [clearOpen, setClearOpen] = useState(false);

  const { data: rows = [], isLoading } = useQuery({
    queryKey: ["sync_conflicts", onlyPending ? "unresolved" : "all"],
    queryFn: () => syncConflictList(onlyPending ? "unresolved" : null, 200, 0),
    staleTime: 30_000,
  });

  const refresh = () => queryClient.invalidateQueries({ queryKey: ["sync_conflicts"] });

  const restoreMutation = useMutation({
    mutationFn: (id: number) => syncConflictRestore(id),
    onSuccess: () => {
      refresh();
      toast.success("已恢复为败方版本；下次同步会以该版本为准");
    },
    onError: (e: Error) => toast.error(`恢复失败：${e.message}`),
  });

  const dismissMutation = useMutation({
    mutationFn: (id: number) => syncConflictDismiss(id),
    onSuccess: refresh,
    onError: () => toast.error("忽略失败"),
  });

  const clearMutation = useMutation({
    mutationFn: () => syncConflictClear(null),
    onSuccess: (n) => {
      refresh();
      toast.success(`已清空冲突记录（${n} 条）`);
    },
    onError: () => toast.error("清空失败"),
  });

  const pendingCount = useMemo(
    () => rows.filter((r) => r.resolution === "unresolved").length,
    [rows],
  );

  return (
    <div className="flex flex-col gap-6">
      <SectionHeader
        title="冲突记录"
        desc="多端同时改同一条数据时，本端会保留被覆盖的那一版。在此查看差异并恢复到该版本。本表仅存本机，不随云同步。"
      />

      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-1">
          {[
            { key: true, label: "待处理" },
            { key: false, label: "全部" },
          ].map((tab) => (
            <Button
              key={String(tab.key)}
              size="sm"
              variant={onlyPending === tab.key ? "secondary" : "ghost"}
              onClick={() => setOnlyPending(tab.key)}
            >
              {tab.label}
            </Button>
          ))}
          <span className="ml-2 text-sm text-muted-foreground">
            {onlyPending ? `待处理 ${pendingCount} 条` : `共 ${rows.length} 条`}
          </span>
        </div>
        <Button
          variant="outline"
          size="sm"
          disabled={rows.length === 0 || clearMutation.isPending}
          onClick={() => setClearOpen(true)}
        >
          <Trash2 className="mr-1 size-3.5" />
          清空记录
        </Button>
      </div>

      <div className="rounded-lg border border-border/60">
        {rows.length === 0 ? (
          <div className="flex flex-col items-center gap-2 px-4 py-10 text-muted-foreground">
            <GitCompare className="size-8" />
            <span className="text-sm">
              {isLoading ? "加载中…" : "暂无冲突；多端并发修改同一记录后会在这里留档。"}
            </span>
          </div>
        ) : (
          rows.map((r, i) => {
            const loser = parsePayload(r.loser_payload);
            const winner = parsePayload(r.winner_payload);
            const diffs = diffFields(loser, winner);
            const open = expanded === r.id;
            return (
              <div
                key={r.id}
                className={cn(
                  "px-4 py-3",
                  i > 0 && "border-t border-border/40",
                  r.resolution !== "unresolved" && "opacity-60",
                )}
              >
                <div className="flex items-start gap-3">
                  <AlertTriangle className="mt-0.5 size-4 shrink-0 text-amber-500" />
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-sm">
                      {r.record_title || r.record_uuid}
                    </div>
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      {TABLE_LABELS[r.table_name] ?? r.table_name} ·{" "}
                      {r.loser_side === "local"
                        ? "本端版本被他端覆盖"
                        : "他端版本被本端保留丢弃"}{" "}
                      · {r.decision === "tie_version" ? "同毫秒按版本号裁决" : "按修改时间裁决"} ·{" "}
                      {fmtWhen(r.created_at)}
                      {r.resolution === "restored" && " · 已恢复"}
                      {r.resolution === "dismissed" && " · 已忽略"}
                    </div>
                  </div>
                  <div className="flex shrink-0 items-center gap-1">
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => setExpanded(open ? null : r.id)}
                    >
                      {open ? "收起" : `查看差异（${diffs.length}）`}
                    </Button>
                    {r.resolution === "unresolved" && (
                      <>
                        <Button
                          size="sm"
                          variant="outline"
                          disabled={restoreMutation.isPending}
                          onClick={() => setRestoreTarget(r)}
                        >
                          <RotateCcw className="mr-1 size-3.5" />
                          恢复
                        </Button>
                        <Button
                          size="sm"
                          variant="ghost"
                          disabled={dismissMutation.isPending}
                          onClick={() => dismissMutation.mutate(r.id)}
                        >
                          <X className="mr-1 size-3.5" />
                          忽略
                        </Button>
                      </>
                    )}
                  </div>
                </div>

                {open && (
                  <div className="mt-3 overflow-hidden rounded-md border border-border/50">
                    <div className="grid grid-cols-[8rem_1fr_1fr] bg-muted/40 px-3 py-1.5 text-xs text-muted-foreground">
                      <span>字段</span>
                      <span>当前（胜方 · {r.winner_side === "local" ? "本端" : "他端"}）</span>
                      <span>被覆盖（败方 · {r.loser_side === "local" ? "本端" : "他端"}）</span>
                    </div>
                    {diffs.length === 0 ? (
                      <div className="px-3 py-3 text-xs text-muted-foreground">
                        两侧业务字段无可见差异（差异可能只存在于记录元数据）。
                      </div>
                    ) : (
                      diffs.map((d) => (
                        <div
                          key={d.key}
                          className="grid grid-cols-[8rem_1fr_1fr] gap-2 border-t border-border/40 px-3 py-1.5 text-xs"
                        >
                          <span className="truncate text-muted-foreground">
                            {FIELD_LABELS[d.key] ?? d.key}
                          </span>
                          <span className="break-all">{fmtValue(d.key, d.after)}</span>
                          <span className="break-all text-amber-600 dark:text-amber-500">
                            {fmtValue(d.key, d.before)}
                          </span>
                        </div>
                      ))
                    )}
                  </div>
                )}
              </div>
            );
          })
        )}
      </div>

      {/* 清空二次确认：删除全部本地副本（不可撤销，但只影响记录不影响业务数据） */}
      <AlertDialog open={clearOpen} onOpenChange={setClearOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>清空冲突记录</AlertDialogTitle>
            <AlertDialogDescription>
              将删除全部 {rows.length} 条本地冲突记录，此操作不可撤销。
              记录仅存于本机，不影响任务数据与云同步。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              disabled={clearMutation.isPending}
              onClick={() => {
                setClearOpen(false);
                clearMutation.mutate();
              }}
            >
              确认清空
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* 恢复二次确认：把败方内容写回业务表并作为新的本端版本参与同步 */}
      <AlertDialog
        open={restoreTarget !== null}
        onOpenChange={(v) => !v && setRestoreTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>恢复为败方版本</AlertDialogTitle>
            <AlertDialogDescription>
              将把「{restoreTarget?.record_title || restoreTarget?.record_uuid}
              」的内容回放为被覆盖的那一版，并作为一次新的本端修改参与同步。
              当前内容会被覆盖，且不会另存副本。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                if (restoreTarget) restoreMutation.mutate(restoreTarget.id);
                setRestoreTarget(null);
              }}
            >
              确认恢复
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
