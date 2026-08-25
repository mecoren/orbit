# P0 快赢改进实施计划（性能/质量六项）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地竞品分析报告(docs/07_竞品对比与改进机会分析.md)P0 六项：CI 门禁、图标字体子集化(−5.1MB)、路由代码分割(985KB 单包拆分)、桌面列表三态接入、双端列表虚拟化(守 500 条 60fps DoD)、删除撤销。

**Architecture:** 全部为前端(src/)与工程配置层改动，零 Rust 侧改动。撤销采用「延迟提交」策略：确认后乐观隐藏 react-query 缓存行，5s 撤销窗口后才执行真删除命令——无需后端 restore 语义。Provider 挂在 ListPage 层保证撤销实例不随行/抽屉卸载而丢失。

**Tech Stack:** pnpm(9.0 lockfile)、React 19、Vite 8(rolldown)、TanStack Query v5、@tanstack/react-virtual ^3(新增)、sonner、vitest 4(node 环境)。

## Global Constraints

- 包管理器只用 pnpm；Node ≥ 20（子集脚本依赖全局 fetch）。
- 不修改 `orbit_core/`、`src-tauri/` 任何文件。
- queryKey 约定不变：`["todo_tasks", keyword]`、`["todo-project", "list"]`、`["todo-label", "list"]`（前缀匹配语义见 events.ts）。
- 全部界面文案为中文；新增文件沿用仓库现有的中文 JSDoc 文件头注释风格。
- **明确排除**：移动端删除撤销（WaitToast 规格无 action 槽位，05 §五，记 P1）；看板列虚拟化（MVP 无看板性能验收线，P1 复核）；Rust 五端构建矩阵（本计划只做 web 质量门禁）。
- 每个 Task 收尾必须 `pnpm typecheck && pnpm test` 全绿后才 Commit。
- 提交信息遵循仓库惯例 `type(scope): 中文描述`（参照 git log：`feat(m4): ...`）。

---

### Task 1: CI 最小质量门禁

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: 无
- Produces: push/PR 到 main 时自动跑 typecheck + test + web build 的门禁（后续任务的回归防线）

- [ ] **Step 1: 写 workflow 文件**

```yaml
# .github/workflows/ci.yml
# P0 最小门禁:typecheck + 单测 + web 构建(Rust 五端矩阵按 06 文档另立)
name: ci

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  web:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: pnpm/action-setup@v4
        with:
          version: 9

      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: pnpm

      - name: 安装依赖
        run: pnpm install --frozen-lockfile

      - name: 类型检查
        run: pnpm typecheck

      - name: 单元测试
        run: pnpm test

      - name: 生产构建(纯 web,不含 Tauri)
        run: pnpm build
```

- [ ] **Step 2: 本地预演三个命令全绿**

Run: `pnpm install --frozen-lockfile; pnpm typecheck; pnpm test; pnpm build`
Expected: install 无报错；typecheck 无输出；39 tests passed；build 产出 dist/。

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: minimal web quality gate (typecheck+test+build)"
```

---

### Task 2: Material Symbols 字体子集化（−5.1MB）

**Files:**
- Create: `scripts/icon-names.json`
- Create: `scripts/subset-icons.mjs`
- Create: `src/components/mobile/material-icon-names.test.ts`（守卫测试）
- Modify: `package.json`（scripts 增加 fonts:subset）
- Modify: `src/index.css:552`（@font-face src 换子集文件）
- Delete: `public/fonts/MaterialSymbolsRounded.woff2`（全量字体，历史可追回）

**Interfaces:**
- Consumes: 各屏 `MaterialIcon name="..."` 字面量（已盘点 32 个，含 sidebar-screen.tsx:47 QUICK_VIEW_ICON 映射值与 form-bottom-sheet.tsx:551 三元动态名）
- Produces: `public/fonts/MaterialSymbolsRounded.subset.woff2`（预期 <100KB）；npm script `pnpm fonts:subset`；守卫测试防止新图标漏入清单

- [ ] **Step 1: 写图标名清单**

```json
[
  "add_circle_outline_rounded",
  "add_rounded",
  "arrow_back_rounded",
  "block_rounded",
  "calendar_today_rounded",
  "check",
  "check_circle_outline_rounded",
  "check_rounded",
  "checklist",
  "chevron_left_rounded",
  "chevron_right_rounded",
  "close",
  "close_rounded",
  "date_range_rounded",
  "delete_outline",
  "delete_outline_rounded",
  "drag_handle_rounded",
  "edit_rounded",
  "expand_less_rounded",
  "expand_more_rounded",
  "inbox_rounded",
  "keyboard_arrow_right_rounded",
  "list_alt_rounded",
  "more_vert_rounded",
  "notifications_outlined",
  "radio_button_unchecked_rounded",
  "schedule_rounded",
  "search_rounded",
  "send_rounded",
  "settings_rounded",
  "star",
  "star_border_rounded"
]
```

- [ ] **Step 2: 写守卫测试（先跑，应通过——清单已覆盖全部静态字面量）**

```ts
// src/components/mobile/material-icon-names.test.ts
// 守卫:src 下所有静态 <MaterialIcon name="xxx"> 字面量必须已登记进
// scripts/icon-names.json(动态名如三元/映射值靠人工评审,此测试兜底静态项)。
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const SRC_DIR = fileURLToPath(new URL("../..", import.meta.url)); // src/

