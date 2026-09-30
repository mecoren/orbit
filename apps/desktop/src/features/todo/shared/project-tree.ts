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
 * 收集某项目的全部后代**本地 id**（不含自身）；项目不存在则返回空数组。
 *
 * 与 [collectDescendantUuids] 同源同口径，只是键不同：
 * - uuid 版供「上级文件夹候选」排除成环；
 * - id 版供**父清单聚合子清单任务**——`todo_tasks.project_id` 是本地 id，
 *   展开成 id 集合才能直接喂给 `ListFilter.project_ids`（SQL `IN`）。
 *
 * 断链/自引用/成环的节点已由 [buildProjectTree] 归到顶层，故本函数的
 * 结果天然不含环上节点的错误祖先链。
 */
export function collectDescendantIds(projects: TodoProject[], rootId: number): number[] {
  const find = (list: ProjectTreeNode[]): ProjectTreeNode | null => {
    for (const node of list) {
      if (node.project.id === rootId) return node;
      const hit = find(node.children);
      if (hit != null) return hit;
    }
    return null;
  };
  const root = find(buildProjectTree(projects));
  if (root == null) return [];
  const out: number[] = [];
  const walk = (list: ProjectTreeNode[]) => {
    for (const node of list) {
      out.push(node.project.id);
      walk(node.children);
    }
  };
  walk(root.children);
  return out;
}

/**
 * 清单视图覆盖的项目 id 集合 = 自身 + 全部后代（聚合口径单一口径源）。
 *
 * 父清单选中时任务列表应包含其所有后代清单的**直接**任务（TickTick
 * List Folder 同款）；返回 [rootId] 打头，保证集合恒非空、顺序稳定
 * （`useMemo` 依赖下避免每次 render 新数组导致查询键抖动）。
 */
