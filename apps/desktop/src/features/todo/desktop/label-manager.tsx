/**
 * LabelManager — 标签管理器（04 文档 §3.8 复刻）
 *
 * Dialog(max-w-md)：标签列表 + 10 色预设色板改色（默认选中第 4 色 #3B82F6）+ 增删。
 */
import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Plus, Trash2 } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
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
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { todoLabelCreate, todoLabelDelete, todoLabelList, todoLabelUpdate } from "@/lib/tauri";
import type { TodoLabel } from "@/lib/tauri";
import { PRESET_10 } from "../shared/constants";
import { hideFromQueries, useUndoableDeleteAction } from "@/hooks/use-undoable-delete";


interface LabelManagerProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function LabelManager({ open, onOpenChange }: LabelManagerProps) {
  const qc = useQueryClient();
  const undoableDelete = useUndoableDeleteAction();
  const [labels, setLabels] = useState<TodoLabel[]>([]);
  const [newTitle, setNewTitle] = useState("");
  // 删除确认（标签删除会连带解除所有任务关联，悬停误触代价高）
  const [deleteTarget, setDeleteTarget] = useState<TodoLabel | null>(null);

  const refetch = async () => {
    // 拉全量并刷新共享缓存（与抽屉内 LabelAdder 共用 ["todo-label","list"]）
    const list = await qc.fetchQuery({
      queryKey: ["todo-label", "list"],
      queryFn: () => todoLabelList({ page: 1, page_size: 1000 }),
      staleTime: 0,
    });
    setLabels(list);
    void qc.invalidateQueries({ queryKey: ["todo-label", "list"] });
  };

  useEffect(() => {
    if (open) void refetch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const add = async () => {
    const title = newTitle.trim();
    if (!title) return;
    await todoLabelCreate({ title, hex_color: PRESET_10[3] });
    setNewTitle("");
    void refetch();
  };

  const changeColor = async (label: TodoLabel, hexColor: string) => {
    await todoLabelUpdate(label.id, { hex_color: hexColor });
    void refetch();
  };

  const rename = async (label: TodoLabel, title: string) => {
    const v = title.trim();
    if (!v || v === label.title) return;
    await todoLabelUpdate(label.id, { title: v });
    void refetch();
  };

  const remove = (label: TodoLabel) => {
    // 本地态同步摘除：对话框渲染的是 useState 而非查询缓存，
    // 仅 hideFromQueries 不足以让 chip 即刻消失（审查 I2）；
    // 撤销恢复由 invalidate→重开对话框时的 useEffect 拉取兜底
    setLabels((prev) => prev.filter((l) => l.id !== label.id));
    undoableDelete({
      entityLabel: "标签",
      recordName: label.title,
      commit: () => todoLabelDelete(label.id),
      hide: (qc) => hideFromQueries(qc, ["todo-label"], label.id),
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>标签管理</DialogTitle>
        </DialogHeader>

        <div className="space-y-1">
          {labels.map((l) => (
            <div key={l.id} className="rounded-md border p-2">
              <div className="flex items-center gap-2">
                <span className="size-3 shrink-0 rounded-sm" style={{ background: l.hex_color }} />
                <Input
                  defaultValue={l.title}
                  className="h-7 flex-1 text-[13px]"
                  onBlur={(e) => void rename(l, e.target.value)}
                  onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
                />
                <Button
                  variant="ghost"
                  size="icon"
                  className="h-7 w-7 text-destructive"
                  aria-label={`删除标签 ${l.title}`}
                  onClick={() => setDeleteTarget(l)}
                >
                  <Trash2 size={14} />
                </Button>
              </div>

              {/* 10 色板：编辑态展开 */}
              <div className="mt-2 flex flex-wrap items-center gap-1.5">
                {PRESET_10.map((c) => (
                  <button
                    key={c}
                    type="button"
                    aria-label={`设为 ${c}`}
                    onClick={() => void changeColor(l, c)}
                    className={cn(
                      "size-5 rounded-full border-2 transition-transform hover:scale-110",
                      l.hex_color.toLowerCase() === c.toLowerCase()
                        ? "border-foreground"
                        : "border-transparent",
                    )}
                    style={{ background: c }}
                  />
                ))}
              </div>
            </div>
          ))}
        </div>

        {/* 新增行 */}
        <div className="flex items-center gap-2 border-t pt-3">
          <Input
            value={newTitle}
            placeholder="新标签名称，Enter 创建"
            className="h-8 flex-1"
            onChange={(e) => setNewTitle(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") void add(); }}
          />
          <Button size="sm" disabled={!newTitle.trim()} onClick={() => void add()}>
            <Plus size={14} className="mr-1" />
            新建
          </Button>
        </div>
      </DialogContent>

      {/* 删除确认：标签删除连带解除全部任务关联（不可撤销恢复关联），须确认 */}
      <AlertDialog
        open={deleteTarget != null}
        onOpenChange={(o) => !o && setDeleteTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>删除标签</AlertDialogTitle>
            <AlertDialogDescription className="break-words">
              确定要删除「{deleteTarget?.title}」吗？所有任务与该标签的关联将一并解除。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => {
                if (deleteTarget) void remove(deleteTarget);
                setDeleteTarget(null);
              }}
            >
              删除
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Dialog>
  );
}
