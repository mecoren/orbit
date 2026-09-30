/**
 * 项目层级树构建（M8 清单文件夹分组）——纯函数，桌面侧栏消费。
 *
 * 数据口径：`TodoProject.parent_uuid` 指向父项目的**同步主键 uuid**（NULL = 顶层）。
 * 不用本地自增 id：云同步按行 uuid 合并，父行未落库时子行必须仍能存续
 * （父行悬空 = 回落顶层）；自增 id 跨端不稳定。
 *
 * 四条容错（前端复刻 Rust `validate_project_parent` 的读取侧口径）：
 * 1. parent_uuid 空/空白 → 顶层
 * 2. parent_uuid 指向不存在的项目（父已软删 / 父尚未同步到位）→ 回落顶层，行不丢
 * 3. parent_uuid 指向自身 → 回落顶层
 * 4. 环（A→B→A）：**真正处于环上**的节点整体回落顶层，保证递归终止；
 *    父链接入环但自身不在环上的节点（如 C→A，而 A↔B）仍挂在父下，子树不丢
 *
 * 同层顺序：沿用输入顺序（调用方已按 sort_order 排好），本模块不再排序。
 */
import type { TodoProject } from "@/lib/tauri";

export interface ProjectTreeNode {
  project: TodoProject;
  /** 层级深度：顶层 = 0 */
  depth: number;
  children: ProjectTreeNode[];
}

/** 父 uuid 归一化：空白 → null（与 Rust `normalize_parent_uuid` 同口径） */
export function normalizeParentUuid(raw: string | null | undefined): string | null {
  if (raw == null) return null;
  const trimmed = raw.trim();
  return trimmed === "" ? null : trimmed;
}

/** uuid → 首个出现下标（空 uuid 不入索引，重复 uuid 以首行为准） */
function indexProjectsByUuid(projects: TodoProject[]): Map<string, number> {
  const indexByUuid = new Map<string, number>();
  projects.forEach((p, i) => {
    const uuid = normalizeParentUuid(p.uuid);
    if (uuid != null && !indexByUuid.has(uuid)) indexByUuid.set(uuid, i);
  });
  return indexByUuid;
}

/** 单跳上溯：idx 的直接父索引（自引用返回自身下标，由调用方判定） */
function parentIndexOf(
  projects: TodoProject[],
  indexByUuid: Map<string, number>,
  idx: number,
): number | null {
  const upUuid = normalizeParentUuid(projects[idx]?.parent_uuid);
  if (upUuid == null) return null;
  return indexByUuid.get(upUuid) ?? null;
}

/**
 * 标定「处于环上」的节点索引集合（含自引用）。
 *
 * 三色迭代 DFS：沿父链走，命中当前路径上的节点即构成环，把环段整体入集。
 * 注意「父链接入环但不属于环」的节点（如 C→A，而 A↔B）**不入集**——
 * 它自身层级合法，只是父恰好成了顶层，仍应挂在父下。
 */
function findCyclicNodes(
  projects: TodoProject[],
  indexByUuid: Map<string, number>,
): Set<number> {
  const state: number[] = new Array(projects.length).fill(0); // 0 未访问 / 1 访问中 / 2 完成
  const cyclic = new Set<number>();

  for (let start = 0; start < projects.length; start++) {
    if (state[start] !== 0) continue;
    const path: number[] = [];
    const posInPath = new Map<number, number>();

    let cur: number | null = start;
    while (cur != null && state[cur] === 0) {
      state[cur] = 1;
      posInPath.set(cur, path.length);
      path.push(cur);
      const next = parentIndexOf(projects, indexByUuid, cur);
      if (next === cur) {
        cyclic.add(cur); // 自引用：自身即环
        cur = null;
      } else {
        cur = next;
      }
    }

    // 命中「访问中」节点 → 从该节点到当前路径末尾构成环
    if (cur != null && state[cur] === 1) {
      const from = posInPath.get(cur);
      if (from != null) {
        for (let i = from; i < path.length; i++) cyclic.add(path[i]);
      }
    }
    for (const idx of path) state[idx] = 2;
  }
  return cyclic;
}

/**
 * 计算每个项目的「有效父索引」：断链 / 自引用 / 环上节点一律返回 null（= 顶层）。
 *
 * 环上节点整体回落顶层（不会只断一跳留下悬挂子链）；环外节点即使父在环上，
 * 仍按父索引挂载（父已提为顶层，子树结构得以保留）。
 */
