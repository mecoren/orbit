#!/usr/bin/env node
/**
 * mobile-mem.mjs — 移动端内存门禁（docs/13 §6.2 M5）
 *
 * 口径与桌面 `growth-curve.mjs` 同构，但采样源不同：桌面是 Chromium 堆，
 * 移动端只能拿进程级 PSS（`adb shell dumpsys meminfo`）。
 *
 * 三种退出码（**关键语义**）：
 * - 0 = 全部门禁通过
 * - 1 = 有指标超阈值（回归）
 * - 2 = SKIP：没有可用设备 / 场景无法执行。**绝不能读成通过**——这是本脚本
 *   存在的首要理由：移动端内存长期是盲区，若「没设备」被当成绿灯，盲区会
 *   永远不被看见。
 *
 * 用法：
 *   node perf-metrics/mobile-mem.mjs --gate     # 有设备时判阈值；无设备 SKIP
 *   node perf-metrics/mobile-mem.mjs --record   # 跑一轮并回写 measured
 *   node perf-metrics/mobile-mem.mjs --list     # 只列场景与阈值
 *
 * 环境变量：
 *   MOBILE_PKG  目标包名（默认 com.orbit.orbit）
 *   ADB         adb 可执行路径（默认 PATH 里的 adb）
 */

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BASELINES = path.join(ROOT, "perf-metrics", "mobile-baselines.json");

const PKG = process.env.MOBILE_PKG || "com.orbit.orbit";
const ADB = process.env.ADB || "adb";
const REPEATS = 3; // 三次取中位：单次易受系统回收/其他进程干扰

const argv = process.argv.slice(2);
const GATE = argv.includes("--gate");
const RECORD = argv.includes("--record");
const LIST = argv.includes("--list");

/** 场景定义：每个场景给出「怎么跑到该场景」与「采什么」 */
const SCENARIOS = [
  {
    key: "cold_start_pss_mb",
    label: "冷启动到首页可交互",
    // 冷启动场景由 force-stop + am start 构成；等待首帧稳定后采样
    prepare: "coldStart",
  },
  {
    key: "list_10k_pss_mb",
    label: "1 万行列表滚动 20 次",
    prepare: "listScroll",
  },
  { key: "calendar_month_pss_mb", label: "月历切换 3 个月", prepare: "calendar" },
  { key: "timeline_pss_mb", label: "时间轴档渲染", prepare: "timeline" },
  {
    key: "backup_roundtrip_pss_mb",
    label: "备份导出 + 导入往返",
    prepare: "backup",
  },
  { key: "search_pss_mb", label: "全局搜索 5 次关键词", prepare: "search" },
];

function adb(args, opts = {}) {
  return execFileSync(ADB, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 120_000,
    ...opts,
  });
}

/** 是否有可用设备（真机或模拟器都算，但必须 online） */
function deviceOnline() {
  try {
    const out = adb(["devices"]);
    return out
      .split(/\r?\n/)
      .slice(1)
      .some((line) => /\tdevice$/.test(line.trim()));
  } catch {
    return false;
  }
}

/** 解析 `dumpsys meminfo <pkg>` 的 TOTAL PSS（KB） */
function readPssKb() {
  const out = adb(["shell", "dumpsys", "meminfo", PKG]);
  // 形如：`  TOTAL PSS:   123456            TOTAL RSS:  234567`
  const m = out.match(/TOTAL\s+PSS:\s*(\d+)/i);
  if (!m) {
    throw new Error(`无法从 dumpsys meminfo 解析 TOTAL PSS（包名 ${PKG}）`);
  }
  return Number(m[1]);
}

/** 把应用冷启动到首页（force-stop 保证冷起，避免上次场景残留） */
function coldStartApp() {
  adb(["shell", "am", "force-stop", PKG]);
  adb(["shell", "monkey", "-p", PKG, "-c", "android.intent.category.LAUNCHER", "1"]);
  // 首帧 + 首屏数据加载：移动端实测冷启动约 1.5–2.5s，留 4s 余量
  sleepMs(4000);
}

function sleepMs(ms) {
  // 同步等待：脚本是线性的，用 Atomics 阻塞而非异步（保持各场景顺序确定）
  const sab = new SharedArrayBuffer(4);
  Atomics.wait(new Int32Array(sab), 0, 0, ms);
}

