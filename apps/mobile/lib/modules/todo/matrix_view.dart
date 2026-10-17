import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_card.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import '../../shared/widgets/shadcn/orbit_row_toggle.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import 'logic/task_logic.dart';

/// 四象限视图（Eisenhower Matrix，竞品口径版式）
///
/// **整幅 2×2 恒在**（不再概览/下钻两态）：四个象限卡同屏等分剩余高度，
/// 任务行直接列在格内、超出格高**格内自滚**（半屏宽的格里右侧日期列会挤掉
/// 标题，行版式改「标题 + 截止日期 + 提醒/进度」纵排两行）；空象限格内居中
/// 「没有任务」。行为与列表档对齐：点行进详情、勾选完成、长按弹行操作菜单。
///
/// - **轴口径**见 [groupEisenhower]：重要 = 优先级≥高，紧急 = 截止≤今天末；
///   已完成不入桶——完成历史交给「已完成」视图。
/// - **象限识别色**（整幅矩阵一套语义）：Ⅰ 红 = 火烧眉毛、Ⅱ 琥珀 = 要事计划、
///   Ⅲ 蓝 = 临时插队、Ⅳ 绿 = 可放一放；头行罗马数字徽标与文案同色，
///   全部取既有 token，不新增色值。
class EisenhowerMatrixBoard extends StatelessWidget {
  const EisenhowerMatrixBoard({
    super.key,
    required this.tasks,
    required this.padding,
    required this.onOpen,
    required this.onToggleDone,
    this.onLongPress,
    this.onToggleFavorite,
    this.remindersByTask = const {},
  });

  /// 已按当前排序档排好的任务集（matrix 档 hideDone 由调用方保证，完成行不入桶）
  final List<TodoTask> tasks;

  /// 外层让位标题栏的内边距（与列表档同口径，切换视图不跳动）
  final EdgeInsets padding;

  final ValueChanged<TodoTask> onOpen;
  final ValueChanged<TodoTask> onToggleDone;

  /// 长按行（弹操作菜单）；null = 无长按语义
  final ValueChanged<TodoTask>? onLongPress;

  /// 星标行内开关（G8，对齐桌面矩阵行 hover 开关）；无我的一天
  final ValueChanged<TodoTask>? onToggleFavorite;

  /// 任务 → 提醒投影（行内提醒徽标数据源；投影未就绪时为空，不渲染徽标）
  final Map<int, List<ProjectedReminder>> remindersByTask;

  /// 象限识别色（Ⅰ 红 / Ⅱ 琥珀 / Ⅲ 蓝 / Ⅳ 绿）
  Color _tint(AppColorSet colors, EisenhowerQuadrant q) => switch (q) {
        EisenhowerQuadrant.urgentImportant => OrbitAccents.overdueRed,
        EisenhowerQuadrant.importantNotUrgent => OrbitAccents.myDayAmber,
        EisenhowerQuadrant.urgentNotImportant => OrbitAccents.todoAccent,
        EisenhowerQuadrant.neither => OrbitAccents.doneGreen,
      };

  /// 罗马数字徽标（竞品同款象限序号）
  String _roman(EisenhowerQuadrant q) => switch (q) {
        EisenhowerQuadrant.urgentImportant => 'Ⅰ',
        EisenhowerQuadrant.importantNotUrgent => 'Ⅱ',
        EisenhowerQuadrant.urgentNotImportant => 'Ⅲ',
        EisenhowerQuadrant.neither => 'Ⅳ',
      };

