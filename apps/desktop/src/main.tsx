import React from "react";
import ReactDOM from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

import App from "./App";
import { initThemeOnStartup, initFontSettingsOnStartup } from "./lib/theme";
import { applyPlatformClass } from "./lib/platform";
import { installBrowserIpc } from "./test/ipc-mock";
import "./index.css";

// 纯浏览器环境（Playwright 冒烟，#19）：伪造 __TAURI_INTERNALS__ 接管
// invoke/listen（真实 Tauri WebView 已注入 internals 时为 no-op）
installBrowserIpc();

// 启动时初始化主题：在 React 渲染前应用持久化主题，避免主题闪烁（FOUC）
initThemeOnStartup();
// 启动时恢复字体设置（字体族 + 字号 + 字重），避免字体闪烁
initFontSettingsOnStartup();
// 平台类挂载：<html> 添加 .platform-{win|mac|linux}——mac 红绿灯让位、
// Linux 材质 CSS 回退等平台规则依赖此类（须在首帧渲染前生效）
applyPlatformClass();

// 首帧就绪后显示窗口：tauri.conf.json 配 visible:false 隐藏原生空窗，
// 由前端在主题/字体初始化后主动 show，消除启动瞬间的白屏闪烁。
// capability 已含 core:default（含 window:allow-show）；非 Tauri 环境
// （纯浏览器 dev）无 window API，静默跳过。
void import("@tauri-apps/api/window")
  .then(({ getCurrentWindow }) => getCurrentWindow().show())
  .catch(() => {});

// 生产环境屏蔽默认网页右键菜单：应用内自定义右键菜单在组件层已 stopPropagation，
// 不受此影响；输入类元素保留原生菜单以便复制粘贴。开发环境不屏蔽，便于调试。
if (!import.meta.env.DEV) {
  document.addEventListener("contextmenu", (e) => {
    const target = e.target as Element | null;
    if (!target?.closest("input, textarea, [contenteditable]")) {
      e.preventDefault();
    }
  });
}

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 30,
      refetchOnWindowFocus: false,
    },
  },
});

// Playwright 冒烟环境（#19）关闭 StrictMode：mock IPC 同步 resolve 与
// React 19 的双调用/批处理组合会让「事件内写命令 → 缓存更新 → 子树提交」
// 静默丢失（渲染函数执行但不提交 DOM；真 Tauri 的 IPC 异步时序不复现）。
// StrictMode 是开发期检查工具而非产品语义，仅 e2e 注入此开关，不影响日常开发。
const strictModeDisabled = import.meta.env.VITE_E2E_NO_STRICT === "1";

ReactDOM.createRoot(document.getElementById("root")!).render(
  strictModeDisabled ? (
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  ) : (
    <React.StrictMode>
      <QueryClientProvider client={queryClient}>
        <App />
      </QueryClientProvider>
    </React.StrictMode>
  ),
);
