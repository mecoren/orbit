/// 任务重复规则常量与标签
///
/// 镜像桌面端 apps/desktop/src/features/todo/shared/repeat.ts：
/// - mode：0=不重复 1=按天 2=按周 3=按月 4=按年；after=间隔数（≥1）
/// - 预设：不重复/每天/每周/每月/每年；自定义 N 走 单位×间隔
///
/// 「完成后推进下一实例」引擎已下沉 orbit-core（complete_todo_task 单事务），
/// 移动端经 todoTaskComplete 调用同一 Rust 入口，与桌面同口径。
library;

/// repeat_mode 取值（与 Rust 模型数字语义一一对应）
class RepeatMode {
  RepeatMode._();

  static const int none = 0;
  static const int daily = 1;
  static const int weekly = 2;
  static const int monthly = 3;
  static const int yearly = 4;
}

/// 结束条件类型（对齐 orbit-core `todo_api` 的 REPEAT_END_* 常量）
class RepeatEnd {
  RepeatEnd._();

  static const int never = 0;
  static const int onDate = 1;
  static const int afterCount = 2;
}

/// 重复预设项（表单 chips 数据源）
class RepeatPreset {
  final int mode;
  final int after;
  final String label;

  const RepeatPreset({required this.mode, required this.after, required this.label});
}

/// 预设列表：不重复 + 四档固定间隔
const repeatPresets = [
  RepeatPreset(mode: RepeatMode.none, after: 1, label: '不重复'),
  RepeatPreset(mode: RepeatMode.daily, after: 1, label: '每天'),
  RepeatPreset(mode: RepeatMode.weekly, after: 1, label: '每周'),
  RepeatPreset(mode: RepeatMode.monthly, after: 1, label: '每月'),
  RepeatPreset(mode: RepeatMode.yearly, after: 1, label: '每年'),
];

/// 自定义间隔的单位（表单「自定义」档位用）
enum RepeatUnit {
  day('天'),
  week('周'),
  month('月'),
  year('年');

  const RepeatUnit(this.label);

  final String label;
}

/// 单位 → repeat_mode 映射（自定义 N 间隔时换算）
int modeForUnit(RepeatUnit unit) => switch (unit) {
      RepeatUnit.day => RepeatMode.daily,
      RepeatUnit.week => RepeatMode.weekly,
      RepeatUnit.month => RepeatMode.monthly,
      RepeatUnit.year => RepeatMode.yearly,
    };

/// 星期几短名（bit0=周一 … bit6=周日；与 Rust weekday_bit 对齐）
const weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

/// mode → 自定义间隔单位（重复编辑抽屉回填用；不重复归到「天」占位）
RepeatUnit unitForMode(int mode) => switch (mode) {
      RepeatMode.weekly => RepeatUnit.week,
      RepeatMode.monthly => RepeatUnit.month,
      RepeatMode.yearly => RepeatUnit.year,
      _ => RepeatUnit.day,
    };

/// 月重复模式（与 Rust REPEAT_MONTH_* 对齐；仅 MONTHLY 生效）
class RepeatMonthMode {
  RepeatMonthMode._();

  static const int day = 0;
  static const int nth = 1;
}

/// repeat_nth_week 取值：1-5 = 第 N 个，6 = 最后一个，0 = 未指定
const int repeatNthLast = 6;

/// 序数中文（1-5 + 末；非法序数返回 null）
String? nthWeekLabel(int nth) => switch (nth) {
      1 => '第 1 个',
      2 => '第 2 个',
      3 => '第 3 个',
      4 => '第 4 个',
      5 => '第 5 个',
      repeatNthLast => '最后一个',
      _ => null,
    };

/// 掩码最低位对应的星期（周一=0 … 周日=6；0 掩码返回 null）
int? firstWeekdayInMask(int mask) {
  for (var b = 0; b < 7; b++) {
    if ((mask & (1 << b)) != 0) return b;
  }
  return null;
}

