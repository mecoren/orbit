import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../shared/widgets/shadcn/orbit_card.dart';
import '../../shared/widgets/shadcn/orbit_list_card.dart';
import 'logic/task_logic.dart';

/// 四象限视图（Eisenhower Matrix）
///
/// 移动端形态取舍：
/// - **概览 + 下钻两态**：手机宽度摆不下桌面版四格一屏铺开的完整工作面，
///   概览 2×2 格只放计数与前三条标题预览（点格看全量），格间用
///   `IntrinsicHeight` 同行等高；下钻态整页滚动展示该象限全部任务行，
///   行直接复用列表档 [buildTile]（勾选 / 侧滑 / 提醒徽标全功能不欠账）。
/// - **轴口径**见 [groupEisenhower]：重要 = 优先级≥高，紧急 = 截止≤今天末；
///   已完成不入桶——完成历史交给「已完成」视图。
/// - 象限色带只落在格顶 3px（shadcn New York：描边 + 表面分层承载结构，
///   色相只做象限识别信号，不整格铺色）。
class EisenhowerMatrixBoard extends StatefulWidget {
  const EisenhowerMatrixBoard({
    super.key,
    required this.tasks,
    required this.padding,
    required this.buildTile,
  });

  /// 已按当前排序档排好的任务集（matrix 档 hideDone 由调用方保证，完成行不入桶）
  final List<TodoTask> tasks;

  /// 外层让位标题栏的内边距（与列表档同口径，切换视图不跳动）
  final EdgeInsets padding;

  /// 行构造口（列表档 [TodoTaskTile] 的包装；edge 由本视图按段位传）
  final Widget Function(TodoTask task, {OrbitCardEdge edge}) buildTile;

  @override
  State<EisenhowerMatrixBoard> createState() => _EisenhowerMatrixBoardState();
}

class _EisenhowerMatrixBoardState extends State<EisenhowerMatrixBoard> {
  /// 下钻象限；null = 概览 2×2
  EisenhowerQuadrant? _open;

  /// 象限识别色（整幅矩阵共用一套语义：红=火烧眉毛、蓝=要事、
  /// 琥珀=临时插队、灰=可放一放；全部取既有 token，不新增色值）
  Color _tint(AppColorSet colors, EisenhowerQuadrant q) => switch (q) {
        EisenhowerQuadrant.urgentImportant => OrbitAccents.overdueRed,
        EisenhowerQuadrant.importantNotUrgent => OrbitAccents.todoAccent,
        EisenhowerQuadrant.urgentNotImportant => OrbitAccents.myDayAmber,
        EisenhowerQuadrant.neither => colors.secondaryText,
      };

  @override
  Widget build(BuildContext context) {
    final buckets = groupEisenhower(widget.tasks);
    final open = _open;
    final child = open == null
        ? _overview(context, buckets)
        : _drilldown(context, open, buckets[open] ?? const <TodoTask>[]);
    return AnimatedSwitcher(
      duration: AppMotion.viewSwitch,
      switchInCurve: AppMotion.decelerate,
      switchOutCurve: AppMotion.accelerate,
      child: KeyedSubtree(
        key: ValueKey('matrix-${open?.name ?? 'overview'}'),
        child: child,
      ),
    );
  }

  // ── 概览：2×2 象限格 ──

  Widget _overview(
    BuildContext context,
    Map<EisenhowerQuadrant, List<TodoTask>> buckets,
  ) {
    Widget row(EisenhowerQuadrant a, EisenhowerQuadrant b) => IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _cell(context, a, buckets[a]!)),
              const SizedBox(width: AppDimens.cardGap),
              Expanded(child: _cell(context, b, buckets[b]!)),
            ],
          ),
        );
    return ListView(
      padding: widget.padding,
      children: [
        row(EisenhowerQuadrant.urgentImportant,
            EisenhowerQuadrant.importantNotUrgent),
        const SizedBox(height: AppDimens.cardGap),
        row(EisenhowerQuadrant.urgentNotImportant, EisenhowerQuadrant.neither),
      ],
    );
  }

  Widget _cell(
    BuildContext context,
    EisenhowerQuadrant q,
    List<TodoTask> tasks,
  ) {
    final colors = AppColors.ofContext(context);
    final tint = _tint(colors, q);
    return OrbitCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: AppShapes.medium,
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _open = q);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 象限色带：顶缘 3px，随格圆角只圆上缘
            Container(
              height: 3,
              decoration: BoxDecoration(
                color: tint,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppShapes.radiusMedium),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppDimens.space12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          q.actionLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors.titleText,
                          ),
                        ),
                      ),
                      Text(
                        '${tasks.length}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: tasks.isEmpty
                              ? colors.secondaryText
                              : tint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppDimens.space2),
                  Text(
                    q.axisLabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.secondaryText,
                    ),
                  ),
                  if (tasks.isNotEmpty) ...[
                    const SizedBox(height: AppDimens.space8),
                    // 前三条标题预览：给「点进去是什么」的实感，不占整格高度
                    for (final t in tasks.take(3))
                      Padding(
                        padding: const EdgeInsets.only(top: AppDimens.space4),
                        child: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.secondaryText,
                          ),
                        ),
                      ),
                    if (tasks.length > 3)
                      Padding(
                        padding: const EdgeInsets.only(top: AppDimens.space4),
                        child: Text(
                          '还有 ${tasks.length - 3} 条',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.secondaryText.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 下钻：单象限全量列表 ──

  Widget _drilldown(
    BuildContext context,
    EisenhowerQuadrant q,
    List<TodoTask> tasks,
  ) {
    final colors = AppColors.ofContext(context);
    final tint = _tint(colors, q);
    return ListView(
      padding: widget.padding,
      children: [
        // 返回行：整行可点回概览（不给独立返回钮，拇指热区更大）
        InkWell(
          onTap: () => setState(() => _open = null),
          borderRadius: AppShapes.small,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
            child: Row(
              children: [
                Icon(OrbitIcons.back,
                    size: AppDimens.iconSizeSm, color: colors.titleText),
                const SizedBox(width: AppDimens.space8),
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        width: 3,
                        height: AppDimens.iconSizeSm,
                        decoration: BoxDecoration(
                          color: tint,
                          borderRadius: AppShapes.small,
                        ),
                      ),
                      const SizedBox(width: AppDimens.space8),
                      Expanded(
                        child: Text(
                          q.actionLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.titleText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${q.axisLabel} · ${tasks.length} 项',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppDimens.space4),
        if (tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppDimens.space32),
            child: Column(
              children: [
                Icon(
                  OrbitIcons.grid,
                  size: AppDimens.iconSizeLg * 2,
                  color: colors.secondaryText.withValues(alpha: 0.4),
                ),
                const SizedBox(height: AppDimens.space12),
                Text(
                  '这格是空的',
                  style: TextStyle(fontSize: 13, color: colors.secondaryText),
                ),
              ],
            ),
          )
        else
          // 任务行按段位成卡（与列表档「逾期置顶」区块同视觉语言）
          for (var i = 0; i < tasks.length; i++)
            widget.buildTile(
              tasks[i],
              edge: OrbitCardEdge.of(i, tasks.length),
            ),
      ],
    );
  }
}
