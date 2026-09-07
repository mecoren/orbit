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