/// #34 重复规则中文标签（扩展字段可选：星期几/结束/when done；
/// #72 加月高级语义 monthMode/nthWeek）
String repeatLabelExt(
  int mode,
  int after, {
  int weekdays = 0,
  int endType = 0,
  int endParam = 0,
  int fromDone = 0,
  int monthMode = 0,
  int nthWeek = 0,
}) {
  var base = repeatLabel(mode, after);
  if (mode == RepeatMode.weekly && weekdays != 0) {
    final parts = [
      for (var i = 0; i < 7; i++)
        if ((weekdays & (1 << i)) != 0) weekdayNames[i],
    ].join();
    base = after == 1 ? '每周$parts' : '每 $after 周$parts';
  } else if (mode == RepeatMode.monthly && monthMode == RepeatMonthMode.nth) {
    // 月高级语义：每月第 N 个星期 X（掩码取最低位，UI 层限制单选）
    final nth = nthWeekLabel(nthWeek);
    final wd = firstWeekdayInMask(weekdays);
    if (nth != null && wd != null) {
      base = after == 1
          ? '每月$nth周${weekdayNames[wd]}'
          : '每 $after 个月$nth周${weekdayNames[wd]}';
    }
  }
  final suffix = <String>[
    if (fromDone == 1) '按完成日',
    if (endType == RepeatEnd.afterCount && endParam > 0) '剩 $endParam 次',
    if (endType == RepeatEnd.onDate && endParam > 0) '至 ${formatYmdSlash(endParam)}',
  ];
  return suffix.isEmpty ? base : '$base（${suffix.join('，')}）';
}

/// 毫秒时间戳 → 「yyyy/M/d」（结束=日期档标签；对齐桌面端 toLocaleDateString 口径）
String formatYmdSlash(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}/${d.month}/${d.day}';
}

/// 规则中文标签（与桌面端 repeatLabel 同口径，徽标/表单回显共用）
String repeatLabel(int mode, int after) {
  final n = after <= 0 ? 1 : after;
  switch (mode) {
    case RepeatMode.daily:
      return n == 1 ? '每天' : '每 $n 天';
    case RepeatMode.weekly:
      return n == 1 ? '每周' : '每 $n 周';
    case RepeatMode.monthly:
      return n == 1 ? '每月' : '每 $n 个月';
    case RepeatMode.yearly:
      return n == 1 ? '每年' : '每 $n 年';
    default:
      return '不重复';
  }
}

/// 「下次 M月d日（周X）」预览标签（Things 口径；对齐桌面端 nextRepeatLabel）
///
/// 锚点语义与完成引擎一致：[fromDone]=0 按原 due 锚点推进（节奏恒定，提前完成
/// 不改变节奏）；[fromDone]=1 从完成时刻起算（下次 = 完成后一个完整周期）。
/// 无规则 / 无锚点日期 / 快进超限返回 null（调用方不渲染徽标）。
String? nextRepeatLabel(
  int mode,
  int after,
  int? anchorMs,
  int fromMs, {
  int fromDone = 0,
  int weekdays = 0,
  int monthMode = 0,
  int nthWeek = 0,
}) {
  if (mode == RepeatMode.none || anchorMs == null) return null;
  // 月高级语义：nth 步进预览（与 Rust next_monthly_nth_from 同口径；
  // 非法配置回落日号语义，见下）
  if (mode == RepeatMode.monthly && monthMode == RepeatMonthMode.nth) {
    final wd = firstWeekdayInMask(weekdays);
    final nth = nthWeekLabel(nthWeek);
    if (wd != null && nth != null) {
      final next = fromDone == 0
          ? nextMonthlyNth(anchorMs, after, wd, nthWeek, anchorMs > fromMs ? anchorMs : fromMs)
          : nextMonthlyNth(fromMs, after, wd, nthWeek, fromMs);
      return next == null ? null : formatCnDate(next);
    }
  }
  final anchor = anchorMs > fromMs ? anchorMs : fromMs;
  final next = fromDone == 0
      ? nextRepeatAt(anchorMs, mode, after, anchor)
      : nextRepeatAt(anchor, mode, after, fromMs);
  return next == null ? null : formatCnDate(next);
}

