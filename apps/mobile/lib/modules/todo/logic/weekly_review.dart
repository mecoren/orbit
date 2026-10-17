import '../../../data/api/dto.dart';

/// 引导式周回顾的清单层（G5；纯函数镜像桌面 `shared/weekly-review.ts`）
///
/// GTD 方法论把周回顾列为成败关键，但品类普遍只有「完成统计」没有「回顾
/// 向导」——用户要自己逐个清单翻。本模块把周回顾的三类待处置对象按口径
/// 归集：逾期（要不要顺延）、无日期（要不要排期）、停滞（要不要唤醒），
/// 供向导逐步引导处理。纯函数无副作用，与桌面逐字同口径。
///
/// 口径：
/// - 三组只收「未完成」任务（已完成不进回顾）；
/// - 三组可重叠（同一任务既是逾期又停滞 = 最需要唤醒的），组内按任务
///   原序去重（同一 id 不重复出现）；
/// - 逾期以「今天零点」为界（今天到期不算逾期，与列表置顶口径同源）；
/// - 停滞 = updated_at 距今超 [kReviewStallDays] 天。

/// 停滞阈值：超过该天数未更新即列入唤醒候选
const int kReviewStallDays = 7;

/// 周回顾三组清单
class WeeklyReviewBuckets {
  /// 逾期未完成（需处置：顺延/改期/放弃）
  final List<TodoTask> overdue;

  /// 无截止日的未完成（需处置：排期/清出清单）
  final List<TodoTask> undated;

  /// 停滞未完成（需唤醒：最近动过或关闭）
  final List<TodoTask> stalled;

  const WeeklyReviewBuckets({
    required this.overdue,
    required this.undated,
    required this.stalled,
  });
}

/// 本地今日零点（毫秒）；与 capacity/task-filters 同口径
int _localDayStartMs(int nowMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(nowMs);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// 归集周回顾三组清单（详见模块头口径）
WeeklyReviewBuckets collectWeeklyReview(List<TodoTask> tasks, int nowMs) {
  final dayStart = _localDayStartMs(nowMs);
  final stallCutoff = nowMs - kReviewStallDays * 86400000;

  final overdue = <TodoTask>[];
  final undated = <TodoTask>[];
  final stalled = <TodoTask>[];

  for (final t in tasks) {
    if (t.isDone) continue;
    if (t.dueDate != null && t.dueDate! < dayStart) overdue.add(t);
    if (t.dueDate == null) undated.add(t);
    if (t.updatedAt < stallCutoff) stalled.add(t);
  }
  return WeeklyReviewBuckets(
    overdue: overdue,
    undated: undated,
    stalled: stalled,
  );
}
