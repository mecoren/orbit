import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';
import '../../../modules/todo/logic/time_block.dart';

/// 时间轴日视图（24 小时网格 + 时段色块；docs/07 #74，对标 TickTick 移动端
/// Timeline）。
///
/// **为什么自绘**：`table_calendar` 只管日期网格、没有任何「一天内的时段轴」
/// 概念；shadcn_flutter 原语层同样没有等价件。按设计系统 v3 的兜底策略，
/// 网格与色块由 Stack/Positioned 自组，但**尺寸与色全部吃 `core/theme` token**
/// （`AppDimens` 网格密度、`AppShapes` 圆角、`OrbitAccents.todoAccent` 块色），
/// 不写裸魔法值。
///
/// 布局（与桌面 `timeline-panel.tsx` 同口径）：
/// - 左侧 36dp 整点刻度（00:00–23:00，每 2 小时标注一次避免拥挤）；
/// - 右侧 24 小时网格：水平细线用 `Divider` 逐条铺（`repeating` 在 Flutter
///   侧无等价装饰，故按行堆叠，24 行代价可忽略）；
/// - 块**绝对定位**（top/height 由 `time_block.dart` 的比例 × 网格高算出），
///   左侧 3dp 项目色竖条 + 浅底，标题单行截断；重叠块按车道横向平分；
/// - 当前时刻红线（今天才有，60s 步进）。
///
/// **只读**（本批刻意不做拖拽）：移动端手势面已占满——整页纵向滚动、
/// 横滑翻页、月历网格收展与长按拾起冲突，时段拖拽需独立手势方案
/// （见 docs/10 B-2），故本原语只消费 `blocksForDay` 的渲染结果。
class OrbitTimelineDay extends StatelessWidget {
  const OrbitTimelineDay({
    super.key,
    required this.dayStart,
    required this.entries,
    required this.projectColorOf,
    this.onOpenTask,
    this.height = _gridHeight,
  });

  /// 本日零点（本地）
  final DateTime dayStart;

  /// 已分车道的渲染条目（`blocksForDay` 产物）
  final List<({TimeBlock block, BlockLayout layout, int lane, int laneCount})>
      entries;

  /// 任务 id → 项目色（无项目/取色失败回落 [OrbitAccents.todoAccent]）
  final Color Function(int taskId) projectColorOf;

  final ValueChanged<int>? onOpenTask;

  /// 网格总高（默认 24h × 48dp）
  final double height;

  static const double hourPx = 48;
  static const double _gridHeight = 24 * hourPx;
  static const double _gutterWidth = 36;
  static const double _blockMinHeight = 20;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final now = DateTime.now();
    final isToday = now.year == dayStart.year &&
        now.month == dayStart.month &&
        now.day == dayStart.day;
    final nowRatio = isToday
        ? (now.hour * 3600000 +
                now.minute * 60000 +
                now.second * 1000 +
                now.millisecond) /
            86400000
        : -1.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _gutterWidth,
          child: Column(
            children: [
              for (var h = 0; h < 24; h++)
                SizedBox(
                  height: hourPx,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: AppDimens.space4),
                      child: Text(
                        h % 2 == 0 ? '${h.toString().padLeft(2, '0')}:00' : '',
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.secondaryText,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          // Stack 必须有界高（Column/滚动容器不给高度约束）——按 24h 定高
          child: SizedBox(
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
              // 24 条水平网格线（末条由容器底收口，故画 0–23）
                for (var h = 0; h < 24; h++)
                  Positioned(
                    top: h * hourPx,
                    left: 0,
                    right: 0,
                    child: Container(height: 1, color: colors.divider),
                  ),
                if (isToday)
                  Positioned(
                    top: nowRatio * height,
                    left: 0,
                    right: 0,
                    child: Row(
                      children: [
                        Container(
                            width: 6, height: 2, color: colors.destructive),
                        Expanded(
                          child: Container(
                              height: 1, color: colors.destructive),
                        ),
                      ],
                    ),
                  ),
              for (final e in entries)
                  _TimelineBlock(
                    entry: e,
                    height: height,
                    color: projectColorOf(e.block.taskId),
                    onTap: onOpenTask == null
                        ? null
                        : () => onOpenTask!(e.block.taskId),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 单个时段块：项目色左竖条 + 浅底 + 标题（单行截断）
class _TimelineBlock extends StatelessWidget {
  const _TimelineBlock({
    required this.entry,
    required this.height,
    required this.color,
    this.onTap,
  });

  final ({TimeBlock block, BlockLayout layout, int lane, int laneCount}) entry;
  final double height;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final lane = entry.lane;
    final laneCount = entry.laneCount;
    // 车道横向平分：块宽占 1/laneCount，中心落在车道中线
    // （FractionallySizedBox 的 alignment 取值域 -1..1，车道中线换算成
    // `(i + 0.5) / n * 2 - 1`）
    final laneCenter = ((lane + 0.5) / laneCount) * 2 - 1;
    return Positioned(
      top: entry.layout.topRatio * height,
      height: (entry.layout.heightRatio * height)
          .clamp(OrbitTimelineDay._blockMinHeight, height),
      left: 0,
      right: 0,
      child: FractionallySizedBox(
        widthFactor: 1 / laneCount,
        alignment: Alignment(laneCenter, 0),
        child: Padding(
          // 左右各留 1dp 让相邻车道的描边可分辨；底部 1dp 免相邻块贴合
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: AppShapes.xs,
              child: Ink(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: AppShapes.xs,
                  border: Border(left: BorderSide(color: color, width: 3)),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: AppDimens.space4,
                    right: AppDimens.space4,
                    top: 2,
                    bottom: 2,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.block.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.2,
                            color: colors.bodyText,
                            decoration: entry.block.done
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space2),
                      Text(
                        _hm(entry.block.startMs),
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.secondaryText,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _hm(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}

/// 时间轴空态（与月档空态同形：图标 + 主副文案）
class OrbitTimelineEmpty extends StatelessWidget {
  const OrbitTimelineEmpty({super.key, required this.dayLabel});

  final String dayLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space24),
      child: Column(
        children: [
          Icon(
            OrbitIcons.clock,
            size: 22,
            color: colors.secondaryText.withValues(alpha: 0.6),
          ),
          const SizedBox(height: AppDimens.space8),
          Text(
            '$dayLabel没有可排时段的任务',
            style: TextStyle(fontSize: 13, color: colors.titleText),
          ),
          const SizedBox(height: AppDimens.space4),
          Text(
            '给任务设预计时长，并填写带时刻的开始或截止时间后在此显示',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: colors.secondaryText),
          ),
        ],
      ),
    );
  }
}
