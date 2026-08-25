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
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { todoLabelCreate, todoLabelDelete, todoLabelList, todoLabelUpdate } from "@/lib/tauri";
import type { TodoLabel } from "@/lib/tauri";
import { hideFromQueries, useUndoableDeleteAction } from "@/hooks/use-undoable-delete";

/** 10 色预设色板（04 §3.8，默认选中第 4 色 #3B82F6） */
const PRESET_COLORS = [
  "#EF4444", "#F59E0B", "#22C55E", "#3B82F6", "#8B5CF6",
  "#EC4899", "#14B8A6", "#F97316", "#6366F1", "#6B7280",
];

interface LabelManagerProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function LabelManager({ open, onOpenChange }: LabelManagerProps) {
  const qc = useQueryClient();
  const undoableDelete = useUndoableDeleteAction();
  const [labels, setLabels] = useState<TodoLabel[]>([]);
  const [newTitle, setNewTitle] = useState("");

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
    await todoLabelCreate({ title, hex_color: PRESET_COLORS[3] });
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
                  onClick={() => void remove(l)}
                >
                  <Trash2 size={14} />
                </Button>
              </div>

              {/* 10 色板：编辑态展开 */}
              <div className="mt-2 flex flex-wrap items-center gap-1.5">
                {PRESET_COLORS.map((c) => (
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
    </Dialog>
  );
}
