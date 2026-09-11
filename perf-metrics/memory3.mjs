/**
 * 差分法内存/CPU：目标进程组 = 启动前后全系统同名进程的净增
 * A. Tauri release（orbit-desktop + msedgewbview2 子树）
 * B. Chromium 同前端（post dist, 万级, 操作期）
 */
import { spawn, execSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const ps = (cmd) => { try { return execSync('powershell -NoProfile -Command ' + JSON.stringify(cmd), { encoding: 'utf8' }).trim(); } catch { return ''; } };

const snapshot = (names) => {
  const list = names.flatMap(n => {
    const out = ps(`Get-Process ${n} -ErrorAction SilentlyContinue | Select-Object Id,WorkingSet64,@{n='CPU';e={[math]::Round($_.CPU,2)}} | ConvertTo-Json -Compress`);
    try { const j = JSON.parse(out); return Array.isArray(j) ? j : [j]; } catch { return []; }
  });
  return { set: new Map(list.map(p => [p.Id, p])), ws: list.reduce((s, p) => s + (p.WorkingSet64 || 0), 0), cpu: list.reduce((s, p) => s + (p.CPU || 0), 0) };
};
const diffMB = (after, before) => Math.round((after.ws - before.ws) / 1048576);

// ===== A. Tauri =====
console.log('== A. Tauri release ==');
const EXE = 'C:/Develop/project/00_AI/orbit/apps/desktop/src-tauri/target/release/orbit-desktop.exe';
{
  const before = snapshot(['orbit-desktop', 'msedgewebview2']);
  const p = spawn(EXE, [], { stdio: 'ignore' });
  await sleep(5000);
  const s1 = snapshot(['orbit-desktop', 'msedgewebview2']);
  await sleep(5000);
  const s2 = snapshot(['orbit-desktop', 'msedgewebview2']);
  console.log(JSON.stringify({
    wsMB_start: diffMB(s1, before), wsMB_stable: diffMB(s2, before),
    cpuS_total: Math.round((s2.cpu - before.cpu) * 10) / 10,
    procs: s2.set.size,
  }));
  ps(`Stop-Process -Id ${p.pid} -Force`);
  await sleep(1500);
}

// ===== B. Chromium 同前端 =====
console.log('== B. Chromium 同前端（post dist, 10k, 操作期）==');
{
  const { chromium } = await import('@playwright/test');
  const srv = http.createServer((req, res) => {
    let q = req.url.split('?')[0]; if (q === '/') q = '/index.html';
    const f = path.join('C:/Develop/project/00_AI/orbit/apps/desktop/perf-snapshots/post/dist', q);
    if (fs.existsSync(f) && fs.statSync(f).isFile()) {
      const ct = f.endsWith('.js') ? 'text/javascript' : f.endsWith('.css') ? 'text/css' : f.endsWith('.html') ? 'text/html' : 'application/octet-stream';
      res.setHeader('Content-Type', ct); res.end(fs.readFileSync(f));
    } else { res.statusCode = 404; res.end(); }
  }).listen(5274);
  const before = snapshot(['chrome', 'chrome-headless-shell', 'chromium']);
  const b = await chromium.launch();
  const page = await b.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto('http://127.0.0.1:5274/');
  await page.waitForTimeout(2000);
  const mk = (i) => { const now = Date.now(); return {
    id: 1000+i, uuid: 'u'+i, title: '性能测量任务 '+String(i).padStart(5,'0'), description: null, project_id: null,
    priority: i%6, status: 'pending', done: 0, done_at: null, due_date: i%3===0? now+(i%30)*86400000 : null, start_date: null,
    repeat_after: 0, repeat_mode: 0, percent_done: 0, position: i, is_favorite: 0,
    my_day_date: null, is_deleted: 0, created_at: now, updated_at: now, deleted_at: null, version: 1 };};
  await page.evaluate((seed) => { const m = window.__orbitMock; for (const t of seed) m.db.tasks.push(t); m.emitDbChange(); }, Array.from({length: 10000}, (_, i) => mk(i)));
  await page.waitForTimeout(3000);
  const sIdle = snapshot(['chrome', 'chrome-headless-shell', 'chromium']);
  const cpu1 = sIdle.cpu;
  // 操作期：10 屏滚动 + 5 勾选
  await page.evaluate(async () => {
    const sc = document.querySelector('div.overflow-y-auto');
    for (let k = 0; k < 10; k++) { if (sc) sc.scrollTop += 900; await new Promise(r => setTimeout(r, 100)); }
    for (let c = 0; c < 5; c++) {
      const row = document.querySelector('[role="button"][aria-label^="未完成任务"]');
      row?.querySelector('button[aria-label="标记完成"]')?.click();
      await new Promise(r => setTimeout(r, 400));
    }
  });
  await page.waitForTimeout(1000);
  const sBusy = snapshot(['chrome', 'chrome-headless-shell', 'chromium']);
  const heap = await page.evaluate(() => performance.memory
    ? { usedJSMB: Math.round(performance.memory.usedJSHeapSize / 1048576), totalMB: Math.round(performance.memory.totalJSHeapSize / 1048576) } : null);
  console.log(JSON.stringify({
    wsMB_idle10k: diffMB(sIdle, before), wsMB_busy: diffMB(sBusy, before),
    cpuDeltaS_操作期: Math.round((sBusy.cpu - cpu1) * 10) / 10, jsHeap: heap,
    procs: sBusy.set.size,
  }));
  await b.close(); srv.close();
}
