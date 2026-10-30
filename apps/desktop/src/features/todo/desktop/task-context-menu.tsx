/**
 * 任务/项目右键菜单（04 文档 §3.7：菜单项集合与文案对齐 wait-home）
 *
 * 任务菜单（2026-10-10 顶部高频段图标行化，对标 TickTick）：
 *   日期▸图标行(今天/明天/+7天/日历Dialog/清除) / 优先级▸旗标图标行(6档) / ─ /
 *   打开详情 / 标记完成·标记未完成 / 收藏·取消收藏 / 我的一天 / 复制任务 /
 *   修改标签▸(勾选切换) / 更换项目▸ / 设置提醒(Dialog) /
 *   添加评论(Dialog,Textarea) / 多选(可选,仅多选态视图传入) / ─ / 删除
 * 项目菜单：项目名标题头 + 编辑项目（重命名/改色，#36）+ 归档（点击不关菜单，
 * 原地展开确认区）+ 删除项目（destructive；删除保护由父级弹窗处理）
 */
import { useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { format } from "date-fns";
import {
  Archive,
  CalendarClock,
  CalendarDays,
  CalendarX,
  Check,
  Clock,
  Copy,
  Eye,
  Flag,
  Folder,
  FolderOpen,
  ListChecks,
  MessageSquare,
  Moon,
  Pencil,
  Star,
  Sunrise,
  Tag,
  Trash2,
  type LucideIcon,
} from "lucide-react";
import { toast } from "sonner";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
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
import { hideFromQueries, useUndoableDeleteAction } from "@/hooks/use-undoable-delete";
import {
  todoTaskDuplicate,
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
  type TodoTaskListItem,
  type TodoTaskLabel,
} from "@/lib/tauri";
import { PRIORITY_COLOR, FAVORITE_COLOR, TODO_ACCENT, PRIORITY_LABELS, MY_DAY_COLOR } from "../shared/constants";
import { buildQuickDateTimeOptions, reminderEndMs } from "@/lib/quick-dates";
import { todayStartMs, toggleMyDayValue } from "../shared/task-filters";
import { completeTask } from "../shared/task-actions";


/** ms → DateTimePicker 值格式（YYYY-MM-DDTHH:MM） */
const tsToInputValue = (ms: number) => format(new Date(ms), "yyyy-MM-dd'T'HH:mm");

interface TaskContextMenuProps {
  /** 列表行（A2 瘦行）：菜单只读留下的列（due_date/start_date/my_day_date/
   *  project_id/priority/is_favorite/done），不需要 uuid / repeat 细节 */
  task: TodoTaskListItem;
  projects: TodoProject[];
  /** 打开详情抽屉（§7-③ selectedTaskId） */
  onOpenDetail: () => void;
  /** 传入时渲染「多选」项：进入多选态并选中当前行（列表/看板传入；日历等无批量态视图不传） */
  onStartSelect?: () => void;
  children: React.ReactNode;
}

export function TaskContextMenu({
  task,
  projects,
  onOpenDetail,
  onStartSelect,
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
  const [dueError, setDueError] = useState<string | null>(null);
  const [reminderOpen, setReminderOpen] = useState(false);
  const [reminderDraft, setReminderDraft] = useState("");
  const [reminderError, setReminderError] = useState<string | null>(null);
  const [commentOpen, setCommentOpen] = useState(false);
  const [commentDraft, setCommentDraft] = useState("");
  // 评论输入框：Dialog onOpenAutoFocus 接管聚焦（autoFocus 错过 open 时机）
  const commentTextareaRef = useRef<HTMLTextAreaElement>(null);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const undoableDelete = useUndoableDeleteAction();
  /**
   * 行内菜单的常驻开销治理（2026-10-30 滚动流畅度）：本组件挂在每个列表行/
   * 看板卡上，虚拟化滚动会逐帧重建可视行——此前连带把「5 个 Radix Dialog 根
   * + 快捷日期档数组」一起重建，单帧脚本耗时翻倍。改为：快捷档数组只在菜单
   * 打开时构造，四个二级 Dialog 在**首次右键打开后**才挂载（此前的行只留
   * 菜单事件壳）。
   */
  const [dialogsMounted, setDialogsMounted] = useState(false);

  const patch = (p: Parameters<typeof todoTaskUpdate>[1]) =>
    todoTaskUpdate(task.id, p).then(refetch);

  // 我的一天「今天」判定：与 task-filters / 行内按钮同口径（本地零点）
  const inMyDay = task.my_day_date === todayStartMs();

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

  const saveDue = () => {
    const raw = dueDraft.trim();
    if (!raw) return;
    const ts = new Date(raw.replace(" ", "T")).getTime();
    if (Number.isNaN(ts)) {
      setDueError("时间格式不正确");
      return;
    }
    void patch({ due_date: ts });
    setDueOpen(false);
  };

  /** 图标按快捷档语义分派：一小时后=Clock、今晚=Moon、明天=Sunrise、下周=CalendarClock */
  const quickDateIcon = (key: string): LucideIcon =>
    key === "in1h" ? Clock : key === "tonight" ? Moon : key === "tomorrow" ? Sunrise : CalendarClock;

  // 日期图标行（对标 TickTick 右键菜单顶部段）：快捷档复用 buildQuickDateTimeOptions
  // （一小时后/今天晚些时候/明天 09:00/下周一 09:00，目标为绝对时刻直接落库、
  // 不做保时刻换算；已过 22:00 自动隐藏今晚档）；「选择日期和时间」点击直接弹
  // DateTimePicker Dialog；末位清除钮写 null。
  // 只在菜单打开时求值（见 dialogsMounted 注释）：关闭态每帧重建这组 Date 对象
  // 是纯浪费。
  const buildDateIcons = (): { key: string; label: string; Icon: LucideIcon; run: () => void }[] => [
    ...buildQuickDateTimeOptions().map((o) => ({
      key: o.key,
      label: `${o.label}（${o.hint}）`,
      Icon: quickDateIcon(o.key),
      run: () => void patch({ due_date: o.value.getTime() }),
    })),
    {
      key: "picker",
      label: "选择日期和时间",
      Icon: CalendarDays,
      run: () => {
        setDueDraft(task.due_date != null ? tsToInputValue(task.due_date) : "");
        setDueError(null);
        setDueOpen(true);
      },
    },
    { key: "clear", label: "清除截止", Icon: CalendarX, run: () => void patch({ due_date: null }) },
  ];

  return (
    <>
      <ContextMenuBase
        onOpenChange={(open) => {
          if (open) setDialogsMounted(true);
        }}
        menu={(close) => (
          <>
            {/* 日期图标行（对标 TickTick 右键菜单顶部段）：快捷档 + 选择日期和时间
                （直接弹 Dialog）+ 清除。 */}
            <DropdownMenuLabel className="px-2 py-1 text-xs font-normal text-muted-foreground">
              日期
            </DropdownMenuLabel>
            <div className="flex items-center gap-0.5 px-1 pb-1">
              {buildDateIcons().map(({ key, label, Icon, run }) => (
                <Tooltip key={key}>
                  <TooltipTrigger asChild>
                    <button
                      type="button"
                      aria-label={label}
                      className="flex size-8 items-center justify-center rounded-md text-foreground/80 transition-colors hover:bg-accent hover:text-accent-foreground"
                      onClick={() => {
                        close();
                        run();
                      }}
                    >
                      <Icon size={16} />
                    </button>
                  </TooltipTrigger>
                  <TooltipContent>{label}</TooltipContent>
                </Tooltip>
              ))}
            </div>

            {/* 优先级图标行（对标 TickTick）：6 档旗标色点，当前档高亮底；点选即改 */}
            <DropdownMenuLabel className="px-2 py-1 text-xs font-normal text-muted-foreground">
              优先级
            </DropdownMenuLabel>
            <div className="flex items-center gap-0.5 px-1 pb-1">
              {PRIORITY_LABELS.map((label, lv) => (
                <Tooltip key={lv}>
                  <TooltipTrigger asChild>
                    <button
                      type="button"
                      aria-label={`优先级：${label}`}
                      aria-pressed={task.priority === lv}
                      className={cn(
                        "flex size-8 items-center justify-center rounded-md transition-colors hover:bg-accent",
                        task.priority === lv && "bg-accent",
                      )}
                      onClick={() => {
                        close();
                        void patch({ priority: lv });
                      }}
                    >
                      <Flag
                        size={16}
                        style={{ color: PRIORITY_COLOR[lv] }}
                        className={cn(lv > 0 && "fill-current")}
                      />
                    </button>
                  </TooltipTrigger>
                  <TooltipContent>{label}</TooltipContent>
                </Tooltip>
              ))}
            </div>

            <DropdownMenuSeparator />
            <DropdownMenuItem onSelect={() => { close(); onOpenDetail(); }}>
              <Eye size={14} />
              打开详情
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() => {
                close();
                void completeTask(task, qc);
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
            <DropdownMenuItem
              onSelect={() => {
                close();
                void patch({ my_day_date: toggleMyDayValue(task.my_day_date) });
              }}
            >
              <Sunrise
                size={14}
                style={{ color: inMyDay ? MY_DAY_COLOR : undefined }}
              />
              {inMyDay ? "移出我的一天" : "加入我的一天"}
            </DropdownMenuItem>

            <DropdownMenuItem
              onSelect={() => {
                close();
                void (async () => {
                  try {
                    const copy = await todoTaskDuplicate(task.id);
                    toast.success(`已复制为「${copy.title}」`);
                  } catch (e) {
                    toast.error(`复制失败：${e}`);
                  }
                })();
              }}
            >
              <Copy size={14} />
              复制任务
            </DropdownMenuItem>

            <DropdownMenuSeparator />

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
                        <span className="flex w-4 shrink-0 items-center justify-center">
                          <span
                            className={cn(
                              "h-2.5 w-2.5 rounded-full",
                              checked && "ring-2 ring-primary ring-offset-1 ring-offset-popover",
                            )}
                            style={{ background: label.hex_color }}
                          />
                        </span>
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
                    {/* #36：项目名按项目色着字（与其他选择位统一），去色点 */}
                    <span className="truncate" style={{ color: p.hex_color || TODO_ACCENT }}>
                      {p.title}
                    </span>
                  </DropdownMenuItem>
                ))}
              </DropdownMenuSubContent>
            </DropdownMenuSub>

            {/* 设置提醒（顶部日期图标行的日历档已承担「选日期」；精确时刻仍走此 Dialog） */}
            <DropdownMenuItem onSelect={() => { close(); setReminderOpen(true); }}>
              <Clock size={14} />
              设置提醒
            </DropdownMenuItem>
            <DropdownMenuItem onSelect={() => { close(); setCommentOpen(true); }}>
              <MessageSquare size={14} />
              添加评论
            </DropdownMenuItem>

            {/* 多选（可选）：进入多选态并选中当前行；多选勾选框已默认隐藏，
                此处是列表/看板唯一的批量态入口 */}
            {onStartSelect && (
              <DropdownMenuItem onSelect={() => { close(); onStartSelect(); }}>
                <ListChecks size={14} />
                多选
              </DropdownMenuItem>
            )}

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

      {/* 二级 Dialog 只在首次打开菜单后挂载：关闭态零 Radix Dialog 根 */}
      {dialogsMounted && (
        <>
          {/* 设置截止时间（与设置提醒同构：Dialog + DateTimePicker，含清除） */}
          <Dialog open={dueOpen} onOpenChange={setDueOpen}>
            <DialogContent className="max-w-sm">
              <DialogHeader>
                <DialogTitle>设置截止时间 · {task.title}</DialogTitle>
              </DialogHeader>
              <div className="space-y-3">
                <p className="text-sm text-muted-foreground">截止时间：</p>
                <DateTimePicker
                  value={dueDraft}
                  onChange={(v) => {
                    setDueDraft(v);
                    setDueError(null);
                  }}
                />
                {dueError && <p className="text-xs text-destructive">{dueError}</p>}
              </div>
              <DialogFooter>
                <Button
                  variant="ghost"
                  onClick={() => {
                    void patch({ due_date: null });
                    setDueOpen(false);
                  }}
                >
                  清除
                </Button>
                <Button variant="outline" onClick={() => setDueOpen(false)}>取消</Button>
                <Button disabled={!dueDraft.trim()} onClick={saveDue}>
                  确定
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>

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
                  dueDateMs={task.due_date}
                  endMs={reminderEndMs({
                    start_date: task.start_date,
                    due_date: task.due_date,
                    duration_minutes: task.duration_minutes,
                  })}
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
            {/* 打开即聚焦输入框：Dialog 常驻渲染、open 切换显隐，React autoFocus
                只在挂载时生效会错过打开时机，且 Radix 默认把焦点给首个可聚焦元素
                （关闭钮）——onOpenAutoFocus 接管， preventDefault 后手动聚焦 */}
            <DialogContent
              className="max-w-sm"
              onOpenAutoFocus={(e) => {
                e.preventDefault();
                commentTextareaRef.current?.focus();
              }}
            >
              <DialogHeader>
                <DialogTitle>添加评论 · {task.title}</DialogTitle>
              </DialogHeader>
              <Textarea
                ref={commentTextareaRef}
                value={commentDraft}
                placeholder="输入评论..."
                // 固定高度（原语 field-sizing-content 会随输入无限增高）：超出走内部滚动
                className="min-h-40 max-h-40 resize-none overflow-y-auto"
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

          {/* 删除确认（P0：确认后进入 5s 撤销窗口，非立即落库） */}
          <AlertDialog open={deleteOpen} onOpenChange={setDeleteOpen}>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>删除待办</AlertDialogTitle>
                <AlertDialogDescription>
                  确定要删除「{task.title}」吗？删除后 5 秒内可撤销，之后将移入回收站。
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>取消</AlertDialogCancel>
                <AlertDialogAction
                  className="bg-destructive text-white hover:bg-destructive/90"
                  onClick={() => {
                    setDeleteOpen(false);
                    undoableDelete({
                      entityLabel: "任务",
                      recordName: task.title,
                      commit: () => todoTaskDelete(task.id),
                      hide: (qc) => hideFromQueries(qc, ["todo_tasks"], task.id),
                    });
                  }}
                >
                  删除
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        </>
      )}
    </>
  );
}

/* ================= 项目菜单 ================= */

export function ProjectContextMenu({
  project,
  undoneCount,
  onRequestEdit,
  onRequestArchive,
  onConfirmDelete,
  children,
}: {
  project: TodoProject;
  /** 未完成任务数：> 0 时删除确认区只告知不可删（原删除保护口径） */
  undoneCount: number;
  /** 上报编辑请求（重命名/改色）；对话框由父级统一渲染 */
  onRequestEdit: () => void;
  /** 确认归档后上报；is_archived 翻转由父级按 project.is_archived 判定 */
  onRequestArchive: () => void;
  /** 确认删除后直接执行（撤销窗口软删由父级负责） */
  onConfirmDelete: () => void;
  children: React.ReactNode;
}) {
  // 菜单内联确认：归档 / 删除都在原位置展开，不收起菜单——先收菜单再弹
  // 外部小窗会让菜单「缩进去」一下（视觉跳变），且两次点击的锚点会漂移。
  // pending 同时充当互斥锁：展开一项时另一项回到普通菜单项。
  const [pending, setPending] = useState<"archive" | "delete" | null>(null);

  return (
    <ContextMenuBase
      onOpenChange={(open) => {
        if (!open) setPending(null);
      }}
      menu={(close) => (
        <>
          <DropdownMenuLabel className="max-w-[240px] truncate px-2 py-1.5 text-xs font-normal text-muted-foreground">
            {project.title}
          </DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            onSelect={() => { close(); onRequestEdit(); }}
          >
            <Pencil size={14} />
            编辑项目
          </DropdownMenuItem>
          {pending === "archive" ? (
            <div className="px-3 pb-2.5 pt-1.5">
              <p className="max-w-[240px] text-xs font-semibold">
                确定要归档「{project.title}」吗？
              </p>
              <p className="mt-1 max-w-[240px] text-[10px] leading-relaxed text-muted-foreground">
                归档后项目从列表收起，可在「已归档」中恢复。
              </p>
              <div className="mt-2 flex justify-end gap-1">
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-7 px-2.5 text-xs"
                  onClick={() => setPending(null)}
                >
                  取消
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="h-7 px-2.5 text-xs text-primary hover:bg-primary/10 hover:text-primary"
                  onClick={() => {
                    close();
                    onRequestArchive();
                  }}
                >
                  归档
                </Button>
              </div>
            </div>
          ) : (
            <DropdownMenuItem
              onSelect={(event) => {
                // preventDefault：Radix 默认选中即关菜单，这里要让确认区留在原处
                event.preventDefault();
                setPending("archive");
              }}
            >
              <Archive size={14} />
              {project.is_archived ? "取消归档" : "归档项目"}
            </DropdownMenuItem>
          )}
          {pending === "delete" ? (
            <div className="px-3 pb-2.5 pt-1.5">
              {undoneCount > 0 ? (
                <>
                  {/* 删除保护：未完成任务拦截（原居中弹窗口径，不提供确认按钮） */}
                  <p className="text-xs font-semibold">无法删除</p>
                  <p className="mt-1 max-w-[240px] text-[10px] leading-relaxed text-muted-foreground">
                    该项目下还有 {undoneCount} 条未完成任务，请先清空或移走任务后再删除。
                  </p>
                  <div className="mt-2 flex justify-end">
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="h-7 px-2.5 text-xs"
                      onClick={() => setPending(null)}
                    >
                      我知道了
                    </Button>
                  </div>
                </>
              ) : (
                <>
                  <p className="max-w-[240px] break-words text-xs font-semibold">
                    确定要删除项目「{project.title}」吗？
                  </p>
                  <p className="mt-1 max-w-[240px] text-[10px] leading-relaxed text-muted-foreground">
                    删除后 5 秒内可撤销。
                  </p>
                  <div className="mt-2 flex justify-end gap-1">
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="h-7 px-2.5 text-xs"
                      onClick={() => setPending(null)}
                    >
                      取消
                    </Button>
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="h-7 px-2.5 text-xs text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => {
                        close();
                        onConfirmDelete();
                      }}
                    >
                      删除
                    </Button>
                  </div>
                </>
              )}
            </div>
          ) : (
            <DropdownMenuItem
              variant="destructive"
              onSelect={(event) => {
                event.preventDefault();
                setPending("delete");
              }}
            >
              <Trash2 size={14} />
              删除项目
            </DropdownMenuItem>
          )}
        </>
      )}
    >
      {children}
    </ContextMenuBase>
  );
}