export function projectIdsWithDescendants(projects: TodoProject[], rootId: number): number[] {
  return [rootId, ...collectDescendantIds(projects, rootId)];
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

// ---------- 拖拽跨层级改父（M8+） ----------

/**
 * 横向位移阈值（px）：超过它就判定为「改层级」而非同级重排。
 *
 * 与缩进步长（14px/层）同量级但不相等——卡在整层宽度上会与「手抖」难分，
 * 20px 大致是半个图标的位移，配合拖拽预览跟随横向位移形成可感知的意图表达。
 */
export const DRAG_REPARENT_PX = 20;

/** 拖拽落位意图（由横向位移与落点行共同判定） */
export type ProjectDropKind = "reorder" | "nest" | "outdent";

/** 拖拽落位计算结果（纯数据，调用方负责落库与乐观更新） */
export interface ProjectDropPlan {
  kind: ProjectDropKind;
  /** 被拖项目改父后的上级 uuid；null = 顶层。kind=reorder 时为原父（不变） */
  parentUuid: string | null;
  /**
   * 落库用的**全局顺序**（项目 id 升序 = 应处的 sort_order 1..n）。
   *
   * 口径 = 未折叠的全量 DFS 序——折叠只是浏览态，不该影响落库结果
   * （旧实现按可见序列编号，折叠子树里的兄弟相对序会漂移）。
   */
  order: number[];
}

/**
 * 拖拽落位解析：把 dnd-kit 的（被拖行、落点行、横向位移）翻译成
 * 「是否改父 + 改到哪个父 + 全局新顺序」。
 *
 * 手势语义（双端同口径）：
 * - 右移 ≥ 阈值 → **内嵌**：成为落点行的最后一个子项（落点在被拖项的子树内
 *   会成环，拒绝并回落同级重排）；
 * - 左移 ≥ 阈值 → **提升一级**：挂到当前父的父下、排在原父之后；已在顶层时
 *   无处可升，回落同级重排；
 * - 位移不足阈值 → **同级重排**（保持原父，只在自身兄弟组内挪位）。
 *
 * **顺序的算法**：改层级必须在**树上做手术**（摘除 + 插入目标兄弟数组），
 * 再把手术后的树按前序展平取其 id 序列作为 sort_order。
 * 反例说明为何不能在「旧展平序列」上做下标算术：把节点插到某子树之后时，
 * 兄弟组的落位由父节点自身的 sort_order 决定（子树内编号会插在中间），
 * 下标算术会让被拖项漂到同层末位。
 *
 * @returns 无法解析（id 不存在 / 自身拖自身）时返回 null
 */
export function planProjectDrop(params: {
  projects: TodoProject[];
  activeId: number;
  overId: number;
  /** dnd-kit `DragEndEvent.delta.x`（指针累计横向位移） */
  deltaX: number;
  /** 横向位移阈值，缺省 [DRAG_REPARENT_PX] */
  threshold?: number;
}): ProjectDropPlan | null {
  const { projects, activeId, overId, deltaX, threshold = DRAG_REPARENT_PX } = params;
  if (activeId === overId) return null;

  const tree = buildProjectTree(projects);
  const fullNodes = flattenProjectTree(tree, () => false);
  const dfsIndex = new Map<number, number>();
  fullNodes.forEach((n, i) => dfsIndex.set(n.project.id, i));

  // 每行登记：所在兄弟数组 + 父节点（顶层为 null）
  const siblingsOf = new Map<number, ProjectTreeNode[]>();
  const parentOf = new Map<number, ProjectTreeNode | null>();
  const nodeOf = new Map<number, ProjectTreeNode>();
  const walk = (list: ProjectTreeNode[], parent: ProjectTreeNode | null) => {
    for (const node of list) {
      siblingsOf.set(node.project.id, list);
      parentOf.set(node.project.id, parent);
      nodeOf.set(node.project.id, node);
      walk(node.children, node);
    }
  };
  walk(tree, null);

  const activeNode = nodeOf.get(activeId);
  const overNode = nodeOf.get(overId);
  const activeIdx = dfsIndex.get(activeId);
  const overIdx = dfsIndex.get(overId);
  if (!activeNode || !overNode || activeIdx == null || overIdx == null) return null;

  // 被拖项子树的 DFS 区间（子树在 DFS 序里连续）：落点落在区间内 = 成环
  let activeSubtreeEnd = activeIdx;
  while (
    activeSubtreeEnd + 1 < fullNodes.length &&
    fullNodes[activeSubtreeEnd + 1].depth > fullNodes[activeIdx].depth
  ) {
    activeSubtreeEnd++;
  }
  const overInActiveSubtree = overIdx >= activeIdx && overIdx <= activeSubtreeEnd;

  // 空 uuid 的项目不能当父（子项存的是 uuid，写空串等于「顶层」，语义会丢）
  const overUuid = normalizeParentUuid(overNode.project.uuid);
  const parentNode = parentOf.get(activeId) ?? null;

  let kind: ProjectDropKind = "reorder";
  let parentUuid: string | null = normalizeParentUuid(activeNode.project.parent_uuid);

  // 摘除：从原兄弟数组里取出被拖节点（后面三种意图各自决定插到哪）
  const oldSiblings = siblingsOf.get(activeId)!;
  oldSiblings.splice(oldSiblings.indexOf(activeNode), 1);

  if (deltaX >= threshold && overUuid != null && !overInActiveSubtree) {
    // 内嵌：挂到落点行的子项末位
    kind = "nest";
    parentUuid = overUuid;
    overNode.children.push(activeNode);
  } else if (deltaX <= -threshold && parentNode != null) {
    // 提升一级：挂到祖父下、紧跟原父之后（祖父用树上的「有效父」，
    // 已含成环/断链归顶层的修正）
    const grandParent = parentOf.get(parentNode.project.id) ?? null;
    kind = "outdent";
    parentUuid = grandParent ? normalizeParentUuid(grandParent.project.uuid) : null;
    const targetSiblings = grandParent ? grandParent.children : tree;
    const at = targetSiblings.indexOf(parentNode);
    targetSiblings.splice(at < 0 ? targetSiblings.length : at + 1, 0, activeNode);
  } else {
    // 同级重排：只在自身兄弟组内挪位；落点不在本组时按 DFS 位置就近取锚
    //（落点是本组兄弟 → 等价 arrayMove；落在别组子树内 → 贴到该子树前后）
    const others = oldSiblings; // 已摘除 active，即其余兄弟
    const next = [...others];
    if (activeIdx < overIdx) {
      // 往下拖：插到「DFS 位置最靠后、且不晚于落点」的兄弟之后；无则最前
      let anchor = -1;
      others.forEach((s, i) => {
        if ((dfsIndex.get(s.project.id) ?? -1) <= overIdx) anchor = i;
      });
      next.splice(anchor + 1, 0, activeNode);
    } else {
      // 往上拖：插到「DFS 位置最靠前、且不早于落点」的兄弟之前；无则最后
      const anchor = others.findIndex(
        (s) => (dfsIndex.get(s.project.id) ?? Number.MAX_SAFE_INTEGER) >= overIdx,
      );
      next.splice(anchor < 0 ? next.length : anchor, 0, activeNode);
    }
    oldSiblings.splice(0, oldSiblings.length, ...next);
  }

  const order = flattenProjectTree(tree, () => false).map((n) => n.project.id);
  return { kind, parentUuid, order };
}
