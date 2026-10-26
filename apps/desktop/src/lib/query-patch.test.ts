/**
 * query-patch 单测（D3）：只改已存在行字段，不增删不重排。
 */
import { QueryClient } from "@tanstack/react-query";
import { describe, expect, it } from "vitest";

import { patchQueriesData, removeRowsFromData } from "./query-patch";

interface Row {
  id: number;
  title: string;
  position: number;
  is_favorite: number;
}

const row = (id: number, position: number): Row => ({
  id,
  title: `任务 ${id}`,
  position,
  is_favorite: 0,
});

function makeClient() {
  const qc = new QueryClient();
  qc.setQueryData(["todo_tasks", "", {}], [row(1, 10), row(2, 20), row(3, 30)]);
  qc.setQueryData(["todo_tasks", "kw", {}], [row(1, 10), row(2, 20)]);
  qc.setQueryData(["todo-task-detail", 2], row(2, 20));
  return qc;
}

describe("patchQueriesData", () => {
  it("命中行字段合并，未命中行保持原引用", () => {
    const qc = makeClient();
    const before = qc.getQueryData<Row[]>(["todo_tasks", "", {}])!;
    patchQueriesData<Row>(qc, ["todo_tasks"], [2], { position: 99 });
    const after = qc.getQueryData<Row[]>(["todo_tasks", "", {}])!;
    expect(after.find((r) => r.id === 2)?.position).toBe(99);
    // 未命中行原引用（memo 友好），数组长度与顺序不变
    expect(after).toHaveLength(3);
    expect(after.map((r) => r.id)).toEqual([1, 2, 3]);
    expect(after[0]).toBe(before[0]);
    expect(after[2]).toBe(before[2]);
  });

  it("同前缀多查询一起提前 paint（含搜索命中集）", () => {
    const qc = makeClient();
    patchQueriesData<Row>(qc, ["todo_tasks"], [1], { is_favorite: 1 });
    expect(qc.getQueryData<Row[]>(["todo_tasks", "", {}])!.find((r) => r.id === 1)?.is_favorite).toBe(1);
    expect(qc.getQueryData<Row[]>(["todo_tasks", "kw", {}])!.find((r) => r.id === 1)?.is_favorite).toBe(1);
  });

  it("单对象详情命中即合并", () => {
    const qc = makeClient();
    patchQueriesData<Row>(qc, ["todo-task-detail"], [2], { title: "新标题" });
    expect(qc.getQueryData<Row>(["todo-task-detail", 2])?.title).toBe("新标题");
  });

  it("未知 id 与空 ids 不碰缓存", () => {
    const qc = makeClient();
    const before = qc.getQueryData<Row[]>(["todo_tasks", "", {}])!;
    patchQueriesData<Row>(qc, ["todo_tasks"], [999], { position: 1 });
    patchQueriesData<Row>(qc, ["todo_tasks"], [], { position: 1 });
    expect(qc.getQueryData(["todo_tasks", "", {}])).toBe(before);
  });
});

describe("removeRowsFromData（删除乐观隐藏，P1 分页形态）", () => {
  it("数组形态：摘除命中行，其余行原引用", () => {
    const rows = [row(1, 10), row(2, 20), row(3, 30)];
    const next = removeRowsFromData<Row>(rows, new Set([2])) as Row[];
    expect(next.map((r) => r.id)).toEqual([1, 3]);
    expect(next[0]).toBe(rows[0]);
  });

  it("分页形态（页 = 行数组）：只摘所在页，页数/顺序/游标不动", () => {
    const page1 = [row(1, 10), row(2, 20)];
    const page2 = [row(3, 30)];
    const data = {
      pages: [page1, page2],
      pageParams: [null, { id: 2 }],
    };
    const next = removeRowsFromData<Row>(data, new Set([1])) as typeof data;
    expect(next.pages).toHaveLength(2);
    expect((next.pages[0] as Row[]).map((r) => r.id)).toEqual([2]);
    expect(next.pages[1]).toBe(page2);
    expect(next.pageParams).toEqual([null, { id: 2 }]);
  });

  it("分页形态（页 = {items,next_cursor}，本仓分页 API）：摘 items 不动游标", () => {
    const data = {
      pages: [
        { items: [row(1, 10), row(2, 20)], next_cursor: { id: 2 }, has_more: true },
        { items: [row(3, 30)], next_cursor: null, has_more: false },
      ],
      pageParams: [null, { id: 2 }],
    };
    const next = removeRowsFromData<Row>(data, new Set([2])) as typeof data;
    const first = next.pages[0] as { items: Row[]; next_cursor: unknown; has_more: boolean };
    expect(first.items.map((r) => r.id)).toEqual([1]);
    // 游标是「上一页最后一行在排序中的位置」，少一条已加载行不影响它
    expect(first.next_cursor).toEqual({ id: 2 });
    expect(next.pages[1]).toBe(data.pages[1]);
  });

  it("未命中返回原引用（不触发订阅者重渲染）", () => {
    const data = { pages: [[row(1, 10)]], pageParams: [null] };
    expect(removeRowsFromData<Row>(data, new Set([99]))).toBe(data);
    const rows = [row(1, 10)];
    expect(removeRowsFromData<Row>(rows, new Set([99]))).toBe(rows);
  });
});
