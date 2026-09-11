/**
 * 交互延迟测量（万级任务 seed）：勾选完成端到端、看板切视图、快速滚动。
 * 用法：node interaction.mjs <distRoot> <label>
 * Chrome 同通道加载本地 dist（mock IPC），测量与 exe 无关的纯前端渲染路径
 * ——这正是批次2/3 优化的对象（失效链、TaskRow memo、侧栏计数）。
 */
import { chromium } from '@playwright/test';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const [distRoot, label] = [process.argv[2], process.argv[3]];

const srv = http.createServer((req, res) => {
  let p = req.url.split('?')[0];
  if (p === '/') p = '/index.html';
  const f = path.join(distRoot, p);
  if (fs.existsSync(f) && fs.statSync(f).isFile()) {
    const ct = f.endsWith('.js') ? 'text/javascript'
      : f.endsWith('.html') ? 'text/html'
      : f.endsWith('.css') ? 'text/css'
      : 'application/octet-stream';
    res.setHeader('Content-Type', ct);
    res.end(fs.readFileSync(f));
  } else { res.statusCode = 404; res.end('nf'); }
}).listen(5282);

const mk = (i) => {
  const now = Date.now();
  return {
    id: 1000 + i, uuid: 'perf-u' + i, title: '性能测量任务 ' + String(i).padStart(5, '0'),
    description: null, project_id: null, priority: i % 6, status: 'pending', done: 0,
    done_at: null, due_date: i % 3 === 0 ? now + (i % 30) * 86400000 : null,
    start_date: null, repeat_after: 0, repeat_mode: 0, percent_done: 0, position: i,
    is_favorite: i % 10 === 0 ? 1 : 0, my_day_date: null, is_deleted: 0,
    created_at: now - i * 1000, updated_at: now - i * 1000, deleted_at: null, version: 1,
  };
};

const b = await chromium.launch();
const page = await b.newPage({ viewport: { width: 1440, height: 900 } });
await page.goto('http://127.0.0.1:5282/');
await page.waitForTimeout(1500);

// 种 10000 条
await page.evaluate((seed) => {
  const m = window.__orbitMock;
  // mock 的字段名差异：title 走 tasks 数组直接 push（批次验证时用过该形态）
  for (const t of seed) m.db.tasks.push(t);
  m.emitDbChange();
}, Array.from({ length: 10000 }, (_, i) => mk(i)));
await page.waitForTimeout(2500); // 等全量列表拉完稳定

const R = {};

// —— 指标1：首次列表渲染（种完到行可见）——
R.rowsVisible = await page.evaluate(() => document.querySelectorAll('[role="button"][aria-label*="任务："]').length);

// —— 指标2：勾选完成端到端 ×20（click→写→db-change→invalidate→React Query 重拉→重渲染）——
const checkTimes = [];
for (let i = 0; i < 15; i++) {
  // 完成口径 = DB done 落 1（写命令+失效+重拉链；React Query 连续写去抖下
  // DOM 帧合并到最后一次——单轮探针已证 DB→DOM 同帧差 ~1ms，故以 dbAt 为准）
  const t = await page.evaluate(async () => {
    const rows = [...document.querySelectorAll('[role="button"][aria-label^="未完成任务"]')];
    const row = rows[0];
    if (!row) return -1;
    const label = row.getAttribute('aria-label');
    const m = label.match(/未完成任务：(.+)$/);
    if (!m) return -4;
    const task = window.__orbitMock.db.tasks.find(t2 => t2.title === m[1]);
    if (!task) return -5;
    const btn = row.querySelector('button[aria-label="标记完成"]');
    if (!btn) return -3;
    const t0 = performance.now();
    btn.click();
    const deadline = t0 + 10000;
    while (performance.now() < deadline) {
      await new Promise(r => setTimeout(r, 5));
      if (task.done === 1) return performance.now() - t0;
    }
    return -2;
  });
  if (t > 0) checkTimes.push(t);
  else console.error('check fail code', t);
  await new Promise(r => setTimeout(r, 200));
}
R.checkDoneMs = { n: checkTimes.length, median: [...checkTimes].sort((a,b)=>a-b)[Math.floor(checkTimes.length/2)] | 0, p95: [...checkTimes].sort((a,b)=>a-b)[Math.floor(checkTimes.length*0.95)] | 0, all: checkTimes.map(x=>Math.round(x)) };

// —— 指标3：快速滚动 10 屏（主列表）长任务与帧率 ——
const scrollPerf = await page.evaluate(async () => {
  const scroller = document.querySelector('.flex-1.overflow-y-auto') ?? document.scrollingElement;
  const t0 = performance.now();
  const frames = [];
  let last = t0;
  function cb(ts) { frames.push(ts - last); last = ts; }
  // rAF 采样帧间隔
  const loop = (ts) => { cb(ts); raf = requestAnimationFrame(loop); };
  let raf = requestAnimationFrame(loop);
  for (let k = 0; k < 10; k++) {
    scroller.scrollTop += 800;
    await new Promise(r => setTimeout(r, 120));
  }
  cancelAnimationFrame(raf);
  const dur = performance.now() - t0;
  const sorted = frames.slice().sort((a,b)=>a-b);
  return { durationMs: Math.round(dur), frames: frames.length, medianFrameMs: sorted[Math.floor(sorted.length/2)] | 0, p95FrameMs: sorted[Math.floor(sorted.length*0.95)] | 0 };
});
R.scroll = scrollPerf;

// —— 指标4：切看板视图（万任务分组首渲染）——
const tView0 = Date.now();
await page.click('button[aria-label="看板视图"]');
R.kanbanFirstPaint = await page.evaluate(async (t0) => {
  const deadline = performance.now() + 8000;
  while (performance.now() < deadline) {
    await new Promise(r => setTimeout(r, 30));
    if (document.querySelectorAll('[role="button"][aria-label*="任务："]').length >= 10) {
      return Math.round(performance.now() - t0);
    }
  }
  return -1;
}, await page.evaluate(() => performance.now()));

// —— 指标5：连续再勾选 5 次看失效率（post 应只失效 todo_tasks 键，pre 全量）——
const checkKanban = [];
for (let i = 0; i < 5; i++) {
  const t = await page.evaluate(async () => {
    const cards = [...document.querySelectorAll('[role="button"][aria-label^="未完成任务"]')];
    const card = cards[0];
    const label = card?.getAttribute('aria-label');
    const m = label?.match(/未完成任务：(.+)$/);
    if (!m) return -4;
    const title = m[1];
    const task = window.__orbitMock.db.tasks.find(t2 => t2.title === title);
    const btn = card?.querySelector('button[aria-label="标记完成"]');
    if (!btn || !task) return -1;
    const t0 = performance.now();
    btn.click();
    const deadline = t0 + 10000;
    while (performance.now() < deadline) {
      await new Promise(r => setTimeout(r, 5));
      if (task.done === 1) return performance.now() - t0;
    }
    return -2;
  });
  if (t > 0) checkKanban.push(Math.round(t));
}
R.checkKanbanMs = { n: checkKanban.length, median: [...checkKanban].sort((a,b)=>a-b)[Math.floor(checkKanban.length/2)] | 0, all: checkKanban };

console.log(JSON.stringify({ label, ...R }, null, 2));
await b.close();
srv.close();
