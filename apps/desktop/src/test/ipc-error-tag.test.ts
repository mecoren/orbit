/**
 * IPC 错误 `[tag]` 通道回归护栏。
 *
 * 背景：第三批给所有 invoke 加 OrbitIpcError 包装时，message 被改成
 * 「IPC 命令 xxx 失败：[tag] ...」，tag 不再位于字符串开头，
 * `syncErrorTag` 的 /^\[(\w+)\]/ 全线失配 —— key_mismatch 恢复页、
 * cancelled 中性提示、wrong_password 文案、两处 errMsg 清洗同时失效。
 * 与 2026-09-10 的 `[[key_mismatch]]` 双括号事故同型（见
 * crates/orbit-core/src/cloud_sync/error.rs::category_tag 注释）。
 *
 * 这里用行为测试锁住「包装之后 tag 仍可解析」，静态测试另核对 errMsg 口径：
 * 原实现分散在两个组件里各一份、注释还相反，现已抽到 `@/lib/error-text`，
 * 护栏要求两个组件都从共享模块导入，避免再次分叉。
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

import { OrbitIpcError, syncErrorTag } from "@/lib/tauri";
import { syncErrorAction, type SyncErrorAction } from "@/lib/sync-status";
import { errMsg } from "@/lib/error-text";

const TEST_DIR = import.meta.dirname;

const CASES: ReadonlyArray<readonly [string, SyncErrorAction]> = [
  ["key_mismatch", "recovery"],
  ["payload_version", "upgrade"],
  ["not_unlocked", "unlock"],
  ["wrong_password", "none"],
  ["cancelled", "none"],
];

describe("OrbitIpcError 包装不得打断同步域 [tag] 路由", () => {
  for (const [tag, action] of CASES) {
    it(`包装后仍能识别 [${tag}] → ${action}`, () => {
      const err = new OrbitIpcError("cloud_sync_now", `[${tag}] 模拟错误`);
      const parsed = syncErrorTag(err);
      expect(parsed).toBe(tag);
      expect(syncErrorAction(parsed)).toBe(action);
    });
  }

  it("命令名仍可定位，且不得排在 tag 前面", () => {
    const err = new OrbitIpcError(
      "cloud_sync_now",
      "[key_mismatch] 云端密钥不一致",
    );
    expect(err.command).toBe("cloud_sync_now");
    expect(err.message.startsWith("[key_mismatch]")).toBe(true);
    expect(err.message).toContain("cloud_sync_now");
    // 两处 errMsg 的 replace(/^\[\w+\]\s*/, "") 只认开头的 tag
    expect(err.message.replace(/^\[\w+\]\s*/, "")).not.toContain(
      "[key_mismatch]",
    );
  });

  it("reason 是 Error 对象时也能从 message 取 tag", () => {
    const err = new OrbitIpcError(
      "cloud_sync_force",
      new Error("[payload_version] 云端数据由更新版本写出"),
    );
    expect(syncErrorTag(err)).toBe("payload_version");
  });

  it("裸字符串 / 裸 Error / 无 tag 错误保持原有行为", () => {
    expect(syncErrorTag("[cancelled] 已取消")).toBe("cancelled");
    expect(syncErrorTag(new Error("[not_unlocked] 未解锁"))).toBe(
      "not_unlocked",
    );
    expect(syncErrorTag(new Error("普通故障"))).toBeNull();
    expect(syncErrorTag(new OrbitIpcError("db_set_device_id", "写入失败"))).toBeNull();
  });

  it("两处组件共用一份 errMsg 清洗实现，toast 不残留 tag", () => {
    const shared = readFileSync(
      path.join(TEST_DIR, "../lib/error-text.ts"),
      "utf8",
    );
    expect(shared).toContain('msg.replace(/^\\[\\w+\\]\\s*/, "")');
    for (const file of [
      "../components/layout/sync-status-button.tsx",
      "../components/settings/sync-section.tsx",
    ]) {
      const src = readFileSync(path.join(TEST_DIR, file), "utf8");
      expect(src, file).toContain('from "@/lib/error-text"');
    }
    expect(
      errMsg(new OrbitIpcError("cloud_sync_now", "[key_mismatch] 云端密钥不一致")),
    ).not.toContain("[key_mismatch]");
  });
});
