/**
 * 任务/项目右键菜单（04 文档 §3.7：菜单项集合与文案对齐 wait-home）
 *
 * 任务菜单：打开详情 / 标记完成·标记未完成 / 收藏·取消收藏 / ─ /
 *           设置优先级▸(6档) / 修改标签▸(勾选切换) / 更换项目▸ /
 *           设置截止时间(Popover+DateTimePicker) / 设置提醒(Dialog) /
 *           添加评论(Dialog,Textarea) / ─ / 删除
 * 项目菜单：项目名标题头 + 删除项目（destructive；删除保护由父级弹窗处理）
 */
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { format } from "date-fns";
import {
  Calendar,
  Check,
  Clock,
  Eye,
  Flag,
  Folder,
  FolderOpen,
  MessageSquare,
  Star,
  Tag,
  Trash2,
} from "lucide-react";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
} from "@/components/ui/dropdown-menu";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { DateTimePicker } from "@/components/business/date-picker";
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
import { ContextMenuBase } from "./context-menu";
import {
  todoCommentCreate,
  todoLabelList,
  todoReminderCreate,
  todoTaskDelete,
  todoTaskLabelCreate,
  todoTaskLabelDelete,
  todoTaskLabelList,
  todoTaskUpdate,
  type TodoLabel,
  type TodoProject,
  type TodoTask,
  type TodoTaskLabel,
} from "@/lib/tauri";
import { PRIORITY_COLOR, FAVORITE_COLOR, TODO_ACCENT } from "../shared/constants";

const PRIORITY_LABELS = ["无", "低", "中", "高", "紧急", "立即处理"];

/** ms → DateTimePicker 值格式（YYYY-MM-DDTHH:MM） */
const tsToInputValue = (ms: number) => format(new Date(ms), "yyyy-MM-dd'T'HH:mm");

interface TaskContextMenuProps {
  task: TodoTask;
  projects: TodoProject[];
  /** 打开详情抽屉（§7-③ selectedTaskId） */
  onOpenDetail: () => void;
  children: React.ReactNode;
}

