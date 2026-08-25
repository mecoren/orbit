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
  clearScreen: false,
  server: {
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
