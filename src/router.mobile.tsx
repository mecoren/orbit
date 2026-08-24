import { Navigate, createHashRouter } from "react-router";
import { SidebarScreen } from "@/features/todo/mobile/sidebar-screen";
import { SubListScreen } from "@/features/todo/mobile/sub-list-screen";
import { DetailScreen } from "@/features/todo/mobile/detail-screen";
import { SettingsMobileScreen } from "@/pages/settings-mobile";
import { AboutPage } from "@/pages/about-page";

/**
 * 移动端栈式导航语义（05 §一路由表）；hash 模式规避 WebView asset 协议 history 差异。
 * /about 复用桌面 AboutPage 组件（无壳上下文依赖，AppShell 外直接渲染，外层补 h-dvh）。
 */
export const mobileRouter = createHashRouter([
  {
    path: "/",
    children: [
      { index: true, element: <Navigate to="/todo" replace /> },
      { path: "todo", element: <SidebarScreen /> },
      { path: "todo/tasks", element: <SubListScreen /> },
      { path: "todo/:id", element: <DetailScreen /> },
      { path: "settings", element: <SettingsMobileScreen /> },
      { path: "about", element: (
        <div className="h-dvh overflow-hidden bg-background text-foreground">
          <AboutPage />
        </div>
      ) },
    ],
  },
]);
