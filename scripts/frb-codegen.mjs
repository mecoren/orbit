#!/usr/bin/env node
/**
 * FRB codegen 本地一致性守卫 —— codegen + 生成物 rustfmt + git 差异自检
 *
 * 用法：
 *   pnpm frb      # 等价 CI 的「FRB codegen 一致性校验」，未提交的生成物差异会被判红
 *
 * 为什么需要它：FRB 2.12 的模板固定输出
 * `use flutter_rust_bridge::for_generated::{transform_result_dco, Lifetimeable, Lockable};`，
 * rustfmt 按字典序重排为 `{Lifetimeable, Lockable, transform_result_dco}`。仓库入库存的是
 * 格式化后的版本，于是「改了桥层函数 → 重新 codegen → 漏跑 cargo fmt」必然让 CI 红，而 diff
 * 永远只有两行 use，反复被误判成门禁误报（9b1d28c / 3d95706 / 2026-10-27 4ae05b4 三次）。
 *
 * 只格式化生成物本身、不跑 `cargo fmt --all`：后者会顺手重排 orbit-core 中若干既有的
 * 非 rustfmt-clean 文件，把并发会话的 WIP 混进本批改动（噪音 diff 且可能误伤他人改动）。
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";

const ROOT = path.resolve(import.meta.dirname, "..");

/** 生成物路径：codegen 的唯一产物集合，CI 门禁的比对范围与提交时的 add 范围都以此为准 */
const GENERATED = ["crates/orbit-flutter/src/frb_generated.rs", "apps/mobile/lib/src/rust"];

/** Rust 侧生成物（dart 侧由 codegen 内部调用 dart format，无需二次格式化） */
const GENERATED_RS = "crates/orbit-flutter/src/frb_generated.rs";

const CODEGEN_VERSION_CONST = /FLUTTER_RUST_BRIDGE_CODEGEN_VERSION: &str = "([^"]+)"/;

/** 运行子进程并透传输出；失败即中止（不经 shell，避免转义与 DEP0190 告警） */
function run(cmd, args, { capture = false } = {}) {
  const shown = [cmd, ...args].join(" ");
  console.log(`\n$ ${shown}`);
  const result = spawnSync(cmd, args, {
    cwd: ROOT,
    stdio: capture ? ["ignore", "pipe", "inherit"] : "inherit",
    encoding: "utf8",
  });
  if (result.status !== 0) {
    console.error(`\n命令失败（exit ${result.status ?? "null"}）：${shown}`);
    process.exit(result.status ?? 1);
  }
  return capture ? result.stdout.trim() : "";
}

/** 生成物路径下的 git 状态（含未跟踪文件），空字符串表示与仓库完全一致 */
function gitStatus() {
  const result = spawnSync("git", ["status", "--porcelain", "--", ...GENERATED], {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    console.error("git status 执行失败，请确认在仓库根目录且 git 可用");
    process.exit(1);
  }
  return result.stdout.trim();
}

/** codegen 版本与仓库内生成物记录的版本不一致时提前示警（CI 装的是固定 2.12.0） */
function warnOnVersionDrift() {
  let toolVersion;
  try {
    toolVersion = run("flutter_rust_bridge_codegen", ["--version"], { capture: true });
  } catch {
    toolVersion = "";
  }
  const localVersion = toolVersion.match(/\d+\.\d+\.\d+/)?.[0];
  let recordedVersion;
  try {
    const text = readFileSync(path.join(ROOT, GENERATED_RS), "utf8");
    recordedVersion = text.match(CODEGEN_VERSION_CONST)?.[1];
  } catch {
    recordedVersion = undefined;
  }
  if (localVersion && recordedVersion && localVersion !== recordedVersion) {
    console.warn(
      `\n⚠ 本地 codegen ${localVersion} 与生成物记录的 ${recordedVersion} 不一致：` +
        `CI 固定装 ${recordedVersion}，产物会成片漂移。先执行\n` +
        `  cargo install flutter_rust_bridge_codegen --version ${recordedVersion}\n`,
    );
  }
}

console.log("FRB codegen 一致性自检（codegen → rustfmt 生成物 → git 差异）");

const dirtyBefore = gitStatus();
if (dirtyBefore) {
  console.log("\n注意：生成物在本次运行前已有未提交改动，下列结果以运行后的状态为准");
}

warnOnVersionDrift();

run("flutter_rust_bridge_codegen", [
  "generate",
  "--config-file",
  "crates/orbit-flutter/flutter_rust_bridge.yaml",
]);

// 与 CI 的 `cargo fmt --all` 对生成物的效果等价；edition 等信息取自仓库根 rustfmt.toml
run("rustfmt", [GENERATED_RS]);

const dirtyAfter = gitStatus();
if (dirtyAfter) {
  console.error("\n✗ 生成物与仓库内容不一致（或存在未提交的重新生成结果）：\n");
  console.error(dirtyAfter);
  run("git", [
    "--no-pager",
    "diff",
    "--stat",
    "--",
    ...GENERATED,
  ]);
  console.error(
    "\n请逐文件 add 上述生成物路径后提交（不要用目录通配，会混进并发会话的 WIP）：\n" +
      GENERATED.map((p) => `  git add ${p}`).join("\n"),
  );
  process.exit(1);
}

console.log("\n✓ FRB 生成物与仓库一致（dart 侧 + rust 侧均无差异），可以直接提交/推送");