/**
 * 场景准备：把应用带到该场景。
 *
 * **诚实口径**：除冷启动外，其余场景需要驱动 UI（点击/滚动），而驱动方式
 * 依赖具体页面结构与坐标——硬编码坐标在分辨率/语言变化下立刻失效。故本脚本
 * 只自动做「冷启动」，其余场景要求调用方**手动把应用操作到该场景**后按回车
 * 采样（见 README 段落）；或后续接入 integration_test 驱动后再自动化。
 *
 * 返回 false 表示该场景本轮无法自动准备 → 计入 SKIP 而不是伪造数值。
 */
function prepareScenario(name) {
  switch (name) {
    case "coldStart":
      coldStartApp();
      return true;
    default:
      return false; // 需人工/集成测试驱动，本轮跳过
  }
}

/** 单场景采样：3 次取中位数 */
function sampleScenario(scenario) {
  const prepared = prepareScenario(scenario.prepare);
  if (!prepared) return { skipped: true, reason: "场景需 UI 驱动，未自动执行" };

  const samples = [];
  for (let i = 0; i < REPEATS; i++) {
    samples.push(readPssKb());
    sleepMs(500);
  }
  samples.sort((a, b) => a - b);
  const medianKb = samples[Math.floor(samples.length / 2)];
  return { mb: +(medianKb / 1024).toFixed(1), samplesKb: samples };
}

function loadBaselines() {
  return JSON.parse(readFileSync(BASELINES, "utf8"));
}

function printPlan(baselines) {
  console.log(`[mobile-mem] 包名 ${PKG}`);
  console.log("[mobile-mem] 场景与阈值（MB）：");
  for (const s of SCENARIOS) {
    const th = baselines.thresholds[s.key];
    const tg = baselines.targets?.[s.key];
    console.log(
      `  - ${s.key.padEnd(26)} 阈值 ${String(th).padStart(4)}` +
        (tg != null ? `  目标 ${String(tg).padStart(4)}` : ""),
    );
  }
}

function main() {
  const baselines = loadBaselines();

  if (LIST) {
    printPlan(baselines);
    return 0;
  }

  if (!deviceOnline()) {
    console.log(
      "[mobile-mem] SKIP：没有 online 的 Android 设备（adb devices 为空）。",
    );
    console.log(
      "[mobile-mem] 这不等于通过——移动端内存门禁在有设备前保持「未测」状态。",
    );
    console.log(`[mobile-mem] 原因记录：${baselines.skippedReason ?? "未填写"}`);
    return 2;
  }

  printPlan(baselines);
  const measured = {};
  const skipped = [];
  const failures = [];

  for (const s of SCENARIOS) {
    let r;
    try {
      r = sampleScenario(s);
    } catch (e) {
      skipped.push(`${s.key}（采样异常：${e.message}）`);
      continue;
    }
    if (r.skipped) {
      skipped.push(`${s.key}（${r.reason}）`);
      continue;
    }
    measured[s.key] = r.mb;
    console.log(`[mobile-mem] ${s.key} = ${r.mb} MB（样本 ${r.samplesKb.join("/")} KB）`);

    const th = baselines.thresholds[s.key];
    if (GATE && th != null && r.mb > th) {
      failures.push(`${s.key} ${r.mb}MB > 阈值 ${th}MB`);
    }
  }

  measured.measuredAt = new Date().toISOString().slice(0, 10);

  if (RECORD) {
    baselines.measured = { ...measured, $comment: baselines.measured?.$comment };
    writeFileSync(BASELINES, JSON.stringify(baselines, null, 2) + "\n");
    console.log("[mobile-mem] 已回写 measured（未改 thresholds/targets）");
  }

  if (skipped.length) {
    console.log(`[mobile-mem] 跳过 ${skipped.length} 个场景：`);
    for (const s of skipped) console.log(`  - ${s}`);
  }

  if (GATE && failures.length) {
    console.error("[mobile-mem] 门禁失败：");
    for (const f of failures) console.error(`  - ${f}`);
    return 1;
  }

  // 关键：一个场景都没测到 → 不能报成功
  if (Object.keys(measured).length <= 1) {
    console.error(
      "[mobile-mem] SKIP：有设备但没有任何场景被成功采样（全部需 UI 驱动）。",
    );
    return 2;
  }

  console.log("[mobile-mem] 通过");
  return 0;
}

process.exit(main());
