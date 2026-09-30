import { describe, expect, it } from "vitest";

import type { TodoProject } from "@/lib/tauri";
import {
  buildFolderPathLabels,
  buildProjectTree,
  collectDescendantUuids,
  flattenProjectTree,
  normalizeParentUuid,
  parentFolderCandidates,
} from "./project-tree";

let seq = 0;
function proj(uuid: string, title: string, parentUuid: string | null = null): TodoProject {
  seq += 1;
  return {
    id: seq,
    uuid,
    title,
    description: null,
    hex_color: "#3B82F6",
    sort_order: seq,
    parent_uuid: parentUuid,
    is_archived: 0,
    is_deleted: 0,
    created_at: 1,
    updated_at: 1,
    deleted_at: null,
    version: 1,
  };
}

const flattenAll = (projects: TodoProject[]) =>
  flattenProjectTree(buildProjectTree(projects), () => false);

describe("normalizeParentUuid", () => {
  it("空值/空白一律归 null（顶层）", () => {
    expect(normalizeParentUuid(null)).toBeNull();
    expect(normalizeParentUuid(undefined)).toBeNull();
    expect(normalizeParentUuid("")).toBeNull();
    expect(normalizeParentUuid("   ")).toBeNull();
  });

  it("有效 uuid 去空白保留", () => {
    expect(normalizeParentUuid("abc")).toBe("abc");
    expect(normalizeParentUuid("  abc  ")).toBe("abc");
  });
});

describe("buildProjectTree", () => {
  it("空输入返回空数组", () => {
    expect(buildProjectTree([])).toEqual([]);
  });

  it("全顶层：顺序保持，depth 全 0", () => {
    const tree = buildProjectTree([proj("a", "甲"), proj("b", "乙"), proj("c", "丙")]);
    expect(tree.map((n) => n.project.title)).toEqual(["甲", "乙", "丙"]);
    expect(tree.every((n) => n.depth === 0)).toBe(true);
    expect(tree.every((n) => n.children.length === 0)).toBe(true);
  });

  it("一层父子：子挂父下，父提为顶层（输入顺序颠倒也成立）", () => {
    const tree = buildProjectTree([proj("b", "子", "a"), proj("a", "父")]);
    expect(tree).toHaveLength(1);
    expect(tree[0].project.title).toBe("父");
    expect(tree[0].depth).toBe(0);
    expect(tree[0].children).toHaveLength(1);
    expect(tree[0].children[0].project.title).toBe("子");
    expect(tree[0].children[0].depth).toBe(1);
  });

  it("三层嵌套 depth 依次 0/1/2", () => {
    const tree = buildProjectTree([
      proj("a", "根"),
      proj("b", "中", "a"),
      proj("c", "叶", "b"),
    ]);
    const nodes = flattenProjectTree(tree, () => false);
    expect(nodes.map((n) => [n.project.title, n.depth])).toEqual([
      ["根", 0],
      ["中", 1],
      ["叶", 2],
    ]);
  });

  it("孤儿（父 uuid 不存在）回落顶层，行不丢", () => {
    const tree = buildProjectTree([proj("a", "甲"), proj("b", "乙", "ghost")]);
    expect(tree.map((n) => n.project.title)).toEqual(["甲", "乙"]);
    expect(tree[1].depth).toBe(0);
  });

  it("自引用回落顶层", () => {
    const tree = buildProjectTree([proj("a", "甲", "a")]);
    expect(tree).toHaveLength(1);
    expect(tree[0].depth).toBe(0);
  });

  it("空白 parent_uuid 回落顶层", () => {
    const tree = buildProjectTree([proj("a", "甲", "   ")]);
    expect(tree[0].depth).toBe(0);
  });

  it("二元环：环上两个节点整体回落顶层（不产生悬挂）", () => {
    const tree = buildProjectTree([proj("a", "甲", "b"), proj("b", "乙", "a")]);
    expect(tree.map((n) => n.project.title).sort()).toEqual(["乙", "甲"]);
    expect(tree.every((n) => n.depth === 0)).toBe(true);
    expect(tree.every((n) => n.children.length === 0)).toBe(true);
  });

  it("三元环：环上三个节点整体回落顶层", () => {
    const tree = buildProjectTree([
      proj("a", "甲", "c"),
      proj("b", "乙", "a"),
      proj("c", "丙", "b"),
    ]);
    expect(tree).toHaveLength(3);
    expect(tree.every((n) => n.depth === 0)).toBe(true);
  });

  it("环外挂子：环回落顶层，挂在环上节点的子树仍完整", () => {
    const tree = buildProjectTree([
      proj("a", "甲", "b"),
      proj("b", "乙", "a"),
      proj("c", "丙", "a"),
    ]);
    const rootA = tree.find((n) => n.project.title === "甲");
    expect(rootA?.depth).toBe(0);
    expect(rootA?.children.map((n) => n.project.title)).toEqual(["丙"]);
    expect(rootA?.children[0].depth).toBe(1);
  });

  it("同层保持输入相对顺序", () => {
    const tree = buildProjectTree([
      proj("r", "根"),
      proj("c2", "子二", "r"),
      proj("c1", "子一", "r"),
    ]);
    expect(tree[0].children.map((n) => n.project.title)).toEqual(["子二", "子一"]);
  });

  it("每个节点只归属一处：展平数量等于输入数量", () => {
    const projects = [
      proj("r", "根"),
      proj("a", "甲", "r"),
      proj("b", "乙", "a"),
      proj("x", "独立"),
    ];
    expect(flattenAll(projects)).toHaveLength(projects.length);
  });

  it("uuid 为空串的项目不参与父查找（按顶层处置）", () => {
    const tree = buildProjectTree([proj("", "无 uuid"), proj("a", "甲", "")]);
    expect(tree.map((n) => n.project.title)).toEqual(["无 uuid", "甲"]);
  });
});

