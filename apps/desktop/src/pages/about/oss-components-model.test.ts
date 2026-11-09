import { describe, expect, it } from "vitest";

import type { OssComponent, OssComponentSource } from "@/lib/tauri";

import {
  desktopVisibleOssComponents,
  filterOssComponents,
  ossSourceLabel,
  sortOssComponents,
  type OssSort,
  type OssSourceFilter,
} from "./oss-components-model";

function component(
  name: string,
  source: OssComponentSource,
  version = "1.0.0",
): OssComponent {
  return {
    name,
    version,
    source,
    description: `${name} 说明`,
    license: "MIT",
  };
}

const rows: OssComponent[] = [
  component("react", "frontend"),
  component("zustand", "frontend"),
  component("ag-grid", "frontend"),
  component("tauri", "rust"),
  component("sqlx", "rust"),
  component("go_router", "flutter"),
  component("flutter_miuix", "flutter"),
];

describe("desktopVisibleOssComponents", () => {
  it("桌面端隐藏 Flutter 来源条目且不改动原数组", () => {
    const before = [...rows];
    const visible = desktopVisibleOssComponents(rows);
    expect(visible.map((row) => row.name)).toEqual([
      "react",
      "zustand",
      "ag-grid",
      "tauri",
      "sqlx",
    ]);
    expect(rows).toEqual(before);
  });
});

describe("filterOssComponents", () => {
  it("all 保留全部条目", () => {
    expect(filterOssComponents(rows, "all")).toHaveLength(rows.length);
  });

  it("按来源过滤且不改动原数组", () => {
    const before = [...rows];
    const filtered = filterOssComponents(rows, "rust");
    expect(filtered.map((row) => row.name)).toEqual(["tauri", "sqlx"]);
    expect(rows).toEqual(before);
  });
});

describe("sortOssComponents", () => {
  it("default 保留 core 给定顺序", () => {
    expect(sortOssComponents(rows, "default").map((row) => row.name)).toEqual(
      rows.map((row) => row.name),
    );
  });

  it("名称升序忽略大小写", () => {
    const data = [
      component("Zustand", "frontend"),
      component("ag-grid", "frontend"),
      component("React", "frontend"),
    ];
    expect(sortOssComponents(data, "name-asc").map((row) => row.name)).toEqual([
      "ag-grid",
      "React",
      "Zustand",
    ]);
  });

  it("名称降序", () => {
    expect(
      sortOssComponents(rows, "name-desc").map((row) => row.name),
    ).toEqual(["zustand", "tauri", "sqlx", "react", "go_router", "flutter_miuix", "ag-grid"]);
  });

  it("来源排序按 前端 → Rust → Flutter，同来源内按名称升序", () => {
    expect(sortOssComponents(rows, "source").map((row) => row.name)).toEqual([
      "ag-grid",
      "react",
      "zustand",
      "sqlx",
      "tauri",
      "flutter_miuix",
      "go_router",
    ]);
  });

  it("不修改原数组顺序", () => {
    const before = [...rows];
    sortOssComponents(rows, "name-asc");
    expect(rows).toEqual(before);
  });
});

describe("ossSourceLabel", () => {
  it("三类来源映射中文标签", () => {
    expect(ossSourceLabel("frontend")).toBe("前端");
    expect(ossSourceLabel("rust")).toBe("Rust");
    expect(ossSourceLabel("flutter")).toBe("Flutter");
  });
});

// 类型守卫：确保导出的筛选/排序联合类型可用于 UI 状态
const _filter: OssSourceFilter = "all";
const _sort: OssSort = "default";
void _filter;
void _sort;
