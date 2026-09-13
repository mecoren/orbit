/**
 * 列裁剪收益测量（批2 专用）：万级任务 × 1KB description 场景下
 * todo_tasks_list 命令返回数据的 JSON 序列化体积 + JS heap 占用。
 *
 * 体积口径：mock IPC 的 list 命令返回对象在真实 Tauri 下要经
 * JSON 序列化过 WebView IPC——此处直接 JSON.stringify 量同一数据形状，
 * 是真机 IPC 传输量的下界估计（序列化开销对齐）。
 *
 * 用法：node perf-metrics/column-prune.mjs <distRoot> <label>
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
      : (f.endsWith('.html') ? 'text/html' : f.endsWith('.css') ? 'text/css' : 'application/octet-stream');
    res.setHeader('Content-Type', ct);
    res.end(fs.readFileSync(f));
  } else { res.statusCode = 404; res.end('nf'); }
}).listen(5283);

// 1KB 描述（UTF-8 中文按 3 字节/字计，~341 字 ≈ 1023B）
const DESC_1KB = '描述内容'.repeat(85) + '尾部';

const mk = (i) => {
  const now = Date.now();
  return {
    id: 1000 + i, uuid: 'prune-u' + i, title: '列裁剪测量 ' + String(i).padStart(5, '0'),
    description: DESC_1KB, project_id: null, priority: i % 6, status: 'pending', done: 0,
    done_at: null, due_date: i % 3 === 0 ? now + (i % 30) * 86400000 : null,
    start_date: null, repeat_after: 0, repeat_mode: 0, percent_done: 0, position: i,
    is_favorite: i % 10 === 0 ? 1 : 0, my_day_date: null, is_deleted: 0,
    created_at: now - i * 1000, updated_at: now - i * 1000, deleted_at: null, version: 1,
  };
};

const b = await chromium.launch();
const page = await b.newPage({ viewport: { width: 1440, height: 900 } });
await page.goto('http://127.0.0.1:5283/');
await page.waitForTimeout(1500);

// 种 10000 条（全部带 1KB description）
await page.evaluate((seed) => {
  const m = window.__orbitMock;
  for (const t of seed) m.db.tasks.push(t);
  m.emitDbChange();
}, Array.from({ length: 10000 }, (_, i) => mk(i)));
await page.waitForTimeout(2500);

// 指标1：列表命令返回数据的序列化体积（= 真机 IPC 传输量口径）。
// 经 mock invoke 走真实命令面（todo_tasks_list 的 ipcClone 返回值），
// 裁剪改 mock 后此数字直接反映实现效果（而非脚本内模拟）。
const sizes = await page.evaluate(async () => {
  const rows = await window.__TAURI_INTERNALS__.invoke('todo_tasks_list', {
    filter: { page: 1, page_size: 10000 },
  });
  const wire = JSON.stringify(rows);
  return {
    rows: rows.length,
    wireBytes: wire.length,
    descBytesInPayload: rows.reduce((m, t) => m + (t.description?.length ?? 0), 0),
  };
});

// 指标3：列表渲染冒烟（裁剪不应破坏主路径——mock 直改后列表仍出万行）
const rowsVisible = await page.evaluate(() =>
  document.querySelectorAll('[role="button"][aria-label*="任务："], [role="button"][aria-label^="未完成任务"]').length,
);

console.log(JSON.stringify({ label, ...sizes, rowsVisible }, null, 2));
await b.close();
srv.close();
