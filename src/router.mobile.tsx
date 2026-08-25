/**
 * 移动端栈式导航语义（05 §一路由表）；hash 模式规避 WebView asset 协议 history 差异。
 * /about 复用桌面 AboutPage 组件（无壳上下文依赖，AppShell 外直接渲染，外层补 h-dvh）。
 * P0 性能治理：React.lazy 分包。
 */
import { Suspense, lazy, type ReactNode } from "react";
import { Navigate, createHashRouter } from "react-router";

import { EqualizerLoader } from "@/components/EqualizerLoader";

const SidebarScreen = lazy(() =>
  import("@/features/todo/mobile/sidebar-screen").then((m) => ({ default: m.SidebarScreen })),
);
const SubListScreen = lazy(() =>
  import("@/features/todo/mobile/sub-list-screen").then((m) => ({ default: m.SubListScreen })),
);
const DetailScreen = lazy(() =>
  import("@/features/todo/mobile/detail-screen").then((m) => ({ default: m.DetailScreen })),
);
const SettingsMobileScreen = lazy(() =>
  import("@/pages/settings-mobile").then((m) => ({ default: m.SettingsMobileScreen })),
);
const AboutPage = lazy(() =>
  import("@/pages/about-page").then((m) => ({ default: m.AboutPage })),
);

function page(node: ReactNode) {
  return (
    <Suspense
      fallback={
        <div className="grid h-dvh place-items-center bg-[var(--m-bg)]">
          <EqualizerLoader />
        </div>
      }
    >
      {node}
    </Suspense>
  );
}

export const mobileRouter = createHashRouter([
  {
    path: "/",
    children: [
      { index: true, element: <Navigate to="/todo" replace /> },
      { path: "todo", element: page(<SidebarScreen />) },
      { path: "todo/tasks", element: page(<SubListScreen />) },
      { path: "todo/:id", element: page(<DetailScreen />) },
      { path: "settings", element: page(<SettingsMobileScreen />) },
      {
        path: "about",
        element: page(
          <div className="h-dvh overflow-hidden bg-background text-foreground">
            <AboutPage />
          </div>,
        ),
      },
    ],
  },
]);
