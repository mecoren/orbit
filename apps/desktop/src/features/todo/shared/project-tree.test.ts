import { describe, expect, it } from "vitest";

import type { TodoProject } from "@/lib/tauri";
import {
  buildFolderPathLabels,
  buildProjectTree,
  collectDescendantIds,
  collectDescendantUuids,
  DRAG_REPARENT_PX,
  flattenProjectTree,
  normalizeParentUuid,
  parentFolderCandidates,
  planProjectDrop,
  projectIdsWithDescendants,
  type ProjectDropPlan,
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

// ---------- 清单聚合（父清单聚合子清单任务） ----------

describe("collectDescendantIds / projectIdsWithDescendants", () => {
  it("无子项：后代为空，集合只有自身", () => {
    const a = proj("a", "甲");
    const b = proj("b", "乙");
    expect(collectDescendantIds([a, b], a.id)).toEqual([]);
    expect(projectIdsWithDescendants([a, b], a.id)).toEqual([a.id]);
  });

  it("一层父子：集合 = 自身 + 子（自身排首位）", () => {
    const a = proj("a", "甲");
    const b = proj("b", "乙", "a");
    expect(collectDescendantIds([a, b], a.id)).toEqual([b.id]);
    expect(projectIdsWithDescendants([a, b], a.id)).toEqual([a.id, b.id]);
  });

  it("三层嵌套：后代按 DFS 序（中 → 叶）", () => {
    const a = proj("a", "根");
    const b = proj("b", "中", "a");
    const c = proj("c", "叶", "b");
    const d = proj("d", "独立");
    const list = [a, b, c, d];
    expect(projectIdsWithDescendants(list, a.id)).toEqual([a.id, b.id, c.id]);
    expect(collectDescendantIds(list, b.id)).toEqual([c.id]);
    expect(collectDescendantIds(list, d.id)).toEqual([]);
  });

  it("孤儿项目（父不存在）不算任何人的后代", () => {
    const a = proj("a", "甲");
    const orphan = proj("x", "孤儿", "missing");
    expect(collectDescendantIds([a, orphan], a.id)).toEqual([]);
  });

  it("id 不在列表里仍返回自身——项目列表未加载完时不能退化成空集", () => {
    const a = proj("a", "甲");
    expect(collectDescendantIds([a], 999_999)).toEqual([]);
    expect(projectIdsWithDescendants([a], 999_999)).toEqual([999_999]);
  });
});

// ---------- 拖拽跨层级改父 ----------

/**
 * 模拟落库后重新拉取：按新 sort_order 排序 → 按新 parent_uuid 构树 → DFS 展平。
 * 这是 planProjectDrop 的真实消费路径（列表查询 ORDER BY sort_order ASC），
 * 断言它才能验出「顺序漂移」这类只有重建才暴露的缺陷。
 */
function displayAfter(
  projects: TodoProject[],
  activeId: number,
  plan: ProjectDropPlan,
): string[] {
  const so = new Map(plan.order.map((id, i) => [id, i + 1]));
  const next = projects
    .map((p) => ({
      ...p,
      sort_order: so.get(p.id) ?? p.sort_order,
      parent_uuid: p.id === activeId ? plan.parentUuid : p.parent_uuid,
    }))
    .sort((a, b) => a.sort_order - b.sort_order);
  return flattenAll(next).map((n) => `${n.project.title}(${n.depth})`);
}

describe("planProjectDrop", () => {
  const flat = () => {
    const a = proj("a", "甲");
    const b = proj("b", "乙");
    const c = proj("c", "丙");
    return { a, b, c, list: [a, b, c] };
  };

  it("位移不足阈值 → 同级重排（保持原父）", () => {
    const { a, c, list } = flat();
    const plan = planProjectDrop({ projects: list, activeId: a.id, overId: c.id, deltaX: 0 });
    expect(plan).not.toBeNull();
    expect(plan!.kind).toBe("reorder");
    expect(plan!.parentUuid).toBeNull();
    expect(displayAfter(list, a.id, plan!)).toEqual(["乙(0)", "丙(0)", "甲(0)"]);
  });

  it("向上拖 → 插到落点之前", () => {
    const { a, c, list } = flat();
    const plan = planProjectDrop({ projects: list, activeId: c.id, overId: a.id, deltaX: 0 })!;
    expect(plan.kind).toBe("reorder");
    expect(displayAfter(list, c.id, plan)).toEqual(["丙(0)", "甲(0)", "乙(0)"]);
  });

  it("右移达阈值 → 内嵌为落点行的子项", () => {
    const { a, c, list } = flat();
    const plan = planProjectDrop({
      projects: list,
      activeId: a.id,
      overId: c.id,
      deltaX: DRAG_REPARENT_PX,
    })!;
    expect(plan.kind).toBe("nest");
    expect(plan.parentUuid).toBe("c");
    expect(displayAfter(list, a.id, plan)).toEqual(["乙(0)", "丙(0)", "甲(1)"]);
  });

  it("内嵌对象已有子项 → 排到子项末位（不插队）", () => {
    const a = proj("a", "甲");
    const b = proj("b", "乙");
    const b1 = proj("b1", "乙一", "b");
    const b2 = proj("b2", "乙二", "b");
    const list = [a, b, b1, b2];
    const plan = planProjectDrop({ projects: list, activeId: a.id, overId: b.id, deltaX: 99 })!;
    expect(plan.kind).toBe("nest");
    expect(plan.parentUuid).toBe("b");
    expect(displayAfter(list, a.id, plan)).toEqual([
      "乙(0)",
      "乙一(1)",
      "乙二(1)",
      "甲(1)",
    ]);
  });

  it("内嵌到自身后代 → 成环被拒，回落同级重排", () => {
    const a = proj("a", "甲");
    const b = proj("b", "乙", "a");
    const plan = planProjectDrop({ projects: [a, b], activeId: a.id, overId: b.id, deltaX: 99 })!;
    expect(plan.kind).toBe("reorder");
    expect(plan.parentUuid).toBeNull();
    expect(displayAfter([a, b], a.id, plan)).toEqual(["甲(0)", "乙(1)"]);
  });

  it("左移达阈值 → 提升一级，排在原父之后", () => {
    const a = proj("a", "甲");
    const b = proj("b", "乙", "a");
    const c = proj("c", "丙");
    const list = [a, b, c];
    const plan = planProjectDrop({
      projects: list,
      activeId: b.id,
      overId: a.id,
      deltaX: -DRAG_REPARENT_PX,
    })!;
    expect(plan.kind).toBe("outdent");
    expect(plan.parentUuid).toBeNull();
    expect(displayAfter(list, b.id, plan)).toEqual(["甲(0)", "乙(0)", "丙(0)"]);
  });

  it("提升一级带子项 → 子树跟随，落位紧跟原父", () => {
    const a = proj("a", "甲");
    const b = proj("b", "乙", "a");
    const b1 = proj("b1", "乙一", "b");
    const c = proj("c", "丙");
    const list = [a, b, b1, c];
    const plan = planProjectDrop({
      projects: list,
      activeId: b.id,
      overId: a.id,
      deltaX: -DRAG_REPARENT_PX,
    })!;
    expect(plan.kind).toBe("outdent");
    expect(plan.parentUuid).toBeNull();
    expect(displayAfter(list, b.id, plan)).toEqual([
      "甲(0)",
      "乙(0)",
      "乙一(1)",
      "丙(0)",
    ]);
  });

  it("已在顶层左移 → 无处可升，回落同级重排", () => {
    const { a, b, list } = flat();
    const plan = planProjectDrop({
      projects: list,
      activeId: a.id,
      overId: b.id,
      deltaX: -99,
    })!;
    expect(plan.kind).toBe("reorder");
    expect(plan.parentUuid).toBeNull();
    expect(displayAfter(list, a.id, plan)).toEqual(["乙(0)", "甲(0)", "丙(0)"]);
  });

  it("同级重排只在自身兄弟组内挪位：落在别组子树里 → 贴到该子树前后", () => {
    // 顶层顺序 甲(带子 甲一) / 乙 / 丙；把 丙 上拖到 甲一（甲的子项）上：
    // 丙 的兄弟组是 [甲, 乙]，能落的最靠上槽位是「甲之后、乙之前」
    const a = proj("a", "甲");
    const a1 = proj("a1", "甲一", "a");
    const b = proj("b", "乙");
    const c = proj("c", "丙");
    const list = [a, a1, b, c];
    const plan = planProjectDrop({ projects: list, activeId: c.id, overId: a1.id, deltaX: 0 })!;
    expect(plan.kind).toBe("reorder");
    expect(plan.parentUuid).toBeNull();
    expect(displayAfter(list, c.id, plan)).toEqual([
      "甲(0)",
      "甲一(1)",
      "丙(0)",
      "乙(0)",
    ]);
  });

  it("自定义阈值：位移 5px 时默认阈值不触发、阈值 5 触发", () => {
    const { a, c, list } = flat();
    expect(
      planProjectDrop({ projects: list, activeId: a.id, overId: c.id, deltaX: 5 })!.kind,
    ).toBe("reorder");
    expect(
      planProjectDrop({ projects: list, activeId: a.id, overId: c.id, deltaX: 5, threshold: 5 })!
        .kind,
    ).toBe("nest");
  });

  it("自身拖自身 / 未知 id → null", () => {
    const { a, list } = flat();
    expect(planProjectDrop({ projects: list, activeId: a.id, overId: a.id, deltaX: 99 })).toBeNull();
    expect(
      planProjectDrop({ projects: list, activeId: 999_999, overId: a.id, deltaX: 99 }),
    ).toBeNull();
    expect(
      planProjectDrop({ projects: list, activeId: a.id, overId: 999_999, deltaX: 99 }),
    ).toBeNull();
  });

  it("order 恒为全量项目 id 的一个排列（不丢行、不重复）", () => {
    const a = proj("a", "甲");
    const b = proj("b", "乙", "a");
    const c = proj("c", "丙");
    const d = proj("d", "丁", "c");
    const list = [a, b, c, d];
    const plan = planProjectDrop({ projects: list, activeId: d.id, overId: b.id, deltaX: 99 })!;
    expect([...plan.order].sort()).toEqual([a.id, b.id, c.id, d.id].sort());
    expect(new Set(plan.order).size).toBe(4);
  });
});
