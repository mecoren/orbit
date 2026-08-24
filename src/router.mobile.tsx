import { Navigate, createHashRouter } from "react-router";
import { SidebarScreen } from "@/features/todo/mobile/sidebar-screen";
import { SubListScreen } from "@/features/todo/mobile/sub-list-screen";
import { DetailScreen } from "@/features/todo/mobile/detail-screen";
import { PlaceholderScreen } from "@/features/todo/mobile/screens/placeholder";

/**
 * 移动端栈式导航语义（05 §一路由表）；hash 模式规避 WebView asset 协议 history 差异。
 * 占位屏仅剩 /settings 消费（Task 17 替换）。
 */
export const mobileRouter = createHashRouter([
  {
    path: "/",
    children: [
      { index: true, element: <Navigate to="/todo" replace /> },
      { path: "todo", element: <SidebarScreen /> },
      { path: "todo/tasks", element: <SubListScreen /> },
      { path: "todo/:id", element: <DetailScreen /> },
      { path: "settings", element: <PlaceholderScreen name="设置" /> },
    ],
  },
]);
