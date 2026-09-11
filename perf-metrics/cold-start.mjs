/**
 * 冷启动测量：release exe 起 → 首窗显示 → +400ms 可交互缓冲（毫秒）
 * 口径：Spawn → MainWindowHandle 轮询（20ms）→ shown；interactive = shown+400ms
 * 用法：node perf-metrics/cold-start.mjs（需先 cargo build --release）
 */
import { spawn } from 'node:child_process';
import { execSync } from 'node:child_process';

const EXE = 'C:/Develop/project/00_AI/orbit/apps/desktop/src-tauri/target/release/orbit-desktop.exe';
const ROUNDS = 5;
const runPS = (cmd) => { try { return execSync('powershell -NoProfile -Command ' + JSON.stringify(cmd), { encoding: 'utf8' }).trim(); } catch { return ''; } };

const run = async () => new Promise((resolve) => {
  const t0 = performance.now();
  const p = spawn(EXE, [], { detached: false, stdio: 'ignore' });
  const poll = setInterval(async () => {
    const win = runPS(`(Get-Process -Id ${p.pid} -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }).Count`);
    if (win && Number(win) > 0) {
      clearInterval(poll);
      const shown = performance.now() - t0;
      setTimeout(() => resolve({ shown: Math.round(shown), interactive: Math.round(shown + 400), pid: p.pid }), 400);
    } else if (performance.now() - t0 > 30000) {
      clearInterval(poll); resolve(null);
    }
  }, 20);
});

const results = [];
for (let i = 0; i < ROUNDS; i++) {
  const r = await run();
  results.push(r);
  console.log(`round ${i+1}: shown=${r?.shown}ms interactive≈${r?.interactive}ms`);
  runPS(`Stop-Process -Id ${r.pid} -Force`);
  await new Promise(r2 => setTimeout(r2, 1500));
}
const arr = results.filter(Boolean).map(r => r.interactive).sort((a,b)=>a-b);
console.log('MEDIAN_INTERACTIVE=' + arr[Math.floor(arr.length/2)]);
console.log('MIN=' + arr[0] + ' MAX=' + arr[arr.length-1]);
