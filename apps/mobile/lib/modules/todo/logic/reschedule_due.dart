import 'task_logic.dart' show viewDueHour;

/// 月历改期的时间语义（纯函数；镜像桌面 `shared/reschedule-due.ts`）
///
/// 把任务的截止日期从一格挪到另一格（桌面 = 拖拽圆点、移动端 = 点圆点
/// 选目标日），时间语义（视图内新增默认 18:00 与 date 档零点口径的折中）：
/// - 原截止带时刻（非 00:00）→ 保留原时分秒（含毫秒），只换日期；
/// - 原截止为零点（仅日期语义）/ 无截止 → 目标日 18:00（[viewDueHour]）；
/// - 目标日与原日期相同 → 返回 null（无变化不写库）。
///
/// 判定顺序必须先判同日：零点分支在前会把「零点同日」误升级成 18:00，
/// 产生一次无意义写库（该约束与桌面实现同款，跨端口径逐字一致）。
///
/// 时刻一律走本地时区墙钟构造（与 `batchRescheduleMs` 同口径），不做
/// 毫秒加法——跨 DST 日毫秒加法会让 18:00 漂移。
int? rescheduleDueMs(int? originalDue, DateTime targetDay) {
  final target = DateTime(targetDay.year, targetDay.month, targetDay.day);
  if (originalDue == null) return _dueAt(target, viewDueHour, 0, 0, 0);

  final orig = DateTime.fromMillisecondsSinceEpoch(originalDue);
  final sameDay = orig.year == target.year &&
      orig.month == target.month &&
      orig.day == target.day;
  if (sameDay) return null;

  final isMidnight = orig.hour == 0 &&
      orig.minute == 0 &&
      orig.second == 0 &&
      orig.millisecond == 0;
  if (isMidnight) return _dueAt(target, viewDueHour, 0, 0, 0);

  return _dueAt(
      target, orig.hour, orig.minute, orig.second, orig.millisecond);
}

int _dueAt(DateTime day, int h, int min, int s, int ms) =>
    DateTime(day.year, day.month, day.day, h, min, s, ms)
        .millisecondsSinceEpoch;
