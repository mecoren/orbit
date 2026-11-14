/**
 * device_id 空标识防线护栏（双端 + core）。
 *
 * 背景（2026-11-14）：BootGate 在 fake_async 下不 await device_id 写入，启动期
 * 失败时 OnceCell 为空。此前各处 `context::get_device_id().unwrap_or_default()`
 * 回落空串：空标识会写进云端 manifest.device_id / touch_device() 检查点，
 * 并让 verify_manifest_write() 的 CAS 比对退化成「所有未初始化设备共用一个
 * 标识」。⚠️ 旧注释写「generic_repo 会跳过 Lamport 版本号写入」是**错误口径**：
 * v1 架构已移除 lamport_version 列，版本号由 `version = version + 1` 维护，
 * generic_repo 的 device_id 只用于 DbEvent 来源元数据。
 *
 * 第五批只修了 orbit-flutter/sync.rs 一个文件，第六轮复核发现全仓共 11 处。
 * 现在：core 提供 require_device_id() + push::ensure_device_id 最终防线；
 * 桌面 sync_runtime / 后台调度器 / 两端设备信息查询统一走 helper；仅剩
 * 「DbEvent 事件来源」与「全量备份 manifest 元数据」两处保留空串白名单。
 *
 * 这里锁住：① 同步桥层调用点全部传播 ?；② 全仓静默回落只在白名单；
 * ③ core 的 helper 与最终防线不被删掉。防止后来者改签名时漏一处。
 */
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.join(import.meta.dirname, "../../../..");
const read = (rel: string) => readFileSync(path.join(ROOT, rel), "utf8");
const SRC = read("crates/orbit-flutter/src/api/sync.rs");

/** 递归收集 Rust 源码（跳过构建产物与依赖目录） */
function rustSources(dir: string, out: string[] = []): string[] {
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    if (["target", ".git", "node_modules"].includes(ent.name)) continue;
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) rustSources(p, out);
    else if (ent.name.endsWith(".rs")) out.push(p);
  }
  return out;
}

describe("移动端同步桥不得静默降级 device_id", () => {
  it("同步桥层不再用 unwrap_or_default 回落空 device_id", () => {
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

describe("全仓 device_id 空标识防线", () => {
  it("静默回落只剩事件来源 / 备份元数据两个白名单文件", () => {
    const hits = new Set<string>();
    for (const dir of ["crates", "apps/desktop/src-tauri/src"]) {
      for (const file of rustSources(path.join(ROOT, dir))) {
        if (
          readFileSync(file, "utf8").includes(
            "get_device_id().unwrap_or_default()",
          )
        ) {
          hits.add(path.relative(ROOT, file).replace(/\\/g, "/"));
        }
      }
    }
    expect([...hits].sort()).toEqual([
      "crates/orbit-core/src/api/full_sync_backup_api.rs",
      "crates/orbit-core/src/db/repository/generic_repo.rs",
    ]);
  });

  it("core 统一 helper + push 最终防线 + config 错误通道", () => {
    expect(read("crates/orbit-core/src/context.rs")).toContain(
      "pub fn require_device_id()",
    );
    const push = read("crates/orbit-core/src/cloud_sync/push.rs");
    expect(push).toContain("fn ensure_device_id(device_id: &str)");
    expect(push).toContain("ensure_device_id(device_id)?;");
    const err = read("crates/orbit-core/src/cloud_sync/error.rs");
    expect(err).toContain("Config { message: String }");
    expect(err).toContain('"config"');
  });

  it("桌面壳的同步配置与后台调度改用 helper", () => {
    const runtime = read("apps/desktop/src-tauri/src/commands/sync_runtime.rs");
    expect(runtime).toContain("context::require_device_id()?");
    const scheduler = read("apps/desktop/src-tauri/src/commands/sync_scheduler.rs");
    const calls = [
      ...scheduler.matchAll(/context::require_device_id\(\)/g),
    ];
    expect(calls.length).toBeGreaterThanOrEqual(2);
  });
});
