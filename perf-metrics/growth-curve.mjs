/**
 * growth-curve.mjs — 内存增长曲线与泄漏判据（CI 可复现口径）
 *
 * 与 memory3.mjs 的分工：memory3 量的是 Tauri exe 与 Chromium 的**单次稳态**
 * （本机真机口径，含 WebView2 固有税，CI 跑不了）；本脚本量的是**同一前端在
 * 1k/5k/10k 三档数据规模下的堆增长斜率 + 重复操作后的回落量**，只依赖
 * Chromium，故可进 CI 当门禁。两者指标不通用，不要互相替换数字。
 *
 * 为什么必须强制 GC：不 GC 直接采 usedJSHeapSize 采到的是「上次回收以来的
 * 分配量」，一次列表重拉就能把它推高而实际没有泄漏——上一轮 758MB 峰值里
 * 有多少是垃圾、多少是驻留，靠单次采样永远分不清。每档采样前调 window.gc()
 * （由 --js-flags=--expose-gc 暴露），拿到的才是真实驻留。
 *
 * 用法：
 *   node perf-metrics/growth-curve.mjs               # 跑一轮，打印并写 last-run.json
 *   node perf-metrics/growth-curve.mjs --gate        # 超 baselines.json 阈值则 exit 1
 *   node perf-metrics/growth-curve.mjs --record      # 跑一轮并把 measured 写回 baselines.json
 */
