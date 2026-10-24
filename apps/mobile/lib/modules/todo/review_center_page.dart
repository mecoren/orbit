// 回顾中心（F1 项目回顾节奏，docs/13 §五 F1 / §八 U1）——OmniFocus Review 的
// 本地等价物：每个项目自带回顾周期，到期项目按「逾期天数」降序归集在此；
// 逐项目走三步向导（复用周回顾弹层，任务集按项目过滤），完成即标记
// review_last_at（下次到期 = 今天 + 周期）。
//
// 页面结构 = OrbitPageHeader（Stack 顶部实色页头）+ 整页 ListView 滚动；
// 数据真值（到期/逾期/计数）全部来自 core project_review_api，本页零口径复刻。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'logic/project_review.dart';
import 'providers/todo_providers.dart';
import 'weekly_review_sheet.dart';

/// 稍后一周（暂缓档与桌面一致）
const int _snoozeDays = 7;

class ReviewCenterPage extends ConsumerStatefulWidget {
  const ReviewCenterPage({super.key});

  @override
  ConsumerState<ReviewCenterPage> createState() => _ReviewCenterPageState();
}

class _ReviewCenterPageState extends ConsumerState<ReviewCenterPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final due = ref.watch(reviewDueProvider).value ?? const <ProjectReviewStatus>[];
    final topInset =
        MediaQuery.of(context).padding.top + OrbitPageHeader.rowHeight;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: due.isEmpty
                ? Padding(
                    padding: EdgeInsets.only(top: topInset),
                    child: const EmptyState(
                      message: '没有待回顾的项目\n在清单编辑里设置回顾周期，到期后会出现在这里',
                      icon: OrbitIcons.calendarCheck,
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                      AppDimens.space16,
                      topInset + AppDimens.space8,
                      AppDimens.space16,
                      AppDimens.pageInline,
                    ),
                    itemCount: due.length,
                    itemBuilder: (context, i) => _ReviewRow(
                      status: due[i],
                      onStart: () => _startReview(due[i]),
                      onSnooze: () => _snooze(due[i]),
                      onMarked: () => _markReviewed(due[i]),
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              showBack: true,
              title: '回顾',
              actions: [
                if (due.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: AppDimens.space12),
                    child: Center(
                      child: Text(
                        '${due.length} 个待回顾',
                        style: TextStyle(
                            fontSize: 13, color: colors.secondaryText),
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

  void _refresh() => ref.invalidate(reviewDueProvider);

  Future<void> _markReviewed(ProjectReviewStatus status) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoProjectMarkReviewed(status.project.id);
      _refresh();
      WaitToast.success('已标记回顾，下次到期 ${formatReviewInterval(status.project.reviewIntervalDays)}后');
    } catch (_) {
      WaitToast.destructive('操作失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _snooze(ProjectReviewStatus status) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).todoProjectSnoozeReview(
          status.project.id, _snoozeDays, DateTime.now().millisecondsSinceEpoch);
      _refresh();
      WaitToast.success('已暂缓一周');
    } catch (_) {
      WaitToast.destructive('操作失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 开始回顾：任务集按项目过滤走周回顾三步向导；**走完**（返回非 null）才
  /// 标记已回顾——下滑关弹不推进周期（中途退出保留到期态）
  Future<void> _startReview(ProjectReviewStatus status) async {
    final tasks = (ref.read(todoTasksProvider).value ?? const <TodoTask>[])
        .where((t) => t.projectId == status.project.id)
        .toList();
    final handled = await showWeeklyReviewSheet(
      context,
      tasks: tasks,
      onSetDue: (id, dueMs) async {
        await ref
            .read(orbitBridgeProvider)
            .todoTaskUpdate(id, encodePatch({'due_date': dueMs}));
      },
      onWake: (id) async {
        await ref
            .read(orbitBridgeProvider)
            .todoTaskUpdate(id, encodePatch(<String, Object?>{}));
      },
    );
    if (handled == null) return;
    if (!mounted) return;
    ref.invalidate(todoTasksProvider);
    await _markReviewed(status);
  }
}

/// 单个待回顾项目行：色点 + 标题 + 元信息（周期/上次回顾/未完成数）+ 逾期徽标
/// + 操作行（开始回顾 / 稍后一周 / 已回顾）。三个动作回调由父级注入——
/// 本组件零桥依赖，widget 测试可直接断言回调触发
class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    required this.status,
    required this.onStart,
    required this.onSnooze,
    required this.onMarked,
  });

  final ProjectReviewStatus status;
  final VoidCallback onStart;
  final VoidCallback onSnooze;
  final VoidCallback onMarked;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final p = status.project;
    final overdue = status.overdueDays > 0;
    final meta = [
      formatReviewInterval(p.reviewIntervalDays),
      formatLastReviewed(p.reviewLastAt),
      if (status.openTaskCount > 0) '${status.openTaskCount} 件未完成',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: AppDimens.cardGap),
      padding: const EdgeInsets.all(AppDimens.cardPadding),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppShapes.medium,
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: hexToColor(p.hexColor),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              Expanded(
                child: Text(
                  p.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: colors.titleText,
                  ),
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: overdue
                      ? OrbitAccents.overdueRed.withValues(alpha: 0.12)
                      : colors.surfaceSecondary,
                  borderRadius: AppShapes.xs,
                ),
                child: Text(
                  formatOverdueDays(status.overdueDays),
                  style: TextStyle(
                    fontSize: 12,
                    color: overdue ? OrbitAccents.overdueRed : colors.secondaryText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(meta, style: TextStyle(fontSize: 13, color: colors.secondaryText)),
          const SizedBox(height: AppDimens.space8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(
                onPressed: onSnooze,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('稍后一周'),
              ),
              const SizedBox(width: AppDimens.space8),
              OutlinedButton(
                onPressed: onMarked,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('已回顾'),
              ),
              const SizedBox(width: AppDimens.space8),
              FilledButton.tonal(
                onPressed: onStart,
                child: const Text('开始回顾'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
