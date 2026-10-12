/// 子任务层级树构建（M10 多层嵌套）——纯函数，移动端详情页「子任务」区块消费。
///
/// 数据口径：`TodoSubtask.parentUuid` 指向父级子任务的**同步主键 uuid**
/// （null = 顶层）。与移动端 `project_tree.dart`、桌面 `shared/project-tree.ts`、
/// 桌面 `shared/subtask-tree.ts` 同源同构（项目树先例 0003）：父行未落库/
/// 已软删时子行必须仍能存续（父悬空 = 回落顶层）。
///
/// 四条容错（读取侧口径，与 Rust `validate_subtask_parent` 一致）：
/// 1. parentUuid 空/空白 → 顶层
/// 2. parentUuid 指向不存在的子任务（父已软删 / 父尚未同步到位）→ 回落顶层，行不丢
/// 3. parentUuid 指向自身 → 回落顶层
/// 4. 环（A→B→A）：**真正处于环上**的节点整体回落顶层，保证递归终止；
///    父链接入环但自身不在环上的节点（如 C→A，而 A↔B）仍挂在父下，子树不丢
///
/// 同层顺序：沿用输入顺序（详情接口已按 position 排好），本模块不再排序。
library;

// 归一化口径复用 dto 层 `normalizeParentUuid`（单一真相源，两份实现必然漂移）
import '../../../data/api/dto.dart';

/// 树节点：子任务 + 层级深度 + 子节点
class SubtaskTreeNode {
  SubtaskTreeNode(this.subtask);

  final TodoSubtask subtask;

  /// 层级深度：顶层 = 0
  int depth = 0;
  final List<SubtaskTreeNode> children = <SubtaskTreeNode>[];
}

/// uuid → 首个出现下标（空 uuid 不入索引，重复 uuid 以首行为准）
Map<String, int> _indexByUuid(List<TodoSubtask> subtasks) {
  final index = <String, int>{};
  for (var i = 0; i < subtasks.length; i++) {
    final uuid = normalizeParentUuid(subtasks[i].uuid);
    if (uuid != null) index.putIfAbsent(uuid, () => i);
  }
  return index;
}

/// 单跳上溯：idx 的直接父索引（自引用返回自身下标，由调用方判定）
int? _parentIndexOf(
  List<TodoSubtask> subtasks,
  Map<String, int> indexByUuid,
  int idx,
) {
  final upUuid = normalizeParentUuid(subtasks[idx].parentUuid);
  if (upUuid == null) return null;
  return indexByUuid[upUuid];
}

/// 标定「处于环上」的节点索引集合（含自引用）。
///
/// 三色迭代 DFS：沿父链走，命中当前路径上的节点即构成环，把环段整体入集。
/// 注意「父链接入环但不属于环」的节点（如 C→A，而 A↔B）**不入集**——
/// 它自身层级合法，只是父恰好成了顶层，仍应挂在父下。
Set<int> _findCyclicNodes(
  List<TodoSubtask> subtasks,
  Map<String, int> indexByUuid,
) {
  final n = subtasks.length;
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
      final next = _parentIndexOf(subtasks, indexByUuid, cur);
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

/// 按 parentUuid 构建子任务树。
///
/// [subtasks] 同任务的**全量活子任务**（详情返回即此形态，已按 position 排序）。
/// 返回顶层节点数组，children 递归展开，depth 已标注。
List<SubtaskTreeNode> buildSubtaskTree(List<TodoSubtask> subtasks) {
  if (subtasks.isEmpty) return const <SubtaskTreeNode>[];

  final nodes = <SubtaskTreeNode>[for (final s in subtasks) SubtaskTreeNode(s)];
  final indexByUuid = _indexByUuid(subtasks);
  final cyclic = _findCyclicNodes(subtasks, indexByUuid);

  final roots = <SubtaskTreeNode>[];
  for (var i = 0; i < subtasks.length; i++) {
    if (cyclic.contains(i)) {
      roots.add(nodes[i]);
      continue;
    }
    final parentIdx = _parentIndexOf(subtasks, indexByUuid, i);
    // 断链 / 自引用 / 空父 → 顶层
    if (parentIdx == null || parentIdx == i) {
      roots.add(nodes[i]);
    } else {
      nodes[parentIdx].children.add(nodes[i]);
    }
  }

  // 递归标注 depth：环检测已保证无环，且每个节点归属唯一
  void markDepth(List<SubtaskTreeNode> list, int depth) {
    for (final node in list) {
      node.depth = depth;
      if (node.children.isNotEmpty) markDepth(node.children, depth + 1);
    }
  }

  markDepth(roots, 0);
  return roots;
}

/// 把树展平为渲染序列（父在前，子紧随其后）。
///
/// [isCollapsed] 折叠判定；仅对「有子节点」的节点有意义（当前 UI 无折叠入口，
/// 传 `(_) => false`；预留同项目侧 flattenProjectTree 的对称能力）。
List<SubtaskTreeNode> flattenSubtaskTree(
  List<SubtaskTreeNode> nodes,
  bool Function(String uuid) isCollapsed,
) {
  final out = <SubtaskTreeNode>[];

  void walk(List<SubtaskTreeNode> list) {
    for (final node in list) {
      out.add(node);
      if (node.children.isNotEmpty && !isCollapsed(node.subtask.uuid)) {
        walk(node.children);
      }
    }
  }

  walk(nodes);
  return out;
}