import { spawn, execSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DIST = path.join(ROOT, 'apps', 'desktop', 'dist');
const BASELINES = path.join(ROOT, 'perf-metrics', 'baselines.json');
const LAST_RUN = path.join(ROOT, 'perf-metrics', 'last-run.json');
const PORT = 5275; // 5273=e2e、5274=memory3，本脚本独立端口防撞
const TIERS = [1000, 5000, 10000];
const CHURN = 20; // 重复操作次数——判「涨了就回不来」，单次峰值测不到
const REPEATS = 3; // 取中位，抵 Chromium/共享 runner 抖动
const BUFFER = 1.1; // 阈值缓冲带 10%

const argv = process.argv.slice(2);
const GATE = argv.includes('--gate');
const RECORD = argv.includes('--record');

/**
 * 浏览器进程组 WorkingSet/RSS 差分（按平台取数据源）
 * Chromium 是多进程，只看主进程会漏掉 renderer——堆外的那部分正是本轮要盯的。
 * 必须按**进程树**收敛而不是按进程名全局求和：本机常开着日常浏览器，
 * 全局 `Get-Process chrome` 会把用户自己的窗口算进指标，门禁即失去可复现性。
 */
function listProcs() {
  if (process.platform === 'win32') {
    const out = sh(
      `powershell -NoProfile -Command "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,WorkingSetSize | ConvertTo-Json -Compress"`,
    );
    try {
      const raw = JSON.parse(out);
      const arr = Array.isArray(raw) ? raw : [raw];
      return arr.map((p) => ({ pid: p.ProcessId, ppid: p.ParentProcessId, rssKB: (p.WorkingSetSize || 0) / 1024 }));
    } catch {
      return [];
    }
  }
  const out = sh('ps -eo pid=,ppid=,rss=');
  return out
    .split('\n')
    .map((line) => line.trim().split(/\s+/))
    .map(([pid, ppid, rss]) => ({ pid: Number(pid), ppid: Number(ppid), rssKB: Number(rss) }))
    .filter((p) => Number.isFinite(p.pid) && Number.isFinite(p.rssKB));
}

/**
 * 浏览器主进程 pid：Playwright 的 browser.process() 在部分版本不可用，
 * 退化为「本 node 进程的直接子进程」——调用点必须早于脚本自己 spawn 任何子进程，
 * 否则会把 powershell/ps 错认成浏览器根。
 */
function browserRootPid(browser) {
  try {
    const pid = browser.process?.()?.pid;
    if (Number.isFinite(pid)) return pid;
  } catch {
    /* 走下面的兜底 */
  }
  return listProcs().find((p) => p.ppid === process.pid)?.pid ?? null;
}

/** 从 rootPid 向下遍历子进程树求和（Chromium 的 renderer/GPU/utility 都挂在浏览器主进程下） */
function treeRssMB(rootPid) {
  if (!rootPid) return null;
  const procs = listProcs();
  if (!procs.length) return null;
  const byPid = new Map();
  const byParent = new Map();
  for (const p of procs) {
    byPid.set(p.pid, p);
    const list = byParent.get(p.ppid);
    if (list) list.push(p);
    else byParent.set(p.ppid, [p]);
  }
  let total = 0;
  const stack = [rootPid];
  while (stack.length) {
    const pid = stack.pop();
    const self = byPid.get(pid);
    if (self) total += self.rssKB;
    for (const c of byParent.get(pid) ?? []) stack.push(c.pid);
  }
  return total > 0 ? Math.round(total / 1024) : null;
}

function sh(cmd) {
  try {
    return execSync(cmd, { encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

/** 造 N 条任务：字段与 ipc-mock 的 MockTask 同构，形状变化会静默少测 */
function makeTasks(n) {
  const now = Date.now();
  return Array.from({ length: n }, (_, i) => ({
    id: 10000 + i,
    uuid: `perf-${i}`,
    title: `性能测量任务 ${String(i).padStart(5, '0')}`,
    description: i % 4 === 0 ? `描述正文 ${i}——工具栏关键词搜索的客户端过滤面依赖此字段` : null,
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
  }));
}

/**
 * 采样点：GC 后取堆 + DOM 节点数 + 进程树 RSS
 * domNodes 是虚拟化的哨兵——列表主体走 useVirtualizer 时节点数应随档位
 * 近似恒定；一旦它随任务数线性增长，说明某处退回裸 .map() 全量渲染
 * （实测已抓到一处：task-list-view 的逾期置顶分组）。
 */
async function sample(page, rootPid) {
  await page.evaluate(async () => {
    if (typeof window.gc === 'function') {
      window.gc();
      await new Promise((r) => setTimeout(r, 300));
      window.gc();
    }
  });
  const heap = await page.evaluate(() =>
    performance.memory
      ? {
          usedMB: Math.round((performance.memory.usedJSHeapSize / 1048576) * 10) / 10,
          totalMB: Math.round((performance.memory.totalJSHeapSize / 1048576) * 10) / 10,
        }
      : { usedMB: null, totalMB: null },
  );
  const domNodes = await page.evaluate(() => document.getElementsByTagName('*').length);
  return { ...heap, domNodes, rssMB: treeRssMB(rootPid) };
}

/**
 * 重复勾选 CHURN 次：每次写都触发 db-change → 万行重拉，是本轮最大的写放大路径
 * 返回真实点击数：选择器一旦因行 DOM 契约变更而失配，静默零点击会被读成
 * 「没有泄漏」——调用方必须把 0 点击判为失败，而不是当成通过。
 *
 * peakMB 是**不 GC** 的滚动最大值：GC 后采到的只有驻留，看不到「重拉窗口里
 * 同时存活两份万行数组」（placeholderData 的代价）——那正是 A1 要消掉的东西，
 * 没有这个指标就无从证明 A1 有效。
 */
async function churn(page) {
  return page.evaluate(async (times) => {
    let clicks = 0;
    let peakBytes = 0;
    for (let i = 0; i < times; i++) {
      const rows = document.querySelectorAll('[role="button"][aria-label^="未完成任务"]');
      const row = rows[i % Math.max(rows.length, 1)];
      const box = row?.querySelector('button[aria-label="标记完成"]');
      if (!box) continue;
      box.click();
      clicks++;
      await new Promise((r) => setTimeout(r, 250));
      const used = performance.memory?.usedJSHeapSize ?? 0;
      if (used > peakBytes) peakBytes = used;
    }
    return { clicks, peakMB: Math.round((peakBytes / 1048576) * 10) / 10 };
  }, CHURN);
}

/**
 * 视图切换风暴：在两个都命中万行的快捷视图间往返 SWITCH 次
 * 这是唯一能观测到 placeholderData 代价的操作——换 queryKey 时保留旧结果，
 * 意味着重拉窗口内新旧两份万行数组同时存活；纯写 churn 走同一个 key，
 * 看不到这个差值（A1 的前后对比因此必须以本指标为准）。
 * 返回点击数与**不 GC** 的堆峰值。
 */
const SWITCH_VIEWS = ['未完成', '全部任务'];
const SWITCH = 12;

async function switchChurn(page) {
  const out = await page.evaluate(
    async ({ views, times }) => {
      let clicks = 0;
      let peakBytes = 0;
      const findBtn = (label) =>
        [...document.querySelectorAll('button')].find((b) =>
          [...b.querySelectorAll('span')].some((s) => s.textContent.trim() === label),
        );
      for (let i = 0; i < times; i++) {
        const btn = findBtn(views[i % views.length]);
        if (!btn) continue;
        btn.click();
        clicks++;
        await new Promise((r) => setTimeout(r, 400));
        const used = performance.memory?.usedJSHeapSize ?? 0;
        if (used > peakBytes) peakBytes = used;
      }
      return { clicks, peakMB: Math.round((peakBytes / 1048576) * 10) / 10 };
    },
    { views: SWITCH_VIEWS, times: SWITCH },
  );
  await page.waitForTimeout(1500);
  return out;
}

function median(nums) {
  const v = nums.filter((n) => Number.isFinite(n)).sort((a, b) => a - b);
  return v.length ? v[Math.floor(v.length / 2)] : null;
}

/** 每行堆驻留：斜率超阈值 = 多养了一份与数据量成正比的驻留集（单位 KB/行） */
function heapKBPerRow(byTier) {
  const lo = byTier[TIERS[0]]?.usedMB;
  const hi = byTier[TIERS[TIERS.length - 1]]?.usedMB;
  if (!Number.isFinite(lo) || !Number.isFinite(hi)) return null;
  const rows = TIERS[TIERS.length - 1] - TIERS[0];
  return Math.round((((hi - lo) * 1024) / rows) * 10) / 10;
}

/**
 * 多存一份万行结果集的边际堆成本 = placeholderData 在换 key 重拉窗口里
 * 实际留下的量（A1 去掉的就是它）。
 * 必须是「整份对象图」而不是「一份指针数组」：mock 的列表通道每次调用都
 * 对每行 JSON 深克隆（ipc-mock filterByKeyword，为对齐真实 IPC 的引用隔离），
 * 所以旧结果被引用住 = 旧万行整图继续驻留。
 */
async function extraCopyCostMB(page, copies = 2) {
  return page.evaluate(async (n) => {
    const gcTwice = async () => {
      if (typeof window.gc !== 'function') return;
      window.gc();
      await new Promise((r) => setTimeout(r, 250));
      window.gc();
    };
    await gcTwice();
    const before = performance.memory?.usedJSHeapSize ?? 0;
    const hold = [];
    for (let i = 0; i < n; i++) {
      hold.push(
        await window.__TAURI_INTERNALS__.invoke('todo_tasks_list', {
          filter: { keyword: '', page: 1, page_size: 10000 },
        }),
      );
    }
    window.__perfHold = hold;
    await gcTwice();
    const after = performance.memory?.usedJSHeapSize ?? 0;
    window.__perfHold = null;
    return {
      perCopyMB: Math.round(((after - before) / 1048576 / n) * 10) / 10,
    };
  }, copies);
}

function serveDist() {
  const srv = http.createServer((req, res) => {
    let q = decodeURIComponent(req.url.split('?')[0]);
    if (q === '/') q = '/index.html';
    const f = path.join(DIST, q);
    // 严格限制在 DIST 内：防 ../ 越界读整仓
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
            : f.endsWith('.json')
              ? 'application/json'
              : 'application/octet-stream';
      res.setHeader('Content-Type', ct);
      res.end(fs.readFileSync(f));
    } else {
      // SPA 回落到 index.html（前端用 history 路由时深链不能 404）
      const idx = path.join(DIST, 'index.html');
      if (fs.existsSync(idx)) {
        res.setHeader('Content-Type', 'text/html');
        res.end(fs.readFileSync(idx));
      } else {
        res.statusCode = 404;
        res.end();
      }
    }
  });
  srv.listen(PORT);
  return srv;
}

if (!fs.existsSync(path.join(DIST, 'index.html'))) {
  console.error(`GROWTH_CURVE_FAIL: 找不到 ${DIST}/index.html —— 先跑 pnpm build`);
  process.exit(1);
}

const { chromium } = await import('@playwright/test');
const srv = serveDist();
const browser = await chromium.launch({
  args: ['--js-flags=--expose-gc', '--enable-precise-memory-info'],
});
const rootPid = browserRootPid(browser);
if (!rootPid) console.warn('WARN: 拿不到浏览器主进程 pid，rssMB 指标将为 null');

const runs = [];
try {
  for (let run = 0; run < REPEATS; run++) {
    const byTier = {};
    // 每档一个全新上下文：同页清数据测不出「驻留回不来」，且缓存会串档
    for (const tier of TIERS) {
      const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
      const page = await ctx.newPage();
      await page.goto(`http://127.0.0.1:${PORT}/`);
      await page.waitForTimeout(1500);
      const seeded = await page.evaluate((rows) => {
        const m = window.__orbitMock;
        if (!m) return false;
        m.db.tasks.push(...rows);
        m.db.seq = Math.max(m.db.seq, 10000 + rows.length + 1); // 防新建任务 id 撞车
        m.emitDbChange();
        return true;
      }, makeTasks(tier));
      if (!seeded) {
        console.error('GROWTH_CURVE_FAIL: window.__orbitMock 不可用（构建未含 mock IPC 桩）');
        process.exit(1);
      }
      await page.waitForTimeout(3500); // 等万行重拉与虚拟化渲染落定
      byTier[tier] = await sample(page, rootPid);
      if (tier === TIERS[TIERS.length - 1]) {
        const before = byTier[tier].usedMB;
        const sw = await switchChurn(page);
        byTier[tier].switchClicks = sw.clicks;
        byTier[tier].switchPeakMB = sw.peakMB;
        const ch = await churn(page);
        byTier[tier].churnClicks = ch.clicks;
        byTier[tier].churnPeakMB = ch.peakMB;
        await page.waitForTimeout(1500); // 等最后一笔写的重拉落定再采回落值
        const after = await sample(page, rootPid);
        byTier[tier].leakMBAfterChurn =
          Number.isFinite(before) && Number.isFinite(after.usedMB)
            ? Math.round((after.usedMB - before) * 10) / 10
            : null;
        byTier[tier].extraCopyMB = (await extraCopyCostMB(page)).perCopyMB;
      }
      await ctx.close();
    }
    runs.push(byTier);
    console.log(`run ${run + 1}/${REPEATS}: ${JSON.stringify(byTier)}`);
  }
} finally {
  await browser.close();
  srv.close();
}

const measured = {
  usedJSHeapMB_1k: median(runs.map((r) => r[TIERS[0]].usedMB)),
  usedJSHeapMB_10k: median(runs.map((r) => r[TIERS[TIERS.length - 1]].usedMB)),
  totalJSHeapMB_10k: median(runs.map((r) => r[TIERS[TIERS.length - 1]].totalMB)),
  heapKB_per_row: median(runs.map(heapKBPerRow)),
  churnClicks: median(runs.map((r) => r[TIERS[TIERS.length - 1]].churnClicks)),
  switchClicks: median(runs.map((r) => r[TIERS[TIERS.length - 1]].switchClicks)),
  peakMB_onViewSwitch: median(runs.map((r) => r[TIERS[TIERS.length - 1]].switchPeakMB)),
  peakMB_duringChurn: median(runs.map((r) => r[TIERS[TIERS.length - 1]].churnPeakMB)),
  leakMB_after20churn: median(runs.map((r) => r[TIERS[TIERS.length - 1]].leakMBAfterChurn)),
  heapMB_per_extra10kCopy: median(
    runs.map((r) => r[TIERS[TIERS.length - 1]].extraCopyMB),
  ),
  domNodes_10k: median(runs.map((r) => r[TIERS[TIERS.length - 1]].domNodes)),
  domNodesSlope_per_1k: median(
    runs.map((r) => {
      const lo = r[TIERS[0]]?.domNodes;
      const hi = r[TIERS[TIERS.length - 1]]?.domNodes;
      return Number.isFinite(lo) && Number.isFinite(hi)
        ? Math.round((((hi - lo) * 1000) / (TIERS[TIERS.length - 1] - TIERS[0])) * 10) / 10
        : null;
    }),
  ),
  rssMB_10k: median(runs.map((r) => r[TIERS[TIERS.length - 1]].rssMB)),
  measuredAt: new Date().toISOString().slice(0, 10),
  samples: runs,
};

fs.writeFileSync(LAST_RUN, JSON.stringify(measured, null, 2) + '\n');

const cfg = JSON.parse(fs.readFileSync(BASELINES, 'utf8'));
// 阈值合并：thresholds 全平台共用（堆类指标跨平台几乎等值），
// thresholdsByPlatform 覆写平台敏感项（进程 RSS 与窗口/合成器实现相关）；
// 覆写值为 null = 该平台不判此项（尚未采到本机以外的可信数值）
const platform = process.platform === 'win32' ? 'win32' : process.platform === 'linux' ? 'linux' : process.platform;
const overrides = (cfg.thresholdsByPlatform ?? {})[platform] ?? {};
const thresholds = { ...(cfg.thresholds ?? {}), ...overrides };
const skipped = Object.keys(thresholds).filter((k) => thresholds[k] === null);
const violations = [];
if (measured.churnClicks !== CHURN) {
  violations.push(`churnClicks: 实际点击 ${measured.churnClicks}/${CHURN}（勾选行 DOM 契约失配，峰值与回落指标不可信）`);
}
if (measured.switchClicks !== SWITCH) {
  violations.push(`switchClicks: 实际点击 ${measured.switchClicks}/${SWITCH}（侧栏快捷视图按钮失配，切视图峰值指标不可信）`);
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

// targets 只报不拦：门禁判的是「别变差」，方案 §1.1 的期望值另列，避免把「没回归」读成「已达标」
const targetGaps = Object.entries(cfg.targets ?? {})
  .map(([key, want]) => {
    const got = measured[key];
    return Number.isFinite(got) && got > want ? `${key}: 实测 ${got} > 目标 ${want}` : null;
  })
  .filter(Boolean);

if (RECORD) {
  cfg.measured = Object.fromEntries(Object.entries(measured).filter(([k]) => k !== 'samples'));
  cfg.recordedAt = measured.measuredAt;
  fs.writeFileSync(BASELINES, JSON.stringify(cfg, null, 2) + '\n');
  console.log(`已写回 measured → ${path.relative(ROOT, BASELINES)}`);
}

console.log(
  JSON.stringify(
    { platform, measured: { ...measured, samples: undefined }, thresholds, targetGaps, skipped, violations },
    null,
    2,
  ),
);

if (GATE) {
  if (violations.length) {
    console.error('PERF_GATE_FAIL:\n- ' + violations.join('\n- '));
    process.exit(1);
  }
  console.log(
    `PERF_GATE_OK（${platform}：${Object.keys(thresholds).length - skipped.length} 项阈值全过，跳过 ${skipped.length} 项，${TIERS.length} 档 × ${REPEATS} 次中位）`,
  );
}
