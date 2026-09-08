// apps/desktop/src/components/layout/global-search-dialog.tsx
/**
 * GlobalSearchDialog — 全局搜索（07 报告 §五-P1#9）
 *
 * Ctrl/Cmd+K 打开；输入防抖 250ms 后调用 Rust global_search 跨表聚合
 * （projects/tasks/comments 三组，各限 20 条）。条目 value 携带可检索文本，
 * 交给 cmdk 本地过滤做二次收敛；任务/评论命中写入 selectedTaskId 打开详情
 * 抽屉并回待办页，项目命中跳待办页（页内筛选仍由 list-page 自管）。
 */
import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { CheckSquare, Folder, MessageSquare } from "lucide-react";

import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { useTodoStore } from "@/features/todo/store";
import { globalSearch } from "@/lib/tauri";

interface GlobalSearchDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

/** 输入防抖：停止击键 delayMs 后才更新 */
function useDebouncedValue(value: string, delayMs: number): string {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setDebounced(value), delayMs);
    return () => clearTimeout(id);
  }, [value, delayMs]);
  return debounced;
}

export function GlobalSearchDialog({ open, onOpenChange }: GlobalSearchDialogProps) {
  const navigate = useNavigate();
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const [keyword, setKeyword] = useState("");
  const debounced = useDebouncedValue(keyword.trim(), 250);

  // 关闭即清词，下次打开是干净上下文
  useEffect(() => {
    if (!open) setKeyword("");
  }, [open]);

  const { data, isFetching, isError } = useQuery({
    queryKey: ["global-search", debounced],
    queryFn: () => globalSearch(debounced, 20),
    enabled: open && debounced.length > 0,
    staleTime: 30_000,
    placeholderData: (prev) => prev, // 逐词输入时保留旧结果，避免闪烁（评审 M3）
  });

  const go = (path: string) => {
    navigate(path);
    onOpenChange(false);
  };
  const openTask = (taskId: number) => {
    setSelectedTaskId(taskId);
    go("/todo");
  };

  const tasks = data?.tasks ?? [];
  const projects = data?.projects ?? [];
  const comments = data?.comments ?? [];

  return (
    <CommandDialog open={open} onOpenChange={onOpenChange}>
      <CommandInput
        value={keyword}
        onValueChange={setKeyword}
        placeholder={isFetching ? "搜索中…" : "搜索任务 / 项目 / 评论…"}
        autoFocus
      />
      <CommandList>
        <CommandEmpty>
          {debounced.length === 0
            ? "输入关键词开始搜索"
            : isError
              ? "搜索出错，请重试"
              : isFetching
                ? "搜索中…"
                : "无匹配结果"}
        </CommandEmpty>

        {projects.length > 0 && (
          <CommandGroup heading="项目">
            {projects.map((p) => (
              <CommandItem
                key={p.id}
                value={`项目 ${p.title} ${p.description ?? ""}`}
                onSelect={() => go("/todo")}
              >
                <Folder
                  className="size-4 shrink-0"
                  style={{ color: p.hex_color || undefined }}
                />
                <span className="truncate" style={{ color: p.hex_color || undefined }}>
                  {p.title}
                </span>
              </CommandItem>
            ))}
          </CommandGroup>
        )}

        {tasks.length > 0 && (
          <CommandGroup heading="任务">
            {tasks.map((t) => (
              <CommandItem
                key={t.id}
                value={`任务 ${t.title} ${t.description ?? ""}`}
                onSelect={() => openTask(t.id)}
              >
                <CheckSquare className="size-4 shrink-0 text-muted-foreground" />
                <span className="min-w-0 flex-1 truncate">{t.title}</span>
                {t.done ? (
                  <span className="shrink-0 text-xs text-muted-foreground">已完成</span>
                ) : null}
              </CommandItem>
            ))}
          </CommandGroup>
        )}

        {comments.length > 0 && (
          <CommandGroup heading="评论">
            {comments.map((c) => (
              <CommandItem
                key={c.comment_id}
                value={`评论 ${c.content} ${c.task_title}`}
                onSelect={() => openTask(c.task_id)}
              >
                <MessageSquare className="size-4 shrink-0 text-muted-foreground" />
                <span className="min-w-0 flex-1 truncate">{c.content}</span>
                <span className="shrink-0 text-xs text-muted-foreground">{c.task_title}</span>
              </CommandItem>
            ))}
          </CommandGroup>
        )}
      </CommandList>
    </CommandDialog>
  );
}
