#!/usr/bin/env node
/**
 * mobile-jank.mjs — 移动端动画帧耗时门禁（2026-11-08）
 *
 * 与 `mobile-mem.mjs` 同构（同三退出码语义），但口径不同：那边量进程 PSS，
 * 这边量 **Flutter 帧构建耗时**。被测端是
 * `apps/mobile/integration_test/perf_jank_test.dart`，经
 * `flutter drive --profile` 跑五个动画场景，`watchPerformance` 把统计写进
 * `apps/mobile/build/integration_response_data.json`，本脚本只做解析、判阈值
 * 与基线回写。
 *
 * 三种退出码（**关键语义**）：
 * - 0 = 全部门禁通过
 * - 1 = 有指标超阈值（回归）
 * - 2 = SKIP：没有可用设备 / flutter drive 失败 / 阈值尚未校准。
 *   **绝不能读成通过**——与 mobile-mem 同一条诚实口径。
 *
 * 为什么只卡 build 侧指标、不卡 raster：
 * 本仓当前只有 x64 模拟器（宿主 GPU 加速），玻璃模糊的 raster 耗时与真机
 * 没有可比性，用它设阈值只会得到一个长期红灯；build 侧（Dart 侧布局/构建）
 * 在模拟器与真机上量级一致，能真实反映「代码把多少活放进帧里」。
 * raster 数字照常打印，供人工观察。
 *
 * 用法：
 *   node perf-metrics/mobile-jank.mjs --list      # 列场景与阈值（不跑）
 *   node perf-metrics/mobile-jank.mjs --record    # 跑一轮并回写 measured + 校准阈值
 *   node perf-metrics/mobile-jank.mjs --gate      # 跑一轮并判阈值
 *
 * 环境变量：
 *   ADB           adb 可执行路径（默认 PATH 里的 adb）
 *   FLUTTER       flutter 可执行路径（默认 PATH 里的 flutter）
 *   JANK_TIMEOUT  flutter drive 超时分钟数（默认 25，首次构建较慢）
 */
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MOBILE_DIR = path.join(ROOT, "apps", "mobile");
const RESPONSE = path.join(
  MOBILE_DIR,
  "build",
  "integration_response_data.json",
);
const BASELINES = path.join(ROOT, "perf-metrics", "mobile-jank-baselines.json");

const ADB = process.env.ADB || "adb";
const FLUTTER = process.env.FLUTTER || "flutter";
const TIMEOUT_MIN = Number(process.env.JANK_TIMEOUT || 25);

const argv = process.argv.slice(2);
const GATE = argv.includes("--gate");
const RECORD = argv.includes("--record");
const LIST = argv.includes("--list");
const deviceArgIndex = argv.indexOf("--device");
const DEVICE = deviceArgIndex >= 0 ? argv[deviceArgIndex + 1] : null;

/** 场景定义：与 `integration_test/perf_jank_test.dart` 的 reportKey 一一对应 */
const SCENARIOS = [
  { key: "sheet_open", label: "快速添加面板入场（含自动聚焦起键盘）" },
  { key: "menu_morph", label: "页头 ⋮ 锚定菜单形变开合" },
  { key: "list_scroll", label: "列表连续滑动 20 次" },
  { key: "view_switch", label: "列表 → 看板 AnimatedSwitcher 过渡" },
  { key: "calendar_page", label: "月历连续翻 3 个月" },
];

/** 60Hz 单帧构建预算（integration_test 的 missed_frame_build_budget 同口径） */
const FRAME_BUDGET_MS = 1000 / 60;

function adb(args) {
  return execFileSync(ADB, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 120_000,
  });
}

/** 第一台 online 设备（真机/模拟器都算；无则 null） */
function pickDevice() {
  if (DEVICE) return DEVICE;
  try {
    const out = adb(["devices"]);
    const line = out
      .split(/\r?\n/)
      .slice(1)
      .map((l) => l.trim())
      .find((l) => /\tdevice$/.test(l));
    return line ? line.split(/\t/)[0] : null;
  } catch {
    return null;
  }
}

function loadBaselines() {
  return JSON.parse(readFileSync(BASELINES, "utf8"));
}

function pct(value, digits = 3) {
  return `${(value * 100).toFixed(digits)}%`;
}

function printPlan(baselines) {
  console.log("[mobile-jank] 场景（profile 档，帧构建侧）：");
  for (const s of SCENARIOS) {
    const th = baselines.thresholds?.[s.key];
    const measured = baselines.measured?.[s.key];
    console.log(
      `  - ${s.key.padEnd(14)} ${s.label}` +
        (th
          ? `\n      阈值 丢帧率 ≤ ${pct(th.maxMissedBuildRatio)}，P99 ≤ ${th.maxP99BuildMs}ms`
          : "\n      阈值 未校准（先跑 --record）") +
        (measured
          ? `\n      基线 丢帧率 ${pct(measured.missedBuildRatio)}，P99 ${measured.p99BuildMs}ms，均 ${measured.avgBuildMs}ms`
          : ""),
    );
  }
}

/** 跑 flutter drive，返回是否成功 */
function runDrive(device) {
  if (existsSync(RESPONSE)) {
    // 上一轮残留会让「本轮没产出」被误读成通过
    try {
      writeFileSync(RESPONSE, "{}");
    } catch {
      /* 读不了就当没有 */
    }
  }
  console.log(`[mobile-jank] flutter drive --profile -d ${device} ...`);
  console.log("[mobile-jank] 首次运行要构建 profile 包，可能数分钟；请勿中断。");
  const result = spawnSync(
    FLUTTER,
    [
      "drive",
      "--profile",
      "-d",
      device,
      "--driver=test_driver/integration_test.dart",
      "--target=integration_test/perf_jank_test.dart",
    ],
    {
      cwd: MOBILE_DIR,
      stdio: "inherit",
      shell: process.platform === "win32",
      timeout: TIMEOUT_MIN * 60_000,
    },
  );
  return result.status === 0;
}

