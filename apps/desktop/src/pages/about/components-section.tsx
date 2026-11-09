import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  ArrowLeft,
  ArrowUpDown,
  ChevronRight,
  ExternalLink,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { ossComponents, type OssComponent } from "@/lib/tauri";
import { cn } from "@/lib/utils";

import { InfoRow } from "./info-row";
import {
  desktopVisibleOssComponents,
  filterOssComponents,
  OSS_SORT_OPTIONS,
  OSS_SOURCE_FILTERS,
  ossSourceLabel,
  sortOssComponents,
  type OssSort,
  type OssSourceFilter,
} from "./oss-components-model";

/** 开源组件：列表（来源 Tab + 排序）与详情原地切换 */
export function ComponentsSection() {
  const [filter, setFilter] = useState<OssSourceFilter>("all");
  const [sort, setSort] = useState<OssSort>("default");
  const [selectedName, setSelectedName] = useState<string | null>(null);

  const { data = [], isPending, isError, refetch } = useQuery({
    queryKey: ["oss_components"],
    queryFn: ossComponents,
    // 编译期静态清单：同一次会话内不会变化，切回关于页不再重复请求
    staleTime: Infinity,
  });

  // 桌面壳只引用自己的直接依赖：Flutter 属移动壳，列表与计数都不含它
  const visible = useMemo(() => desktopVisibleOssComponents(data), [data]);

  const counts = useMemo(
    () => ({
      frontend: visible.filter((item) => item.source === "frontend").length,
      rust: visible.filter((item) => item.source === "rust").length,
    }),
    [visible],
  );

  const selected = selectedName
    ? visible.find((item) => item.name === selectedName)
    : undefined;

  if (selected) {
    return (
      <ComponentDetail
        component={selected}
        onBack={() => setSelectedName(null)}
      />
    );
  }

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-base font-semibold">开源组件</h2>
        <p className="mt-0.5 text-sm text-muted-foreground">
          共 {visible.length} 个直接依赖（前端 {counts.frontend} · Rust{" "}
          {counts.rust}）
        </p>
      </div>

      <Tabs
        value={filter}
        onValueChange={(value) => setFilter(value as OssSourceFilter)}
      >
        <div className="flex flex-wrap items-center gap-2">
          <TabsList>
            {OSS_SOURCE_FILTERS.map((option) => (
              <TabsTrigger key={option.value} value={option.value}>
                {option.label}
              </TabsTrigger>
            ))}
          </TabsList>

          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="outline" size="sm" className="gap-1.5">
                <ArrowUpDown className="size-3.5" />
                {
                  OSS_SORT_OPTIONS.find((option) => option.value === sort)
                    ?.label
                }
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start">
              <DropdownMenuLabel>排序方式</DropdownMenuLabel>
              <DropdownMenuRadioGroup
                value={sort}
                onValueChange={(value) => setSort(value as OssSort)}
              >
                {OSS_SORT_OPTIONS.map((option) => (
                  <DropdownMenuRadioItem key={option.value} value={option.value}>
                    {option.label}
                  </DropdownMenuRadioItem>
                ))}
              </DropdownMenuRadioGroup>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>

        {isPending ? (
          <p className="pt-2 text-sm text-muted-foreground">加载中…</p>
        ) : isError ? (
          <div className="mt-2 flex items-center justify-between gap-3 rounded-lg border p-4">
            <p className="text-sm text-muted-foreground">
              开源组件加载失败，请稍后重试。
            </p>
            <Button variant="outline" size="sm" onClick={() => refetch()}>
              重试
            </Button>
          </div>
        ) : (
          OSS_SOURCE_FILTERS.map((option) => (
            <TabsContent
              key={option.value}
              value={option.value}
              className="mt-2"
            >
              <ComponentList
                rows={sortOssComponents(
                  filterOssComponents(visible, option.value),
                  sort,
                )}
                onSelect={setSelectedName}
              />
            </TabsContent>
          ))
        )}
      </Tabs>
    </div>
  );
}

function ComponentList({
  rows,
  onSelect,
}: {
  rows: OssComponent[];
  onSelect: (name: string) => void;
}) {
  if (rows.length === 0) {
    return (
      <p className="py-12 text-center text-sm text-muted-foreground">
        没有符合当前来源的组件。
      </p>
    );
  }

  return (
    <div className="divide-y overflow-hidden rounded-lg border">
      {rows.map((component) => (
        <button
          key={component.name}
          type="button"
          onClick={() => onSelect(component.name)}
          className="flex min-h-14 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-accent/50 focus-visible:bg-accent/50 focus-visible:outline-none"
        >
          <span className="min-w-0 flex-1">
            <span className="block truncate text-sm font-medium">
              {component.name}
            </span>
            <span className="mt-0.5 block truncate text-xs text-muted-foreground">
              {component.description}
            </span>
          </span>
          <Badge variant="outline" className="shrink-0 text-[10px]">
            {ossSourceLabel(component.source)}
          </Badge>
          <Badge variant="outline" className="shrink-0 text-[10px]">
            v{component.version}
          </Badge>
          <Badge variant="secondary" className="shrink-0 text-[10px]">
            {component.license}
          </Badge>
          <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
        </button>
      ))}
    </div>
  );
}

function ComponentDetail({
  component,
  onBack,
}: {
  component: OssComponent;
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
        返回组件列表
      </Button>

      <div>
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-lg font-semibold">{component.name}</h2>
          <Badge variant="outline" className="text-[10px]">
            {ossSourceLabel(component.source)}
          </Badge>
          <Badge variant="outline" className="text-[10px]">
            v{component.version}
          </Badge>
          <Badge variant="secondary" className="text-[10px]">
            {component.license}
          </Badge>
        </div>
        <p className="mt-2 text-sm text-muted-foreground">
          {component.description}
        </p>
      </div>

      <div className="divide-y rounded-lg border">
        <InfoRow label="来源" value={ossSourceLabel(component.source)} />
        <InfoRow label="版本" value={component.version} />
        <InfoRow label="许可证" value={component.license} />
      </div>

      {(component.repository || component.homepage) && (
        <div className="space-y-2 rounded-lg border p-4 text-sm">
          {component.repository && (
            <LinkRow label="仓库" href={component.repository} />
          )}
          {component.homepage && (
            <LinkRow label="主页" href={component.homepage} />
          )}
        </div>
      )}
    </div>
  );
}

function LinkRow({ label, href }: { label: string; href: string }) {
  return (
    <p className="flex items-start gap-2">
      <span className="shrink-0 text-muted-foreground">{label}</span>
      <a
        href={href}
        target="_blank"
        rel="noreferrer"
        className={cn(
          "inline-flex min-w-0 items-center gap-1 text-primary hover:underline",
        )}
      >
        <span className="truncate">{href.replace(/^https?:\/\//, "")}</span>
        <ExternalLink className="size-3.5 shrink-0" />
      </a>
    </p>
  );
}
