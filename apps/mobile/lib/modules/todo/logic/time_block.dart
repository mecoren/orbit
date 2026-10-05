/// 时间轴（Timeline）时段块布局纯函数（docs/07 #74；镜像桌面
/// `apps/desktop/src/features/todo/shared/time-block.ts`）。
///
/// 口径（双端共享约定，改这里必须同步桌面端与 docs）：
/// 1. 块起点：[startDate] 带时刻 → 直接用（用户显式排程最强）；否则
///    [dueDate] 带时刻 → 按截止倒推 `due − 时长`（「该时刻要完成」的块
///    向截止收拢）；两处都无时刻 → 不出块（这类任务属于月/议程的日格，
///    不属时段）。带时刻判定用**本地字段**（时分秒毫秒任一非零）——
///    本地零点在 UTC+8 下对应前日 16:00 epoch，按 epoch 取模会误判。
/// 2. 块长 = [durationMinutes]（>0）；未设时长给默认 30 分钟最小可视块
///    （有明确时刻的任务也应在时间轴可见可点）。
/// 3. 块渲染在**起点所在日**；起止 clamp 到该日 [00:00, 24:00]（视觉截断，
///    完整时段走点击后的详情）。跨零点倒推的块贴当日 0 点起渲染。
/// 4. 同日重叠**贪心分车道**（复用最早空闲车道），供移动端窄列并排。
library;

import '../../../data/api/dto.dart';

/// 未设时长任务的默认块长（分钟）
const int defaultBlockMinutes = 30;

/// 时间戳是否带本地非零时刻（纯日期落零点 → false）。
bool hasTimePart(int? ms) {
  if (ms == null) return false;
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return d.hour != 0 ||
      d.minute != 0 ||
      d.second != 0 ||
      d.millisecond != 0;
}

/// 一个时间块（起点真值 + 时长）
class TimeBlock {
  const TimeBlock({
    required this.taskId,
    required this.title,
    required this.startMs,
    required this.durationMin,
    required this.done,
  });

  final int taskId;
  final String title;

  /// 块起点（真实时刻，可能早于所在日 0 点）
  final int startMs;

  /// 块长（分钟，>0）
  final int durationMin;
  final bool done;
}

/// 任务 → 时间块；不满足时段口径（无任何带时刻的 start/due）返回 null。
/// 完成任务照常出块（渲染层弱化），口径与日历日格一致。
TimeBlock? taskTimeBlock(TodoTask task) {
  final durationMin = (task.durationMinutes != null && task.durationMinutes! > 0)
      ? task.durationMinutes!
      : defaultBlockMinutes;
  int? startMs;
  if (hasTimePart(task.startDate)) {
    startMs = task.startDate;
  } else if (hasTimePart(task.dueDate)) {
    startMs = task.dueDate! - durationMin * 60000;
  }
  if (startMs == null) return null;
  return TimeBlock(
    taskId: task.id,
    title: task.title,
    startMs: startMs,
    durationMin: durationMin,
    done: task.isDone,
  );
}

/// 块在某日的渲染比例（起止 clamp 到该日 [00:00, 24:00]）
class BlockLayout {
  const BlockLayout(this.topRatio, this.heightRatio);

  /// 块顶相对当日高度的 0–1 比例
  final double topRatio;

  /// 块高比例（clamp 到当日 [0,1]）
  final double heightRatio;
}

/// 块在日内的渲染比例。dayStartMs 取该日本地零点。
BlockLayout layoutTimeBlock(TimeBlock block, int dayStartMs) {
  final relStart = block.startMs - dayStartMs;
  final relEnd = relStart + block.durationMin * 60000;
  final top = relStart < 0 ? 0 : (relStart > 86400000 ? 86400000 : relStart);
  var bottom = relEnd < top ? top : relEnd;
  if (bottom > 86400000) bottom = 86400000;
  return BlockLayout(top / 86400000, (bottom - top) / 86400000);
}

/// 同日重叠分车道：按块顶排序，贪心复用「车道尾早于新块顶」的最早车道。
/// 返回与入参同序的车道号；车道总数 = max(车道号)+1（空输入 0）。
List<int> assignLanes(List<BlockLayout> blocks) {
  final laneEnds = <double>[];
  final order = [
    for (var i = 0; i < blocks.length; i++) (i: i, top: blocks[i].topRatio),
  ]..sort((a, b) => a.top.compareTo(b.top));
  final lanes = List<int>.filled(blocks.length, 0);
  for (final e in order) {
    var lane = laneEnds.indexWhere((end) => end <= e.top);
    if (lane == -1) {
      lane = laneEnds.length;
      laneEnds.add(e.top);
    }
    laneEnds[lane] = e.top + blocks[e.i].heightRatio;
    lanes[e.i] = lane;
  }
  return lanes;
}