function* walk(dir: string): Generator<string> {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else if (p.endsWith(".tsx")) yield p;
  }
}

const allowlist: string[] = JSON.parse(
  readFileSync(join(SRC_DIR, "..", "scripts", "icon-names.json"), "utf8"),
);

describe("material icon 子集清单守卫", () => {
  it("清单无空项、无重复", () => {
    expect(allowlist.every((n) => /^[a-z0-9_]+$/.test(n))).toBe(true);
    expect(new Set(allowlist).size).toBe(allowlist.length);
  });

  it("所有静态 name 字面量都已登记", () => {
    const missing: string[] = [];
    const re = /<MaterialIcon\s+name="([a-z0-9_]+)"/g;
    for (const file of walk(SRC_DIR)) {
      const content = readFileSync(file, "utf8");
      for (const m of content.matchAll(re)) {
        if (!allowlist.includes(m[1])) missing.push(`${m[1]} (${file})`);
      }
    }
    expect(missing).toEqual([]);
  });
});
```

- [ ] **Step 3: 跑测试确认通过**

Run: `pnpm test -- material-icon-names`
Expected: 2 passed。

- [ ] **Step 4: 写子集脚本**

```js
// scripts/subset-icons.mjs
// Material Symbols 子集生成器(P0 性能治理):
// 按 scripts/icon-names.json 清单调 Google Fonts css2 API,生成保留 ligature
// 的可变字体子集 woff2(全量 5.1MB → 预期 <100KB)。
// 用法:pnpm fonts:subset(需联网,一次性执行,产物提交入库)
import { readFile, writeFile } from "node:fs/promises";

const NAMES_PATH = new URL("./icon-names.json", import.meta.url);
const OUT_PATH = new URL("../public/fonts/MaterialSymbolsRounded.subset.woff2", import.meta.url);

const names = JSON.parse(await readFile(NAMES_PATH, "utf8"));
if (!Array.isArray(names) || names.length === 0 || names.some((n) => !/^[a-z0-9_]+$/.test(n))) {
  console.error("icon-names.json 必须是非空的 [a-z0-9_] 字符串数组");
  process.exit(1);
}

// icon_names 需字母序;UA 必须是浏览器身份才返回 woff2(默认 UA 给 ttf)
const family = "Material+Symbols+Rounded";
const axes = "opsz,wght,FILL,GRAD@20..48,100..700,0..1,-50..200";
const cssUrl =
  `https://fonts.googleapis.com/css2?family=${family}:${axes}` +
  `&icon_names=${[...names].sort().join(",")}&display=block`;
const cssRes = await fetch(cssUrl, {
  headers: {
    "User-Agent":
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
  },
});
if (!cssRes.ok) {
  console.error(`css2 请求失败: ${cssRes.status}`);
  process.exit(1);
}
const css = await cssRes.text();
const m = css.match(/url\((https:[^)]+\.woff2)\)/);
if (!m) {
  console.error("css 响应中未找到 woff2 链接,响应头部:\n" + css.slice(0, 400));
  process.exit(1);
}
const fontRes = await fetch(m[1]);
if (!fontRes.ok) {
  console.error(`字体下载失败: ${fontRes.status}`);
  process.exit(1);
}
const buf = Buffer.from(await fontRes.arrayBuffer());
await writeFile(OUT_PATH, buf);
console.log(`已写入 ${OUT_PATH.pathname} — ${buf.length} bytes, ${names.length} 个图标`);
```

同时给 `package.json` 的 scripts 段加一行（放在 `"tauri"` 之前）：

```json
    "fonts:subset": "node scripts/subset-icons.mjs",
```

- [ ] **Step 5: 执行子集化并核对体积**

Run: `pnpm fonts:subset`
Expected: 输出 `已写入 ... — NNNNN bytes, 32 个图标`，N < 102400（约 15–60KB）。若失败（网络），重试或检查代理；产物一旦生成本地不再依赖网络。

- [ ] **Step 6: 切换 @font-face 并删除全量字体**

`src/index.css:552` 改为：

```css
  src: url("/fonts/MaterialSymbolsRounded.subset.woff2") format("woff2");
