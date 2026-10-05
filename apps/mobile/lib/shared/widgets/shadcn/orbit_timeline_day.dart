import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';
import '../../../core/theme/orbit_accents.dart';
import '../../../modules/todo/logic/time_block.dart';

/// 时间轴日视图（24 小时网格 + 时段色块；docs/07 #74/#75，对标 TickTick
/// 移动端 Timeline）。
///
/// **为什么自绘**：`table_calendar` 只管日期网格、没有任何「一天内的时段轴」
/// 概念；shadcn_flutter 原语层同样没有等价件。按设计系统 v3 的兜底策略，
/// 网格与色块由 Stack/Positioned 自组，但**尺寸与色全部吃 `core/theme` token**
/// （`AppDimens` 网格密度、`AppShapes` 圆角、`AppMotion` 抬起动效、
/// `OrbitAccents.todoAccent` 块色），不写裸魔法值。
///
/// 布局（与桌面 `timeline-panel.tsx` 同口径）：
/// - 左侧 36dp 整点刻度（00:00–23:00，每 2 小时标注一次避免拥挤）；
/// - 右侧 24 小时网格：水平细线逐条铺（`repeating` 在 Flutter 侧无等价
///   装饰，按行堆叠 24 条代价可忽略）；
/// - 块**绝对定位**（top/height 由 `time_block.dart` 的比例 × 网格高算出），
///   左侧 3dp 项目色竖条 + 浅底，标题单行截断；重叠块按车道横向平分；
/// - 当前时刻红线（今天才有，60s 步进）。
///
/// **拖拽手势方案**（docs/07 #75，桌面 `timeslot-drag.ts` 的移动端子集）——
/// 四个冲突面各有一条裁决：
/// - **长按 500ms 拾起**才接管纵向位移：与列表重排同款仲裁（[AppMotion] 的
///   长按阈值），长按赢 arena 前整页纵向滚动先赢，拾起后滚动被拒——故滚动
///   手感零变化；
/// - **不做横向跨天**：移动端日维度是**竖向堆叠**，跨天要拖过整日高
///   （24 × 48dp = 1152dp）导致手指出屏，物理不可达；且跨天改的是「日期」，
///   属月历/议程档职责（桌面 7 列并排才做得动横向跨列）；
/// - **不做底边 resize**：与纵向拖同轴冲突，改时长走长按菜单（时长档位抽屉）；
/// - 横滑翻月在拾起前先赢 arena 并被后续移动拒绝，**无冲突**。
///
/// **落库不在本原语**：松手只回抛 `(taskId, 新起点)`，由调用方用
/// `timeslotDropPatch` 按块来源（显式 start / due 倒推）算字段——保持原语
/// 只消费 `time_block.dart` 的渲染与推导，不碰 DTO 写库路径。
class OrbitTimelineDay extends StatefulWidget {
  const OrbitTimelineDay({
    super.key,
    required this.dayStart,
    required this.entries,
    required this.projectColorOf,
    this.onOpenTask,
    this.onMoveTimeslot,
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

  /// 长按拖拽落位（回抛新起点；写库字段由调用方按块来源算）
  final void Function(int taskId, int nextStartMs)? onMoveTimeslot;

  /// 网格总高（默认 24h × 48dp）
  final double height;

  static const double hourPx = 48;
  static const double _gridHeight = 24 * hourPx;
  static const double _gutterWidth = 36;
  static const double _blockMinHeight = 20;

  @override
  State<OrbitTimelineDay> createState() => _OrbitTimelineDayState();
}

class _OrbitTimelineDayState extends State<OrbitTimelineDay> {
  /// 拖拽中的块 id（null = 无拖拽）；抬起动效的开关随它进出
  int? _dragTaskId;
  /// 拖拽累计纵向位移（px；预览按它平移，松手交给纯函数吸附）
  double _dragDy = 0;

  bool get _draggable => widget.onMoveTimeslot != null;

  @override
  void didUpdateWidget(OrbitTimelineDay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换档/换跨度/数据刷新后旧拖拽块可能已不在表内 → 清态，避免幽灵预览
    if (_dragTaskId != null &&
        !widget.entries.any((e) => e.block.taskId == _dragTaskId)) {
      _dragTaskId = null;
      _dragDy = 0;
    }
  }

  void _onLongPressStart(int taskId) {
    if (!_draggable) return;
    setState(() {
      _dragTaskId = taskId;
      _dragDy = 0;
    });
    HapticFeedback.selectionClick();
  }

  void _onLongPressMove(int taskId, double dy) {
    if (_dragTaskId != taskId) return;
    setState(() => _dragDy = dy);
  }

  void _onLongPressEnd(int taskId) {
    final entry = _entryOf(taskId);
    final dy = _dragDy;
    setState(() {
      _dragTaskId = null;
      _dragDy = 0;
    });
    // 长按未移动 = 「按住看看」而非拖拽，按桌面口径不开详情（长按无位移
    // 在移动端是各处的菜单入口；这里不接菜单，安静无副作用）
    if (entry == null || dy == 0) return;
    final moved = resolveTimeslotMove(
      entry.block,
      localDayStartMs(widget.dayStart),
      deltaPx: dy,
      hourPx: OrbitTimelineDay.hourPx,
    );
    // 吸附回原格（无变化）不落库也不给触感，避免「像改了却没改」的错觉
    if (moved.startMs == entry.block.startMs) return;
    HapticFeedback.selectionClick();
    widget.onMoveTimeslot?.call(taskId, moved.startMs);
  }

  ({TimeBlock block, BlockLayout layout, int lane, int laneCount})? _entryOf(
    int taskId,
  ) {
    for (final e in widget.entries) {
      if (e.block.taskId == taskId) return e;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final now = DateTime.now();
    final isToday = now.year == widget.dayStart.year &&
        now.month == widget.dayStart.month &&
        now.day == widget.dayStart.day;
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
          width: OrbitTimelineDay._gutterWidth,
          child: Column(
            children: [
              for (var h = 0; h < 24; h++)
                SizedBox(
                  height: OrbitTimelineDay.hourPx,
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
          // Stack 必须有界高（Column / 滚动容器不给高度约束）——按 24h 定高
          child: SizedBox(
            height: widget.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 24 条水平网格线（末条由容器底收口，故画 0–23）
                for (var h = 0; h < 24; h++)
                  Positioned(
                    top: h * OrbitTimelineDay.hourPx,
                    left: 0,
                    right: 0,
                    child: Container(height: 1, color: colors.divider),
                  ),
                if (isToday)
                  Positioned(
                    top: nowRatio * widget.height,
                    left: 0,
                    right: 0,
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 2,
                          color: colors.destructive,
                        ),
                        Expanded(
                          child:
                              Container(height: 1, color: colors.destructive),
                        ),
                      ],
                    ),
                  ),
                for (final e in widget.entries)
                  _TimelineBlock(
                    key: ValueKey(e.block.taskId),
                    entry: e,
                    height: widget.height,
                    color: widget.projectColorOf(e.block.taskId),
                    dragDy: _dragTaskId == e.block.taskId ? _dragDy : 0,
                    onTap: widget.onOpenTask == null
                        ? null
                        : () => widget.onOpenTask!(e.block.taskId),
                    onLongPressStart: _draggable
                        ? () => _onLongPressStart(e.block.taskId)
                        : null,
                    onLongPressMove: _draggable
                        ? (dy) => _onLongPressMove(e.block.taskId, dy)
                        : null,
                    onLongPressEnd: _draggable
                        ? () => _onLongPressEnd(e.block.taskId)
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 单个时段块：项目色左竖条 + 浅底 + 标题（单行截断）+ 起点时刻
class _TimelineBlock extends StatelessWidget {
  const _TimelineBlock({
    super.key,
    required this.entry,
    required this.height,
    required this.color,
    this.dragDy = 0,
    this.onTap,
    this.onLongPressStart,
    this.onLongPressMove,
    this.onLongPressEnd,
  });

  final ({TimeBlock block, BlockLayout layout, int lane, int laneCount}) entry;
  final double height;
  final Color color;

  /// 块（局部别名，省去 record 解构噪音）
  TimeBlock get block => entry.block;

  /// 拖拽预览位移（px，正 = 向下 = 更晚）
  final double dragDy;

  final VoidCallback? onTap;
  final VoidCallback? onLongPressStart;

  /// 拾起后纵向位移（局部坐标，自拾起点算起；正 = 向下 = 更晚）
  final ValueChanged<double>? onLongPressMove;

  /// 拾起结束（结束位移由调用方从 move 回调累计值取，
  /// `LongPressEndDetails` 不带 offset）
  final VoidCallback? onLongPressEnd;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final lane = entry.lane;
    final laneCount = entry.laneCount;
    // 车道横向平分：块宽占 1/laneCount，中心落在车道中线
    // （FractionallySizedBox 的 alignment 取值域 -1..1，车道中线换算成
    // `(i + 0.5) / n * 2 - 1`）
    final laneCenter = ((lane + 0.5) / laneCount) * 2 - 1;
    final dragging = dragDy != 0;
    // Positioned 必须是 Stack 的直接子节点（Positioned 不能被 AnimatedSlide
    // 等包装），故位移直接进 top：跟手即时，手指松开才落库，不做位移动画。
    return Positioned(
      top: entry.layout.topRatio * height + dragDy,
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
          child: Transform.scale(
            // 抬起态：放大一档 + 阴影加深（口径取列表重排的 proxyDecorator，
            // 见 AGENTS「拖拽浮层统一口径」）
            scale: dragging ? AppMotion.dragLiftScale : 1,
            child: Material(
              elevation: dragging ? 6 : 0,
              borderRadius: AppShapes.xs,
              clipBehavior: Clip.antiAlias,
              color: color.withValues(alpha: 0.16),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                onLongPressStart: onLongPressStart == null
                    ? null
                    : (_) => onLongPressStart!(),
                onLongPressMoveUpdate: onLongPressMove == null
                    ? null
                    : (d) => onLongPressMove!(d.localOffsetFromOrigin.dy),
                // LongPressEndDetails 不带 offsetFromOrigin（只有 globalPosition
                // 与 velocity），故结束位移取 State 侧累计值（move 回调已记）
                onLongPressEnd:
                    onLongPressEnd == null ? null : (_) => onLongPressEnd!(),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: AppShapes.xs,
                    border: Border(left: BorderSide(color: color, width: 3)),
                  ),
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
                          block.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.2,
                            color: colors.bodyText,
                            decoration: block.done
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space2),
                      // 拖拽中回显吸附后的新起点（按 15 分钟网格取整，
                      // 抬手即可见落点，不必等落库刷新）
                      Text(
                        _hm(dragging
                            ? block.startMs +
                                snapMinutesDelta(
                                        dragDy, OrbitTimelineDay.hourPx) *
                                    60000
                            : block.startMs),
                        style: TextStyle(
                          fontSize: 10,
                          color: dragging
                              ? OrbitAccents.themeAccent
                              : colors.secondaryText,
                          fontWeight:
                              dragging ? FontWeight.w600 : FontWeight.w400,
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
            size: AppDimens.iconSizeMd,
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
