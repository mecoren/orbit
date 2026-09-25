import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_card.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import 'logic/task_logic.dart';
import '../../core/theme/icon_map.dart';

/// 看板视图（对齐桌面 `kanban-view.tsx` 的分列 + 卡片信息层级）
///
/// 移动端形态取舍：
/// - **横向分列滚动**而非桌面的一屏铺开——手机宽度只够一列半，横滑是
///   唯一可用形态；列宽固定 264，带 `PageScrollPhysics` 式的对齐吸附感
///   （`ListWheelScrollView` 过重，此处用固定列宽 + 惯性滚动即可）。
/// - **列内各自惰性 ListView**：一列上百张卡时只构建可视部分，不引入
///   虚拟化库（仓库约定 UI 自绘不引库）。
/// - **不做跨列拖拽**：移动端长按既承载拖拽又与「长按弹操作菜单」冲突，
///   跨列改归属走卡片长按菜单（改项目/改状态），语义等价且不误触。
///
/// 卡片信息层级：完成勾选 + 标题（最多 2 行）+ 截止（逾期红）+ 优先级色条 +
/// 标签色点行 + 项目名（仅「按状态」分组时显示，按项目分组时列头已表达）。
class KanbanBoard extends StatelessWidget {
  const KanbanBoard({
    super.key,
    required this.columns,
    required this.padding,
    required this.onToggleDone,
    required this.onOpen,
    required this.onLongPress,
    this.projectTitleOf,
    this.labelDotsByTask = const {},
  });

  /// 分列表（由 `groupTasksForKanban` 纯函数产出）
  final List<KanbanColumn> columns;

  /// 外层让位标题栏的内边距（与列表档同口径，避免切换视图时跳动）
  final EdgeInsets padding;
  final ValueChanged<TodoTask> onToggleDone;
  final ValueChanged<TodoTask> onOpen;
  final ValueChanged<TodoTask> onLongPress;

  /// 卡片项目名取用口（按项目分组时列头已表达，传 null 不渲染该行）
  final String? Function(TodoTask)? projectTitleOf;

  /// 任务 → 标签色点（投影未就绪时为空，卡片退化为无标签点）
  final Map<int, List<ProjectedTaskLabel>> labelDotsByTask;

  /// 列宽（264 = 一屏可见约 1.5 列，暗示可横滑）
  static const double columnWidth = 264;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: padding,
      itemCount: columns.length,
      // 末列不再加列间距：右页边由列表 padding 承担，避免双重留白
      itemBuilder: (context, index) => _column(
        context,
        columns[index],
        isLast: index == columns.length - 1,
      ),
    );
  }

  Widget _column(
    BuildContext context,
    KanbanColumn column, {
    bool isLast = false,
  }) {
    final colors = AppColors.ofContext(context);
    final accent = hexToColor(column.colorHex);
    return Container(
      width: columnWidth,
      margin: EdgeInsets.only(right: isLast ? 0 : AppDimens.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 列头：色点 + 名称 + 计数
          Row(
            children: [
              Container(
                width: AppDimens.colorDotSize,
                height: AppDimens.colorDotSize,
                decoration:
                    BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: AppDimens.space8),
              Expanded(
                child: Text(
                  column.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.titleText,
                  ),
                ),
              ),
              Text(
                '${column.tasks.length}',
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space8),
          Expanded(
            child: column.tasks.isEmpty
                ? Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      '暂无任务',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.secondaryText.withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: column.tasks.length,
                    itemBuilder: (context, i) => _card(context, column.tasks[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, TodoTask task) {
    final colors = AppColors.ofContext(context);
    final overdue = isOverdue(task);
    final dots = labelDotsByTask[task.id] ?? const <ProjectedTaskLabel>[];
    final projectTitle = projectTitleOf?.call(task);

    // v3 卡片：描边/圆角/填充下沉 OrbitCard，去掉 v2 的 e1 阴影；
    // OrbitCard padding 归零、内层保留原 Padding——InkWell 水波纹仍盖满整卡
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.space8),
      child: OrbitCard(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: AppShapes.medium,
          onTap: () => onOpen(task),
          onLongPress: () => onLongPress(task),
          child: Padding(
            padding: const EdgeInsets.all(AppDimens.space12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OrbitCheckbox(
                    checked: task.isDone,
                    size: AppDimens.subtaskCheckboxSize,
                    // 优先级由描边环承载（列表行同口径），不再另画色条
                    borderColor: task.priority > 0
                        ? hexToColor(priorityRingHex(task.priority)!)
                        : null,
                    onToggle: () => onToggleDone(task),
                  ),
                  const SizedBox(width: AppDimens.space8),
                  Expanded(
                    child: AnimatedStrikethrough(
                      text: task.title,
                      done: task.isDone,
                      maxLines: 2,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        color: colors.bodyText,
                      ),
                      // 完成态全口径统一：划线 + 置灰一档
                      doneColor: colors.secondaryText,
                    ),
                  ),
                  if (task.isStarred)
                    Icon(
                      OrbitIcons.star,
                      size: AppDimens.iconSizeSm,
                      // 星标统一黄色语义（列表行同源），不再借强调色
                      color: OrbitAccents.starYellow,
                    ),
                ],
              ),
              const SizedBox(height: AppDimens.space8),
              Row(
                children: [
                  if (task.dueDate != null) ...[
                    Icon(
                      OrbitIcons.calendar,
                      size: AppDimens.iconSizeSm - 4,
                      // 逾期红统一 OrbitAccents 口径（任务行/表格/多选行同源）
                      color: overdue
                          ? OrbitAccents.overdueRed
                          : colors.secondaryText,
                    ),
                    const SizedBox(width: AppDimens.space2),
                    Text(
                      formatDueShort(task.dueDate!),
                      style: TextStyle(
                        fontSize: 11,
                        color: overdue
                            ? OrbitAccents.overdueRed
                            : colors.secondaryText,
                      ),
                    ),
                    const SizedBox(width: AppDimens.space8),
                  ],
                  if (dots.isNotEmpty)
                    for (final l in dots.take(4))
                      Padding(
                        padding: const EdgeInsets.only(
                            right: AppDimens.space4),
                        child: Container(
                          width: AppDimens.colorDotSize - 4,
                          height: AppDimens.colorDotSize - 4,
                          decoration: BoxDecoration(
                            color: hexToColor(l.hexColor),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                ],
              ),
              if (projectTitle != null) ...[
                const SizedBox(height: AppDimens.space4),
                Text(
                  projectTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: colors.secondaryText),
                ),
              ],
            ],
            ),
          ),
        ),
      ),
    );
  }
}