/** 取某场景的指标（缺项返回 null —— 不拿 0 冒充） */
function readMetrics(key) {
  let raw;
  try {
    raw = JSON.parse(readFileSync(RESPONSE, "utf8"));
  } catch {
    return null;
  }
  const d = raw?.[key];
  if (!d || typeof d.frame_count !== "number" || d.frame_count <= 0) return null;
  const frames = d.frame_count;
  const missed = d.missed_frame_build_budget_count ?? 0;
  return {
    frames,
    missedBuildFrames: missed,
    missedBuildRatio: missed / frames,
    missedRasterFrames: d.missed_frame_rasterizer_budget_count ?? 0,
    avgBuildMs: round(d.average_frame_build_time_millis),
    p99BuildMs: round(d["99th_percentile_frame_build_time_millis"]),
    worstBuildMs: round(d.worst_frame_build_time_millis),
    avgRasterMs: round(d.average_frame_rasterizer_time_millis),
    p99RasterMs: round(d["99th_percentile_frame_rasterizer_time_millis"]),
    worstRasterMs: round(d.worst_frame_rasterizer_time_millis),
  };
}

function round(v) {
  return typeof v === "number" ? +v.toFixed(2) : null;
}

/** 本地日期（不用 `toISOString`：那是 UTC，东八区夜间会记成前一天） */
function localDate() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 校准阈值：取实测的 1.25 倍（留一次抖动余量），并夹到物理下限之上 */
function calibrate(m) {
  return {
    maxMissedBuildRatio: +Math.min(0.5, Math.max(0.02, m.missedBuildRatio * 1.25)).toFixed(4),
    maxP99BuildMs: +Math.max(FRAME_BUDGET_MS, m.p99BuildMs * 1.25).toFixed(2),
  };
}

function main() {
  const baselines = loadBaselines();

  if (LIST) {
    printPlan(baselines);
    return 0;
  }

  const device = pickDevice();
  if (!device) {
    console.log("[mobile-jank] SKIP：没有 online 的 Android 设备。");
    console.log(
      "[mobile-jank] 这不等于通过——移动端帧耗时门禁在有设备前保持「未测」状态。",
    );
    return 2;
  }

  printPlan(baselines);

  const ok = runDrive(device);
  if (!ok) {
    console.error("[mobile-jank] SKIP：flutter drive 未成功退出（见上方日志）。");
    console.error(
      "[mobile-jank] 常见原因：profile 包构建失败、设备断连、用例断言失败。",
    );
    return 2;
  }

  const measured = {};
  const missing = [];
  for (const s of SCENARIOS) {
    const m = readMetrics(s.key);
    if (!m) {
      missing.push(s.key);
      continue;
    }
    measured[s.key] = m;
    console.log(
      `[mobile-jank] ${s.key.padEnd(14)} 帧 ${String(m.frames).padStart(4)}` +
        ` | build 丢帧 ${pct(m.missedBuildRatio)}` +
        ` 均 ${m.avgBuildMs}ms P99 ${m.p99BuildMs}ms 最差 ${m.worstBuildMs}ms` +
        ` | raster 均 ${m.avgRasterMs}ms P99 ${m.p99RasterMs}ms（不设阈值）`,
    );
  }

  if (missing.length) {
    console.warn(
      `[mobile-jank] 缺 ${missing.length} 个场景的帧数据：${missing.join("、")}`,
    );
  }

  if (Object.keys(measured).length === 0) {
    console.error(
      "[mobile-jank] SKIP：一轮跑完没有任何场景产出帧数据（用例被 skip 或 watchPerformance 未上报）。",
    );
    console.error(
      "[mobile-jank] 检查是否漏了 --profile（debug 档下用例整组 skip）。",
    );
    return 2;
  }

  const measuredAt = localDate();
  baselines.measured = { ...measured, measuredAt };
  if (RECORD) {
    baselines.thresholds = Object.fromEntries(
      Object.entries(measured).map(([k, v]) => [k, calibrate(v)]),
    );
    console.log("[mobile-jank] 已回写 measured 并按实测 ×1.25 校准 thresholds");
  }
  writeFileSync(BASELINES, JSON.stringify(baselines, null, 2) + "\n");

  if (!RECORD && GATE) {
    if (!baselines.thresholds || Object.keys(baselines.thresholds).length === 0) {
      console.error("[mobile-jank] SKIP：阈值尚未校准，先跑 `--record`。");
      return 2;
    }
    const failures = [];
    for (const [key, m] of Object.entries(measured)) {
      const th = baselines.thresholds[key];
      if (!th) continue;
      if (m.missedBuildRatio > th.maxMissedBuildRatio) {
        failures.push(
          `${key} 丢帧率 ${pct(m.missedBuildRatio)} > 阈值 ${pct(th.maxMissedBuildRatio)}`,
        );
      }
      if (m.p99BuildMs != null && m.p99BuildMs > th.maxP99BuildMs) {
        failures.push(
          `${key} P99 构建 ${m.p99BuildMs}ms > 阈值 ${th.maxP99BuildMs}ms`,
        );
      }
    }
    if (failures.length) {
      console.error("[mobile-jank] 门禁失败：");
      for (const f of failures) console.error(`  - ${f}`);
      return 1;
    }
  }

  console.log("[mobile-jank] 通过");
  return 0;
}

process.exit(main());
