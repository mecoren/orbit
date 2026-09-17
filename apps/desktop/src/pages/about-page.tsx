/**
 * 关于页 —— 四分区完整实现（对齐 wait-home AboutPage）
 *
 * 左导航：应用信息 / 更新日志 / 开源许可 / 开源组件。
 * - 应用信息：图标 + 名称 + 版本徽标 + 信息行（版本号取构建期注入，数据库模式实时读取）
 * - 更新日志：src/lib/changelog.ts 数据 + Accordion（分类徽标）
 * - 开源许可：名称 / 许可证 / 主页 行列表
 * - 开源组件：前端依赖（npm）/ Rust 依赖（crates.io）双 Tab Accordion
 */
import { useEffect, useState } from "react";
import {
  BookOpen,
  Code,
  Info,
  ScrollText,
  type LucideIcon,
} from "lucide-react";

import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import { CHANGELOG_VERSIONS, type ChangeEntry } from "@/lib/changelog";
import { masterAuthHas } from "@/lib/tauri";

/** 构建期注入（源：apps/desktop/package.json#version），不再手写以防清单漂移 */
const APP_VERSION = __APP_VERSION__;

type AboutCategory = "info" | "changelog" | "licenses" | "components";

const categories: { key: AboutCategory; label: string; icon: LucideIcon }[] = [
  { key: "info", label: "应用信息", icon: Info },
  { key: "changelog", label: "更新日志", icon: ScrollText },
  { key: "licenses", label: "开源许可", icon: BookOpen },
  { key: "components", label: "开源组件", icon: Code },
];

/* ================= 应用信息 ================= */