describe("flattenProjectTree", () => {
  const projects = [
    proj("a", "根"),
    proj("b", "子", "a"),
    proj("c", "孙", "b"),
    proj("d", "独立"),
  ];

  it("不折叠：父在前，子孙紧随其后", () => {
    expect(flattenAll(projects).map((n) => n.project.title)).toEqual([
      "根",
      "子",
      "孙",
      "独立",
    ]);
  });

  it("折叠顶层父：子孙全部隐藏，其它分支不受影响", () => {
    const flat = flattenProjectTree(buildProjectTree(projects), (uuid) => uuid === "a");
    expect(flat.map((n) => n.project.title)).toEqual(["根", "独立"]);
  });

  it("折叠中间层：只隐藏其子树，根仍可见", () => {
    const flat = flattenProjectTree(buildProjectTree(projects), (uuid) => uuid === "b");
    expect(flat.map((n) => n.project.title)).toEqual(["根", "子", "独立"]);
  });

  it("折叠叶子节点无副作用（本来就没有子孙）", () => {
    const flat = flattenProjectTree(buildProjectTree(projects), (uuid) => uuid === "c");
    expect(flat).toHaveLength(4);
  });
});

describe("collectDescendantUuids", () => {
  const projects = [
    proj("a", "根"),
    proj("b", "子", "a"),
    proj("c", "孙", "b"),
    proj("d", "独立"),
  ];

  it("返回全部后代（不含自身）", () => {
    const set = collectDescendantUuids(projects, "a");
    expect([...set].sort()).toEqual(["b", "c"]);
  });

  it("中间层只含其子树", () => {
    expect([...collectDescendantUuids(projects, "b")]).toEqual(["c"]);
  });

  it("叶子返回空集；不存在的 uuid 也返回空集", () => {
    expect(collectDescendantUuids(projects, "c").size).toBe(0);
    expect(collectDescendantUuids(projects, "ghost").size).toBe(0);
  });
});

describe("parentFolderCandidates", () => {
  const projects = [
    proj("a", "根"),
    proj("b", "子", "a"),
    proj("c", "孙", "b"),
    proj("d", "独立"),
  ];

  it("编辑根：排除自身与全部后代，只剩无关项目", () => {
    expect(parentFolderCandidates(projects, "a").map((p) => p.uuid)).toEqual(["d"]);
  });

  it("编辑中层：排除自身与后代，父与无关项保留", () => {
    expect(parentFolderCandidates(projects, "b").map((p) => p.uuid)).toEqual(["a", "d"]);
  });

  it("编辑叶子：排除自身，其余全保留", () => {
    expect(parentFolderCandidates(projects, "c").map((p) => p.uuid)).toEqual(["a", "b", "d"]);
  });

  it("新建（selfUuid = null）返回全量", () => {
    expect(parentFolderCandidates(projects, null)).toHaveLength(4);
  });
});

describe("buildFolderPathLabels", () => {
  it("层级路径用 / 拼接，顶层为纯标题", () => {
    const labels = buildFolderPathLabels(
      buildProjectTree([
        proj("a", "根"),
        proj("b", "子", "a"),
        proj("c", "孙", "b"),
        proj("d", "独立"),
      ]),
    );
    expect(labels.get("a")).toBe("根");
    expect(labels.get("b")).toBe("根 / 子");
    expect(labels.get("c")).toBe("根 / 子 / 孙");
    expect(labels.get("d")).toBe("独立");
  });
});