```

然后：

```bash
git rm public/fonts/MaterialSymbolsRounded.woff2
```

- [ ] **Step 7: 全量验证**

Run: `pnpm typecheck; pnpm test; pnpm build`
Expected: 全绿；dist/assets 中不再出现 5MB 级资源。
人工抽查（可选）：`pnpm dev` 用 DevTools 设备模拟（命中移动 hash 路由）打开 `/todo`，确认图标正常渲染非圆点占位。

- [ ] **Step 8: Commit**

```bash
git add scripts/icon-names.json scripts/subset-icons.mjs src/components/mobile/material-icon-names.test.ts package.json src/index.css public/fonts/
git commit -m "perf(m4): subset material symbols font (5.1MB -> <100KB) with guard test"
```

---

### Task 3: 路由级代码分割

**Files:**
- Modify: `src/router.tsx`（全文重写，29 行）
- Modify: `src/router.mobile.tsx`（全文重写，28 行）

**Interfaces:**
- Consumes: 各页面导出形态——list-page 为 default 导出；SettingsPage/AboutPage/SyncRecoveryPage/SidebarScreen/SubListScreen/DetailScreen/SettingsMobileScreen 为具名导出
- Produces: 路由懒加载 chunk（无 API 变化，路由表路径完全不变）

- [ ] **Step 1: 重写桌面路由**

```tsx
// src/router.tsx
/**
 * router — 桌面端路由（createBrowserRouter）
 *
 * MVP 路由面：/todo + /settings + /about + /sync-recovery。
 * M4 平台分叉：移动 UA 下改挂 router.mobile.tsx 的 hash 路由，桌面路由零变化。
 * P0 性能治理：React.lazy 路由级分包——首屏仅加载当前页。
 */
import { Suspense, lazy, type ReactNode } from "react";
import { Navigate, createBrowserRouter } from "react-router";

import { AppShell } from "@/components/layout/app-shell";
import { EqualizerLoader } from "@/components/EqualizerLoader";
import { isMobilePlatform } from "@/lib/platform";
import { mobileRouter } from "@/router.mobile";

const TodoListPage = lazy(() => import("@/features/todo/desktop/list-page"));
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

/** 桌面子路由表（路径与 M4 前一致，零行为变化） */
const desktopChildren = [
  { index: true, element: <Navigate to="/todo" replace /> },
  { path: "todo", element: page(<TodoListPage />) },
  { path: "settings", element: page(<SettingsPage />) },
  { path: "about", element: page(<AboutPage />) },
  { path: "sync-recovery", element: page(<SyncRecoveryPage />) },
];

export const router = isMobilePlatform()
  ? mobileRouter
  : createBrowserRouter([{ path: "/", element: <AppShell />, children: desktopChildren }]);
```

- [ ] **Step 2: 重写移动路由**

```tsx
// src/router.mobile.tsx
/**
 * 移动端栈式导航语义（05 §一路由表）；hash 模式规避 WebView asset 协议 history 差异。
 * /about 复用桌面 AboutPage 组件（无壳上下文依赖，AppShell 外直接渲染，外层补 h-dvh）。
 * P0 性能治理：React.lazy 分包。
 */
import { Suspense, lazy } from "react";
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

function page(node: React.ReactNode) {
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
      { path: "about", element: page(
        <div className="h-dvh overflow-hidden bg-background text-foreground">
          <AboutPage />
        </div>
      ) },
    ],
  },
]);
```

注意：mobile 版 `page` 里用了 `React.ReactNode`，需在顶部 import 补 `type ReactNode` 并写作 `ReactNode`（保持与桌面版一致的显式类型导入，避免依赖全局 React UMD 类型）。

- [ ] **Step 3: 构建验证分包生效**

Run: `pnpm typecheck; pnpm build`
Expected: dist/assets 出现多个 JS chunk（不再是单一 index-*.js）；主 chunk 明显小于此前 984KB（经验值 <650KB）。记录构建输出中的各 chunk 体积到提交说明。

- [ ] **Step 4: 手工冒烟**

Run: `pnpm dev`
浏览器访问 http://localhost:5173/todo → Ctrl+P 打开命令面板跳转「设置」「关于」，确认懒加载页正常出现（Network 面板可见按需 chunk）。移动 UA 模拟下访问 `/todo`、`/todo/tasks`、`/settings` 同样正常。

- [ ] **Step 5: Commit**

```bash
git add src/router.tsx src/router.mobile.tsx
git commit -m "perf: route-level code splitting via React.lazy"
```

---

### Task 4: 桌面列表三态接入（Skeleton/ErrorState/EmptyState）

**Files:**
- Create: `src/components/business/empty-state.tsx`
- Modify: `src/features/todo/desktop/task-list-view.tsx`（props 与三分支）
- Modify: `src/features/todo/desktop/list-page.tsx:288-294`（传参）

**Interfaces:**
- Consumes: 已存在但未使用的 `ui/skeleton.tsx`（Skeleton）、`business/error-state.tsx`（ErrorState）
- Produces: `EmptyState({ icon?, title, hint?, action?, className? })` 组件；`TaskListViewProps` 新增 `error?: string | null`、`onCreateClick?: () => void`（Task 5 的虚拟化重构将保留这两个 props）

- [ ] **Step 1: 新建 EmptyState 组件**

```tsx
// src/components/business/empty-state.tsx
import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";
import { Inbox } from "lucide-react";

import { cn } from "@/lib/utils";

interface EmptyStateProps {
  /** 主图标，默认 Inbox */
  icon?: LucideIcon;
  /** 主文案（如"暂无任务"） */
  title: string;
  /** 辅助说明 */
  hint?: string;
  /** 底部动作（如"新建任务"按钮） */
  action?: ReactNode;
  /** 附加样式类 */
  className?: string;
}

