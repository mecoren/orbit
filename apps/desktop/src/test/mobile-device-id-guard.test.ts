/**
 * 移动端云同步桥 device_id 前置校验护栏。
 *
 * 背景（2026-11-14）：BootGate 在 fake_async 下不 await device_id 写入，启动期
 * 失败时 OnceCell 为空。此前 sync.rs 四处用
 * `context::get_device_id().unwrap_or_default()` 回落空串：generic_repo 会跳过
 * Lamport 版本号写入，深层 validate_config 只丢一句「device_id 不能为空」，
 * 用户无从区分「启动接线失败」与「配置填错」。第四批只修了 cloud_sync_now /
 * cloud_sync_force 两条入口，rekey / v2 改密 / 升级 v2 仍会带着空 device_id
 * 做云端全量重传。
 *
 * 现在统一由 engine_config_of_record 在构造 SyncConfig 时取 current_device_id()?，
 * 所有云端入口都在本机状态变更/云端写入之前经过它；v1 改密只换本机包装、
 * 不构造 SyncConfig，故不被拦。这里锁住「没有静默回落」与「每个调用点都传播 ?」，
 * 防止后续改签名时漏掉一条入口。
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.join(import.meta.dirname, "../../../..");
const SRC = readFileSync(
  path.join(ROOT, "crates/orbit-flutter/src/api/sync.rs"),
  "utf8",
);

describe("移动端同步桥不得静默降级 device_id", () => {
  it("不再用 unwrap_or_default 回落空 device_id", () => {
    expect(SRC).not.toContain("context::get_device_id().unwrap_or_default()");
  });

  it("engine_config_of_record 统一取 current_device_id()? 并返回 Result", () => {
    const start = SRC.indexOf("fn engine_config_of_record(");
    const end = SRC.indexOf("/// 附件目录", start);
    expect(start).toBeGreaterThan(0);
    const body = SRC.slice(start, end);
    expect(body).toContain(
      "Result<Option<orbit_core::sync::engine::SyncConfig>, String>",
    );
    expect(body).toContain("let device_id = current_device_id()?;");
  });

  it("所有 engine_config_of_record 调用点都传播 ?", () => {
    const calls = [...SRC.matchAll(/engine_config_of_record\(&record\)(.)/g)];
    expect(calls.length).toBeGreaterThanOrEqual(8);
    expect(calls.every((m) => m[1] === "?")).toBe(true);
  });

  it("v1 改密分支不被 device_id 校验拦住（不重传云端）", () => {
    const start = SRC.indexOf("pub async fn sync_crypto_change_password(");
    const end = SRC.indexOf("/// 导出 crypto bundle", start);
    expect(start).toBeGreaterThan(0);
    const fn = SRC.slice(start, end);
    const v2 = fn.indexOf("// v2：");
    expect(v2).toBeGreaterThan(0);
    expect(fn.slice(0, v2)).toContain("if !is_v2");
    expect(fn.slice(0, v2)).not.toContain("engine_config_of_record");
    expect(fn.slice(v2)).toContain("engine_config_of_record(&record)?");
  });
});
