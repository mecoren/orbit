/// 项目层级树构建（M8 清单文件夹分组）——纯函数，移动端侧栏与编辑页消费。
///
/// 数据口径：`TodoProject.parentUuid` 指向父项目的**同步主键 uuid**（null = 顶层）。
/// 不用本地自增 id：云同步按行 uuid 合并，父行未落库时子行必须仍能存续
/// （父行悬空 = 回落顶层）；自增 id 跨端不稳定。
///
/// 四条容错（读取侧口径，与桌面 `shared/project-tree.ts`、Rust `validate_project_parent` 一致）：
/// 1. parentUuid 空/空白 → 顶层
/// 2. parentUuid 指向不存在的项目（父已软删 / 父尚未同步到位）→ 回落顶层，行不丢
/// 3. parentUuid 指向自身 → 回落顶层
/// 4. 环（A→B→A）：**真正处于环上**的节点整体回落顶层，保证递归终止；
///    父链接入环但自身不在环上的节点（如 C→A，而 A↔B）仍挂在父下，子树不丢
///
/// 同层顺序：沿用输入顺序（调用方已按 sortOrder 排好），本模块不再排序。
library;

// 归一化口径复用 dto 层 `normalizeParentUuid`（M8 桥接阶段已定义）——单一真相源，
// 不在此重复实现：两份实现必然漂移，且同符号会与 `import dto.dart` 的调用方冲突。
import '../../../data/api/dto.dart';

/// 树节点：项目 + 层级深度 + 子节点
class ProjectTreeNode {
  ProjectTreeNode(this.project);

  final TodoProject project;

  /// 层级深度：顶层 = 0
  int depth = 0;
  final List<ProjectTreeNode> children = <ProjectTreeNode>[];
}

/// uuid → 首个出现下标（空 uuid 不入索引，重复 uuid 以首行为准）
Map<String, int> _indexByUuid(List<TodoProject> projects) {
  final index = <String, int>{};
  for (var i = 0; i < projects.length; i++) {
    final uuid = normalizeParentUuid(projects[i].uuid);
    if (uuid != null) index.putIfAbsent(uuid, () => i);
  }
  return index;
}

/// 单跳上溯：idx 的直接父索引（自引用返回自身下标，由调用方判定）
int? _parentIndexOf(
  List<TodoProject> projects,
  Map<String, int> indexByUuid,
  int idx,
) {
  final upUuid = normalizeParentUuid(projects[idx].parentUuid);
  if (upUuid == null) return null;
  return indexByUuid[upUuid];
}

/// 标定「处于环上」的节点索引集合（含自引用）。
///
/// 三色迭代 DFS：沿父链走，命中当前路径上的节点即构成环，把环段整体入集。
/// 注意「父链接入环但不属于环」的节点（如 C→A，而 A↔B）**不入集**——
/// 它自身层级合法，只是父恰好成了顶层，仍应挂在父下。
Set<int> _findCyclicNodes(
  List<TodoProject> projects,
  Map<String, int> indexByUuid,
) {
  final n = projects.length;
  final state = List<int>.filled(n, 0); // 0 未访问 / 1 访问中 / 2 完成
  final cyclic = <int>{};

  for (var start = 0; start < n; start++) {
    if (state[start] != 0) continue;
    final path = <int>[];
    final posInPath = <int, int>{};

    int? cur = start;
    while (cur != null && state[cur] == 0) {
      state[cur] = 1;
      posInPath[cur] = path.length;
      path.add(cur);
      final next = _parentIndexOf(projects, indexByUuid, cur);
      if (next == cur) {
        cyclic.add(cur); // 自引用：自身即环
        cur = null;
      } else {
        cur = next;
      }
    }

    // 命中「访问中」节点 → 从该节点到当前路径末尾构成环
    if (cur != null && state[cur] == 1) {
      final from = posInPath[cur];
      if (from != null) {
        for (var i = from; i < path.length; i++) {
          cyclic.add(path[i]);
        }
      }
    }
    for (final idx in path) {
      state[idx] = 2;
    }
  }
  return cyclic;
}