/**
 * 统一空状态展示组件（error-state.tsx 注释中预告的对称件）：
 * 居中图标 + 主文案 + 辅助说明 + 可选动作按钮。
 */
export function EmptyState({ icon: Icon = Inbox, title, hint, action, className }: EmptyStateProps) {
  return (
    <div className={cn("flex flex-col items-center gap-2 px-8 py-16 text-center", className)}>
      <Icon className="size-10 text-muted-foreground/40" />
      <p className="text-sm text-muted-foreground">{title}</p>
      {hint ? <p className="text-xs text-muted-foreground/70">{hint}</p> : null}
      {action ? <div className="mt-2">{action}</div> : null}
    </div>
  );
}
```

- [ ] **Step 2: 改造 TaskListView 三分支**

在 `task-list-view.tsx` 顶部补 import：

```tsx
import { useRef } from "react";
import { Clock, Inbox, Plus, Star } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorState } from "@/components/business/error-state";
import { EmptyState } from "@/components/business/empty-state";
```

props 接口替换为：

```tsx
interface TaskListViewProps {
  tasks: TodoTask[];
  projects: TodoProject[];
  loading?: boolean;
  /** 列表查询错误文案；非空时整块渲染 ErrorState */
  error?: string | null;
  /** 空态"新建任务"动作回调（由 list-page 注入打开表单） */
  onCreateClick?: () => void;
  onOpenDetail: (id: number) => void;
}

export function TaskListView({ tasks, projects, loading, error, onCreateClick, onOpenDetail }: TaskListViewProps) {
  if (loading) {
    return (
      <div className="flex-1 divide-y divide-border/30" aria-busy="true">
        {Array.from({ length: 8 }, (_, i) => (
          <div key={i} className="flex items-center gap-3 px-4 py-3">
            <Skeleton className="h-5 w-5 shrink-0 rounded-full" />
            <div className="min-w-0 flex-1 space-y-2">
              <Skeleton className="h-4 w-2/5" />
              <Skeleton className="h-3 w-1/5" />
            </div>
          </div>
        ))}
      </div>
    );
  }
  if (error) {
    return (
      <div className="flex-1 overflow-y-auto p-4">
        <ErrorState message={error} />
      </div>
    );
  }
  if (tasks.length === 0) {
    return (
      <div className="flex flex-1 items-center justify-center overflow-y-auto">
        <EmptyState
          icon={Inbox}
          title="暂无任务"
          hint="用底部输入栏快速记录，或点击下方按钮"
          action={
            onCreateClick ? (
              <Button size="sm" variant="outline" onClick={onCreateClick}>
                <Plus size={14} className="mr-1" />
                新建任务
              </Button>
            ) : undefined
          }
        />
      </div>
    );
  }
  // ……以下 projectById/toggleDone/toggleFavorite/return 主渲染段保持原样（Task 5 将重构）
```

- [ ] **Step 3: list-page 传参**

`list-page.tsx:288-294` 的 `<TaskListView …>` 替换为：

```tsx
            <TaskListView
              tasks={visibleTasks}
              projects={projects}
              loading={tasksQuery.isLoading}
              error={
                tasksQuery.error instanceof Error
                  ? tasksQuery.error.message
                  : tasksQuery.error
                    ? String(tasksQuery.error)
                    : null
              }
              onCreateClick={() => {
                setEditingTask(null);
                setFormOpen(true);
              }}
              onOpenDetail={(id) => setSelectedTaskId(id)}
            />
```

- [ ] **Step 4: 验证**

Run: `pnpm typecheck; pnpm test; pnpm build`
Expected: 全绿。手工冒烟：`pnpm dev` 打开 /todo，断网或临时把 queryFn 改抛错可见红色错误条；筛选到空视图可见居中空态与「新建任务」按钮（点击打开表单 Sheet）。

- [ ] **Step 5: Commit**

```bash
git add src/components/business/empty-state.tsx src/features/todo/desktop/task-list-view.tsx src/features/todo/desktop/list-page.tsx
git commit -m "feat(desktop): wire skeleton/error/empty states into task list"
```

---

### Task 5: 双端任务列表虚拟化

**Files:**
- Modify: `package.json`（新增依赖 @tanstack/react-virtual ^3）
- Modify: `src/features/todo/desktop/task-list-view.tsx`（主渲染段重构）
- Modify: `src/features/todo/mobile/sub-list-screen.tsx:150-172`（visible.map 重构）

**Interfaces:**
- Consumes: Task 4 后的 TaskListView（props 含 error/onCreateClick）；sub-list-screen 既有 `scrollRef`（LiquidGlassTitleBar 契约，不可挪作他用）
- Produces: 两端列表仅渲染可视窗 ± overscan；DOM 节点数从 任务数×N 降为常数级

- [ ] **Step 1: 安装依赖**

Run: `pnpm add @tanstack/react-virtual`
Expected: package.json dependencies 出现 `"@tanstack/react-virtual": "^3.x"`。

- [ ] **Step 2: 桌面 TaskListView 主渲染段虚拟化**

顶部补：

```tsx
import { useVirtualizer } from "@tanstack/react-virtual";
```

组件体开头（早退分支之前，保证 hook 顺序无条件执行）加：

```tsx
  const scrollRef = useRef<HTMLDivElement>(null);
  // 行高估算：py-3(24)+标题20+meta16+边框≈57；measureElement 动态校正两态行高差
  const virtualizer = useVirtualizer({
    count: tasks.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 57,
    overscan: 8,
    getItemKey: (i) => tasks[i].id,
  });
```

主渲染 return 整段替换（原 `divide-y` 在绝对定位下行不通，改为每行自带 border-b）：

```tsx
  const projectById = new Map(projects.map((p) => [p.id, p]));

  const toggleDone = (t: TodoTask) => {
    const done = t.done ? 0 : 1;
    void todoTaskUpdate(t.id, {
      done,
      done_at: done ? Date.now() : null,
      status: done ? "done" : "pending",
    });
  };

  const toggleFavorite = (t: TodoTask) => {
    void todoTaskUpdate(t.id, { is_favorite: t.is_favorite ? 0 : 1 });
  };

  return (
    <div ref={scrollRef} className="flex-1 overflow-y-auto">
      <div style={{ height: virtualizer.getTotalSize(), position: "relative" }}>
        {virtualizer.getVirtualItems().map((vi) => {
          const t = tasks[vi.index];
          const overdue = !!t.due_date && !t.done && t.due_date < Date.now();
          const due = dueText(t.due_date);
          const projectName = t.project_id != null ? projectById.get(t.project_id)?.title : undefined;
          return (
            <div
              key={t.id}
              data-index={vi.index}
              ref={virtualizer.measureElement}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                transform: `translateY(${vi.start}px)`,
              }}
            >
              <TaskContextMenu
                task={t}
                projects={projects}
                onOpenDetail={() => onOpenDetail(t.id)}
              >
                {/* 行内容与改造前逐字节一致（checkbox/标题/元信息/hover 星标），仅外层 div 类名
                    由 "group flex items-center gap-3 px-4 py-3 hover:bg-accent/30" 改为追加
                    "border-b border-border/30"（替代 divide-y）： */}
                <div
                  className="group flex items-center gap-3 border-b border-border/30 px-4 py-3 hover:bg-accent/30"
                  onClick={() => onOpenDetail(t.id)}
                >
                  {/* ……此处保留原 76–144 行的 checkbox/标题+元信息/星标 JSX，一字不改…… */}
                </div>
              </TaskContextMenu>
            </div>
          );
        })}
      </div>
    </div>
  );
