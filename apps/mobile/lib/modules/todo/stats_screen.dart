import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_elevation.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';
import '../../shared/widgets/shadcn/orbit_heatmap.dart';
import '../../core/theme/icon_map.dart';

/// 统计页 /todo/stats（backlog #25：统计仪表盘，对标 TickTick 成就页）
///
/// 数据 = bridge.statsAggregate 一次性聚合（只读）：
/// - 总览五卡 + streak 行；
/// - 热力图（2026-09-10 对齐 wait-home：按年视图 + 右侧年份按钮 +
///   月份标签/Portal 同款 tooltip/少多图例，组件见 todo_heatmap.dart）；
/// - 项目 / 优先级 / 星期三分布卡（纯 Row 条形，不引图表库）。
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  final _scrollController = ScrollController();
  late int _year = DateTime.now().year;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(statsProvider(_year)).value;

    // 年份列表到达后校正选中：初始当前年若不在可选列表（无完成记录回退口径），
    // 切到列表最新年，避免停在"只有空格"的年份
    if (stats != null &&
        stats.availableYears.isNotEmpty &&
        !stats.availableYears.contains(_year)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _year = stats.availableYears.last);
      });
    }

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: stats == null
                // 初次加载骨架：总览卡 + streak + 热力图占位（有旧值时不闪，直接旧内容）
                ? const _StatsSkeleton()
                : stats.overview.total == 0
                    ? Padding(
                        // 空态对齐 trash_screen / SubListScreen 模式：
                        // 让出状态栏 + 标题栏后在剩余视口内垂直居中
                        padding: EdgeInsets.only(
                          top: MediaQuery.of(context).padding.top +
                              OrbitPageHeader.rowHeight,
                        ),
                        child: const EmptyState(
                          message: '暂无统计数据，创建并完成一些任务后这里会展示完成情况',
                          icon: OrbitIcons.trending,
                        ),
                      )
                    : RefreshIndicator(
                        // 下拉刷新：本地重读 + 已配置时跑一轮云同步（共用回调见 pullToRefresh）。
                        // edgeOffset 下移到页头之下，否则指示条被 OrbitPageHeader 盖住。
                        onRefresh: () => pullToRefresh(ref),
                        color: OrbitAccents.themeAccent,
                        edgeOffset: MediaQuery.of(context).padding.top +
                            OrbitPageHeader.rowHeight,
                        displacement: AppDimens.space8,
                        child: ListView(
                          controller: _scrollController,
                          padding: EdgeInsets.only(
                            top: MediaQuery.of(context).padding.top +
                                OrbitPageHeader.rowHeight +
                                AppDimens.space8,
                            bottom: AppDimens.gestureInsetFallback +
                                AppDimens.space32,
                          ),
                          children: [
                            _OverviewCards(overview: stats.overview),
                            const SizedBox(height: AppDimens.space12),
                            _StreakCard(streak: stats.streak),
                            const SizedBox(height: AppDimens.space12),
                            _HeatmapCard(
                              stats: stats,
                              year: _year,
                              onYearChange: (y) => setState(() => _year = y),
                            ),
                            const SizedBox(height: AppDimens.space12),
                            _DistSection(
                              title: '项目分布',
                              rows: [
                                for (final r in stats.byProject)
                                  (
                                    r.projectTitle ?? '未分组',
                                    r.doneCount,
                                    r.pendingCount,
                                    hexToColor(r.projectHexColor,
                                        fallback: OrbitAccents.todoAccent),
                                  ),
                              ],
                            ),
                            _DistSection(
                              title: '优先级分布',
                              rows: [
                                for (final r in stats.byPriority)
                                  (
                                    _priorityLabel(r.priority),
                                    r.doneCount,
                                    r.pendingCount,
                                    hexToColor(priorityColorHex(r.priority)),
                                  ),
                              ],
                            ),
                            _DistSection(
                              title: '星期分布（已完成）',
                              rows: [
                                for (final r in stats.byWeekday)
                                  (
                                    _weekdayLabel(r.weekday),
                                    r.doneCount,
                                    0,
                                    OrbitAccents.todoAccent,
                                  ),
                              ],
                            ),
                          ],
                        ),
                    ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '统计',
            ),
          ),
        ],
      ),
    );
  }

  static String _priorityLabel(int p) {
    const labels = ['无', '低', '中', '高', '紧急', '立即处理'];
    return p >= 0 && p < labels.length ? labels[p] : 'P$p';
  }

  static String _weekdayLabel(int wd) {
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return wd >= 0 && wd < labels.length ? labels[wd] : '$wd';
  }
}

/// 总览五卡（2×2 + 1 满宽尾卡）
class _OverviewCards extends StatelessWidget {
  const _OverviewCards({required this.overview});