/// 某日的时间轴分桶（块 → 比例 + 车道）。
///
/// [dayStartMs] = 该日本地零点；返回按传入顺序的渲染条目（重叠块已分车道）。
/// 起点不在该日的块直接丢弃（跨日块只渲染在起点日，桌面同口径）。
List<({TimeBlock block, BlockLayout layout, int lane, int laneCount})>
    blocksForDay(List<TimeBlock> blocks, int dayStartMs) {
  final dayEndMs = dayStartMs + 86400000;
  final inDay = <TimeBlock>[
    for (final b in blocks)
      if (b.startMs >= dayStartMs && b.startMs < dayEndMs) b,
  ];
  final layouts = [
    for (final b in inDay) layoutTimeBlock(b, dayStartMs),
  ];
  final lanes = assignLanes(layouts);
  final laneCount = lanes.isEmpty ? 1 : lanes.reduce((a, b) => a > b ? a : b) + 1;
  return [
    for (var i = 0; i < inDay.length; i++)
      (
        block: inDay[i],
        layout: layouts[i],
        lane: lanes[i],
        laneCount: laneCount,
      ),
  ];
}

/// 毫秒时间戳 → 本地日零点（分桶锚点；跨 DST 日恒对齐）
int localDayStartMs(DateTime d) =>
    DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;

// ============================================================================
// 时段拖拽（docs/07 #75；镜像桌面 shared/timeslot-drag.ts 的移动端子集）
// ============================================================================

/// 拖拽吸附粒度（分钟）——15 分钟是日程软件的事实标准
const int snapMinutes = 15;

/// 纵向像素位移（正 = 向下 = 更晚）→ 吸附后的分钟增量。
///
/// [hourPx] 为每小时行高（网格几何）；非有限值与非法行高归 0——防 NaN
/// 传播到写库（与桌面同款守卫）。取整用 `round` 就近吸附（14 分钟 → 15，
/// 16 分钟 → 15）。
int snapMinutesDelta(double deltaPx, double hourPx) {
  if (hourPx <= 0 ||
      hourPx.isNaN ||
      hourPx.isInfinite ||
      deltaPx.isNaN ||
      deltaPx.isInfinite) {
    return 0;
  }
  final raw = deltaPx * 60 / hourPx;
  return (raw / snapMinutes).round() * snapMinutes;
}

/// 移动落点：块 + 纵向位移 → 新起点（已吸附、已夹到日内）。
///
/// **夹取语义**：起点不早于该日 00:00，且 `起点 + 时长 ≤ 该日 24:00`
/// ——保证块完整落在可视日内。跨日不在本函数的能力内：移动端日维度是
/// **竖向堆叠**，跨天要拖过整日高（1152dp）导致手指出屏，物理不可达
/// （桌面 7 列并排才做得动横向跨列，见 `timeslot-drag.ts` 的 `snapDayDelta`）。
({int startMs, int durationMin}) resolveTimeslotMove(
  TimeBlock block,
  int dayStartMs, {
  required double deltaPx,
  required double hourPx,
}) {
  final minutes = snapMinutesDelta(deltaPx, hourPx);
  final moved = DateTime.fromMillisecondsSinceEpoch(block.startMs)
      .add(Duration(minutes: minutes));
  var startMs = moved.millisecondsSinceEpoch;
  final dayEndMs = dayStartMs + 86400000;
  if (startMs < dayStartMs) startMs = dayStartMs;
  final latest = dayEndMs - block.durationMin * 60000;
  if (startMs > latest) startMs = latest;
  return (startMs: startMs, durationMin: block.durationMin);
}

/// 落库载荷（键与 `todoTaskUpdate` 的 patch 一一对应）
typedef TimeslotPatch = Map<String, Object?>;

/// 拖拽结果 → 写库字段。**三种块来源各走各的口径**（与桌面
/// `timeslotDropPatch` 逐字一致）：
/// - **显式排程**（`start_date` 带时刻）：写 `start_date`；
/// - **截止倒推**（`due_date` 带时刻）：只写 `due_date`（= 起点 + 时长），
///   **绝不种 `start_date`**——种 start 会让任务从「截止向截止收拢」漂移成
///   「显式排程」，语义变了且与详情页显示打架；
/// - **纯日期任务**（无任何带时刻字段）：不渲染块、拖不到这里；防御起见
///   只落时长，绝不臆造时刻字段。
///
/// 无变化（起点未动）返回 null，调用方直接跳过写库。
TimeslotPatch? timeslotDropPatch(TodoTask task, int nextStartMs) {
  final explicitStart = hasTimePart(task.startDate);
  final derivedFromDue = !explicitStart && hasTimePart(task.dueDate);
  final durationMin = (task.durationMinutes != null &&
          task.durationMinutes! > 0)
      ? task.durationMinutes!
      : defaultBlockMinutes;
  final blockStart = explicitStart
      ? task.startDate
      : derivedFromDue
          ? task.dueDate! - durationMin * 60000
          : null;
  // 块起点未动 → 无变化（时长在本函数外单独落，见时长档位抽屉）
  if (blockStart == null || blockStart == nextStartMs) return null;
  if (explicitStart) return {'start_date': nextStartMs};
  return {'due_date': nextStartMs + durationMin * 60000};
}
