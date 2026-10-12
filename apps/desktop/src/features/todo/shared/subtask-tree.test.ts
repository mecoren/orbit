import { describe, expect, it } from "vitest";

import type { TodoSubtask } from "@/lib/tauri";
import { buildSubtaskTree, flattenSubtaskTree } from "./subtask-tree";

let seq = 0;
function sub(
  uuid: string,
  title: string,
  parentUuid: string | null = null,
  position = 0,
): TodoSubtask {
  seq += 1;
  return {
    id: seq,
    uuid,
    task_id: 1,
    title,
    done: 0,
    done_at: null,
    position,
    parent_uuid: parentUuid,
    is_deleted: 0,
    created_at: 1,
    updated_at: 1,
    deleted_at: null,
    version: 1,
  };
}

const flattenAll = (subtasks: TodoSubtask[]) =>
  flattenSubtaskTree(buildSubtaskTree(subtasks), () => false);

describe("buildSubtaskTree", () => {
  it("空输入返回空数组", () => {
    expect(buildSubtaskTree([])).toEqual([]);
  });

  it("全顶层：顺序保持，depth 全 0", () => {
    const tree = buildSubtaskTree([sub("a", "甲"), sub("b", "乙"), sub("c", "丙")]);
    expect(tree.map((n) => n.subtask.title)).toEqual(["甲", "乙", "丙"]);
    expect(tree.every((n) => n.depth === 0)).toBe(true);
    expect(tree.every((n) => n.children.length === 0)).toBe(true);
  });

  it("一层父子：子挂父下，父提为顶层（输入顺序颠倒也成立）", () => {
    const tree = buildSubtaskTree([sub("b", "子", "a"), sub("a", "父")]);
    expect(tree).toHaveLength(1);
    expect(tree[0].subtask.title).toBe("父");
    expect(tree[0].depth).toBe(0);
    expect(tree[0].children).toHaveLength(1);
    expect(tree[0].children[0].subtask.title).toBe("子");
    expect(tree[0].children[0].depth).toBe(1);
  });

  it("三层嵌套 depth 依次 0/1/2，DFS 父在前", () => {
    const nodes = flattenAll([sub("a", "根"), sub("b", "中", "a"), sub("c", "叶", "b")]);
    expect(nodes.map((n) => [n.subtask.title, n.depth])).toEqual([
      ["根", 0],
      ["中", 1],
      ["叶", 2],
    ]);
  });

  it("多 sibling 按入参顺序（后端 position 序）展开", () => {
    const nodes = flattenAll([
      sub("a", "父"),
      sub("x", "一", "a", 0),
      sub("y", "二", "a", 1),
      sub("z", "三", "a", 2),
    ]);
    expect(nodes.map((n) => [n.subtask.title, n.depth])).toEqual([
      ["父", 0],
      ["一", 1],
      ["二", 1],
      ["三", 1],
    ]);
  });

  it("孤儿（父 uuid 不存在）回落顶层，行不丢", () => {
    const tree = buildSubtaskTree([sub("a", "甲"), sub("b", "乙", "ghost")]);
    expect(tree.map((n) => n.subtask.title)).toEqual(["甲", "乙"]);
    expect(tree[1].depth).toBe(0);
  });

  it("自引用回落顶层", () => {
    const tree = buildSubtaskTree([sub("a", "甲", "a")]);
    expect(tree).toHaveLength(1);
    expect(tree[0].depth).toBe(0);
  });

  it("空白 parent_uuid 回落顶层", () => {
    const tree = buildSubtaskTree([sub("a", "甲", "   ")]);
    expect(tree[0].depth).toBe(0);
  });

  it("二元环：环上两个节点整体回落顶层（不产生悬挂）", () => {
    const tree = buildSubtaskTree([sub("a", "甲", "b"), sub("b", "乙", "a")]);
    expect(tree.map((n) => n.subtask.title).sort()).toEqual(["乙", "甲"]);
    expect(tree.every((n) => n.depth === 0)).toBe(true);
    expect(tree.every((n) => n.children.length === 0)).toBe(true);
  });

  it("三元环：环上三个节点整体回落顶层", () => {
    const tree = buildSubtaskTree([
      sub("a", "甲", "c"),
      sub("b", "乙", "a"),
      sub("c", "丙", "b"),
    ]);
    expect(tree).toHaveLength(3);
    expect(tree.every((n) => n.depth === 0 && n.children.length === 0)).toBe(true);
  });

  it("环外节点挂在「被提顶层」的父下，子树不丢", () => {
    // a↔b 成环；c→a 不在环上 → c 仍挂 a 下（a 已回落顶层）
    const nodes = flattenAll([
      sub("a", "甲", "b"),
      sub("b", "乙", "a"),
      sub("c", "丙", "a"),
      sub("d", "丁", "c"),
    ]);
    const byTitle = new Map(nodes.map((n) => [n.subtask.title, n]));
    expect(byTitle.get("甲")!.depth).toBe(0);
    expect(byTitle.get("乙")!.depth).toBe(0);
    expect(byTitle.get("丙")!.depth).toBe(1);
    expect(byTitle.get("丁")!.depth).toBe(2);
  });

  it("重复 uuid 以首行为准（索引不覆盖；行不丢）", () => {
    // uuid 重复时索引取首行；第二行自身 parent_uuid="a" 仍可解析 → 挂到父下
    const tree = buildSubtaskTree([
      sub("a", "父"),
      sub("b", "子", "a"),
      sub("b", "重名行", "a"),
    ]);
    expect(tree).toHaveLength(1);
    expect(tree[0].subtask.title).toBe("父");
    expect(tree[0].children.map((n) => n.subtask.title)).toEqual(["子", "重名行"]);
  });
});

describe("flattenSubtaskTree", () => {
  it("折叠判定跳过子树（预留能力，当前 UI 无折叠入口）", () => {
    const tree = buildSubtaskTree([sub("a", "父"), sub("b", "子", "a")]);
    const nodes = flattenSubtaskTree(tree, (uuid) => uuid === "a");
    expect(nodes.map((n) => n.subtask.title)).toEqual(["父"]);
  });

  it("空树返回空", () => {
    expect(flattenSubtaskTree([], () => false)).toEqual([]);
  });
});
