import React from "react";
import ReactDOM from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

import App from "./App";
import { initThemeOnStartup, initFontSettingsOnStartup } from "./lib/theme";
import "./index.css";

// 启动时初始化主题：在 React 渲染前应用持久化主题，避免主题闪烁（FOUC）
initThemeOnStartup();
// 启动时恢复字体设置（字体族 + 字号 + 字重），避免字体闪烁
initFontSettingsOnStartup();

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

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  </React.StrictMode>,
);