function resolveEffectiveParents(projects: TodoProject[]): (number | null)[] {
  const indexByUuid = indexProjectsByUuid(projects);
  const cyclic = findCyclicNodes(projects, indexByUuid);

  return projects.map((_p, selfIdx) => {
    if (cyclic.has(selfIdx)) return null;
    const parentIdx = parentIndexOf(projects, indexByUuid, selfIdx);
    if (parentIdx == null || parentIdx === selfIdx) return null; // 断链 / 自引用防守
    return parentIdx;
  });
}

/**
 * 按 parent_uuid 构建项目树。
 *
 * @param projects 已按 sort_order 排好的**全量活跃项目**（不含归档）
 * @returns 顶层节点数组，children 递归展开，depth 已标注
 */
export function buildProjectTree(projects: TodoProject[]): ProjectTreeNode[] {
  const nodes: ProjectTreeNode[] = projects.map((project) => ({
    project,
    depth: 0,
    children: [],
  }));

  const effectiveParents = resolveEffectiveParents(projects);

  const roots: ProjectTreeNode[] = [];
  nodes.forEach((node, idx) => {
    const parentIdx = effectiveParents[idx];
    if (parentIdx != null && parentIdx !== idx) {
      nodes[parentIdx].children.push(node);
    } else {
      roots.push(node);
    }
  });

  // 递归标注 depth：环检测已保证无环，且每个节点归属唯一（父的 children 或 roots 二选一）
  const markDepth = (list: ProjectTreeNode[], depth: number) => {
    for (const node of list) {
      node.depth = depth;
      if (node.children.length > 0) markDepth(node.children, depth + 1);
    }
  };
  markDepth(roots, 0);

  return roots;
}

/**
 * 按折叠状态把树展平为渲染序列（父在前，子紧随其后；折叠节点的子孙跳过）。
 *
 * @param isCollapsed 折叠判定；仅对「有子节点」的节点有意义
 */
export function flattenProjectTree(
  nodes: ProjectTreeNode[],
  isCollapsed: (uuid: string) => boolean,
): ProjectTreeNode[] {
  const out: ProjectTreeNode[] = [];
  const walk = (list: ProjectTreeNode[]) => {
    for (const node of list) {
      out.push(node);
      if (node.children.length > 0 && !isCollapsed(node.project.uuid)) {
        walk(node.children);
      }
    }
  };
  walk(nodes);
  return out;
}

/** 收集某项目的全部后代 uuid（不含自身）；项目不存在则返回空集 */
export function collectDescendantUuids(projects: TodoProject[], rootUuid: string): Set<string> {
  const result = new Set<string>();
  const find = (list: ProjectTreeNode[]): ProjectTreeNode | null => {
    for (const node of list) {
      if (node.project.uuid === rootUuid) return node;
      const hit = find(node.children);
      if (hit != null) return hit;
    }
    return null;
  };
  const root = find(buildProjectTree(projects));
  if (root == null) return result;
  const walk = (list: ProjectTreeNode[]) => {
    for (const node of list) {
      result.add(node.project.uuid);
      walk(node.children);
    }
  };
  walk(root.children);
  return result;
}

/**
 * 「上级文件夹」候选列表：排除自身与其全部后代（否则成环，Rust 侧必拒）。
 *
 * @param selfUuid 当前编辑项目的 uuid；新建（无 uuid）传 null → 返回全量
 */
export function parentFolderCandidates(
  projects: TodoProject[],
  selfUuid: string | null,
): TodoProject[] {
  if (selfUuid == null) return projects;
  const excluded = collectDescendantUuids(projects, selfUuid);
  excluded.add(selfUuid);
  return projects.filter((p) => !excluded.has(normalizeParentUuid(p.uuid) ?? ""));
}

/** 候选列表显示名：带祖先路径（"父 / 子"），避免不同层级同名歧义 */
export function buildFolderPathLabels(tree: ProjectTreeNode[]): Map<string, string> {
  const labels = new Map<string, string>();
  const walk = (list: ProjectTreeNode[], prefix: string) => {
    for (const node of list) {
      const uuid = normalizeParentUuid(node.project.uuid);
      if (uuid == null) continue;
      const label = prefix === "" ? node.project.title : `${prefix} / ${node.project.title}`;
      labels.set(uuid, label);
      if (node.children.length > 0) walk(node.children, label);
    }
  };
  walk(tree, "");
  return labels;
}
