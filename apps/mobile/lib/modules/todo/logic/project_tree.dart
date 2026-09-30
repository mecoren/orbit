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
