/**
 * 子任务层级树构建（M10 多层嵌套）——纯函数，详情抽屉「子任务」区块消费。
 *
 * 数据口径：`TodoSubtask.parent_uuid` 指向父级子任务的**同步主键 uuid**
 * （NULL = 顶层）。与项目侧 `project-tree.ts` 同源同构（项目树先例 0003）：
 * 父行未落库/已软删时子行必须仍能存续（父悬空 = 回落顶层）。
 *
 * 四条容错（前端复刻 Rust `validate_subtask_parent` 的读取侧口径）：
 * 1. parent_uuid 空/空白 → 顶层
 * 2. parent_uuid 指向不存在的子任务（父已软删 / 父尚未同步到位）→ 回落顶层，行不丢
 * 3. parent_uuid 指向自身 → 回落顶层
 * 4. 环（A→B→A）：**真正处于环上**的节点整体回落顶层，保证递归终止；
 *    父链接入环但自身不在环上的节点（如 C→A，而 A↔B）仍挂在父下，子树不丢
 *
 * 同层顺序：入参已由后端按 position 排好（详情 SQL `ORDER BY position, id`），
 * 本模块保持该顺序不再排序。
 */
import type { TodoSubtask } from "@/lib/tauri";
import { normalizeParentUuid } from "./project-tree";

export interface SubtaskTreeNode {
  subtask: TodoSubtask;
  /** 层级深度：顶层 = 0 */
  depth: number;
  children: SubtaskTreeNode[];
}

/** uuid → 首个出现下标（空 uuid 不入索引，重复 uuid 以首行为准） */
function indexByUuid(subtasks: TodoSubtask[]): Map<string, number> {
  const index = new Map<string, number>();
  subtasks.forEach((s, i) => {
    const uuid = normalizeParentUuid(s.uuid);
    if (uuid != null && !index.has(uuid)) index.set(uuid, i);
  });
  return index;
}

/** 单跳上溯：idx 的直接父索引（自引用返回自身下标，由调用方判定） */
function parentIndexOf(
  subtasks: TodoSubtask[],
  index: Map<string, number>,
  idx: number,
): number | null {
  const upUuid = normalizeParentUuid(subtasks[idx]?.parent_uuid);
  if (upUuid == null) return null;
  return index.get(upUuid) ?? null;
}

/**
 * 标定「处于环上」的节点索引集合（含自引用）。
 *
 * 三色迭代 DFS：沿父链走，命中当前路径上的节点即构成环，把环段整体入集。
 * 注意「父链接入环但不属于环」的节点（如 C→A，而 A↔B）**不入集**——
 * 它自身层级合法，只是父恰好成了顶层，仍应挂在父下。
 */
function findCyclicNodes(
  subtasks: TodoSubtask[],
  index: Map<string, number>,
): Set<number> {
  const state: number[] = new Array(subtasks.length).fill(0); // 0 未访问 / 1 访问中 / 2 完成
  const cyclic = new Set<number>();

  for (let start = 0; start < subtasks.length; start++) {
    if (state[start] !== 0) continue;
    const path: number[] = [];
    const posInPath = new Map<number, number>();

    let cur: number | null = start;
    while (cur != null && state[cur] === 0) {
      state[cur] = 1;
      posInPath.set(cur, path.length);
      path.push(cur);
      const next = parentIndexOf(subtasks, index, cur);
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
 * 计算每个子任务的「有效父索引」：断链 / 自引用 / 环上节点一律返回 null（= 顶层）。
 *
 * 环上节点整体回落顶层（不会只断一跳留下悬挂子链）；环外节点即使父在环上，
 * 仍按父索引挂载（父已提为顶层，子树结构得以保留）。
 */
function resolveEffectiveParents(subtasks: TodoSubtask[]): (number | null)[] {
  const index = indexByUuid(subtasks);
  const cyclic = findCyclicNodes(subtasks, index);

  return subtasks.map((_s, selfIdx) => {
    if (cyclic.has(selfIdx)) return null;
    const parentIdx = parentIndexOf(subtasks, index, selfIdx);
    if (parentIdx == null || parentIdx === selfIdx) return null; // 断链 / 自引用防守
    return parentIdx;
  });
}

/**
 * 按 parent_uuid 构建子任务树。
 *
 * @param subtasks 同任务的**全量活子任务**（详情/列表返回即此形态，已按 position 排序）
 * @returns 顶层节点数组，children 递归展开，depth 已标注
 */
export function buildSubtaskTree(subtasks: TodoSubtask[]): SubtaskTreeNode[] {
  const nodes: SubtaskTreeNode[] = subtasks.map((subtask) => ({
    subtask,
    depth: 0,
    children: [],
  }));

  const effectiveParents = resolveEffectiveParents(subtasks);

  const roots: SubtaskTreeNode[] = [];
  nodes.forEach((node, idx) => {
    const parentIdx = effectiveParents[idx];
    if (parentIdx != null && parentIdx !== idx) {
      nodes[parentIdx].children.push(node);
    } else {
      roots.push(node);
    }
  });

  // 递归标注 depth：环检测已保证无环，且每个节点归属唯一（父的 children 或 roots 二选一）
  const markDepth = (list: SubtaskTreeNode[], depth: number) => {
    for (const node of list) {
      node.depth = depth;
      if (node.children.length > 0) markDepth(node.children, depth + 1);
    }
  };
  markDepth(roots, 0);

  return roots;
}

/**
 * 把树展平为渲染序列（父在前，子紧随其后）。
 *
 * @param isCollapsed 折叠判定；仅对「有子节点」的节点有意义（当前 UI 无折叠入口，
 *   传 `() => false`；预留同项目侧 flattenProjectTree 的对称能力）
 */
export function flattenSubtaskTree(
  nodes: SubtaskTreeNode[],
  isCollapsed: (uuid: string) => boolean = () => false,
): SubtaskTreeNode[] {
  const out: SubtaskTreeNode[] = [];
  const walk = (list: SubtaskTreeNode[]) => {
    for (const node of list) {
      out.push(node);
      if (node.children.length > 0 && !isCollapsed(node.subtask.uuid)) {
        walk(node.children);
      }
    }
  };
  walk(nodes);
  return out;
}
