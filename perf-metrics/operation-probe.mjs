/**
 * operation-probe.mjs — 大对象操作的内存峰值探针（docs/13 §6.2 M6 / 总计划 T0.1）
 *
 * 与 growth-curve.mjs 的分工：曲线量的是**前端列表**在 1k/5k/10k 数据量下的
 * 驻留与重拉峰值；本脚本量的是 **core 侧大对象操作**（备份导出/导入、CSV 导入、
 * 附件写入/导出/云端推拉）的峰值增量。两者指标不通用，不要互相替换。
 *
 * M3/T1.1 后附件场景的口径：`attachment-write` 走路径入参（流式 SHA-256 + 落盘），
 * `attachment-read` 走流式导出，`attachment-sync-push/pull` 走 OSAC 分块容器
 * 加解密 + 适配器按块传输——四者峰值都应与 50MB 规模解耦（验收线 32MB）。
 *
 * 口径：
 * - 每个场景跑在独立进程（`orbit-core/examples/operation_probe.rs`），避免上一
 *   场景的驻留污染下一场景；
 * - 堆增量由探针内的 `GlobalAlloc` 计数器精确采集（不受 SQLite page cache 干扰）；
 * - RSS 增量由探针内 10ms 采样 WorkingSet/VmRSS；macOS 未适配 RSS，指标为 null；
 * - 三跑取中位；基线文件记录数据规模，跨版本对比必须同规模。
 *
 * 用法：
 *   node perf-metrics/operation-probe.mjs            # 跑一轮，打印并写 last-run
 *   node perf-metrics/operation-probe.mjs --gate     # 超 operation-baselines.json 阈值则 exit 1
 *   node perf-metrics/operation-probe.mjs --record   # 跑一轮并把 measured 写回基线
 *   node perf-metrics/operation-probe.mjs --skip-build --repeats 1   # 本地调参
 *
 * 首次运行会 `cargo build --release -p orbit-core --example operation_probe`
 * （release profile 含 LTO，首次编译较慢；产物在根 `target/release/examples/`）。
 */