/// 按 parentUuid 构建项目树。
///
/// [projects] 已按 sortOrder 排好的**全量活跃项目**（不含归档）。
/// 返回顶层节点数组，children 递归展开，depth 已标注。
List<ProjectTreeNode> buildProjectTree(List<TodoProject> projects) {
  if (projects.isEmpty) return const <ProjectTreeNode>[];

  final nodes = <ProjectTreeNode>[for (final p in projects) ProjectTreeNode(p)];
  final indexByUuid = _indexByUuid(projects);
  final cyclic = _findCyclicNodes(projects, indexByUuid);

  final roots = <ProjectTreeNode>[];
  for (var i = 0; i < projects.length; i++) {
    if (cyclic.contains(i)) {
      roots.add(nodes[i]);
      continue;
    }
    final parentIdx = _parentIndexOf(projects, indexByUuid, i);
    // 断链 / 自引用 / 空父 → 顶层
    if (parentIdx == null || parentIdx == i) {
      roots.add(nodes[i]);
    } else {
      nodes[parentIdx].children.add(nodes[i]);
    }
  }

  // 递归标注 depth：环检测已保证无环，且每个节点归属唯一
  void markDepth(List<ProjectTreeNode> list, int depth) {
    for (final node in list) {
      node.depth = depth;
      if (node.children.isNotEmpty) markDepth(node.children, depth + 1);
    }
  }

  markDepth(roots, 0);
  return roots;
}

/// 按折叠状态把树展平为渲染序列（父在前，子紧随其后；折叠节点的子孙跳过）。
///
/// [isCollapsed] 折叠判定；仅对「有子节点」的节点有意义。
List<ProjectTreeNode> flattenProjectTree(
  List<ProjectTreeNode> nodes,
  bool Function(String uuid) isCollapsed,
) {
  final out = <ProjectTreeNode>[];

  void walk(List<ProjectTreeNode> list) {
    for (final node in list) {
      out.add(node);
      if (node.children.isNotEmpty && !isCollapsed(node.project.uuid)) {
        walk(node.children);
      }
    }
  }

  walk(nodes);
  return out;
}

/// 收集某项目的全部后代 uuid（不含自身）；项目不存在则返回空集
Set<String> collectDescendantUuids(
  List<TodoProject> projects,
  String rootUuid,
) {
  final result = <String>{};

  ProjectTreeNode? find(List<ProjectTreeNode> list) {
    for (final node in list) {
      if (node.project.uuid == rootUuid) return node;
      final hit = find(node.children);
      if (hit != null) return hit;
    }
    return null;
  }

  final root = find(buildProjectTree(projects));
  if (root == null) return result;

  void walk(List<ProjectTreeNode> list) {
    for (final node in list) {
      result.add(node.project.uuid);
      walk(node.children);
    }
  }

  walk(root.children);
  return result;
}

/// 收集某项目的全部后代**本地 id**（不含自身）；项目不存在则返回空列表。
///
/// 与 [collectDescendantUuids] 同源同口径，只是键不同：
/// - uuid 版供「上级文件夹候选」排除成环；
/// - id 版供**父清单聚合子清单任务**——`TodoTask.projectId` 是本地 id，
///   展开成 id 集合才能喂给 `TaskFilterInput.projectIds`。
///
/// 断链/自引用/成环的节点已由 [buildProjectTree] 归到顶层，故结果天然不含
/// 环上节点的错误祖先链。
List<int> collectDescendantIds(List<TodoProject> projects, int rootId) {
  ProjectTreeNode? find(List<ProjectTreeNode> list) {
    for (final node in list) {
      if (node.project.id == rootId) return node;
      final hit = find(node.children);
      if (hit != null) return hit;
    }
    return null;
  }

  final root = find(buildProjectTree(projects));
  if (root == null) return const <int>[];

  final out = <int>[];

  void walk(List<ProjectTreeNode> list) {
    for (final node in list) {
      out.add(node.project.id);
      walk(node.children);
    }
  }

  walk(root.children);
  return out;
}

/// 清单视图覆盖的项目 id 集合 = 自身 + 全部后代（聚合口径单一口径源）。
///
/// 父清单选中时任务列表应包含其所有后代清单的**直接**任务（TickTick
/// List Folder 同款）；[rootId] 打头保证集合恒非空——项目列表尚未加载完时
/// 不能退化成空集（那会让列表闪空）。
List<int> projectIdsWithDescendants(List<TodoProject> projects, int rootId) =>
    <int>[rootId, ...collectDescendantIds(projects, rootId)];

