/**
 * 备份列表展示格式化（云端副本 / 本地历史共用）
 *
 * 后端零值语义：云端 PROPFIND 取不到的属性（部分 WebDAV 服务省略
 * getcontentlength / getlastmodified）以及本地元数据读取失败时，
 * 后端填 0。前端一律展示“未知”而非 1970/0 B，诚实表达缺失。
 */

/** 备份时间展示：Unix 秒 → 本地字符串；<=0 显示“时间未知” */
export function formatBackupTime(modifiedAtSecs: number): string {
  if (!Number.isFinite(modifiedAtSecs) || modifiedAtSecs <= 0) return "时间未知";
  return new Date(modifiedAtSecs * 1000).toLocaleString();
}

/** 备份大小展示：B/KB/MB 阶梯；<=0 显示“大小未知” */
export function formatBackupSize(sizeBytes: number): string {
  if (!Number.isFinite(sizeBytes) || sizeBytes <= 0) return "大小未知";
  if (sizeBytes < 1024) return `${sizeBytes} B`;
  if (sizeBytes < 1024 * 1024) return `${(sizeBytes / 1024).toFixed(1)} KB`;
  return `${(sizeBytes / (1024 * 1024)).toFixed(1)} MB`;
}
