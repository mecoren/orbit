/**
 * 关于页 —— 四分区完整实现（对齐 wait-home AboutPage）
 *
 * 左导航：应用信息 / 更新日志 / 开源许可 / 开源组件。
 * - 应用信息：图标 + 名称 + 版本徽标 + 信息行（版本号取构建期注入，数据库模式实时读取）
 * - 更新日志：changelog_versions 命令（数据源在 orbit-core，双端共用）+ 列表与原地详情
 * - 开源许可：名称 / 许可证 / 主页 行列表
 * - 开源组件：来源 Tab + 排序 + 列表与原地详情（版式与更新日志同源）
 */
import { useEffect, useState } from "react";
import {
  ArrowLeft,
  BookOpen,
  ChevronRight,
  Code,
  Info,
  ScrollText,
  type LucideIcon,
} from "lucide-react";

import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { ComponentsSection } from "@/pages/about/components-section";
import { InfoRow } from "@/pages/about/info-row";
import {
  changelogVersions,
  masterAuthHas,
  type ChangeEntry,
  type ChangelogVersion,
} from "@/lib/tauri";

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
  const [hasMasterAuth, setHasMasterAuth] = useState<boolean | null>(null);
  const [statusFailed, setStatusFailed] = useState(false);
  useEffect(() => {
    masterAuthHas()
      .then(setHasMasterAuth)
      .catch((err) => {
        // 读取失败不能显示成「明文」——那是加密库的安全状态误报。
        console.error("[AboutPage] 读取主密码状态失败", err);
        setStatusFailed(true);
      });
  }, []);

  let dbMode = "读取中…";
  if (statusFailed) dbMode = "读取失败";
  else if (hasMasterAuth !== null) dbMode = hasMasterAuth ? "加密" : "明文";

  const infoItems = [
    { label: "应用名称", value: "循迹（Orbit）" },
    { label: "版本号", value: APP_VERSION },
    { label: "数据库模式", value: dbMode },
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
          className="size-20 object-contain"
          draggable={false}
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
  const [versions, setVersions] = useState<ChangelogVersion[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [selectedVersion, setSelectedVersion] = useState<string | null>(null);

  // 数据源在 orbit-core（只读静态数据）：桌面壳不再内联日志，双端同一份
  useEffect(() => {
    let cancelled = false;
    changelogVersions()
      .then((data) => {
        if (!cancelled) setVersions(data);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (!versions) {
    return (
      <div className="space-y-4">
        <h2 className="text-base font-semibold">更新日志</h2>
        <p className="text-sm text-muted-foreground">
          {failed ? "更新日志加载失败，请重启应用后重试。" : "加载中…"}
        </p>
      </div>
    );
  }

  const selected = selectedVersion
    ? versions.find((version) => version.version === selectedVersion)
    : undefined;

  if (selected) {
    return (
      <ChangelogDetail
        version={selected}
        onBack={() => setSelectedVersion(null)}
      />
    );
  }

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-base font-semibold">更新日志</h2>
        <p className="mt-0.5 text-sm text-muted-foreground">
          版本迭代记录（共 {versions.length} 个版本）
        </p>
      </div>

      {versions.length === 0 ? (
        <p className="py-12 text-center text-sm text-muted-foreground">
          暂无更新日志。
        </p>
      ) : (
        <div className="divide-y overflow-hidden rounded-lg border">
          {versions.map((log) => (
            <button
              key={log.version}
              type="button"
              onClick={() => setSelectedVersion(log.version)}
              className="flex min-h-14 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-accent/50 focus-visible:bg-accent/50 focus-visible:outline-none"
            >
              <span className="min-w-0 flex-1">
                <span className="block truncate text-sm font-medium">
                  v{log.version}
                </span>
                {log.summary && (
                  <span className="mt-0.5 block truncate text-xs text-muted-foreground">
                    {log.summary}
                  </span>
                )}
              </span>
              <Badge variant="outline" className="shrink-0 text-[10px]">
                {log.date}
              </Badge>
              <Badge variant="secondary" className="shrink-0 text-[10px]">
                {log.changes.length} 项
              </Badge>
              <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/* ================= 更新日志详情 ================= */

function ChangelogDetail({
  version,
  onBack,
}: {
  version: ChangelogVersion;
  onBack: () => void;
}) {
  return (
    <div className="space-y-4">
      <Button
        variant="ghost"
        size="sm"
        onClick={onBack}
        className="-ml-2 gap-1.5 text-muted-foreground"
      >
        <ArrowLeft className="size-4" />
        返回版本列表
      </Button>

      <div>
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-lg font-semibold">v{version.version}</h2>
          <Badge variant="outline" className="text-[10px]">
            {version.date}
          </Badge>
          <Badge variant="secondary" className="text-[10px]">
            {version.changes.length} 项更新
          </Badge>
        </div>
        <p className="mt-2 text-sm text-muted-foreground">
          {version.summary || "本版本未提供摘要。"}
        </p>
      </div>

      <div className="divide-y rounded-lg border">
        <InfoRow label="版本" value={`v${version.version}`} />
        <InfoRow label="发布日期" value={version.date} />
        <InfoRow label="变更条目" value={`${version.changes.length} 项`} />
      </div>

      {version.changes.length === 0 ? (
        <p className="py-6 text-center text-sm text-muted-foreground">
          本版本未逐条记录变更。
        </p>
      ) : (
        <div className="divide-y overflow-hidden rounded-lg border">
          {version.changes.map((change, index) => (
            <div
              key={index}
              className="flex items-start gap-2 px-4 py-3 text-sm"
            >
              <Badge
                variant={CHANGE_CATEGORY_STYLE[change.category].variant}
                className="mt-0.5 shrink-0 px-1.5 text-[10px]"
              >
                {CHANGE_CATEGORY_STYLE[change.category].label}
              </Badge>
              <span>{change.description}</span>
            </div>
          ))}
        </div>
      )}
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
