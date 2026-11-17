/// constant_interval —— 持续提醒间隔的档位与文案（与桌面 constant-interval.ts 同口径）
///
/// 持续提醒（G2，`is_constant = 1`）到期未完成时按「行级间隔」原地顺延，
/// 间隔落库列 `todo_reminders.constant_interval_ms`；core 侧按
/// [1 分钟, 24 小时] 钳制（`clamp_constant_interval_ms`）。本文件只负责
/// 选择档位、归一与展示文案——写入前调用 [normalizeConstantIntervalMs]，
/// 越界值由后端与本地同口径收敛。
library;

/// 默认间隔（5 分钟）：与 core `DEFAULT_CONSTANT_INTERVAL_MS` 一致
const int defaultConstantIntervalMs = 5 * 60 * 1000;

/// 间隔下限（1 分钟）：与 core `MIN_CONSTANT_INTERVAL_MS` 一致
const int minConstantIntervalMs = 60 * 1000;

/// 间隔上限（24 小时）：与 core `MAX_CONSTANT_INTERVAL_MS` 一致
const int maxConstantIntervalMs = 24 * 60 * 60 * 1000;

/// 预设档位（分钟）：1/5/10/15/30/60
const List<int> constantIntervalPresetsMin = [1, 5, 10, 15, 30, 60];

/// 归一间隔：非正/缺失 → 默认 5 分钟；越界钳到 [1 分钟, 24 小时]
int normalizeConstantIntervalMs(int? ms) {
  if (ms == null || ms <= 0) return defaultConstantIntervalMs;
  if (ms < minConstantIntervalMs) return minConstantIntervalMs;
  if (ms > maxConstantIntervalMs) return maxConstantIntervalMs;
  return ms;
}

/// 下拉档位：预设 ∪ 当前值（跨端写入的自定义分钟数补进档位，避免选择器无选中项）
List<int> constantIntervalOptions(int currentMs) {
  final current = normalizeConstantIntervalMs(currentMs);
  final preset = [
    for (final m in constantIntervalPresetsMin) m * 60 * 1000,
  ];
  if (preset.contains(current)) return preset;
  return [...preset, current]..sort();
}

/// 间隔文案：「每 5 分钟」/「每 1 小时」。整小时档走小时措辞，其余用分钟。
String formatConstantInterval(int ms) {
  final normalized = normalizeConstantIntervalMs(ms);
  final minutes = (normalized / 60000).round();
  if (minutes % 60 == 0) return '每 ${minutes ~/ 60} 小时';
  return '每 $minutes 分钟';
}
