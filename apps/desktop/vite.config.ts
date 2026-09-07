import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "path";

// Orbit 前端 Vite 配置
// - 固定端口 5173（与 tauri.conf.json devUrl 对齐，strictPort 避免端口漂移）
// - @ 别名指向 src/
const host = process.env.TAURI_DEV_HOST;

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
  ],
  resolve: {
    alias: {
      "@": path.resolve(import.meta.dirname, "./src"),
    },
  },
  build: {
    rollupOptions: {
      // P0 #2 补齐：vendor 分包——框架/大库独立 chunk，避免被随机打进
      // 首屏或某个懒页（懒页间共享的依赖若随页各自复制会重复解析）。
      // Tauri 本地加载无网络成本，但解析/执行时间仍计入冷启动；
      // vendor 首屏一次加载后跨懒页复用
      output: {
        manualChunks(id) {
          if (!id.includes("node_modules")) return undefined;
          // react 全家（react/react-dom/scheduler）+ router + react-query
          if (
            /[\\/]react[\\/]|[\\/]react-dom[\\/]|[\\/]react-router[\\/]|[\\/]scheduler[\\/]/.test(
              id,
            ) ||
            id.includes("@tanstack" + path.sep + "react-query") ||
            id.includes("@tanstack/react-query")
          ) {
            return "vendor-react";
          }
          // 其余依赖统一 vendor（date-fns/lucide/sonner/radix/dnd-kit 等）
          return "vendor";
        },
      },
    },
  },
  clearScreen: false,
  server: {
    // 基准端口 5173（与 tauri.conf.json devUrl 对齐）；CLI --port 可覆盖
    // （Playwright e2e 传 5273 隔离端口，防 reuseExistingServer 连上同机
    //   其他项目的 dev server）。strictPort 避免端口漂移。
    port: 5173,
    strictPort: true,
    host: host || false,
    hmr: host
      ? { protocol: "ws", host, port: 5174 }
      : undefined,
    watch: {
      // monorepo：vite cwd = apps/desktop，必须排除 Rust 构建产物与源码目录
      // （target/ 内的 dll 在 cargo 链接时被锁定，fs.watch 会抛 EBUSY 致
      //   dev server 崩溃；Rust 源码变更由 Tauri 自身监视重启，Vite 不重复触发）
      ignored: ["**/src-tauri/**", "**/crates/**", "**/target/**"],
    },
  },
});
