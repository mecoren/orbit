/**
 * 云端孤儿附件清理弹窗的纯函数（可单测，不依赖 DOM）
 *
 * 与本地清单（`unused-attachments-selection.ts`）的口径差异：云端行是「对象」，
 * 体积有两个来源——
 * - `cipher_bytes`：上游列举给的长度；WebDAV 分片形态只有目录 mtime，拿不到长度 → 0；
 * - `size_bytes`：本地账本明文体积；账本无该行（他端上传/本端从未下载）→ 0。
 *
 * 展示与汇总统一用 `cloudItemBytes`：密文优先，缺省回退明文，都缺记 0
 * （不显示「0 B」误导用户以为是空文件，UI 层用「体积未知」兜底）。
 */
import type { CloudUnusedAttachmentView } from "@/lib/tauri";

/** 汇总口径的单行体积（字节） */
export function cloudItemBytes(item: CloudUnusedAttachmentView): number {
  return item.cipher_bytes > 0 ? item.cipher_bytes : Math.max(0, item.size_bytes);
}

export interface CloudSelectionSummary {
  /** 已勾选条数 */
  count: number;
  /** 已勾选体积合计（字节，`cloudItemBytes` 口径） */
  bytes: number;
  /** 是否已全选（清单为空时视为未全选） */
  allSelected: boolean;
}

export function summarizeCloudSelection(
  items: readonly CloudUnusedAttachmentView[],
  selected: ReadonlySet<string>,
): CloudSelectionSummary {
  let count = 0;
  let bytes = 0;
  for (const item of items) {
    if (!selected.has(item.hash)) continue;
    count += 1;
    bytes += cloudItemBytes(item);
  }
  return { count, bytes, allSelected: items.length > 0 && count === items.length };
}

/** 全选/取消全选：全选态点击清空，否则勾选全部 */
export function toggleAllCloud(
  items: readonly CloudUnusedAttachmentView[],
  selected: ReadonlySet<string>,
): Set<string> {
  const allSelected = items.length > 0 && items.every((i) => selected.has(i.hash));
  return allSelected ? new Set<string>() : new Set(items.map((i) => i.hash));
}

/** 显示名：账本没有原始文件名时用 hash 前 12 位兜底 */
export function cloudAttachmentLabel(item: CloudUnusedAttachmentView): string {
  const name = item.original_name.trim();
  return name.length > 0 ? name : `${item.hash.slice(0, 12)}…`;
}

/** 云端形态文案（删除覆盖整包与分片两种布局） */
export function cloudKindLabel(kind: CloudUnusedAttachmentView["kind"]): string {
  if (kind === "chunked") return "分片";
  if (kind === "both") return "整包+分片";
  return "整包";
}

/** 最后写入日期（本地时区，YYYY-MM-DD；服务端未提供 mtime 时不给假时间） */
export function formatCloudLastModified(secs: number): string {
  if (secs <= 0) return "时间未知";
  const d = new Date(secs * 1000);
  const month = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${month}-${day}`;
}