export function TaskContextMenu({
  task,
  projects,
  onOpenDetail,
  children,
}: TaskContextMenuProps) {
  const qc = useQueryClient();
  const refetch = () => {
    void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
    void qc.invalidateQueries({ queryKey: ["todo-task-detail"] });
  };

  // 标签数据（打开「修改标签」子菜单时懒加载）
  const [labels, setLabels] = useState<TodoLabel[] | null>(null);
  const [linkedRows, setLinkedRows] = useState<TodoTaskLabel[]>([]);

  // 菜单内触发的二级对话框
  const [dueOpen, setDueOpen] = useState(false);
  const [dueDraft, setDueDraft] = useState("");
  const [reminderOpen, setReminderOpen] = useState(false);
  const [reminderDraft, setReminderDraft] = useState("");
  const [reminderError, setReminderError] = useState<string | null>(null);
  const [commentOpen, setCommentOpen] = useState(false);
  const [commentDraft, setCommentDraft] = useState("");
  const [deleteOpen, setDeleteOpen] = useState(false);

  const patch = (p: Parameters<typeof todoTaskUpdate>[1]) =>
    todoTaskUpdate(task.id, p).then(refetch);

  const loadLabels = async () => {
    try {
      const [all, links] = await Promise.all([
        todoLabelList({ page: 1, page_size: 1000 }),
        todoTaskLabelList({ page: 1, page_size: 1000 }),
      ]);
      setLabels(all.filter((l) => !l.is_deleted));
      setLinkedRows(links.filter((l) => l.task_id === task.id && !l.is_deleted));
    } catch {
      toast.error("标签加载失败");
    }
  };

  const toggleLabel = async (labelId: number) => {
    const match = linkedRows.find((r) => r.label_id === labelId);
    if (match) {
      // 乐观移除，失败回滚由 refetch 兜底
      setLinkedRows((rows) => rows.filter((r) => r.label_id !== labelId));
      await todoTaskLabelDelete(match.id);
    } else {
      const row = await todoTaskLabelCreate({ task_id: task.id, label_id: labelId });
      setLinkedRows((rows) => [...rows, row]);
    }
    refetch();
  };

  const saveDue = (close: () => void) => {
    const raw = dueDraft.trim();
    if (!raw) return;
    const ts = new Date(raw.replace(" ", "T")).getTime();
    if (Number.isNaN(ts)) return;
    void patch({ due_date: ts });
    setDueOpen(false);
    close();
  };

  return (
    <>
      <ContextMenuBase
        menu={(close) => (
          <>
            <DropdownMenuItem onSelect={() => { close(); onOpenDetail(); }}>
              <Eye size={14} />
              打开详情
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() => {
                close();
                void patch(
                  task.done
                    ? { done: 0, done_at: null, status: "pending" }
                    : { done: 1, done_at: Date.now(), status: "done" },
                );
              }}
            >
              <Check size={14} />
              {task.done ? "标记未完成" : "标记完成"}
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() => {
                close();
                void patch({ is_favorite: task.is_favorite ? 0 : 1 });
              }}
            >
              <Star
                size={14}
                className={cn(task.is_favorite && "fill-current")}
                style={task.is_favorite ? { color: FAVORITE_COLOR } : undefined}
              />
              {task.is_favorite ? "取消收藏" : "收藏"}
            </DropdownMenuItem>

            <DropdownMenuSeparator />

            {/* 设置优先级（6 档色点） */}
            <DropdownMenuSub>
              <DropdownMenuSubTrigger>
                <Flag size={14} />
                设置优先级
              </DropdownMenuSubTrigger>
              <DropdownMenuSubContent className="min-w-[160px]">
                {PRIORITY_LABELS.map((label, lv) => (
                  <DropdownMenuItem
                    key={lv}
                    disabled={task.priority === lv}
                    className={cn(task.priority === lv && "font-medium text-accent-foreground")}
                    onSelect={() => { close(); void patch({ priority: lv }); }}
                  >
                    {lv > 0 && (
                      <span
                        className="mr-1 inline-block h-2 w-2 shrink-0 rounded-full"
                        style={{ backgroundColor: PRIORITY_COLOR[lv] }}
                      />
                    )}
                    {label}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuSubContent>
            </DropdownMenuSub>

            {/* 修改标签（勾选切换；子菜单展开时懒加载） */}
            <DropdownMenuSub onOpenChange={(o) => o && void loadLabels()}>
              <DropdownMenuSubTrigger>
                <Tag size={14} />
                修改标签
              </DropdownMenuSubTrigger>
              <DropdownMenuSubContent className="min-w-[180px]">
                {!labels ? (
                  <div className="px-2 py-1.5 text-xs text-muted-foreground">加载中…</div>
                ) : labels.length === 0 ? (
                  <div className="px-2 py-1.5 text-xs text-muted-foreground">暂无标签</div>
                ) : (
                  labels.map((label) => {
                    const checked = linkedRows.some((r) => r.label_id === label.id);
                    return (
                      <DropdownMenuItem
                        key={label.id}
                        onSelect={() => void toggleLabel(label.id)}
                      >
                        <span
                          className={cn(
                            "inline-block h-2.5 w-2.5 shrink-0 rounded-full",
                            checked && "ring-2 ring-primary ring-offset-1 ring-offset-popover",
                          )}
                          style={{ background: label.hex_color }}
                        />
                        <span className="min-w-0 flex-1 truncate">{label.title}</span>
                        {checked && <Check size={13} className="text-primary" />}
                      </DropdownMenuItem>
                    );
                  })
                )}
              </DropdownMenuSubContent>
            </DropdownMenuSub>

            {/* 更换项目 */}
            <DropdownMenuSub>
              <DropdownMenuSubTrigger>
                <Folder size={14} />
                更换项目
              </DropdownMenuSubTrigger>
              <DropdownMenuSubContent className="min-w-[180px]">
                <DropdownMenuItem
                  disabled={task.project_id == null}
                  className={cn(task.project_id == null && "font-medium text-accent-foreground")}
                  onSelect={() => { close(); void patch({ project_id: null }); }}
                >
                  <FolderOpen size={13} />
                  未分组
                </DropdownMenuItem>
                {projects.map((p) => (
                  <DropdownMenuItem
                    key={p.id}
                    disabled={task.project_id === p.id}
                    className={cn(
                      task.project_id === p.id && "font-medium text-accent-foreground",
                    )}
                    onSelect={() => { close(); void patch({ project_id: p.id }); }}
                  >
                    <span
                      className="size-2.5 shrink-0 rounded-sm"
                      style={{ background: p.hex_color || TODO_ACCENT }}
                    />
                    {p.title}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuSubContent>
            </DropdownMenuSub>

            {/* 设置截止时间（Popover 内嵌 DateTimePicker） */}
            <Popover
              open={dueOpen}
              onOpenChange={(o) => {
                if (o) setDueDraft(task.due_date != null ? tsToInputValue(task.due_date) : "");
                setDueOpen(o);
              }}
            >
              <PopoverTrigger asChild>
                <DropdownMenuItem onSelect={(e) => e.preventDefault()}>
                  <Calendar size={14} />
                  设置截止时间
                </DropdownMenuItem>
              </PopoverTrigger>
              <PopoverContent
                side="right"
                align="start"
                className="w-auto p-3"
                onOpenAutoFocus={(e) => e.preventDefault()}
              >
                <DateTimePicker value={dueDraft} onChange={setDueDraft} />
                <div className="mt-3 flex justify-end gap-2">
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => {
                      void patch({ due_date: null });
                      setDueOpen(false);
                      close();
                    }}
                  >
                    清除
                  </Button>
                  <Button variant="outline" size="sm" onClick={() => setDueOpen(false)}>
                    取消
                  </Button>
                  <Button size="sm" disabled={!dueDraft.trim()} onClick={() => saveDue(close)}>
                    确定
                  </Button>
                </div>
              </PopoverContent>
            </Popover>

            <DropdownMenuItem onSelect={() => { close(); setReminderOpen(true); }}>
              <Clock size={14} />
              设置提醒
            </DropdownMenuItem>
            <DropdownMenuItem onSelect={() => { close(); setCommentOpen(true); }}>
              <MessageSquare size={14} />
              添加评论
            </DropdownMenuItem>

            <DropdownMenuSeparator />
            <DropdownMenuItem variant="destructive" onSelect={() => { close(); setDeleteOpen(true); }}>
              <Trash2 size={14} />
              删除
            </DropdownMenuItem>
          </>
        )}
      >
        {children}
      </ContextMenuBase>

      {/* 设置提醒（⚖① 统一用自有 DateTimePicker） */}
      <Dialog open={reminderOpen} onOpenChange={setReminderOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>设置提醒 · {task.title}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <p className="text-sm text-muted-foreground">提醒时间：</p>
            <DateTimePicker
              value={reminderDraft}
              onChange={(v) => {
                setReminderDraft(v);
                setReminderError(null);
              }}
            />
            {reminderError && <p className="text-xs text-destructive">{reminderError}</p>}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setReminderOpen(false)}>取消</Button>
            <Button
              disabled={!reminderDraft.trim()}
              onClick={() => {
                const ms = new Date(reminderDraft.replace(" ", "T")).getTime();
                if (Number.isNaN(ms)) {
                  setReminderError("时间格式不正确");
                  return;
                }
                void todoReminderCreate({ task_id: task.id, remind_at: ms }).then(() => {
                  toast.success("提醒已创建");
                  refetch();
                });
                setReminderOpen(false);
                setReminderDraft("");
              }}
            >
              保存
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* 添加评论（max-w-sm + Textarea） */}
      <Dialog open={commentOpen} onOpenChange={setCommentOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>添加评论 · {task.title}</DialogTitle>
          </DialogHeader>
          <Textarea
            rows={4}
            autoFocus
            value={commentDraft}
            placeholder="输入评论..."
            onChange={(e) => setCommentDraft(e.target.value)}
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setCommentOpen(false)}>取消</Button>
            <Button
              disabled={!commentDraft.trim()}
              onClick={() => {
                void todoCommentCreate({ task_id: task.id, content: commentDraft.trim() }).then(refetch);
                setCommentOpen(false);
                setCommentDraft("");
              }}
            >
              保存
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* 删除确认 */}
      <AlertDialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>删除待办</AlertDialogTitle>
            <AlertDialogDescription>
              确定要删除「{task.title}」吗？此操作无法撤销。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => { void todoTaskDelete(task.id).then(refetch); }}
            >
              删除
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

/* ================= 项目菜单 ================= */

export function ProjectContextMenu({
  projectTitle,
  onRequestDelete,
  children,
}: {
  /** 菜单顶部标题头（wait-home：项目名灰字行） */
  projectTitle: string;
  /** 上报删除请求；删除保护（未完成任务拦截）由父级弹窗处理 */
  onRequestDelete: () => void;
  children: React.ReactNode;
}) {
  return (
    <ContextMenuBase
      menu={(close) => (
        <>
          <DropdownMenuLabel className="px-2 py-1.5 text-xs font-normal text-muted-foreground">
            {projectTitle}
          </DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            variant="destructive"
            onSelect={() => { close(); onRequestDelete(); }}
          >
            <Trash2 size={14} />
            删除项目
          </DropdownMenuItem>
        </>
      )}
    >
      {children}
    </ContextMenuBase>
  );
}