```

> 实施注记：上方 `{/* …… */}` 占位指「原 task-list-view.tsx 第 76–145 行的行内 JSX 原样搬移进新的行容器 div」，不是留空。搬移时保持缩进层级（多包一层绝对定位 wrapper）。

- [ ] **Step 3: 移动 SubListScreen 虚拟化**

顶部补：

```tsx
import { useEffect, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
```

组件体内（`visible` useMemo 之后）加：

```tsx
  // 列表区锚点：AppBar 之下的 offsetTop 作为 scrollMargin（官方模式，
  // 使 virtual item 偏移换算到滚动容器坐标系）
  const listRef = useRef<HTMLDivElement | null>(null);
  const [listOffset, setListOffset] = useState(0);
  useEffect(() => {
    if (listRef.current) setListOffset(listRef.current.offsetTop);
  }, []);

  const virtualizer = useVirtualizer({
    count: visible.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 76,
    overscan: 6,
    getItemKey: (i) => visible[i].id,
    scrollMargin: listOffset,
  });
```

`sub-list-screen.tsx:151-169`（`<div className="flex-1">…</div>` 块）整体替换为：

```tsx
            <div ref={listRef} className="flex-1">
              {visible.length > 0 && (
                <div style={{ height: virtualizer.getTotalSize(), position: "relative" }}>
                  {virtualizer.getVirtualItems().map((vi) => {
                    const t = visible[vi.index];
                    return (
                      <div
                        key={vi.key}
                        data-index={vi.index}
                        ref={virtualizer.measureElement}
                        style={{
                          position: "absolute",
                          top: 0,
                          left: 0,
                          width: "100%",
                          transform: `translateY(${vi.start - virtualizer.options.scrollMargin}px)`,
                        }}
                      >
                        <TodoTaskTile
                          task={t}
                          projectTitle={t.project_id != null ? (projectTitleById.get(t.project_id) ?? null) : null}
                          onToggleDone={() => toggleDone(t)}
                          onToggleFavorite={() => toggleFavorite(t)}
                          onEdit={() => openForm(t.id)}
                        />
                      </div>
                    );
                  })}
                </div>
              )}
              {visible.length === 0 && (
                /* 空态 EmptyState（05 §4.2）：checklist 大图标 + 八种映射文案 */
                <div className="flex flex-col items-center gap-3 pt-24 text-[var(--m-sub)]">
                  <MaterialIcon name="checklist" size={56} className="opacity-40" />
                  <p className="text-sm">{emptyMessage({ projectId, ungrouped, view })}</p>
                </div>
              )}
            </div>
```

- [ ] **Step 4: 验证**

Run: `pnpm typecheck; pnpm test; pnpm build`
Expected: 全绿。
人工冒烟（桌面）：`pnpm dev` 打开 /todo，DevTools Elements 面板确认滚动容器下 `.absolute` 行节点数量恒定（约 overscan+视口行数，≈20 个上下），滚动到底无空白行、右键菜单正常弹出、勾选刷新后顺序稳定。
人工冒烟（移动）：UA 模拟打开 /todo/tasks，长按菜单、勾选、FAB 正常；滚动流畅无跳动。

- [ ] **Step 5: Commit**

```bash
git add package.json pnpm-lock.yaml src/features/todo/desktop/task-list-view.tsx src/features/todo/mobile/sub-list-screen.tsx
git commit -m "perf: virtualize task lists on desktop and mobile (@tanstack/react-virtual)"
```

---

### Task 6: 删除撤销（延迟提交策略，仅桌面）

**Files:**
- Create: `src/features/todo/shared/undo-delete.ts`（纯逻辑）
- Test: `src/features/todo/shared/undo-delete.test.ts`
- Create: `src/hooks/use-undoable-delete.tsx`（hook + Provider + hideFromQueries）
- Modify: `src/features/todo/desktop/list-page.tsx`（包 Provider）
- Modify: `src/features/todo/desktop/task-context-menu.tsx:434-452`（接撤销）
- Modify: `src/features/todo/desktop/task-detail-drawer.tsx:259-280`（接撤销）
- Modify: `src/features/todo/desktop/project-sidebar.tsx:114-120`（接撤销）
- Modify: `src/features/todo/desktop/label-manager.tsx:74-77`（接撤销）

**Interfaces:**
- Consumes: sonner `toast`；queryKey 前缀 `["todo_tasks"]` / `["todo-project"]` / `["todo-label"]`
- Produces:
  - `createDelayedRun(run, delayMs, timers?) => DelayedRun`（`cancel(): boolean`、`flush(): void`）、常量 `UNDO_DELAY_MS = 5000`
  - `useUndoableDeleteAction(): (input: UndoableDeleteInput) => void`，其中 `UndoableDeleteInput = { entityLabel: string; recordName?: string; commit: () => Promise<unknown>; hide: (qc: QueryClient) => void }`
  - `hideFromQueries<T extends {id:number}>(qc, keyPrefix, id)`
  - `<UndoableDeleteProvider>`（挂在 ListPage，保证撤销实例不随行/抽屉卸载丢失）

- [ ] **Step 1: 写失败测试**

```ts
// src/features/todo/shared/undo-delete.test.ts
import { afterEach, describe, expect, it, vi } from "vitest";

import { createDelayedRun } from "./undo-delete";

afterEach(() => vi.useRealTimers());

describe("createDelayedRun", () => {
  it("超时后执行一次", () => {
    vi.useFakeTimers();
    const run = vi.fn();
    createDelayedRun(run, 1000);
    expect(run).not.toHaveBeenCalled();
    vi.advanceTimersByTime(999);
    expect(run).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(run).toHaveBeenCalledTimes(1);
  });

  it("cancel 拦截执行并返回 true", () => {
    vi.useFakeTimers();
    const run = vi.fn();
    const d = createDelayedRun(run, 1000);
    expect(d.cancel()).toBe(true);
    vi.advanceTimersByTime(5000);
    expect(run).not.toHaveBeenCalled();
  });

  it("重复 cancel 第二次返回 false", () => {
    vi.useFakeTimers();
    const d = createDelayedRun(vi.fn(), 1000);
    expect(d.cancel()).toBe(true);
    expect(d.cancel()).toBe(false);
  });

  it("flush 立即执行且计时器不再触发", () => {
    vi.useFakeTimers();
    const run = vi.fn();
    const d = createDelayedRun(run, 1000);
    d.flush();
    expect(run).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(5000);
    expect(run).toHaveBeenCalledTimes(1);
    expect(d.cancel()).toBe(false);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `pnpm test -- undo-delete`
Expected: FAIL（模块不存在）。

- [ ] **Step 3: 写最小实现使测试通过**

```ts
// src/features/todo/shared/undo-delete.ts
/**
 * 删除撤销核心调度（P0，07 报告 §五-P0#3）
 *
 * 策略：延迟提交——UI 先乐观隐藏行，UNDO_DELAY_MS 撤销窗口后才执行真删除；
 * 无需后端 restore 语义。窗口期内退出应用 = 未删除（安全方向）。
 */

/** 可注入计时器（测试注入 fake timers） */
export interface TimerApi {
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (id: unknown) => void;
}

export interface DelayedRun {
  /** 拦截待执行删除；返回 true = 确实拦截了一次 */
  cancel(): boolean;
  /** 立即执行并作废计时（组件卸载兜底） */
  flush(): void;
}

/** 撤销窗口时长（ms），与 toast duration 保持一致 */
export const UNDO_DELAY_MS = 5000;

export function createDelayedRun(
  run: () => Promise<unknown> | unknown,
  delayMs: number,
  timers: TimerApi = { setTimeout, clearTimeout },
): DelayedRun {
  let cancelled = false;
  let ran = false;
  const fire = () => {
    if (!cancelled && !ran) {
      ran = true;
      void run();
    }
  };
  const id = timers.setTimeout(fire, delayMs);
  return {
    cancel() {
      if (cancelled || ran) return false;
      cancelled = true;
      timers.clearTimeout(id);
      return true;
    },
    flush() {
      if (cancelled || ran) return;
      cancelled = true;
      timers.clearTimeout(id);
      void run();
    },
  };
}
```

Run: `pnpm test -- undo-delete`
Expected: 4 passed。

- [ ] **Step 4: 写 hook + Provider + 缓存隐藏工具**

```tsx
// src/hooks/use-undoable-delete.tsx
/**
 * 可撤销删除 Hook（P0，07 报告 §五-P0#3）
 *
 * 流程：hide() 乐观摘除缓存行 → success toast（action=撤销，duration=UNDO_DELAY_MS）
 *   ├─ 点撤销 → cancel 计时 + invalidateQueries 恢复显示
 *   └─ 超时 → commit() 真删除 → invalidateQueries 刷新计数/关联缓存
 *
 * Provider 挂在 ListPage 层：任务行（虚拟化滚动会卸载）与详情抽屉（关闭即卸载）
 * 都可能中途消失，撤销状态必须活得更久。
 */
import { createContext, useCallback, useContext, useEffect, useRef, type ReactNode } from "react";
import { useQueryClient, type QueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { UNDO_DELAY_MS, createDelayedRun, type DelayedRun } from "@/features/todo/shared/undo-delete";

export interface UndoableDeleteInput {
  /** 实体中文名，如"任务"/"项目"/"标签" */
  entityLabel: string;
  /** 记录名（标题等），用于 toast 文案 */
  recordName?: string;
  /** 真删除命令（延迟执行；内部已 catch，无需调用方兜底） */
  commit: () => Promise<unknown>;
  /** 乐观隐藏：从 react-query 数组型缓存中摘除该行 */
  hide: (qc: QueryClient) => void;
}

/** 按 id 从匹配 keyPrefix 的数组缓存中隐藏一行（前缀匹配多个同族变体 key） */
export function hideFromQueries<T extends { id: number }>(
  qc: QueryClient,
  keyPrefix: readonly unknown[],
  id: number,
) {
  qc.setQueriesData<T[]>({ queryKey: keyPrefix }, (old) =>
    old?.some((r) => r.id === id) ? old.filter((r) => r.id !== id) : old,
  );
}

function useUndoableDeleteImpl() {
  const qc = useQueryClient();
  const pendingRef = useRef<DelayedRun | null>(null);

  // 卸载兜底：窗口期未结束就离开页面 → 立即提交，避免"看似删了实际没删"
  useEffect(() => () => pendingRef.current?.flush(), []);

  return useCallback(
    (input: UndoableDeleteInput) => {
      input.hide(qc);
      pendingRef.current?.flush(); // 连续删除：上一笔先落库（MVP 单槽位足够）
      pendingRef.current = createDelayedRun(async () => {
        try {
          await input.commit();
        } catch {
          toast.error(`删除${input.entityLabel}失败，已还原`);
          input.hide(qc); // 失败回滚：再次 invalidate 由 finally 兜底
        } finally {
          pendingRef.current = null;
          void qc.invalidateQueries();
        }
      }, UNDO_DELAY_MS);

      let toastId: string | number = "";
      toastId = toast.success(
        `已删除${input.entityLabel}${input.recordName ? `「${input.recordName}」` : ""}`,
        {
          duration: UNDO_DELAY_MS,
          action: {
            label: "撤销",
            onClick: () => {
              if (pendingRef.current?.cancel()) {
                pendingRef.current = null;
                void qc.invalidateQueries(); // 恢复被隐藏的行
                toast.dismiss(toastId);
              }
            },
          },
        },
      );
    },
    [qc],
  );
}

const UndoableDeleteContext = createContext<(input: UndoableDeleteInput) => void>(() => {});

export function UndoableDeleteProvider({ children }: { children: ReactNode }) {
  const del = useUndoableDeleteImpl();
  return <UndoableDeleteContext.Provider value={del}>{children}</UndoableDeleteContext.Provider>;
}

/** 页面树内任意删除入口取同一撤销实例 */
export function useUndoableDeleteAction() {
  return useContext(UndoableDeleteContext);
}
```

注意实现里 catch 分支的「已还原」语义：commit 失败时行已被乐观隐藏，finally 的 invalidateQueries 会把它刷回来，toast 文案与之呼应。

- [ ] **Step 5: list-page 包 Provider**

`list-page.tsx` 顶部补：

```tsx
import { UndoableDeleteProvider } from "@/hooks/use-undoable-delete";
```

最外层 `<div className="flex h-full overflow-hidden">` 用 Provider 包裹：

```tsx
  return (
    <UndoableDeleteProvider>
      <div className="flex h-full overflow-hidden">
        {/* ……原有全部子节点不动…… */}
      </div>
    </UndoableDeleteProvider>
  );
```

- [ ] **Step 6: 四个删除入口接线**

**(a) task-context-menu.tsx** —— 顶部补：

```tsx
import { useUndoableDeleteAction, hideFromQueries } from "@/hooks/use-undoable-delete";
```

TaskContextMenu 组件体内加 `const undoableDelete = useUndoableDeleteAction();`，并把 `L444-449` AlertDialogAction 改为：

```tsx
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => {
                setDeleteOpen(false);
                undoableDelete({
                  entityLabel: "任务",
                  recordName: task.title,
                  commit: () => todoTaskDelete(task.id),
                  hide: (qc) => hideFromQueries(qc, ["todo_tasks"], task.id),
                });
              }}
            >
```

同步把 L438 描述文案「确定要删除「{task.title}」吗？此操作无法撤销。」改为「确定要删除「{task.title}」吗？删除后 5 秒内可撤销。」。若 `todoTaskDelete` 在本文件仅剩这一处使用，从 import 中移除该符号。

**(b) task-detail-drawer.tsx** —— 同样补 import 与 `useUndoableDeleteAction()`，L269-274 AlertDialogAction 改为：

```tsx
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              onClick={() => {
                setConfirmDelete(false);
                setSelectedTaskId(null);
                undoableDelete({
                  entityLabel: "任务",
                  recordName: task.title,
                  commit: () => todoTaskDelete(task.id),
                  hide: (qc) => hideFromQueries(qc, ["todo_tasks"], task.id),
                });
              }}
            >
```

L264 描述文案同 (a) 措辞替换。

**(c) project-sidebar.tsx** —— 补 import 与 `useUndoableDeleteAction()`，`confirmDelete`（L115-120）改为：

```tsx
  // 删除项目：项目下有未完成任务 → 拒绝；无任务 → 确认后进入撤销窗口软删
  const confirmDelete = (project: TodoProject) => {
    setDeleteTarget(null);
    if (activeProjectId === project.id) navigate("/todo");
    undoableDelete({
      entityLabel: "项目",
      recordName: project.title,
      commit: async () => {
        await todoProjectDelete(project.id);
        await refetchProjects();
      },
      hide: (qc) => hideFromQueries(qc, ["todo-project"], project.id),
    });
  };
```

（调用点 L270 `void confirmDelete(...)` 的 `void` 对同步函数无害，可不改。）

**(d) label-manager.tsx** —— 补 import 与 `useUndoableDeleteAction()`，`remove`（L74-77）改为：

```tsx
  const remove = (label: TodoLabel) => {
    undoableDelete({
      entityLabel: "标签",
      recordName: label.title,
      commit: () => todoLabelDelete(label.id),
      hide: (qc) => hideFromQueries(qc, ["todo-label"], label.id),
    });
  };
```

调用点若有 `void remove(l)` 形式，去掉 `void` 或保留均可（同步返回值忽略）。

- [ ] **Step 7: 全量验证 + 冒烟**

Run: `pnpm typecheck; pnpm test; pnpm build`
Expected: 全绿（含 Task 6 Step 1 的 4 条新测试）。
冒烟清单（`pnpm dev`）：
1. 右键任务→删除→确认：行立即消失 + 绿色 toast「已删除任务「xx」[撤销]」；点撤销 → 行回来；不点 → 5 秒后 db-change 失效刷新，行不再出现。
2. 详情抽屉删除：抽屉关闭 + toast 撤销可用（验证 Provider 存活于抽屉卸载）。
3. 项目删除（空项目）：侧栏行立即消失，撤销恢复。
4. 标签管理器删除标签：chip 即刻消失，撤销恢复。
5. 连续快速删除两个任务：第一笔立即落库、第二笔进撤销窗口。

- [ ] **Step 8: Commit**

```bash
git add src/features/todo/shared/undo-delete.ts src/features/todo/shared/undo-delete.test.ts src/hooks/use-undoable-delete.tsx src/features/todo/desktop/list-page.tsx src/features/todo/desktop/task-context-menu.tsx src/features/todo/desktop/task-detail-drawer.tsx src/features/todo/desktop/project-sidebar.tsx src/features/todo/desktop/label-manager.tsx
git commit -m "feat(desktop): undoable delete via delayed-commit (5s toast action)"
```

---

## Self-Review 记录

1. **Spec coverage**：07 报告 P0 表 #1–#6 ↔ Task 2 / Task 3 / Task 6 / Task 4 / Task 5 / Task 1，一一对应，无遗漏。
2. **Placeholder scan**：Task 5 Step 2 行内容以「实施注记」明确指认源行号搬移（76–145 行原 JSX），非 TBD；其余步骤均含完整代码。
3. **Type consistency**：`UndoableDeleteInput.hide` 签名 `(qc: QueryClient) => void` 与四处调用 lambda 一致；`createDelayedRun` 第三参可选且测试未传；`TaskListViewProps` 的 `error/onCreateClick` 在 Task 5 重构中显式声明保留。
