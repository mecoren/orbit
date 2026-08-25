import { defineConfig } from "vitest/config";
import path from "path";

// Orbit 前端 vitest 配置
// - 纯逻辑单测（node 环境），不挂载组件；@ 别名与 vite.config.ts 对齐指向 src/
export default defineConfig({
  resolve: { alias: { "@": path.resolve(import.meta.dirname, "./src") } },
  test: { environment: "node", include: ["src/**/*.test.ts"] },
});