  @override
  Widget build(BuildContext context) {
    final buckets = groupEisenhower(tasks);
    return Padding(
      padding: padding,
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _cell(context, EisenhowerQuadrant.urgentImportant,
                      buckets[EisenhowerQuadrant.urgentImportant]!),
                ),
                const SizedBox(width: AppDimens.cardGap),
                Expanded(
                  child: _cell(context, EisenhowerQuadrant.importantNotUrgent,
                      buckets[EisenhowerQuadrant.importantNotUrgent]!),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppDimens.cardGap),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _cell(context, EisenhowerQuadrant.urgentNotImportant,
                      buckets[EisenhowerQuadrant.urgentNotImportant]!),
                ),
                const SizedBox(width: AppDimens.cardGap),
                Expanded(
                  child: _cell(context, EisenhowerQuadrant.neither,
                      buckets[EisenhowerQuadrant.neither]!),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 象限卡：头行（罗马数字徽标 + 行动短语 + 计数）+ 1px 分隔线 +
  /// 任务列（格内自滚；空象限居中「没有任务」）
  Widget _cell(
    BuildContext context,
    EisenhowerQuadrant q,
    List<TodoTask> tasks,
  ) {
    final colors = AppColors.ofContext(context);
    final tint = _tint(colors, q);
    return OrbitCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppDimens.space12, AppDimens.space8, AppDimens.space12,
                AppDimens.space8),
            child: Row(
              children: [
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
                  child: Text(
                    _roman(q),
                    style: const TextStyle(
                      fontSize: 9,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFFFFFFF),
                    ),
                  ),
                ),
                const SizedBox(width: AppDimens.space6),
                Expanded(
                  child: Text(
                    q.actionLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: tint,
                    ),
                  ),
                ),
                const SizedBox(width: AppDimens.space4),
                Text(
                  '${tasks.length}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: tasks.isEmpty ? colors.secondaryText : tint,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: colors.divider),
          Expanded(
            child: tasks.isEmpty
                ? Center(
                    child: Text(
                      '没有任务',
                      style:
                          TextStyle(fontSize: 12, color: colors.secondaryText),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        vertical: AppDimens.space2),
                    itemCount: tasks.length,
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      return _QuadrantRow(
                        task: task,
                        // 行内提醒徽标：未来最近一条 / 全过期最早一条
                        // （列表行 displayReminder 同口径）
                        reminder: displayReminder(
                          remindersByTask[task.id] ??
                              const <ProjectedReminder>[],
                          DateTime.now().millisecondsSinceEpoch,
                          taskDone: task.isDone,
                        ),
                        onOpen: onOpen,
                        onToggleDone: onToggleDone,
                        onLongPress: onLongPress,
                        onToggleFavorite: onToggleFavorite,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 象限格内的紧凑任务行：勾选框 +「标题 / 截止日期 + 提醒铃铛 + 进度」纵排
///
/// 半屏宽格里放不下列表档的右侧日期列，日期改落在标题下（竞品同款）：
/// 相对口径 [formatDueShort]，未来/今天主题蓝、逾期红；完成态标题划线置灰。
/// 提醒铃铛只示态不带时刻（同日历任务行口径；时刻在列表/看板/详情可读）。
class _QuadrantRow extends StatelessWidget {
  const _QuadrantRow({
    required this.task,
    required this.onOpen,
    required this.onToggleDone,
    this.reminder,
    this.onLongPress,
    this.onToggleFavorite,
  });

  final TodoTask task;
  final ValueChanged<TodoTask> onOpen;
  final ValueChanged<TodoTask> onToggleDone;

  /// 行内提醒载荷；null（无存活提醒）不渲染
  final DisplayReminder? reminder;

  final ValueChanged<TodoTask>? onLongPress;

  /// 星标行内开关（G8，对齐桌面 matrix-view.tsx:347-363 的 hover 开关钮）；
  /// 无我的一天（桌面明注「象限格是优先级工作面」，不补）
  final ValueChanged<TodoTask>? onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final hex = priorityRingHex(task.priority);
    final dueLabel =
        task.dueDate == null ? null : formatDueShort(task.dueDate!);
    final pct = task.percentDone;
    final showMeta =
        dueLabel != null || reminder != null || (pct > 0 && pct < 100);

    return InkWell(
      onTap: () => onOpen(task),
      onLongPress: onLongPress == null ? null : () => onLongPress!(task),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space12,
          vertical: AppDimens.space6,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: AppDimens.taskCheckboxSize,
              child: OrbitCheckbox(
                checked: task.isDone,
                onToggle: () {
                  HapticFeedback.selectionClick();
                  onToggleDone(task);
                },
                borderColor:
                    hex == null ? null : hexToColor(hex),
              ),
            ),
            const SizedBox(width: AppDimens.space8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedStrikethrough(
                    text: task.title,
                    done: task.isDone,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.titleText,
                    ),
                    doneColor: colors.secondaryText,
                  ),
                  if (showMeta)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          if (dueLabel != null)
                            Flexible(
                              child: Text(
                                dueLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                  color: isOverdue(task)
                                      ? OrbitAccents.overdueRed
                                      : OrbitAccents.themeAccent,
                                ),
                              ),
                            ),
                          if (reminder != null) ...[
                            const SizedBox(width: AppDimens.space4),
                            Icon(
                              OrbitIcons.notification,
                              size: 11,
                              // 到期未完转逾期红（日历任务行同口径）
                              color: reminder!.fired
                                  ? OrbitAccents.overdueRed
                                  : colors.secondaryText,
                            ),
                          ],
                          if (pct > 0 && pct < 100) ...[
                            const SizedBox(width: AppDimens.space4),
                            Text(
                              '${pct.round()}%',
                              style: TextStyle(
                                fontSize: 11,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                                color: colors.secondaryText,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
            // 星标（G8，对齐桌面 matrix-view.tsx:347-363 hover 开关）：
            // 恒显可点；无我的一天（桌面明注象限格是优先级工作面）
            if (onToggleFavorite != null)
              OrbitRowToggle(
                icon: OrbitIcons.star,
                active: task.isStarred,
                activeColor: task.isDone
                    ? colors.deactivatedText
                    : OrbitAccents.starYellow,
                inactiveColor: colors.deactivatedText,
                tooltip: task.isStarred ? '取消收藏' : '收藏',
                onTap: () {
                  HapticFeedback.selectionClick();
                  onToggleFavorite!(task);
                },
                iconSize: 14,
                hitExtent: 32,
              ),
          ],
        ),
      ),
    );
  }
}