// ---------- 拖拽跨层级改父（M8+） ----------

/// 横向位移阈值（逻辑像素）：超过它即判定「改层级」而非同级重排。
///
/// 与缩进步长（14）同量级但不相等——整层宽度会与手抖难分。
const double dragReparentPx = 20;

/// 拖拽落位意图（由横向位移与落点行共同判定）
enum ProjectDropKind { reorder, nest, outdent }

/// 拖拽落位计算结果（纯数据，调用方负责落库与刷新）
class ProjectDropPlan {
  const ProjectDropPlan({
    required this.kind,
    required this.parentUuid,
    required this.order,
  });

  final ProjectDropKind kind;

  /// 被拖项目改父后的上级 uuid；null = 顶层。kind=reorder 时为原父（不变）
  final String? parentUuid;

  /// 落库用的**全局顺序**（项目 id 升序 = 应处的 sortOrder 1..n）。
  ///
  /// 口径 = 未折叠的全量 DFS 序——折叠只是浏览态，不该影响落库结果。
  final List<int> order;
}

/// 拖拽落位解析：把（被拖行、落点行、横向位移）翻译成「是否改父 + 改到哪个父
/// + 全局新顺序」。与桌面 `shared/project-tree.ts::planProjectDrop` 逐字同口径。
///
/// 手势语义：
/// - 右移 ≥ 阈值 → **内嵌**：成为落点行的最后一个子项（落点在被拖项子树内会
///   成环，拒绝并回落同级重排）；
/// - 左移 ≥ 阈值 → **提升一级**：挂到当前父的父下、排在原父之后；已在顶层时
///   无处可升，回落同级重排；
/// - 位移不足阈值 → **同级重排**（保持原父，只在自身兄弟组内挪位）。
///
/// **顺序的算法**：改层级必须在**树上做手术**（摘除 + 插入目标兄弟数组），
/// 再把手术后的树按前序展平取其 id 序列。反例说明为何不能在「旧展平序列」上
/// 做下标算术：把节点插到某子树之后时，兄弟组的落位由父节点自身的 sortOrder
/// 决定（子树内编号会插在中间），下标算术会让被拖项漂到同层末位。
///
/// 返回 null = 无法解析（id 不存在 / 自身拖自身）。
ProjectDropPlan? planProjectDrop({
  required List<TodoProject> projects,
  required int activeId,
  required int overId,
  required double deltaX,
  double threshold = dragReparentPx,
}) {
  if (activeId == overId) return null;

  final tree = buildProjectTree(projects);
  final fullNodes = flattenProjectTree(tree, (_) => false);
  final dfsIndex = <int, int>{};
  for (var i = 0; i < fullNodes.length; i++) {
    dfsIndex[fullNodes[i].project.id] = i;
  }

  final siblingsOf = <int, List<ProjectTreeNode>>{};
  final parentOf = <int, ProjectTreeNode?>{};
  final nodeOf = <int, ProjectTreeNode>{};

  void walk(List<ProjectTreeNode> list, ProjectTreeNode? parent) {
    for (final node in list) {
      siblingsOf[node.project.id] = list;
      parentOf[node.project.id] = parent;
      nodeOf[node.project.id] = node;
      walk(node.children, node);
    }
  }

  walk(tree, null);

  final activeNode = nodeOf[activeId];
  final overNode = nodeOf[overId];
  final activeIdx = dfsIndex[activeId];
  final overIdx = dfsIndex[overId];
  if (activeNode == null ||
      overNode == null ||
      activeIdx == null ||
      overIdx == null) {
    return null;
  }

  // 被拖项子树的 DFS 区间（子树在 DFS 序里连续）：落点落在区间内 = 成环
  var activeSubtreeEnd = activeIdx;
  while (activeSubtreeEnd + 1 < fullNodes.length &&
      fullNodes[activeSubtreeEnd + 1].depth > fullNodes[activeIdx].depth) {
    activeSubtreeEnd++;
  }
  final overInActiveSubtree =
      overIdx >= activeIdx && overIdx <= activeSubtreeEnd;

  // 空 uuid 的项目不能当父（子项存的是 uuid，写空串等于「顶层」，语义会丢）
  final overUuid = normalizeParentUuid(overNode.project.uuid);
  final parentNode = parentOf[activeId];

  var kind = ProjectDropKind.reorder;
  var parentUuid = normalizeParentUuid(activeNode.project.parentUuid);

  // 摘除：从原兄弟数组里取出被拖节点（三种意图各自决定插到哪）
  final oldSiblings = siblingsOf[activeId]!;
  oldSiblings.remove(activeNode);

  if (deltaX >= threshold && overUuid != null && !overInActiveSubtree) {
    // 内嵌：挂到落点行的子项末位
    kind = ProjectDropKind.nest;
    parentUuid = overUuid;
    overNode.children.add(activeNode);
  } else if (deltaX <= -threshold && parentNode != null) {
    // 提升一级：挂到祖父下、紧跟原父之后（祖父用树上的「有效父」，
    // 已含成环/断链归顶层的修正）
    final grandParent = parentOf[parentNode.project.id];
    kind = ProjectDropKind.outdent;
    parentUuid = grandParent == null
        ? null
        : normalizeParentUuid(grandParent.project.uuid);
    final targetSiblings = grandParent?.children ?? tree;
    final at = targetSiblings.indexOf(parentNode);
    targetSiblings.insert(
      at < 0 ? targetSiblings.length : at + 1,
      activeNode,
    );
  } else {
    // 同级重排：只在自身兄弟组内挪位；落点不在本组时按 DFS 位置就近取锚
    final others = oldSiblings; // 已摘除 active，即其余兄弟
    final next = <ProjectTreeNode>[...others];
    if (activeIdx < overIdx) {
      // 往下拖：插到「DFS 位置最靠后、且不晚于落点」的兄弟之后；无则最前
      var anchor = -1;
      for (var i = 0; i < others.length; i++) {
        if ((dfsIndex[others[i].project.id] ?? -1) <= overIdx) anchor = i;
      }
      next.insert(anchor + 1, activeNode);
    } else {
      // 往上拖：插到「DFS 位置最靠前、且不早于落点」的兄弟之前；无则最后
      var anchor = -1;
      for (var i = 0; i < others.length; i++) {
        if ((dfsIndex[others[i].project.id] ?? _maxDfsIndex) >= overIdx) {
          anchor = i;
          break;
        }
      }
      next.insert(anchor < 0 ? next.length : anchor, activeNode);
    }
    oldSiblings
      ..clear()
      ..addAll(next);
  }

  final order = <int>[
    for (final n in flattenProjectTree(tree, (_) => false)) n.project.id,
  ];
  return ProjectDropPlan(kind: kind, parentUuid: parentUuid, order: order);
}

