/**
 * memory3.mjs — 真机 exe 口径内存门禁（Windows 本地，不入 CI）
 *
 * 两个口径，互不替代：
 * A. Tauri release（orbit + msedgewebview2 子树）：真机稳态 WorkingSet 净增；
 * B. Chromium 同前端（当前 `apps/desktop/dist`，10k 行）：操作期峰值与 JS 堆。
 *
 * 为什么按「启动前后同名进程的净增」：本机常驻的 WebView2/浏览器进程不能算进
 * 指标，否则数字随用户当天开没开浏览器漂移。A 段先快照全系统同名进程、启动后
 * 再快照，差值才是本 exe 的占用；B 段同理。
 *
 * 用法（Windows）：
 *   node perf-metrics/memory3.mjs            # 跑一轮，打印并写 memory3-last-run.json
 *   node perf-metrics/memory3.mjs --gate     # 与 baselines.json#desktopExe 阈值比对
 *   node perf-metrics/memory3.mjs --record   # 把 measured 写回 baselines.json#desktopExe
 *
 * 前置：`pnpm --filter orbit build`（B 段需要 dist）、桌面 release exe
 * （`cd apps/desktop/src-tauri && cargo build --release`）。缺任何一项时按 SKIP
 * 语义 exit 2 并打印原因——绝不把「没测」读成「通过」。
 */
import { execSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const EXE = path.join(
  ROOT,
  'apps',
  'desktop',
  'src-tauri',
  'target',
  'release',
  process.platform === 'win32' ? 'orbit.exe' : 'orbit',
);
const DIST = path.join(ROOT, 'apps', 'desktop', 'dist');
const BASELINES = path.join(ROOT, 'perf-metrics', 'baselines.json');
const LAST_RUN = path.join(ROOT, 'perf-metrics', 'memory3-last-run.json');
const PORT = 5274;
const argv = process.argv.slice(2);
const GATE = argv.includes('--gate');
const RECORD = argv.includes('--record');
const BUFFER = 1.1;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ps = (cmd) => {
  try {
    return execSync('powershell -NoProfile -Command ' + JSON.stringify(cmd), {
      encoding: 'utf8',
    }).trim();
  } catch {
    return '';
  }
};

const snapshot = (names) => {
  const list = names.flatMap((n) => {
    const out = ps(
      `Get-Process ${n} -ErrorAction SilentlyContinue | Select-Object Id,WorkingSet64,@{n='CPU';e={[math]::Round($_.CPU,2)}} | ConvertTo-Json -Compress`,
    );
    try {
      const j = JSON.parse(out);
      return Array.isArray(j) ? j : [j];
    } catch {
      return [];
    }
  });
  return {
    set: new Map(list.map((p) => [p.Id, p])),
    ws: list.reduce((s, p) => s + (p.WorkingSet64 || 0), 0),
    cpu: list.reduce((s, p) => s + (p.CPU || 0), 0),
  };
};
const diffMB = (after, before) => Math.round((after.ws - before.ws) / 1048576);

function skip(reason) {
  console.error(`MEMORY3_SKIP: ${reason}`);
  process.exit(2);
}

if (process.platform !== 'win32') skip('memory3 是 Windows 真机口径（Get-Process WorkingSet）');
if (!fs.existsSync(EXE)) skip(`缺少 release exe：${path.relative(ROOT, EXE)}（先 cargo build --release）`);

const result = { measuredAt: new Date().toISOString().slice(0, 10), tauri: null, chromium: null };

// ===== A. Tauri release =====
console.log('== A. Tauri release ==');
{
  const before = snapshot(['orbit', 'msedgewebview2']);
  const p = spawn(EXE, [], { stdio: 'ignore' });
  await sleep(5000);
  const s1 = snapshot(['orbit', 'msedgewebview2']);
  await sleep(5000);
  const s2 = snapshot(['orbit', 'msedgewebview2']);
  result.tauri = {
    wsMBStart: diffMB(s1, before),
    wsMBStable: diffMB(s2, before),
    cpuS10s: Math.round((s2.cpu - before.cpu) * 10) / 10,
    procs: s2.set.size,
  };
  console.log(JSON.stringify(result.tauri));
  ps(`Stop-Process -Id ${p.pid} -Force`);
  await sleep(1500);
}

// ===== B. Chromium 同前端（当前 dist, 10k, 操作期）=====
console.log('== B. Chromium 同前端（dist, 10k, 操作期）==');
if (!fs.existsSync(path.join(DIST, 'index.html'))) {
  console.warn(`WARN: 缺少 ${path.relative(ROOT, DIST)}/index.html，B 段跳过（先 pnpm --filter orbit build）`);
} else {
  const { chromium } = await import('@playwright/test');
  const srv = http
    .createServer((req, res) => {
      let q = decodeURIComponent(req.url.split('?')[0]);
      if (q === '/') q = '/index.html';
      const f = path.join(DIST, q);
      if (!f.startsWith(DIST + path.sep)) {
        res.statusCode = 403;
        res.end();
        return;
      }
      if (fs.existsSync(f) && fs.statSync(f).isFile()) {
        const ct = f.endsWith('.js')
          ? 'text/javascript'
          : f.endsWith('.css')
            ? 'text/css'
            : f.endsWith('.html')
              ? 'text/html'
              : 'application/octet-stream';
        res.setHeader('Content-Type', ct);
        res.end(fs.readFileSync(f));
      } else {
        const idx = path.join(DIST, 'index.html');
        if (fs.existsSync(idx)) {
          res.setHeader('Content-Type', 'text/html');
          res.end(fs.readFileSync(idx));
        } else {
          res.statusCode = 404;
          res.end();
        }
      }
    })
    .listen(PORT);
  const before = snapshot(['chrome', 'chrome-headless-shell', 'chromium']);
  const b = await chromium.launch();
  try {
    const page = await b.newPage({ viewport: { width: 1440, height: 900 } });
    await page.goto(`http://127.0.0.1:${PORT}/`);
    await page.waitForTimeout(2000);
    const mk = (i) => {
      const now = Date.now();
      return {
        id: 1000 + i,
        uuid: 'u' + i,
        title: '性能测量任务 ' + String(i).padStart(5, '0'),
        description: null,
        project_id: null,
        priority: i % 6,
        status: 'pending',
        done: 0,
        done_at: null,
        due_date: i % 3 === 0 ? now + (i % 30) * 86400000 : null,
        start_date: null,
        repeat_after: 0,
        repeat_mode: 0,
        percent_done: 0,
        position: i,
        is_favorite: 0,
        my_day_date: null,
        is_deleted: 0,
        created_at: now,
        updated_at: now,
        deleted_at: null,
        version: 1,
      };
    };
    const seeded = await page.evaluate((seed) => {
      const m = window.__orbitMock;
      if (!m) return false;
      for (const t of seed) m.db.tasks.push(t);
      m.emitDbChange();
      return true;
    }, Array.from({ length: 10000 }, (_, i) => mk(i)));
    if (!seeded) skip('dist 未含 mock IPC 桩（window.__orbitMock 不可用）');
    await page.waitForTimeout(3000);
    const sIdle = snapshot(['chrome', 'chrome-headless-shell', 'chromium']);
    const cpu1 = sIdle.cpu;
    // 操作期：10 屏滚动 + 5 勾选
    await page.evaluate(async () => {
      const sc = document.querySelector('div.overflow-y-auto');
      for (let k = 0; k < 10; k++) {
        if (sc) sc.scrollTop += 900;
        await new Promise((r) => setTimeout(r, 100));
      }
      for (let c = 0; c < 5; c++) {
        const row = document.querySelector('[role="button"][aria-label^="未完成任务"]');
        row?.querySelector('button[aria-label="标记完成"]')?.click();
        await new Promise((r) => setTimeout(r, 400));
      }
    });
    await page.waitForTimeout(1000);
    const sBusy = snapshot(['chrome', 'chrome-headless-shell', 'chromium']);
    const heap = await page.evaluate(() =>
      performance.memory
        ? {
            usedJSMB: Math.round(performance.memory.usedJSHeapSize / 1048576),
            totalMB: Math.round(performance.memory.totalJSHeapSize / 1048576),
          }
        : null,
    );
    result.chromium = {
      wsMBIdle10k: diffMB(sIdle, before),
      wsMBBusy: diffMB(sBusy, before),
      cpuS: Math.round((sBusy.cpu - cpu1) * 10) / 10,
      jsUsedMB: heap?.usedJSMB ?? null,
      jsTotalMB: heap?.totalMB ?? null,
      procs: sBusy.set.size,
    };
    console.log(JSON.stringify(result.chromium));
  } finally {
    await b.close();
    srv.close();
  }
}

// 扁平化 measured：嵌套两段合并为 `tauri.*` / `chromium.*`
const measured = {};
for (const section of ['tauri', 'chromium']) {
  for (const [k, v] of Object.entries(result[section] ?? {})) {
    if (typeof v === 'number') measured[`${section}.${k}`] = v;
  }
}
fs.writeFileSync(LAST_RUN, JSON.stringify({ ...result, measured }, null, 2) + '\n');

const cfg = JSON.parse(fs.readFileSync(BASELINES, 'utf8'));
if (RECORD) {
  cfg.desktopExe = { ...(cfg.desktopExe ?? {}), measured, measuredAt: result.measuredAt };
  fs.writeFileSync(BASELINES, JSON.stringify(cfg, null, 2) + '\n');
  console.log(`已写回 desktopExe.measured → ${path.relative(ROOT, BASELINES)}`);
}

if (GATE) {
  const thresholds = cfg.desktopExe?.thresholds ?? {};
  const violations = [];
  if (Object.keys(thresholds).length === 0) {
    violations.push('desktopExe.thresholds 为空——先跑 --record 建立 measured，再按实测手工设定阈值');
  }
  for (const [key, limit] of Object.entries(thresholds)) {
    if (limit === null) continue;
    const got = measured[key];
    if (!Number.isFinite(got)) {
      violations.push(`${key}: 未采到数（指标不可用，不能判通过）`);
    } else if (got > limit * BUFFER) {
      violations.push(`${key}: ${got} > 阈值 ${limit}（含 10% 缓冲 ${Math.round(limit * BUFFER * 10) / 10}）`);
    }
  }
  console.log(JSON.stringify({ thresholds, measured, violations }, null, 2));
  if (violations.length) {
    console.error('MEMORY3_GATE_FAIL:\n- ' + violations.join('\n- '));
    process.exit(1);
  }
  console.log('MEMORY3_GATE_OK（真机 exe 口径）');
}
