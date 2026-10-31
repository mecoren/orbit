// 种子日期夹具：让「当月有任务」类用例与真实日期解耦
//
// 背景：`MockStore.seed()` 把「完成移动端重构方案评审」的截止日定为次日零点
// （dueIn(1)）。月末最后一天时次日跨到下月，而议程档只渲染当前月——任务整行
// 消失，用例在 2026-10-31 这类日子会无故变红（与业务改动无关）。
import 'package:orbit/data/api/mock_orbit_bridge.dart';

/// 把种子任务钉到「当前月内且不是今天」的一天，返回落库的毫秒时间戳。
///
/// 优先明天；明天跨月（月末）则退到昨天——月初的明天必在同月，故退位不会
/// 落到上月。锚点既不是今天（选中日空态断言仍成立），也在当前月（议程档与
/// 月历圆点可见）。
int pinSeedTaskIntoCurrentMonth(
  MockOrbitBridge bridge, {
  String title = '完成移动端重构方案评审',
}) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  var target = today.add(const Duration(days: 1));
  if (target.month != now.month) {
    target = today.subtract(const Duration(days: 1));
  }
  final row = bridge.store.tasks.values.firstWhere(
    (t) => t['title'] == title,
    orElse: () => throw StateError('种子任务「$title」不在库内'),
  );
  final ts = target.millisecondsSinceEpoch;
  row['due_date'] = ts;
  return ts;
}
