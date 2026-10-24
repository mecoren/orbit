// 收件箱分诊（F2，docs/13 §五 F2 / §八 U2）纯逻辑——与桌面
// `shared/triage.ts` 逐字同口径的 Dart 镜像。
//
// - **队列** = 未分组（projectId 为空）且未完成的活动任务；排序对齐未分组
//   列表的 manual 档（position 升序 → createdAt 降序），捕获顺序处理；
// - **归属动作**（移入项目 / 排今天 / 排明天 / 删除 / 跳过）完成即出队；
//   **字段修正**（清日期 / 改优先级）不出队——它们是「决定归属过程中」的
//   就地编辑；
// - 队列在页面打开时**快照**（按 id）：写操作经 db-change 失效全量缓存会
//   引发重拉，队列若跟着缓存走会在连击时抖动。

import '../../../data/api/dto.dart';

/// 归集分诊队列（纯函数：过滤 + 排序，不触库）
List<TodoTask> collectTriageQueue(List<TodoTask> tasks) {
  final list = tasks.where((t) => t.projectId == null && !t.isDone).toList()
    ..sort((a, b) {
      final byPos = a.position.compareTo(b.position);
      if (byPos != 0) return byPos;
      final byCreated = b.createdAt.compareTo(a.createdAt);
      if (byCreated != 0) return byCreated;
      return a.id.compareTo(b.id);
    });
  return list;
}

/// 汇总文案：「已分诊 X · 跳过 Y · 删除 Z」（X = 归属+排期合计）
String formatTriageSummary(
    int moved, int scheduled, int skipped, int deleted) {
  final deletedPart = deleted > 0 ? ' · 删除 $deleted' : '';
  return '已分诊 ${moved + scheduled} · 跳过 $skipped$deletedPart';
}