function InfoSection() {
  const [hasMasterAuth, setHasMasterAuth] = useState(false);
  useEffect(() => {
    masterAuthHas().then(setHasMasterAuth).catch(() => setHasMasterAuth(false));
  }, []);

  const infoItems = [
    { label: "应用名称", value: "循迹（Orbit）" },
    { label: "版本号", value: APP_VERSION },
    { label: "数据库模式", value: hasMasterAuth ? "加密" : "明文" },
    { label: "技术栈", value: "Tauri 2.0 + React 19 + Rust" },
    { label: "UI 框架", value: "shadcn/ui + Tailwind CSS v4" },
  ];

  return (
    <div className="space-y-4">
      <h2 className="text-base font-semibold">应用信息</h2>

      {/* 图标与名称 */}
      <div className="flex flex-col items-center gap-2 py-6">
        <img
          src="/app-icon.png"
          alt="循迹"
          className="size-20 rounded-2xl object-cover shadow-md"
        />
        <p className="mt-1 text-lg font-semibold">循迹</p>
        <p className="text-xs text-muted-foreground">桌面优先 · 本地优先 · 端到端加密</p>
        <Badge variant="secondary">v{APP_VERSION}</Badge>
      </div>

      {/* 信息行 */}
      <div className="divide-y rounded-lg border">
        {infoItems.map((item) => (
          <div
            key={item.label}
            className="flex items-center justify-between px-4 py-3 text-sm"
          >
            <span className="text-muted-foreground">{item.label}</span>
            <span className="font-medium">{item.value}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ================= 更新日志 ================= */

const CHANGE_CATEGORY_STYLE: Record<
  ChangeEntry["category"],
  { label: string; variant: "default" | "destructive" | "secondary" | "outline" }
> = {
  feature: { label: "新增", variant: "default" },
  fix: { label: "修复", variant: "destructive" },
  refactor: { label: "优化", variant: "secondary" },
  chore: { label: "其他", variant: "outline" },
};

function ChangelogSection() {
  return (
    <div className="space-y-4">
      <h2 className="text-base font-semibold">更新日志</h2>
      <p className="text-sm text-muted-foreground">
        版本迭代记录（共 {CHANGELOG_VERSIONS.length} 个版本）
      </p>

      <Accordion type="single" defaultValue={CHANGELOG_VERSIONS[0]?.version} collapsible>
        {CHANGELOG_VERSIONS.map((log) => (
          <AccordionItem key={log.version} value={log.version}>
            <AccordionTrigger>
              <span className="flex items-baseline gap-2">
                <span className="font-medium">v{log.version}</span>
                <Badge variant="outline" className="px-1.5 text-[10px]">
                  {log.date}
                </Badge>
              </span>
              <span className="block max-w-md truncate text-xs font-normal text-muted-foreground">
                {log.summary}
              </span>
            </AccordionTrigger>
            <AccordionContent>
              <ul className="space-y-2 pl-1">
                {log.changes.map((change, i) => (
                  <li key={i} className="flex items-start gap-2 text-sm">
                    <Badge
                      variant={CHANGE_CATEGORY_STYLE[change.category].variant}
                      className="mt-0.5 shrink-0 px-1.5 text-[10px]"
                    >
                      {CHANGE_CATEGORY_STYLE[change.category].label}
                    </Badge>
                    <span>{change.description}</span>
                  </li>
                ))}
              </ul>
            </AccordionContent>
          </AccordionItem>
        ))}
      </Accordion>
    </div>
  );
}

/* ================= 开源许可 ================= */

interface LicenseEntry {
  name: string;
  license: string;
  homepage?: string;
}

const LICENSES: LicenseEntry[] = [
  { name: "React", license: "MIT License", homepage: "https://react.dev" },
  { name: "React Router", license: "MIT License", homepage: "https://reactrouter.com" },
  { name: "Tailwind CSS", license: "MIT License", homepage: "https://tailwindcss.com" },
  { name: "shadcn/ui", license: "MIT License", homepage: "https://ui.shadcn.com" },
  { name: "Radix UI", license: "MIT License", homepage: "https://www.radix-ui.com" },
  { name: "TanStack Query", license: "MIT License", homepage: "https://tanstack.com/query" },
  { name: "Zustand", license: "MIT License", homepage: "https://github.com/pmndrs/zustand" },
  { name: "dnd-kit", license: "MIT License", homepage: "https://dndkit.com" },
  { name: "cmdk", license: "MIT License", homepage: "https://cmdk.paco.me" },
  { name: "Sonner", license: "MIT License", homepage: "https://sonner.emilkowal.ski" },
  { name: "date-fns", license: "MIT License", homepage: "https://date-fns.org" },
  { name: "Lucide Icons", license: "ISC License", homepage: "https://lucide.dev" },
  { name: "Tauri", license: "Apache-2.0 / MIT", homepage: "https://tauri.app" },
  { name: "Vite", license: "MIT License", homepage: "https://vitejs.dev" },
  { name: "TypeScript", license: "Apache-2.0", homepage: "https://www.typescriptlang.org" },
  { name: "Rust", license: "MIT / Apache-2.0", homepage: "https://www.rust-lang.org" },
  { name: "SQLCipher", license: "BSD-3-Clause", homepage: "https://www.zetetic.net/sqlcipher" },
  { name: "Tokio", license: "MIT License", homepage: "https://tokio.rs" },
  { name: "Serde", license: "MIT / Apache-2.0", homepage: "https://serde.rs" },
  { name: "SQLx", license: "MIT / Apache-2.0", homepage: "https://github.com/launchbadge/sqlx" },
];

function LicensesSection() {
  return (
    <div className="space-y-4">
      <h2 className="text-base font-semibold">开源许可</h2>
      <p className="text-sm text-muted-foreground">
        循迹基于以下优秀的开源项目构建，感谢原作者们的贡献
      </p>

      <div className="divide-y overflow-hidden rounded-lg border">
        {LICENSES.map((entry) => (
          <div
            key={entry.name}
            className="flex items-center justify-between gap-3 px-4 py-3"
          >
            <div className="min-w-0">
              <p className="truncate text-sm font-medium">{entry.name}</p>
              {entry.homepage && (
                <a
                  href={entry.homepage}
                  target="_blank"
                  rel="noreferrer"
                  className="block truncate text-xs text-primary hover:underline"
                >
                  {entry.homepage.replace(/^https?:\/\//, "")}
                </a>
              )}
            </div>
            <Badge variant="secondary" className="shrink-0 text-[10px]">
              {entry.license}
            </Badge>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ================= 开源组件 ================= */

type ComponentSource = "frontend" | "rust";

interface OpenSourceComponent {
  name: string;
  version: string;
  source: ComponentSource;
  description: string;
  license: string;
  repository?: string;
  homepage?: string;
}

const OSS_FRONTEND: OpenSourceComponent[] = [
  { name: "react", version: "^19.0.0", source: "frontend", description: "用于构建用户界面的声明式库", license: "MIT", repository: "https://github.com/facebook/react", homepage: "https://react.dev" },
  { name: "react-dom", version: "^19.0.0", source: "frontend", description: "React 的 DOM 渲染器", license: "MIT", repository: "https://github.com/facebook/react", homepage: "https://react.dev" },
  { name: "react-router", version: "^7.18.1", source: "frontend", description: "React 应用路由方案", license: "MIT", repository: "https://github.com/remix-run/react-router", homepage: "https://reactrouter.com" },
  { name: "@tanstack/react-query", version: "^5.0.0", source: "frontend", description: "异步状态管理与数据请求缓存", license: "MIT", repository: "https://github.com/TanStack/query", homepage: "https://tanstack.com/query" },
  { name: "zustand", version: "^5.0.0", source: "frontend", description: "轻量级 React 状态管理", license: "MIT", repository: "https://github.com/pmndrs/zustand" },
  { name: "@dnd-kit/core", version: "^6.3.1", source: "frontend", description: "现代化拖拽工具包核心", license: "MIT", repository: "https://github.com/clauderic/dnd-kit" },
  { name: "@dnd-kit/sortable", version: "^10.0.0", source: "frontend", description: "dnd-kit 列表排序预设", license: "MIT", repository: "https://github.com/clauderic/dnd-kit" },
  { name: "@dnd-kit/utilities", version: "^3.2.2", source: "frontend", description: "dnd-kit 工具函数（transform 等）", license: "MIT", repository: "https://github.com/clauderic/dnd-kit" },
  { name: "tailwindcss", version: "^4.3.0", source: "frontend", description: "原子化 CSS 框架 v4", license: "MIT", repository: "https://github.com/tailwindlabs/tailwindcss", homepage: "https://tailwindcss.com" },
  { name: "lucide-react", version: "^0.460.0", source: "frontend", description: "简洁一致的开源图标库", license: "ISC", repository: "https://github.com/lucide-icons/lucide", homepage: "https://lucide.dev" },
  { name: "cmdk", version: "^1.1.1", source: "frontend", description: "命令面板原语（⌘K 快速入口）", license: "MIT", repository: "https://github.com/pacocoursey/cmdk", homepage: "https://cmdk.paco.me" },
  { name: "sonner", version: "^2.0.7", source: "frontend", description: "Toast 通知组件", license: "MIT", repository: "https://github.com/emilkowalski/sonner" },
  { name: "date-fns", version: "^4.4.0", source: "frontend", description: "现代 JavaScript 日期工具库", license: "MIT", repository: "https://github.com/date-fns/date-fns", homepage: "https://date-fns.org" },
  { name: "class-variance-authority", version: "^0.7.0", source: "frontend", description: "组件变体样式管理（cva）", license: "Apache-2.0", repository: "https://github.com/joe-bell/cva" },
  { name: "clsx", version: "^2.1.1", source: "frontend", description: "className 条件拼接工具", license: "MIT", repository: "https://github.com/lukeed/clsx" },
  { name: "tailwind-merge", version: "^2.5.0", source: "frontend", description: "Tailwind 类名冲突合并", license: "MIT", repository: "https://github.com/dcastil/tailwind-merge" },
  { name: "@tauri-apps/api", version: "^2.0.0", source: "frontend", description: "Tauri 前端 API（invoke / event）", license: "MIT / Apache-2.0", repository: "https://github.com/tauri-apps/tauri", homepage: "https://tauri.app" },
  { name: "@radix-ui/react-dialog", version: "^1.1.19", source: "frontend", description: "无障碍对话框原语", license: "MIT", repository: "https://github.com/radix-ui/primitives", homepage: "https://www.radix-ui.com" },
  { name: "@radix-ui/react-dropdown-menu", version: "^2.1.20", source: "frontend", description: "无障碍下拉菜单原语", license: "MIT", repository: "https://github.com/radix-ui/primitives", homepage: "https://www.radix-ui.com" },
  { name: "@radix-ui/react-select", version: "^2.3.3", source: "frontend", description: "无障碍下拉选择原语", license: "MIT", repository: "https://github.com/radix-ui/primitives", homepage: "https://www.radix-ui.com" },
  { name: "@radix-ui/react-tabs", version: "^1.1.17", source: "frontend", description: "无障碍标签页原语", license: "MIT", repository: "https://github.com/radix-ui/primitives", homepage: "https://www.radix-ui.com" },
  { name: "@tauri-apps/plugin-notification", version: "^2.0.0", source: "frontend", description: "Tauri 系统通知插件（前端绑定）", license: "MIT / Apache-2.0", repository: "https://github.com/tauri-apps/plugins-workspace" },
  { name: "@tauri-apps/plugin-dialog", version: "^2.7.1", source: "frontend", description: "Tauri 原生对话框插件（前端绑定）", license: "MIT / Apache-2.0", repository: "https://github.com/tauri-apps/plugins-workspace" },
];

const OSS_RUST: OpenSourceComponent[] = [
  { name: "tauri", version: "2", source: "rust", description: "构建跨平台应用的 Rust 框架", license: "Apache-2.0 / MIT", repository: "https://github.com/tauri-apps/tauri", homepage: "https://tauri.app" },
  { name: "sqlx", version: "0.8", source: "rust", description: "异步 Rust SQL 工具包", license: "MIT / Apache-2.0", repository: "https://github.com/launchbadge/sqlx", homepage: "https://github.com/launchbadge/sqlx" },
  { name: "libsqlite3-sys", version: "0.30", source: "rust", description: "SQLite/SQLCipher 绑定（bundled 编译）", license: "MIT", repository: "https://github.com/rusqlite/rusqlite" },
  { name: "tokio", version: "1.45", source: "rust", description: "Rust 异步运行时", license: "MIT", repository: "https://github.com/tokio-rs/tokio", homepage: "https://tokio.rs" },
  { name: "serde", version: "1", source: "rust", description: "Rust 序列化 / 反序列化框架", license: "MIT / Apache-2.0", repository: "https://github.com/serde-rs/serde", homepage: "https://serde.rs" },
  { name: "serde_json", version: "1", source: "rust", description: "JSON 序列化支持", license: "MIT / Apache-2.0", repository: "https://github.com/serde-rs/json" },
  { name: "chrono", version: "0.4", source: "rust", description: "日期与时间处理库", license: "MIT / Apache-2.0", repository: "https://github.com/chronotope/chrono" },
  { name: "uuid", version: "1", source: "rust", description: "UUID 生成与解析（v4）", license: "MIT / Apache-2.0", repository: "https://github.com/uuid-rs/uuid" },
  { name: "reqwest", version: "0.12", source: "rust", description: "HTTP 客户端（WebDAV/S3 同步通道）", license: "MIT / Apache-2.0", repository: "https://github.com/seanmonstar/reqwest" },
  { name: "aes-gcm", version: "0.10", source: "rust", description: "AES-256-GCM 认证加密", license: "MIT / Apache-2.0", repository: "https://github.com/RustCrypto/AEADs" },
  { name: "pbkdf2", version: "0.12", source: "rust", description: "PBKDF2 密钥派生函数", license: "MIT / Apache-2.0", repository: "https://github.com/RustCrypto/password-hashes" },
  { name: "hmac", version: "0.12", source: "rust", description: "HMAC 消息认证码", license: "MIT / Apache-2.0", repository: "https://github.com/RustCrypto/MACs" },
  { name: "sha2", version: "0.10", source: "rust", description: "SHA-2 哈希算法族", license: "MIT / Apache-2.0", repository: "https://github.com/RustCrypto/hashes" },
  { name: "subtle", version: "2", source: "rust", description: "常数时间比较（防时序攻击）", license: "BSD-3-Clause", repository: "https://github.com/dalek-cryptography/subtle" },
  { name: "rand", version: "0.8", source: "rust", description: "随机数生成", license: "MIT / Apache-2.0", repository: "https://github.com/rust-random/rand" },
  { name: "base64", version: "0.22", source: "rust", description: "Base64 编解码", license: "MIT / Apache-2.0", repository: "https://github.com/marshallpierce/rust-base64" },
  { name: "zip", version: "2", source: "rust", description: "ZIP 归档读写（同步包打包）", license: "MIT", repository: "https://github.com/zip-rs/zip2" },
  { name: "zstd", version: "0.13", source: "rust", description: "Zstandard 压缩", license: "MIT", repository: "https://github.com/gyscos/zstd-rs" },
  { name: "quick-xml", version: "0.36", source: "rust", description: "XML 解析（WebDAV 响应处理）", license: "MIT", repository: "https://github.com/tafia/quick-xml" },
  { name: "thiserror", version: "2", source: "rust", description: "错误类型派生宏", license: "MIT / Apache-2.0", repository: "https://github.com/dtolnay/thiserror" },
  { name: "anyhow", version: "1", source: "rust", description: "灵活的错误处理工具", license: "MIT / Apache-2.0", repository: "https://github.com/dtolnay/anyhow" },
  { name: "once_cell", version: "1", source: "rust", description: "惰性初始化原语", license: "MIT / Apache-2.0", repository: "https://github.com/matklad/once_cell" },
  { name: "windows", version: "0.61", source: "rust", description: "Windows API 绑定（Mica 云母材质）", license: "MIT / Apache-2.0", repository: "https://github.com/microsoft/windows-rs" },
  { name: "raw-window-handle", version: "0.6", source: "rust", description: "窗口句柄互操作抽象", license: "MIT / Apache-2.0 / Zlib", repository: "https://github.com/rust-windowing/raw-window-handle" },
  { name: "dirs", version: "6", source: "rust", description: "平台标准目录定位", license: "MIT / Apache-2.0", repository: "https://github.com/soc/dirs-rs" },
  { name: "whoami", version: "1.5", source: "rust", description: "当前用户 / 设备名获取", license: "MIT / Apache-2.0", repository: "https://github.com/ardaku/whoami" },
];

function ComponentsSection() {
  return (
    <div className="space-y-4">
      <h2 className="text-base font-semibold">开源组件</h2>
      <p className="text-sm text-muted-foreground">
        前端 {OSS_FRONTEND.length} 个 + Rust {OSS_RUST.length} 个，共{" "}
        {OSS_FRONTEND.length + OSS_RUST.length} 个依赖
      </p>

      <Tabs defaultValue="frontend">
        <TabsList>
          <TabsTrigger value="frontend">前端依赖（npm）</TabsTrigger>
          <TabsTrigger value="rust">Rust 依赖（crates.io）</TabsTrigger>
        </TabsList>

        {(
          [
            { key: "frontend", data: OSS_FRONTEND },
            { key: "rust", data: OSS_RUST },
          ] as const
        ).map(({ key, data }) => (
          <TabsContent key={key} value={key}>
            <Accordion type="single" collapsible className="rounded-lg border px-4">
              {data.map((comp) => (
                <AccordionItem key={`${key}-${comp.name}`} value={comp.name}>
                  <AccordionTrigger className="hover:no-underline">
                    <span className="min-w-0 flex-1 pr-3">
                      <span className="block truncate text-sm font-medium">{comp.name}</span>
                      <span className="block truncate text-xs font-normal text-muted-foreground">
                        {comp.description}
                      </span>
                    </span>
                    <span className="flex shrink-0 items-center gap-1.5">
                      <Badge variant="outline" className="text-[10px]">
                        v{comp.version}
                      </Badge>
                      <Badge variant="secondary" className="text-[10px]">
                        {comp.license}
                      </Badge>
                    </span>
                  </AccordionTrigger>
                  <AccordionContent className="space-y-1.5 text-xs text-muted-foreground">
                    {comp.repository && (
                      <p>
                        仓库：
                        <a
                          href={comp.repository}
                          target="_blank"
                          rel="noreferrer"
                          className="ml-1 text-primary hover:underline"
                        >
                          {comp.repository}
                        </a>
                      </p>
                    )}
                    {comp.homepage && (
                      <p>
                        主页：
                        <a
                          href={comp.homepage}
                          target="_blank"
                          rel="noreferrer"
                          className="ml-1 text-primary hover:underline"
                        >
                          {comp.homepage}
                        </a>
                      </p>
                    )}
                    <p>许可证:{comp.license}</p>
                  </AccordionContent>
                </AccordionItem>
              ))}
            </Accordion>
          </TabsContent>
        ))}
      </Tabs>
    </div>
  );
}

/* ================= 页面骨架 ================= */

export function AboutPage() {
  const [active, setActive] = useState<AboutCategory>("info");

  return (
    <div className="flex h-full flex-col">
      {/* 页头 */}
      <header className="border-b px-6 py-4">
        <h1 className="text-lg font-semibold text-foreground">关于</h1>
      </header>

      <div className="flex min-h-0 flex-1">
        {/* 左导航 */}
        <nav className="w-48 shrink-0 space-y-1 overflow-y-auto border-r p-3">
          {categories.map((cat) => (
            <Button
              key={cat.key}
              variant="ghost"
              onClick={() => setActive(cat.key)}
              className={cn(
                "flex w-full items-center justify-start gap-2 px-3 py-2",
                active === cat.key
                  ? "bg-accent text-accent-foreground"
                  : "text-muted-foreground hover:bg-accent/50 hover:text-foreground",
              )}
            >
              <cat.icon className="size-4" />
              {cat.label}
            </Button>
          ))}
        </nav>

        {/* 右内容 */}
        <div className="min-w-0 flex-1 overflow-y-auto">
          <div className="mx-auto max-w-3xl p-6">
            {active === "info" && <InfoSection />}
            {active === "changelog" && <ChangelogSection />}
            {active === "licenses" && <LicensesSection />}
            {active === "components" && <ComponentsSection />}
          </div>
        </div>
      </div>
    </div>
  );
}
