/// 会话级撤销栈（纯数据结构，无 UI / 无 IO，可直接单测）
///
/// 与桌面 `use-undo-stack.tsx`（Ctrl+Z 全局栈）的语义等价物：栈内只存
/// **反向补丁**，不进 DB、不进同步——撤销窗口是短时的用户行为补偿，
/// 不是一个需要跨会话存活的数据面。
///
/// 移动端形态差异：桌面有 Ctrl+Z 可反复回退，移动端以「浮层提示 + 撤销钮」
/// 暴露**最近一条**（`last`）。深栈保留是为了让未来接入手势撤销时不必
/// 改数据结构，但当前消费面只有单条。
library;

/// 单条反向补丁的载体（数据驱动：执行由调用方经桥完成）
class UndoEntry {
  /// 浮层提示文案（如「已删除 3 个任务」）
  final String label;

  /// 字段级反向补丁（逐条 `todoTaskUpdate(id, patchJson)`）
  final List<UndoTaskPatch> patches;

  /// 需从回收站恢复的任务 id（批量删除的反向操作）
  final List<int> restoreTaskIds;

  /// 需卸载的标签关联主键（批量加标签的反向操作）
  final List<int> detachLinkIds;

  final int createdAt;

  const UndoEntry({
    required this.label,
    this.patches = const [],
    this.restoreTaskIds = const [],
    this.detachLinkIds = const [],
    required this.createdAt,
  });

  /// 是否含任何可执行的反向动作（空条目不进栈）
  bool get isEmpty =>
      patches.isEmpty && restoreTaskIds.isEmpty && detachLinkIds.isEmpty;
}

/// 单任务字段反向补丁（patch 与 `todoTaskUpdate` 的 JSON patch 同形）
class UndoTaskPatch {
  final int taskId;
  final Map<String, Object?> patch;

  const UndoTaskPatch({required this.taskId, required this.patch});
}

/// 有界撤销栈
///
/// // bounded: 20 条 + FIFO 淘汰（撤销窗口只有 5 秒，深栈无消费者；
/// 上界防长时间会话内反复批量操作把历史无限堆在内存里）
class UndoStack {
  /// 栈深度上界（FIFO 淘汰最旧条目）
  static const int maxDepth = 20;

  final List<UndoEntry> _entries = [];

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  /// 最近一条（浮层「撤销」钮作用于它）
  UndoEntry? get last => _entries.isEmpty ? null : _entries.last;

  /// 入栈；空条目直接忽略（无反向动作的操作不该占用撤销位）
  void push(UndoEntry entry) {
    if (entry.isEmpty) return;
    _entries.add(entry);
    while (_entries.length > maxDepth) {
      _entries.removeAt(0);
    }
  }

  /// 取出并移除最近一条
  UndoEntry? pop() => _entries.isEmpty ? null : _entries.removeLast();

  void clear() => _entries.clear();
}