import { execFileSync, execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BASELINES = path.join(ROOT, 'perf-metrics', 'operation-baselines.json');
const LAST_RUN = path.join(ROOT, 'perf-metrics', 'operation-last-run.json');
const PROBE = path.join(
  ROOT,
  'target',
  'release',
  'examples',
  process.platform === 'win32' ? 'operation_probe.exe' : 'operation_probe',
);
const ALL_SCENARIOS = [
  'backup-export',
  'backup-import',
  'csv-import',
  'attachment-write',
  'attachment-read',
  'attachment-sync-push',
  'attachment-sync-pull',
  'backup-export-large',
  'initial-sync',
];
const ATTACHMENT_SCENARIOS = new Set([
  'attachment-write',
  'attachment-read',
  'attachment-sync-push',
  'attachment-sync-pull',
]);
const METRICS = [
  'allocPeakDeltaMB',
  'allocEndDeltaMB',
  'rssPeakDeltaMB',
  'rssEndDeltaMB',
  'durationMs',
  'artifactMB',
];
const BUFFER = 1.15; // 操作级采样受调度/磁盘缓存影响，缓冲带比 growth-curve 的 10% 略宽

const argv = process.argv.slice(2);
const GATE = argv.includes('--gate');
const RECORD = argv.includes('--record');
const KEEP = argv.includes('--keep');
const SKIP_BUILD = argv.includes('--skip-build');
const argValue = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const REPEATS = Number(argValue('--repeats', '3'));
const ROWS = Number(argValue('--rows', '10000'));
const CSV_ROWS = Number(argValue('--csv-rows', '20000'));
const ATTACHMENT_MB = Number(argValue('--attachment-mb', '50'));
// T0.2/T1.2 验收批：200MB 级备份（50k 行 × 4KiB 描述）与 50k 行首同步
const LARGE_ROWS = Number(argValue('--large-rows', '50000'));
const LARGE_DESC_KB = Number(argValue('--large-description-kb', '4'));
const INITIAL_SYNC_ROWS = Number(argValue('--initial-sync-rows', '50000'));
const ONLY = argValue('--only', '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const SCENARIOS = ALL_SCENARIOS.filter((s) => !ONLY.length || ONLY.includes(s));

/** 每场景的数据规模（未列出的走基准 10k 行 / 小描述） */
const scenarioInput = (scenario) => {
  if (scenario === 'backup-export-large') {
    return { rows: LARGE_ROWS, descriptionKb: LARGE_DESC_KB };
  }
  if (scenario === 'initial-sync') {
    return { rows: INITIAL_SYNC_ROWS, descriptionKb: 0 };
  }
  return { rows: ROWS, descriptionKb: 0 };
};

if (!Number.isFinite(REPEATS) || REPEATS < 1) {
  console.error('OPS_GATE_FAIL: --repeats 必须 ≥ 1');
  process.exit(1);
}
if (!SCENARIOS.length) {
  console.error(`OPS_GATE_FAIL: --only 未匹配到场景（可选 ${ALL_SCENARIOS.join(', ')}）`);
  process.exit(1);
}

function median(nums) {
  const v = nums.filter((n) => Number.isFinite(n)).sort((a, b) => a - b);
  return v.length ? v[Math.floor(v.length / 2)] : null;
}

function buildProbe() {
  if (SKIP_BUILD && fs.existsSync(PROBE)) return;
  console.log('cargo build --release -p orbit-core --example operation_probe …');
  execSync('cargo build --release -p orbit-core --example operation_probe', {
    cwd: ROOT,
    stdio: 'inherit',
  });
  if (!fs.existsSync(PROBE)) {
    console.error(`OPS_GATE_FAIL: 探针未生成（期望 ${path.relative(ROOT, PROBE)}）`);
    process.exit(1);
  }
}

/** 20k 行 Todoist 模板 CSV：内容确定，保证跨版本可比 */
function writeCsv(file, rows) {
  const lines = ['Type,Content,Description,Priority,Due Date,List Name'];
  for (let i = 0; i < rows; i++) {
    lines.push(
      `task,操作探针任务 ${String(i).padStart(6, '0')},CSV 导入样本描述 ${i},p3,2026-12-31,操作探针项目`,
    );
  }
  fs.writeFileSync(file, lines.join('\n') + '\n');
}

/** 50MB 附件样本：全 'a' 内容（内容寻址只关心确定性，不关心熵） */
function writeAttachment(file, mb) {
  fs.writeFileSync(file, Buffer.alloc(mb * 1024 * 1024, 0x61));
}

function runProbe({ scenario, workdir, out, backup }) {
  fs.mkdirSync(workdir, { recursive: true });
  const { rows, descriptionKb } = scenarioInput(scenario);
  const args = [
    '--scenario',
    scenario,
    '--workdir',
    workdir,
    '--out',
    out,
    '--rows',
    String(rows),
    '--description-kb',
    String(descriptionKb),
    '--csv-rows',
    String(CSV_ROWS),
    '--attachment-mb',
    String(ATTACHMENT_MB),
  ];
  if (backup) args.push('--backup', backup);
  const started = Date.now();
  try {
    execFileSync(PROBE, args, { cwd: ROOT, encoding: 'utf8' });
  } catch (err) {
    const detail = (err.stderr || err.stdout || err.message || '').toString().trim();
    throw new Error(`${scenario} 探针失败（exit ${err.status ?? '?'}）：${detail}`);
  }
  const result = JSON.parse(fs.readFileSync(out, 'utf8'));
  if (!result.ok) throw new Error(`${scenario} 探针自报失败：${result.error}`);
  // wallMs 是子进程墙钟（含建库/种子），只做排查；阶段时长以 metrics.durationMs 为准
  result.wallMs = Date.now() - started;
  return result;
}

buildProbe();

// 落仓库内而非系统 TEMP：本机对工作区可执行文件强制 Low 完整性级别，
// 它无权写用户 TEMP（memory3/探针都踩过），工作区内可写且随 --keep 可控。
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const tmpRoot = path.join(ROOT, 'perf-metrics', '.runs', `operation-probe-${stamp}`);
fs.mkdirSync(tmpRoot, { recursive: true });

const samples = [];
try {
  for (let run = 0; run < REPEATS; run++) {
    const runDir = path.join(tmpRoot, `run-${run + 1}`);
    fs.mkdirSync(runDir, { recursive: true });
    const row = {};
    for (const scenario of SCENARIOS) {
      const workdir = path.join(runDir, scenario);
      fs.mkdirSync(workdir, { recursive: true });
      if (scenario === 'csv-import') writeCsv(path.join(workdir, 'probe.csv'), CSV_ROWS);
      if (ATTACHMENT_SCENARIOS.has(scenario)) {
        writeAttachment(path.join(workdir, 'probe-attachment.bin'), ATTACHMENT_MB);
      }
      const backup =
        scenario === 'backup-import'
          ? path.join(runDir, 'backup-export', 'probe.orfullsync')
          : undefined;
      if (scenario === 'backup-import' && !fs.existsSync(backup)) {
        throw new Error('backup-import 依赖本轮 backup-export 的产物，场景顺序被破坏');
      }
      const result = runProbe({
        scenario,
        workdir,
        out: path.join(runDir, `${scenario}.json`),
        backup,
      });
      row[scenario] = result;
      console.log(
        `run ${run + 1}/${REPEATS} ${scenario}: ` +
          `堆峰值 +${result.metrics.allocPeakDeltaMB}MB / ` +
          `RSS 峰值 +${result.metrics.rssPeakDeltaMB ?? 'null'}MB / ` +
          `${result.metrics.durationMs}ms`,
      );
    }
    samples.push(row);
  }
} finally {
  if (!KEEP) fs.rmSync(tmpRoot, { recursive: true, force: true });
  else console.log(`保留探针临时目录：${tmpRoot}`);
}

/** 扁平化：`<scenario>.<metric>`，与 baselines.json 的 thresholds 同键 */
const measured = {};
for (const scenario of SCENARIOS) {
  for (const metric of METRICS) {
    measured[`${scenario}.${metric}`] = median(
      samples.map((s) => s[scenario]?.metrics?.[metric]).filter((v) => v !== null && v !== undefined),
    );
  }
}
// 上下文指标：不进 thresholds，只做数据集核对（首同步上传总量验证数据确实流过链路）
if (SCENARIOS.includes('initial-sync')) {
  measured['initial-sync.uploadedMB'] = median(
    samples
      .map((s) => s['initial-sync']?.metrics?.uploadedMB)
      .filter((v) => v !== null && v !== undefined),
  );
}

const datasets = {
  backupRows: ROWS,
  csvRows: CSV_ROWS,
  attachmentMB: ATTACHMENT_MB,
  backupLargeRows: LARGE_ROWS,
  backupLargeDescriptionKb: LARGE_DESC_KB,
  initialSyncRows: INITIAL_SYNC_ROWS,
  backupArtifactMB: measured['backup-export.artifactMB'],
  backupLargeArtifactMB: measured['backup-export-large.artifactMB'],
  csvArtifactMB: measured['csv-import.artifactMB'],
  attachmentArtifactMB: measured['attachment-write.artifactMB'],
  initialSyncUploadedMB: measured['initial-sync.uploadedMB'],
  repeats: REPEATS,
};
// --only 调试时未跑的场景指标为 undefined：record 合并写回，别清掉其他场景的基线
const fullRun = SCENARIOS.length === ALL_SCENARIOS.length;
if (!fullRun) delete datasets.repeats;
const definedDatasets = Object.fromEntries(
  Object.entries(datasets).filter(([, v]) => v !== undefined && v !== null),
);

const measuredAt = new Date().toISOString().slice(0, 10);
const payload = { measured, datasets, measuredAt, samples };
fs.writeFileSync(LAST_RUN, JSON.stringify(payload, null, 2) + '\n');

const cfg = JSON.parse(fs.readFileSync(BASELINES, 'utf8'));
const violations = [];
if (Object.keys(cfg.thresholds ?? {}).length === 0) {
  violations.push('thresholds 为空——先跑 --record 建立 measured，再按实测手工设定阈值');
}
const skipped = [];
for (const [key, limit] of Object.entries(cfg.thresholds ?? {})) {
  if (limit === null) {
    skipped.push(key);
    continue;
  }
  const got = measured[key];
  if (!Number.isFinite(got)) {
    violations.push(`${key}: 未采到数（指标不可用，不能判通过）`);
  } else if (got > limit * BUFFER) {
    violations.push(
      `${key}: ${got} > 阈值 ${limit}（含 15% 缓冲 ${Math.round(limit * BUFFER * 10) / 10}）`,
    );
  }
}

// targets 只报不拦：M1/M2/M3 的验收线今天可能未达，别把「没变差」读成「已达标」
const targetGaps = Object.entries(cfg.targets ?? {})
  .filter(([, want]) => Number.isFinite(want))
  .map(([key, want]) => {
    const got = measured[key];
    return Number.isFinite(got) && got > want ? `${key}: 实测 ${got} > 目标 ${want}` : null;
  })
  .filter(Boolean);

if (RECORD) {
  cfg.measured = { ...(cfg.measured ?? {}), ...measured };
  cfg.datasets = { ...(cfg.datasets ?? {}), ...definedDatasets };
  cfg.measuredAt = measuredAt;
  fs.writeFileSync(BASELINES, JSON.stringify(cfg, null, 2) + '\n');
  console.log(`已写回 measured → ${path.relative(ROOT, BASELINES)}`);
}

console.log(
  JSON.stringify({ platform: process.platform, datasets, measured, targetGaps, skipped, violations }, null, 2),
);

if (GATE) {
  if (violations.length) {
    console.error('OPS_GATE_FAIL:\n- ' + violations.join('\n- '));
    process.exit(1);
  }
  console.log(
    `OPS_GATE_OK（${SCENARIOS.length} 场景 × ${REPEATS} 次中位，${Object.keys(cfg.thresholds ?? {}).length - skipped.length} 项阈值全过）`,
  );
}
