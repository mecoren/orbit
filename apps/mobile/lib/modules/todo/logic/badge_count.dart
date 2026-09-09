import '../../../data/api/dto.dart';

/// B6 图标角标计数口径：**今天截止或已逾期**的未完成数。
/// 比「今天截止」多含逾期项——逾期未完成仍是「今天要做的事」，
/// 与「今天截止」快捷视图（仅 [今日零点,明日零点)）口径互补。
/// now 仅测试注入用；缺省用 DateTime.now()。
int dueTodayOrOverdueCount(List<TodoTask> tasks, [DateTime? now]) {
  final clock = now ?? DateTime.now();
  final endOfToday =
      DateTime(clock.year, clock.month, clock.day).millisecondsSinceEpoch +
          24 * 3600 * 1000;
  return tasks
      .where((t) => !t.isDone && t.dueDate != null && t.dueDate! < endOfToday)
      .length;
}
