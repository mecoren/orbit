/**
 * 未使用附件清理弹窗的选中态纯函数（可单测，不依赖 DOM）
 *
 * 口径与 core `list_unused_attachments` 一致：以 hash 为唯一键（内容寻址，
 * 同一 hash 在清单里只会出现一次）。
 */
import type { UnusedAttachmentView } from "@/lib/tauri";

export interface SelectionSummary {
  /** 已勾选条数 */
  count: number;
  /** 已勾选体积合计（字节） */
  bytes: number;
  /** 是否已全选（清单为空时视为未全选，避免全选框误显示勾中） */
  allSelected: boolean;
}

export function summarizeSelection(
  items: readonly UnusedAttachmentView[],
  selected: ReadonlySet<string>,
): SelectionSummary {
  let count = 0;
  let bytes = 0;
  for (const item of items) {
    if (!selected.has(item.hash)) continue;
    count += 1;
    bytes += item.size_bytes;
  }
  return { count, bytes, allSelected: items.length > 0 && count === items.length };
}

/** 全选/取消全选：全选态点击清空，否则勾选全部 */
export function toggleAll(
  items: readonly UnusedAttachmentView[],
  selected: ReadonlySet<string>,
): Set<string> {
  const allSelected = items.length > 0 && items.every((i) => selected.has(i.hash));
  return allSelected ? new Set<string>() : new Set(items.map((i) => i.hash));
}

/** 显示名：账本没有原始文件名时用 hash 前 12 位兜底 */
export function attachmentLabel(item: UnusedAttachmentView): string {
  const name = item.original_name.trim();
  return name.length > 0 ? name : `${item.hash.slice(0, 12)}…`;
}
