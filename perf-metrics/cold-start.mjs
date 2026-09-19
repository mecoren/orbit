/**
 * 冷启动测量（真首屏口径，docs/09 §六）
 *
 * 口径：spawn release exe 前取 t0 → 应用在「boot 门控落到持续画面
 * （解锁页/主界面）且首帧绘制完成」时调 perf_first_screen_mark，把当时
 * epoch 毫秒写入 ORBIT_PERF_MARKER 指定文件 → 脚本按 `文件内时刻 - t0`
 * 得到首屏耗时。旧口径「首窗句柄轮询 + 400ms 拍定常数」不是就绪信号，
 * 已废弃（2026-09-19 换真 marker）。
 *
 * 注意：有主密码的库会停在解锁页——那测到的是「解锁页就绪」；测启动
 * 性能请用免密库。标记文件每轮先删（Rust 侧 create_new + 进程内 once 闸，
 * 只记第一笔且不覆盖既有文件）。
 *
 * 用法：node perf-metrics/cold-start.mjs（需先 cargo build --release）
 */
import { spawn, execSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROUNDS = 5;
const MARKER = path.join(os.tmpdir(), `orbit-cold-start-${process.pid}.marker`);
// 包名改名过渡期（orbit-desktop → orbit）两候选：取存在的那个
const RELEASE_DIR = 'C:/Develop/project/00_AI/orbit/apps/desktop/src-tauri/target/release';
const EXE = ['orbit.exe', 'orbit-desktop.exe']
  .map((n) => path.join(RELEASE_DIR, n))
  .find((p) => fs.existsSync(p));
const runPS = (cmd) => { try { return execSync('powershell -NoProfile -Command ' + JSON.stringify(cmd), { encoding: 'utf8' }).trim(); } catch { return ''; } };

if (!EXE) {
  console.error('未找到 release exe（先 `cargo build --release` 且先 `pnpm build` 出新前端）');
  process.exit(1);
}

const run = async () => new Promise((resolve) => {
  try { fs.rmSync(MARKER, { force: true }); } catch { /* 无残留 */ }
  const t0 = Date.now();
  const p = spawn(EXE, [], {
    detached: false,
    stdio: 'ignore',
    env: { ...process.env, ORBIT_PERF_MARKER: MARKER },
  });
  let done = false;
  const finish = (v) => { if (!done) { done = true; clearInterval(poll); resolve(v); } };
  const poll = setInterval(() => {
    try {
      if (fs.existsSync(MARKER)) {
        const at = Number(fs.readFileSync(MARKER, 'utf8').trim());
        finish({ firstScreenMs: at > 0 ? at - t0 : Date.now() - t0, pid: p.pid });
        return;
      }
    } catch { /* 写入中，下一轮再读 */ }
    if (Date.now() - t0 > 30000) finish(null);
  }, 10);
});

const results = [];
for (let i = 0; i < ROUNDS; i++) {
  const r = await run();
  results.push(r);
  console.log(`round ${i + 1}: firstScreen=${r ? r.firstScreenMs + 'ms' : '未上报（超时）'}`);
  if (r) runPS(`Stop-Process -Id ${r.pid} -Force`);
  await new Promise((r2) => setTimeout(r2, 1500));
}
const arr = results.filter(Boolean).map((r) => r.firstScreenMs).sort((a, b) => a - b);
if (arr.length === 0) {
  console.log('MEDIAN_FIRST_SCREEN=n/a（全部轮次未收到 marker：确认 exe 为含 perf_first_screen_mark 的最新 release 构建）');
} else {
  console.log('MEDIAN_FIRST_SCREEN=' + arr[Math.floor(arr.length / 2)]);
  console.log('MIN=' + arr[0] + ' MAX=' + arr[arr.length - 1] + `（${arr.length}/${ROUNDS} 轮有效）`);
}
