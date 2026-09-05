// Playwright 冒烟配置（07 报告 §五-P2#19）
//
// 策略：纯浏览器环境跑主链路——不启动 Tauri 壳，src/test/ipc-mock.ts
// 在页面加载时伪造 __TAURI_INTERNALS__ 接管 invoke/listen，内存库模拟
// Rust 后端。这样 e2e 只依赖 vite dev server（CI 上免 Rust 工具链），
// 与 web job 同一依赖面。
//
// - webServer：自动起 apps/desktop 的 vite dev——专用端口 5273，
//   不用 vite 默认 5173：reuseExistingServer 在本地会直连已监听端口，
//   若恰被同机其他项目的 dev server 占用（实测踩过），测试会全程跑在
//   别人的页面上静默假绿/假红。5273 + strictPort 双保险。
// - 只装 chromium：冒烟主链路单浏览器足够（07 原文「新建→完成→删除」）
import { defineConfig, devices } from "@playwright/test";

const PORT = 5273;

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: `http://localhost:${PORT}`,
    trace: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: {
    command: "pnpm --filter orbit dev --port " + PORT,
    // VITE_E2E_NO_STRICT=1：mock IPC 同步 resolve 与 React 19 StrictMode 的
    // 双调用/批处理组合会让事件内写命令的子树提交静默丢失（见 main.tsx 注释）。
    // 经 webServer.env 注入，跨平台免 cross-env 依赖。
    env: { VITE_E2E_NO_STRICT: "1" },
    url: `http://localhost:${PORT}`,
    reuseExistingServer: !process.env.CI,
    stdout: "ignore",
    timeout: 60_000,
  },
});