/// `dfsIndex` 查不到时的兜底上界（等价 `Number.MAX_SAFE_INTEGER`）
const int _maxDfsIndex = 1 << 62;

/// 「上级文件夹」候选列表：排除自身与其全部后代（否则成环，Rust 侧必拒）。
///
/// [selfUuid] 当前编辑项目的 uuid；新建（无 uuid）传 null → 返回全量。
List<TodoProject> parentFolderCandidates(
  List<TodoProject> projects,
  String? selfUuid,
) {
  if (selfUuid == null) return projects;
  final excluded = collectDescendantUuids(projects, selfUuid)..add(selfUuid);
  return [
    for (final p in projects)
      if (!excluded.contains(normalizeParentUuid(p.uuid) ?? '')) p,
  ];
}

/// 候选列表显示名：带祖先路径（"父 / 子"），避免不同层级同名歧义
Map<String, String> buildFolderPathLabels(List<ProjectTreeNode> tree) {
  final labels = <String, String>{};

  void walk(List<ProjectTreeNode> list, String prefix) {
    for (final node in list) {
      final uuid = normalizeParentUuid(node.project.uuid);
      if (uuid == null) continue;
      final label = prefix.isEmpty
          ? node.project.title
          : '$prefix / ${node.project.title}';
      labels[uuid] = label;
      if (node.children.isNotEmpty) walk(node.children, label);
    }
  }

  walk(tree, '');
  return labels;
}
