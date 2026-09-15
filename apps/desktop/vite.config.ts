import { defineConfig } from "vite";
import { readFileSync } from "node:fs";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "path";

// Orbit 前端 Vite 配置
// - 固定端口 5173（与 tauri.conf.json devUrl 对齐，strictPort 避免端口漂移）
// - @ 别名指向 src/
// - __APP_VERSION__ 构建期注入：版本唯一数据源 = 本包 package.json#version
//   （其余清单由 scripts/bump-version.mjs 同步），前端不再硬编码版本号
const host = process.env.TAURI_DEV_HOST;

const appVersion = JSON.parse(
  readFileSync(path.resolve(import.meta.dirname, "./package.json"), "utf8"),
).version as string;

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
  define: {
    __APP_VERSION__: JSON.stringify(appVersion),
  },
  server: {
    // 基准端口 5173（与 tauri.conf.json devUrl 对齐）；CLI --port 可覆盖
    // （Playwright e2e 传 5273 隔离端口，防 reuseExistingServer 连上同机
    //   其他项目的 dev server）。strictPort 避免端口漂移。
    port: 5173,
    strictPort: true,
    // 默认绑定 IPv4 回环 127.0.0.1，与 tauri.conf.json 的 devUrl 显式对齐：
    // 规避 Windows 下 localhost 优先解析 IPv6(::1) 而 Vite 仅监听 IPv4，
    // 导致 Tauri 一直 "Waiting for your frontend dev server" 的坑。
    // 跨设备调试（如真机）通过 TAURI_DEV_HOST 指定局域网 IP，并同步改 devUrl。
    host: host || "127.0.0.1",
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
