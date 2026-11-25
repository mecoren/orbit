#!/usr/bin/env node
/**
 * 开源组件清单 ↔ 真实直接依赖 一致性门禁（零依赖，秒级）
 *
 * 背景：「关于 → 开源组件」页的数据在 `crates/orbit-core/src/models/oss_components/data.rs`
 * 手工维护（桌面与移动共用）。新增依赖忘补一行时不会让任何测试变红，许可证归属
 * 就这么静默缺项（2026-11-25 盘查：npm 缺 18 条、Rust 缺 31 条，无人发现）。
 *
 * 判定口径：
 * - Frontend = `apps/desktop/package.json` 的 runtime dependencies；
 * - Rust     = 根 workspace / orbit-core / orbit-flutter / desktop 壳 四个 Cargo.toml
 *              的 [dependencies] / [build-dependencies] / [workspace.dependencies]
 *              （不含 dev-dependencies；内部 crate 不进清单）；
 * - Flutter  = `apps/mobile/pubspec.yaml` 的 dependencies（本地 path 包 rust_lib_orbit 除外）。
 *
 * 用法：`node perf-metrics/oss-parity.mjs` 打印差异；`--gate` 有缺项即 exit 1。
 */
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const has = (rel) => fs.existsSync(path.join(ROOT, rel));

/** Cargo.toml 的直接依赖名（deps / build-deps / workspace.deps，含 target 限定段）。 */
function rustDeps(rel) {
  const out = new Set();
  if (!has(rel)) return out;
  let section = "";
  for (const raw of read(rel).split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const sec = /^\[(.+)\]$/.exec(line);
    if (sec) {
      section = sec[1];
      continue;
    }
    if (
      section !== "dependencies" &&
      section !== "build-dependencies" &&
      section !== "workspace.dependencies" &&
      !/\.dependencies$/.test(section)
    ) {
      continue;
    }
    const m = /^([A-Za-z0-9_-]+)\s*=/.exec(line);
    if (m) out.add(m[1]);
  }
  return out;
}

// ---- 已登记条目 ----
const registered = new Map();
const nameOwners = new Map(); // 名称 → 已占用来源（关于页按名称去重，跨来源也不许重名）
const dupNames = [];
for (const m of read("crates/orbit-core/src/models/oss_components/data.rs").matchAll(
  /c\(\s*"([^"]+)",\s*"([^"]+)",\s*S::(\w+)/g,
)) {
  const key = `${m[3]}:${m[1]}`;
  if (registered.has(key)) dupNames.push(key);
  if (nameOwners.has(m[1])) dupNames.push(`${m[1]}（${nameOwners.get(m[1])} + ${m[3]}）`);
  else nameOwners.set(m[1], m[3]);
  registered.set(key, m[2]);
}

// ---- 期望集合 ----
const expected = new Set();
const desktopPkg = JSON.parse(read("apps/desktop/package.json"));
for (const name of Object.keys(desktopPkg.dependencies)) expected.add(`Frontend:${name}`);
// devDependencies 只做「已登记就不算幽灵」的豁免（如 tailwindcss 是构建期组件，
// 关于页列它是刻意的）；**不**要求 devDeps 都进清单，避免测试工具污染归属表。
for (const name of Object.keys(desktopPkg.devDependencies ?? {})) {
  if (registered.has(`Frontend:${name}`)) expected.add(`Frontend:${name}`);
}
const INTERNAL = new Set(["orbit-core", "orbit-flutter"]);
for (const rel of [
  "Cargo.toml",
  "crates/orbit-core/Cargo.toml",
  "crates/orbit-flutter/Cargo.toml",
  "apps/desktop/src-tauri/Cargo.toml",
]) {
  for (const name of rustDeps(rel)) if (!INTERNAL.has(name)) expected.add(`Rust:${name}`);
}
{
  const m = /^dependencies:\s*\n([\s\S]*?)^[A-Za-z]/m.exec(read("apps/mobile/pubspec.yaml"));
  for (const hit of (m?.[1] ?? "").matchAll(/^  ([a-z0-9_]+):/gm)) {
    if (hit[1] === "rust_lib_orbit") continue; // 本地 path 包，不是第三方组件
    expected.add(`Flutter:${hit[1]}`);
  }
}

// ---- 比对 ----
// 同一组件可能同时是 npm 与 crates 依赖（如 flutter_rust_bridge），
// 关于页只展示一条：名称已在**任一**来源登记即视为已归属。
const coveredNames = new Set([...registered.keys()].map((k) => k.slice(k.indexOf(":") + 1)));
const missing = [...expected]
  .filter((k) => !registered.has(k) && !coveredNames.has(k.slice(k.indexOf(":") + 1)))
  .sort();
const unknown = [...registered.keys()].filter((k) => !expected.has(k)).sort();

console.log(`[oss-parity] 清单 ${registered.size} 条 / 直接依赖 ${expected.size} 条`);
if (missing.length) {
  console.log(`\n未登记（新增依赖请补 data.rs，桌面与移动关于页共用）：${missing.length} 条`);
  for (const k of missing) console.log(`  - ${k}`);
}
if (unknown.length) {
  console.log(`\n清单里有、依赖里找不到（可能已删依赖或写错名）：${unknown.length} 条`);
  for (const k of unknown) console.log(`  - ${k}`);
}
if (dupNames.length) {
  console.log(`\n重名条目（关于页按名称展示，同一组件只能登记一次）：${dupNames.length} 条`);
  for (const k of dupNames) console.log(`  - ${k}`);
}

if (missing.length === 0 && unknown.length === 0 && dupNames.length === 0) {
  console.log("\n[oss-parity] 通过：清单与直接依赖一致");
  process.exit(0);
}
if (process.argv.includes("--gate")) process.exit(1);
console.log("\n（未加 --gate，仅提示）");
