/**
 * router — 桌面端路由（createBrowserRouter）
 *
 * MVP 路由面：/todo（待办，M2 复刻替换占位）+ /settings + /about。
 * M1 将追加 /unlock 解锁页与启动引导流（01 文档 §四）。
 */
import { Navigate, createBrowserRouter } from "react-router";

import { AppShell } from "@/components/layout/app-shell";
import TodoListPage from "@/features/todo/desktop/list-page";
import { SettingsPage } from "@/pages/settings-page";
import { AboutPage } from "@/pages/about-page";
import { SyncRecoveryPage } from "@/pages/sync-recovery-page";

export const router = createBrowserRouter([
  {
    path: "/",
    element: <AppShell />,
    children: [
      { index: true, element: <Navigate to="/todo" replace /> },
      { path: "todo", element: <TodoListPage /> },
      { path: "settings", element: <SettingsPage /> },
      { path: "about", element: <AboutPage /> },
      { path: "sync-recovery", element: <SyncRecoveryPage /> },
    ],
  },
]);
