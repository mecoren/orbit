import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import 'logic/capacity.dart';

/// 今日上下文条（G2 正反馈 + G4 容量规划；镜像桌面 `today-strip.tsx`）
///
/// 品类两处普遍缺口的合并落点：
/// - G2 情绪减负：打开应用先看到「今日已达成 N 项」的正向反馈，
///   而不是只剩红色逾期与未完成堆积；
/// - G4 容量规划：把「今天装得下多少」量化为「今日已排 X / 预算 Y」，
///   超载/偏紧给醒目提示（My Day 类功能普遍只回答「做什么」）。
///
/// 数据口径全在内存任务集上算（[todayLoadMinutes] / 今日完成计数），
/// 不引新查询、不改桥。预算由调用方注入（[budgetMinutes]，未设 = null），
/// 点击整条回调 [onTapBudget] 编辑预算（本层不自管落盘）。
/// 两项皆空（今天没达成也没排程且未设预算）时返回空白，不占位。
class TodayStrip extends StatelessWidget {
  const TodayStrip({
    super.key,
    required this.tasks,
    required this.budgetMinutes,
    required this.onTapBudget,
  });

  /// 条高（固定值）：列表 padding 与 Positioned 共用，改这里即两处同步
  /// （与 `_TruncationBanner.height` 同款约定）。
  static const double height = 40.0;

  /// 内存任务集（今日口径在本层算）
  final List<TodoTask> tasks;

  /// 每日容量预算（分钟）；null = 未设（不做超载判定）
  final int? budgetMinutes;

  /// 点击「每日容量」编辑区回调
  final VoidCallback onTapBudget;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final dayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;

    final doneToday = tasks
        .where((t) =>
            t.isDone &&
            t.doneAt != null &&
            t.doneAt! >= dayStart &&
            t.doneAt! < dayStart + 86400000)
        .length;
    final load = todayLoadMinutes(tasks, nowMs);
    final status = capacityStatus(load, budgetMinutes);

    if (doneToday == 0 && load == 0 && budgetMinutes == null) {
      return const SizedBox.shrink();
    }

    final loadColor = switch (status.level) {
      CapacityLevel.over => colors.destructive,
      CapacityLevel.tight => colors.warning,
      _ => colors.secondaryText,
    };

    return SizedBox(
      height: height,
      child: Container(
        color: colors.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space8,
      ),
      child: Row(
        children: [
          // G2 正反馈：今日已达成（成功色，数字为体）。
          // 整句用 Text.rich 合并——数字不单开 Text 节点，避免与列表别处
          // 的裸数字计数在 find.text 断言里撞车（done_section 同名计数）
          Icon(OrbitIcons.success, size: 16, color: colors.success),
          const SizedBox(width: AppDimens.space4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '今日已达成 ',
                  style: TextStyle(fontSize: 12, color: colors.secondaryText),
                ),
                TextSpan(
                  text: '$doneToday',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: doneToday > 0 ? colors.success : colors.secondaryText,
                  ),
                ),
                TextSpan(
                  text: ' 项',
                  style: TextStyle(fontSize: 12, color: colors.secondaryText),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppDimens.space12),
          Container(width: 1, height: 12, color: colors.divider),
          const SizedBox(width: AppDimens.space12),
          // G4 容量：今日已排 vs 预算（超载/偏紧给色调提示）
          Icon(OrbitIcons.clock, size: 16, color: loadColor),
          const SizedBox(width: AppDimens.space4),
          Flexible(
            child: Text(
              capacityHint(load, budgetMinutes),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: loadColor),
            ),
          ),
          const SizedBox(width: AppDimens.space8),
          // 预算编辑入口（点按开抽屉，由调用方接手）
          InkWell(
            onTap: onTapBudget,
            borderRadius: AppShapes.xs,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space4,
                vertical: AppDimens.space2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '每日容量',
                    style: TextStyle(fontSize: 11, color: colors.secondaryText),
                  ),
                  const SizedBox(width: AppDimens.space2),
                  Icon(OrbitIcons.edit, size: 12, color: colors.deactivatedText),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}
