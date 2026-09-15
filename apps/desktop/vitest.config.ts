import { defineConfig } from "vitest/config";
import { readFileSync } from "node:fs";
import path from "path";

// Orbit 前端 vitest 配置
// - 纯逻辑单测（node 环境），不挂载组件；@ 别名与 vite.config.ts 对齐指向 src/
// - __APP_VERSION__ 与 vite.config.ts 同口径注入：避免引用该全局的模块在测试下取到 undefined
const appVersion = JSON.parse(
  readFileSync(path.resolve(import.meta.dirname, "./package.json"), "utf8"),
).version as string;

export default defineConfig({
  resolve: { alias: { "@": path.resolve(import.meta.dirname, "./src") } },
  define: { __APP_VERSION__: JSON.stringify(appVersion) },
  test: { environment: "node", include: ["src/**/*.test.ts"] },
});
