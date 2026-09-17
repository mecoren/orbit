/**
 * 任务模板管理分区（设置页；竞品矩阵高价值缺口）
 *
 * 模板列表（名称 + payload 摘要）+ 新建/编辑弹窗（名称 + 五字段编辑）+
 * 删除（软删）。payload 存白名单 JSON（title/notes/priority/due_offset_days/
 * subtasks），套用预填语义见 features/todo/shared/template-apply.ts。
 */
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CopyPlus, FileStack, Trash2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { toast } from "sonner";
import {
  templateCreate,
  templateDelete,
  templateUpdate,
  templatesList,
  type TodoTemplate,
} from "@/lib/tauri";

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

/** 模板编辑草稿（五字段独立受控；subtasks 文本框每行一条） */
interface TemplateDraft {
  name: string;
  title: string;
  notes: string;
  priority: string;
  dueOffsetDays: string;
  subtasks: string;
}

const emptyDraft: TemplateDraft = {
  name: "",
  title: "",
  notes: "",
  priority: "0",
  dueOffsetDays: "",
  subtasks: "",
};

function draftOf(t: TodoTemplate): TemplateDraft {
  let payload: Record<string, unknown> = {};
  try {
    const parsed = JSON.parse(t.payload);
    if (parsed && typeof parsed === "object") payload = parsed as Record<string, unknown>;
  } catch {
    /* 损坏 payload 按空编辑 */
  }
  const num = (v: unknown) => (typeof v === "number" ? String(v) : "");
  const sub = Array.isArray(payload.subtasks) && payload.subtasks.every((x) => typeof x === "string")
    ? (payload.subtasks as string[]).join("\n")
    : "";
  return {
    name: t.name,
    title: typeof payload.title === "string" ? payload.title : "",
    notes: typeof payload.notes === "string" ? payload.notes : "",
    priority: num(payload.priority) || "0",
    dueOffsetDays: num(payload.due_offset_days),
    subtasks: sub,
  };
}

/** 草稿 → payload JSON（只存有值字段；空字符串不进 JSON） */
function draftToPayload(d: TemplateDraft): string {
  const payload: Record<string, unknown> = {};
  if (d.title.trim()) payload.title = d.title.trim();
  if (d.notes.trim()) payload.notes = d.notes.trim();
  if (d.priority !== "0") payload.priority = Number(d.priority) || 0;
  if (d.dueOffsetDays.trim()) {
    const n = Number(d.dueOffsetDays.trim());
    if (!Number.isNaN(n)) payload.due_offset_days = n;
  }
  const subs = d.subtasks.split("\n").map((x) => x.trim()).filter(Boolean);
  if (subs.length > 0) payload.subtasks = subs;
  return JSON.stringify(payload);
}

/** payload 摘要（列表行一行说明：标题 + 优先级 + 子任务数） */
function payloadSummary(t: TodoTemplate): string {
  try {
    const p = JSON.parse(t.payload) as Record<string, unknown>;
    const parts: string[] = [];
    if (typeof p.title === "string" && p.title) parts.push(`标题「${p.title}」`);
    if (typeof p.priority === "number" && p.priority > 0) parts.push(`优先级 ${p.priority}`);
    if (typeof p.due_offset_days === "number") parts.push(`截止 +${p.due_offset_days} 天`);
    if (Array.isArray(p.subtasks) && p.subtasks.length > 0) {
      parts.push(`${p.subtasks.length} 条子任务`);
    }
    return parts.length > 0 ? parts.join(" · ") : "空白模板";
  } catch {
    return "（内容损坏）";
  }
}

const PRIORITY_OPTIONS = ["0 无", "1 低", "2 中", "3 高", "4 紧急", "5 立即处理"];

