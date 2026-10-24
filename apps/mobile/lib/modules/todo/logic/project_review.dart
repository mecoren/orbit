// 项目回顾节奏（F1）展示层纯函数——与桌面 shared/project-review.ts 逐字同口径。
//
// 到期/逾期的判定真值在 Rust core（project_review_api，本地时区日界），
// Dart 侧只做档位标签映射与相对时间文案；天数为唯一真值，label 仅是展示层映射。

import 'package:flutter/foundation.dart';

/// 回顾周期档位（与 core set_project_review_interval 语义一致：≤0/未设置 = 关闭）
@immutable
class ReviewIntervalPreset {
  final int days;
  final String label;
  const ReviewIntervalPreset(this.days, this.label);
}

const List<ReviewIntervalPreset> reviewIntervalPresets = [
  ReviewIntervalPreset(1, '每天'),
  ReviewIntervalPreset(7, '每周'),
  ReviewIntervalPreset(14, '每两周'),
  ReviewIntervalPreset(30, '每月'),
];

/// 周期天数 → 档位标签；非档位天数回退「每 N 天」
String formatReviewInterval(int? days) {
  if (days == null || days <= 0) return '关闭';
  for (final p in reviewIntervalPresets) {
    if (p.days == days) return p.label;
  }
  return '每 $days 天';
}

/// 逾期天数 → 行内文案（0 = 今天到期；core overdue_days 同口径）
String formatOverdueDays(int overdueDays) {
  if (overdueDays <= 0) return '今天到期';
  if (overdueDays == 1) return '已逾期 1 天';
  return '已逾期 $overdueDays 天';
}

/// 本地日差（两侧毫秒时间戳 → 日历天数差；用本地年月日拼 UTC 零点，
/// 不受 DST 偏移影响）
int _localDayDiff(int aMs, int bMs) {
  final a = DateTime.fromMillisecondsSinceEpoch(aMs);
  final b = DateTime.fromMillisecondsSinceEpoch(bMs);
  final aDay = DateTime.utc(a.year, a.month, a.day).millisecondsSinceEpoch;
  final bDay = DateTime.utc(b.year, b.month, b.day).millisecondsSinceEpoch;
  return (aDay - bDay) ~/ Duration.millisecondsPerDay;
}

/// 上次回顾时间 → 相对文案（从未 / 今天 / 昨天 / N 天前 / 日期）
String formatLastReviewed(int? ms, [int? nowMs]) {
  if (ms == null) return '从未回顾';
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final diff = _localDayDiff(now, ms);
  if (diff <= 0) return '今天回顾过';
  if (diff == 1) return '昨天回顾过';
  if (diff < 30) return '$diff 天前回顾';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}/${d.month}/${d.day} 回顾';
}
