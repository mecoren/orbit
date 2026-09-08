import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';

/// 统计页 /todo/stats（backlog #25：统计仪表盘，对标 TickTick 成就页）
///
/// 数据 = bridge.statsAggregate 一次性聚合（只读）：
/// - 总览五卡 + streak 行；
/// - 热力图（窗口档位 35/182/371 自绘，周一为行首）；
/// - 项目 / 优先级 / 星期三分布卡（纯 Row 条形，不引图表库）。
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  final _scrollController = ScrollController();
  int _windowDays = 182;

  static const _windowChoices = [
    (35, '近 5 周'),
    (182, '近半年'),
    (371, '近一年'),
  ];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(statsProvider(_windowDays)).value;
    final colors = AppColors.ofContext(context);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: stats == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    controller: _scrollController,
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top +
                          LiquidGlassTitleBar.rowHeight +
                          AppDimens.space8,
                      bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
                    ),
                    children: [
                      _OverviewCards(overview: stats.overview),
                      const SizedBox(height: AppDimens.space12),
                      _StreakCard(streak: stats.streak),
                      const SizedBox(height: AppDimens.space12),
                      _HeatmapCard(heatmap: stats.heatmap),
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
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: '统计',
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
              actions: [
                PopupMenuButton<int>(
                  initialValue: _windowDays,
                  onSelected: (d) => setState(() => _windowDays = d),
                  itemBuilder: (_) => [
                    for (final (d, label) in _windowChoices)
                      PopupMenuItem(value: d, child: Text(label)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.space8,
                      vertical: AppDimens.space4,
                    ),
                    child: Text(
                      _windowChoices
                          .firstWhere((w) => w.$1 == _windowDays)
                          .$2,
                      style: TextStyle(
                        fontSize: 14,
                        color: colors.titleText,
                      ),
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
            color: colors.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.divider.withValues(alpha: 0.3)),
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
        color: colors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.local_fire_department_outlined,
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

/// 热力图卡（横滚：列 = 周，行 = 周一..周日；5 档色阶待办强调色）
class _HeatmapCard extends StatelessWidget {
  const _HeatmapCard({required this.heatmap});

  final StatsHeatmap heatmap;

  /// count → 色阶档（与桌面同口径：0 / 1 / 2-3 / 4-6 / ≥7）
  static int _level(int count) {
    if (count <= 0) return 0;
    if (count == 1) return 1;
    if (count <= 3) return 2;
    if (count <= 6) return 3;
    return 4;
  }

  static const _alphas = [0.0, 0.30, 0.55, 0.80, 1.0];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    const cellSize = 11.0;
    const gap = 3.0;
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];

    // 周日历分列：首格补前置空格对齐周一
    final cells = heatmap.cells;
    if (cells.isEmpty) return const SizedBox.shrink();
    final first = DateTime.parse('${cells.first.date}T00:00:00');
    final pad = (first.weekday - 1) % 7;
    final padded = [
      ...List.filled(pad, null),
      ...cells,
    ];
    final weeks = [
      for (var i = 0; i < padded.length; i += 7)
        padded.sublist(i, (i + 7).clamp(0, padded.length)),
    ];

    final dayLabels = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 7; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: gap),
            child: SizedBox(
              width: 12,
              height: cellSize,
              child: Center(
                child: Text(
                  weekdays[i],
                  style: TextStyle(fontSize: 9, color: colors.secondaryText),
                ),
              ),
            ),
          ),
      ],
    );

    return Container(
      padding: const EdgeInsets.all(AppDimens.space16),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '完成热力图',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.titleText,
            ),
          ),
          const SizedBox(height: AppDimens.space12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                dayLabels,
                const SizedBox(width: gap),
                for (final week in weeks)
                  Padding(
                    padding: const EdgeInsets.only(right: gap),
                    child: Column(
                      children: [
                        for (var i = 0; i < week.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: gap),
                            child: week[i] == null
                                ? const SizedBox(width: cellSize, height: cellSize)
                                : Container(
                                    width: cellSize,
                                    height: cellSize,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(3),
                                      color: _level(week[i]!.count) == 0
                                          ? colors.divider.withValues(alpha: 0.25)
                                          : OrbitAccents.todoAccent.withValues(
                                              alpha: _alphas[_level(week[i]!.count)]),
                                    ),
                                  ),
                          ),
                      ],
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

/// 分布卡（label + 双段条形：完成段行色 / 未完成段弱化；行色按来源取
/// 项目自选色 / 优先级语义色 / 待办强调色）
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
        color: colors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.3)),
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
                                  color: colors.secondaryText.withValues(alpha: 0.25),
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
