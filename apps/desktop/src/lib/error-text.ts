/**
 * 同步域错误 → 用户文案。
 *
 * Rust 侧错误协议是 `[tag] message`（见 `cloud_sync_cmd::err_tagged` 与
 * `cloud_sync/error.rs::category_tag`）：tag 由 `syncErrorTag` 单独解析做
 * 恢复页 / 解锁 / 升级的路由，展示层只需把它剥掉。
 *
 * `OrbitIpcError` 把命令名保留在 message 尾部，故这里**不**额外处理命令名——
 * toast / 日志仍可定位失败的 command，别再「顺手清理」掉。
 *
 * 抽成共享函数前，`sync-status-button.tsx` 与 `sync-section.tsx` 各有一份
 * 实现，注释口径还相反（一处写「保留 tag」、一处写「去 tag」），极易改错正则。
 */
export function errMsg(err: unknown): string {
  const msg = err instanceof Error ? err.message : String(err);
  return msg.replace(/^\[\w+\]\s*/, "");
}