/// 某年月第 N 个星期 X 是几号（Rust nth_weekday_in_month 的 Dart 镜像；
/// [weekdayMon0] 周一=0 … 周日=6；[nth]=6 取最后一个；无 occurrence 返回 null）
int? nthWeekdayInMonth(int year, int month, int nth, int weekdayMon0) {
  final firstWd = DateTime(year, month).weekday - 1; // 周一=0
  final first = 1 + ((weekdayMon0 + 7 - firstWd) % 7);
  final lastDay = DateTime(year, month + 1, 0).day;
  if (nth == repeatNthLast) {
    final lastWd = DateTime(year, month, lastDay).weekday - 1;
    return lastDay - ((lastWd + 7 - weekdayMon0) % 7);
  }
  if (nth < 1 || nth > 5) return null;
  final day = first + 7 * (nth - 1);
  return day <= lastDay ? day : null;
}

/// 每月第 N 个星期 X 步进（Rust next_monthly_nth_from 的 Dart 镜像，
/// 供 [nextRepeatLabel] 预览用；调度真值在 orbit-core）。
///
/// 口径：锚定 [anchorMs] 所在月，按 [after] 步长逐月取首个 > [fromMs] 的
/// occurrence（k 从 1 起：anchor 当月属当前周期）；无 occurrence 的月份跳过；
/// 时刻沿用 anchor 本地时刻。
int? nextMonthlyNth(
  int anchorMs,
  int after,
  int weekdayMon0,
  int nth,
  int fromMs,
) {
  final anchor = DateTime.fromMillisecondsSinceEpoch(anchorMs);
  final step = after <= 0 ? 1 : after;
  for (var k = 1; k <= 5000; k++) {
    final total = anchor.year * 12 + (anchor.month - 1) + k * step;
    final ty = total ~/ 12;
    final tm = total % 12 + 1;
    final day = nthWeekdayInMonth(ty, tm, nth, weekdayMon0);
    if (day == null) continue;
    final cand = DateTime(ty, tm, day, anchor.hour, anchor.minute,
        anchor.second, anchor.millisecond);
    if (cand.millisecondsSinceEpoch > fromMs) return cand.millisecondsSinceEpoch;
  }
  return null;
}

/// 毫秒时间戳 → 「M月d日（周X）」
String formatCnDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const names = ['一', '二', '三', '四', '五', '六', '日'];
  return '${d.month}月${d.day}日（周${names[d.weekday - 1]}）';
}

/// base 的下一次发生时间（> fromMs）；无规则或快进超限返回 null。
///
/// 天/周走日历日推进（保持钟面时刻）；月/年走日历语义（日号超过目标月天数时
/// 截断到月末，如 1/31 → 2/28，避免溢出滚入下下月）。上限 5000 步（按天约 13 年）
/// 防异常数据死循环——与桌面端 nextRepeatAt 同实现。
int? nextRepeatAt(int baseMs, int mode, int after, int fromMs) {
  if (mode == RepeatMode.none) return null;
  final step = after <= 0 ? 1 : after;
  var next = DateTime.fromMillisecondsSinceEpoch(baseMs);
  for (var i = 0; i < 5000; i++) {
    switch (mode) {
      case RepeatMode.daily:
        next = _addDays(next, step);
      case RepeatMode.weekly:
        next = _addDays(next, 7 * step);
      case RepeatMode.monthly:
        next = _addCalendarMonths(next, step);
      case RepeatMode.yearly:
        next = _addCalendarMonths(next, 12 * step);
      default:
        return null;
    }
    if (next.millisecondsSinceEpoch > fromMs) {
      return next.millisecondsSinceEpoch;
    }
  }
  return null;
}

/// 日历日推进（跨月/年由 DateTime 归一化，钟面时刻保持不变）
DateTime _addDays(DateTime d, int days) => DateTime(
      d.year,
      d.month,
      d.day + days,
      d.hour,
      d.minute,
      d.second,
      d.millisecond,
    );

/// 日历月推进：日号超过目标月天数时截断到月末（1/31 + 1 月 → 2/28）
DateTime _addCalendarMonths(DateTime d, int months) {
  final first = DateTime(d.year, d.month + months, 1);
  final daysInTarget = DateTime(first.year, first.month + 1, 0).day;
  return DateTime(
    first.year,
    first.month,
    d.day <= daysInTarget ? d.day : daysInTarget,
    d.hour,
    d.minute,
    d.second,
    d.millisecond,
  );
}