export function TemplatesSection() {
  const queryClient = useQueryClient();
  const { data: templates = [] } = useQuery({
    queryKey: ["templates", "list"],
    queryFn: () => templatesList(),
    staleTime: 2 * 60 * 1000,
    placeholderData: (prev) => prev,
  });

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["templates"] });

  const [editing, setEditing] = useState<number | null>(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [draft, setDraft] = useState<TemplateDraft>(emptyDraft);

  const saveMutation = useMutation({
    mutationFn: async () => {
      if (!draft.name.trim()) throw new Error("模板名称不能为空");
      const payload = draftToPayload(draft);
      if (editing != null) {
        return templateUpdate(editing, { name: draft.name.trim(), payload });
      }
      return templateCreate({ name: draft.name.trim(), payload });
    },
    onSuccess: () => {
      invalidate();
      setDialogOpen(false);
      toast.success(editing != null ? "模板已更新" : "模板已创建");
    },
    onError: (e) => toast.error(String(e).replace(/^.*?:\s*/, "")),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: number) => templateDelete(id),
    onSuccess: () => {
      invalidate();
      toast.success("模板已删除");
    },
    onError: (e) => toast.error(String(e).replace(/^.*?:\s*/, "")),
  });

  const openCreate = () => {
    setEditing(null);
    setDraft(emptyDraft);
    setDialogOpen(true);
  };
  const openEdit = (t: TodoTemplate) => {
    setEditing(t.id);
    setDraft(draftOf(t));
    setDialogOpen(true);
  };

  return (
    <div className="flex flex-col gap-6">
      <SectionHeader
        title="任务模板"
        desc="周报、报销单、差旅检查清单等多字段任务骨架存为模板，任务面板「模板」按钮一键预填。模板随云同步，设备间共享。"
      />

      <div className="flex items-center justify-between">
        <span className="text-sm text-muted-foreground">{templates.length} 个模板</span>
        <Button size="sm" onClick={openCreate}>
          <CopyPlus size={14} className="mr-1" />
          新建模板
        </Button>
      </div>

      <div className="rounded-lg border border-border/60">
        {templates.length === 0 ? (
          <div className="flex flex-col items-center gap-2 px-4 py-10 text-muted-foreground">
            <FileStack className="size-8" />
            <span className="text-sm">还没有模板；新建一个，把常用任务骨架存下来。</span>
          </div>
        ) : (
          templates.map((t, i) => (
            <div
              key={t.id}
              className={
                "flex items-center gap-3 px-4 py-2.5" +
                (i > 0 ? " border-t border-border/40" : "")
              }
            >
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-medium">{t.name}</div>
                <div className="truncate text-xs text-muted-foreground">
                  {payloadSummary(t)}
                </div>
              </div>
              <Button variant="ghost" size="sm" onClick={() => openEdit(t)}>
                编辑
              </Button>
              <Button
                variant="ghost"
                size="icon"
                aria-label={`删除模板 ${t.name}`}
                onClick={() => deleteMutation.mutate(t.id)}
              >
                <Trash2 className="size-4 text-muted-foreground" />
              </Button>
            </div>
          ))
        )}
      </div>

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{editing != null ? "编辑模板" : "新建模板"}</DialogTitle>
          </DialogHeader>
          <div className="flex flex-col gap-3">
            <div>
              <Label>模板名称</Label>
              <Input
                autoFocus
                value={draft.name}
                placeholder="如：差旅检查清单"
                onChange={(e) => setDraft((d) => ({ ...d, name: e.target.value }))}
              />
            </div>
            <div>
              <Label>任务标题</Label>
              <Input
                value={draft.title}
                placeholder="套用时预填的任务标题（可留空）"
                onChange={(e) => setDraft((d) => ({ ...d, title: e.target.value }))}
              />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <Label>优先级</Label>
                <Select
                  value={draft.priority}
                  onValueChange={(v) => setDraft((d) => ({ ...d, priority: v }))}
                >
                  <SelectTrigger className="h-9 w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {PRIORITY_OPTIONS.map((opt, i) => (
                      <SelectItem key={i} value={String(i)}>
                        {opt}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div>
                <Label>截止偏移（天）</Label>
                <Input
                  type="number"
                  value={draft.dueOffsetDays}
                  placeholder="0 = 今天；留空不预填"
                  onChange={(e) => setDraft((d) => ({ ...d, dueOffsetDays: e.target.value }))}
                />
              </div>
            </div>
            <div>
              <Label>备注</Label>
              <Input
                value={draft.notes}
                placeholder="套用时预填的任务备注（可留空）"
                onChange={(e) => setDraft((d) => ({ ...d, notes: e.target.value }))}
              />
            </div>
            <div>
              <Label>子任务（每行一条）</Label>
              <Textarea
                className="min-h-24 resize-y"
                value={draft.subtasks}
                placeholder={"订机票\n订酒店\n报销"}
                onChange={(e) => setDraft((d) => ({ ...d, subtasks: e.target.value }))}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="ghost" onClick={() => setDialogOpen(false)}>
              取消
            </Button>
            <Button
              disabled={saveMutation.isPending || !draft.name.trim()}
              onClick={() => saveMutation.mutate()}
            >
              {saveMutation.isPending ? "保存中…" : "保存"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