  final StatsOverview overview;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    Widget cell(String label, int value) => Container(
          padding: const EdgeInsets.all(AppDimens.space12),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: AppShapes.medium,
            border: Border.all(color: colors.outline),
            boxShadow: AppElevation.e1(Theme.of(context).brightness),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
              const SizedBox(height: AppDimens.space4),
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
            ],
          ),
        );

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: cell('总任务', overview.total)),
            const SizedBox(width: AppDimens.space8),
            Expanded(child: cell('已完成', overview.done)),
            const SizedBox(width: AppDimens.space8),
            Expanded(child: cell('未完成', overview.pending)),
          ],
        ),
        const SizedBox(height: AppDimens.space8),
        Row(
          children: [
            Expanded(child: cell('近 7 天完成', overview.doneLast7d)),
            const SizedBox(width: AppDimens.space8),
            Expanded(child: cell('近 30 天完成', overview.doneLast30d)),
          ],
        ),
      ],
    );
  }
}

/// streak 行（火焰图标 + 当前/最长/今日状态）
class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.streak});

  final StatsStreak streak;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space12,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppShapes.medium,
        border: Border.all(color: colors.outline),
        boxShadow: AppElevation.e1(Theme.of(context).brightness),
      ),
      child: Row(
        children: [
          Icon(
            OrbitIcons.flame,
            size: 22,
            color: streak.current > 0 ? OrbitAccents.myDayAmber : colors.secondaryText,
          ),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: '连续完成 ',
                style: TextStyle(fontSize: 14, color: colors.titleText),
                children: [
                  TextSpan(
                    text: '${streak.current}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const TextSpan(text: ' 天'),
                  TextSpan(
                    text: '　历史最长 ${streak.best} 天 · '
                        '${streak.doneToday ? '今天已完成' : '今天还没完成任何任务'}',
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 热力图卡（标题行带年份/完成数副标题；主体 = todo_heatmap.dart 组件）
class _HeatmapCard extends StatelessWidget {
  const _HeatmapCard({
    required this.stats,
    required this.year,
    required this.onYearChange,
  });

  final StatsAggregate stats;
  final int year;
  final ValueChanged<int> onYearChange;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final heatTotal =
        stats.heatmap.cells.fold<int>(0, (s, c) => s + c.count);

    return Container(
      padding: const EdgeInsets.all(AppDimens.space16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppShapes.medium,
        border: Border.all(color: colors.outline),
        boxShadow: AppElevation.e1(Theme.of(context).brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '完成热力图',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              Text(
                '$year 年 · $heatTotal 个完成',
                style: TextStyle(
                  fontSize: 12,
                  color: colors.secondaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space12),
          OrbitHeatmap(
            heatmap: stats.heatmap,
            availableYears: stats.availableYears,
            year: year,
            onYearChange: onYearChange,
          ),
        ],
      ),
    );
  }
}

/// 分布卡（label + 双段条形：完成段行色实心 / 未完成段同色 25% 弱化；
/// 行色按来源取项目自选色 / 优先级语义色 / 待办强调色）
class _DistSection extends StatelessWidget {
  const _DistSection({required this.title, required this.rows});

  final String title;
  final List<(String, int, int, Color)> rows;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final visible = rows.where((r) => r.$2 + r.$3 > 0).toList();

    return Container(
      margin: const EdgeInsets.only(top: AppDimens.space12),
      padding: const EdgeInsets.all(AppDimens.space16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppShapes.medium,
        border: Border.all(color: colors.outline),
        boxShadow: AppElevation.e1(Theme.of(context).brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.titleText,
            ),
          ),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppDimens.space8),
              child: Text(
                '暂无任务',
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
            )
          else
            for (final (label, done, pending, color) in visible)
              Padding(
                padding: const EdgeInsets.only(top: AppDimens.space8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: colors.titleText),
                          ),
                        ),
                        Text(
                          '$done / ${done + pending}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        height: 6,
                        child: Row(
                          children: [
                            if (done > 0)
                              Flexible(
                                flex: done,
                                child: Container(color: color),
                              ),
                            if (pending > 0)
                              Flexible(
                                flex: pending,
                                child: Container(
                                  color: color.withValues(alpha: 0.25),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// 统计页初次加载骨架：总览三卡 + streak 行 + 热力图区占位
///
/// 版式对齐真实内容（横向 space16、三卡等分），加载落定即整块替换为实数；
/// 年份切换等"有旧值"的重查不走这里（旧内容保留，不闪骨架）。
class _StatsSkeleton extends StatelessWidget {
  const _StatsSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget row(double height, {int flex = 1}) => Expanded(
          flex: flex,
          child: OrbitSkeleton.block(height: height),
        );
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top +
            OrbitPageHeader.rowHeight +
            AppDimens.space8,
        left: AppDimens.space16,
        right: AppDimens.space16,
      ),
      children: [
        Row(
          children: [
            row(86),
            const SizedBox(width: AppDimens.space8),
            row(86),
            const SizedBox(width: AppDimens.space8),
            row(86),
          ],
        ),
        const SizedBox(height: AppDimens.space12),
        const OrbitSkeleton.block(height: 64),
        const SizedBox(height: AppDimens.space12),
        const OrbitSkeleton.block(height: 220),
      ],
    );
  }
}
