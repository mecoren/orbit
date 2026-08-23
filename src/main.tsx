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
