/**
 * router — 桌面端路由（createBrowserRouter）
 *
 * MVP 路由面：/todo + /settings + /about + /sync-recovery。
 * 移动端已拆分为独立 Flutter 应用（apps/mobile），本文件仅服务桌面。
 * P0 性能治理：React.lazy 路由级分包——首屏仅加载当前页。
 */
import { Suspense, lazy, type ReactNode } from "react";
import { Navigate, createBrowserRouter } from "react-router";

import { AppShell } from "@/components/layout/app-shell";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { RouteError } from "@/components/layout/route-error";

const TodoShell = lazy(() => import("@/features/todo/desktop/todo-shell"));
const TaskPanel = lazy(() => import("@/features/todo/desktop/task-panel"));
const TrashPanel = lazy(() =>
  import("@/features/todo/desktop/trash-page").then((m) => ({ default: m.TrashPanel })),
);
const SettingsPage = lazy(() =>
  import("@/pages/settings-page").then((m) => ({ default: m.SettingsPage })),
);
const AboutPage = lazy(() =>
  import("@/pages/about-page").then((m) => ({ default: m.AboutPage })),
);
const SyncRecoveryPage = lazy(() =>
  import("@/pages/sync-recovery-page").then((m) => ({ default: m.SyncRecoveryPage })),
);

/** 懒加载页统一 fallback：壳内居中加载动画 */
function LazyFallback() {
  return (
    <div className="grid h-full place-items-center">
      <EqualizerLoader />
    </div>
  );
}

function page(node: ReactNode) {
  return <Suspense fallback={<LazyFallback />}>{node}</Suspense>;
}

/** 桌面子路由表（路径与 M4 前一致，零行为变化；每个懒页挂 errorElement 兜 chunk 失败） */
const desktopChildren = [
  { index: true, element: <Navigate to="/todo" replace /> },
  {
    path: "todo",
    element: page(<TodoShell />),
    errorElement: <RouteError />,
    children: [
      // 壳层嵌套：侧栏/选中态/抽屉表单跨面板持久，Outlet 出任务/回收站面板
      { index: true, element: page(<TaskPanel />), errorElement: <RouteError /> },
      { path: "trash", element: page(<TrashPanel />), errorElement: <RouteError /> },
    ],
  },
  { path: "settings", element: page(<SettingsPage />), errorElement: <RouteError /> },
  { path: "about", element: page(<AboutPage />), errorElement: <RouteError /> },
  { path: "sync-recovery", element: page(<SyncRecoveryPage />), errorElement: <RouteError /> },
];

export const router = createBrowserRouter([
  { path: "/", element: <AppShell />, children: desktopChildren },
]);
