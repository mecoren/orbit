import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../data/api/dto.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import 'logic/task_logic.dart';

/// 表格视图（对齐桌面 `task-table-view.tsx` 的六列概览）
///
/// 移动端形态取舍：
/// - 桌面六列 `完成 / 标题 / 项目 / 标签 / 截止 / 优先级` 在 360dp 宽度下
///   放不下六栏文本，故按**权重压缩**：完成 24、标题 flex 3、项目 flex 2、
///   标签 36（色点列）、截止 64、优先级 28（色点列）——色点列替代文本列，
///   信息不丢且不折行。
/// - 不做表内编辑（桌面同样无表内编辑），点行开详情、长按弹操作菜单。
/// - `ListView.builder` 惰性构建，不引入虚拟化库。
class TaskTableView extends StatelessWidget {
  const TaskTableView({
    super.key,
    required this.tasks,
    required this.padding,
    required this.onToggleDone,
    required this.onOpen,
    required this.onLongPress,
    this.projectTitleOf,
    this.labelDotsByTask = const {},
  });

  final List<TodoTask> tasks;
  final EdgeInsets padding;
  final ValueChanged<TodoTask> onToggleDone;
  final ValueChanged<TodoTask> onOpen;
  final ValueChanged<TodoTask> onLongPress;

  /// 项目名取用口（未分组返回 null → 渲染「—」）
  final String? Function(TodoTask)? projectTitleOf;

  /// 任务 → 标签色点（投影未就绪时为空）
  final Map<int, List<ProjectedTaskLabel>> labelDotsByTask;

  /// 表头行高
  static const double headerHeight = 32;

  /// 数据行高（与列表档 56 对齐，保证触控热区）
  static const double rowHeight = 56;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            top: padding.top,
            left: padding.left + AppDimens.space12,
            right: padding.right + AppDimens.space12,
          ),
          child: SizedBox(height: headerHeight, child: _headerRow(colors)),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.only(
              left: padding.left,
              right: padding.right,
              bottom: padding.bottom,
            ),
            itemCount: tasks.length,
            itemBuilder: (context, index) => _row(context, tasks[index]),
          ),
        ),
      ],
    );
  }

  Widget _headerRow(AppColorSet colors) {
    final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: colors.secondaryText,
    );
    return Row(
      children: [
        const SizedBox(width: 24),
        const SizedBox(width: AppDimens.space8),
        Expanded(flex: 3, child: Text('标题', style: style)),
        Expanded(flex: 2, child: Text('项目', style: style)),
        SizedBox(
            width: 36, child: Text('标签', style: style, textAlign: TextAlign.center)),
        SizedBox(
            width: 64, child: Text('截止', style: style, textAlign: TextAlign.right)),
        SizedBox(
            width: 28,
            child: Text('优先级', style: style, textAlign: TextAlign.right)),
      ],
    );
  }

  Widget _row(BuildContext context, TodoTask task) {
    final colors = AppColors.ofContext(context);
    final overdue = isOverdue(task);
    final dots = labelDotsByTask[task.id] ?? const <ProjectedTaskLabel>[];
    final projectTitle = projectTitleOf?.call(task);

    return InkWell(
      onTap: () => onOpen(task),
      onLongPress: () => onLongPress(task),
      child: Container(
        height: rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: colors.divider),
          ),
        ),
        child: Row(
          children: [
            CircleCheckbox(
              checked: task.isDone,
              size: AppDimens.subtaskCheckboxSize,
              onToggle: () => onToggleDone(task),
            ),
            const SizedBox(width: AppDimens.space8),
            Expanded(
              flex: 3,
              child: AnimatedStrikethrough(
                text: task.title,
                done: task.isDone,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  color: colors.bodyText,
                ),
                doneColor: colors.bodyText,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                projectTitle ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
            ),
            SizedBox(
              width: 36,
              child: Center(
                child: dots.isEmpty
                    ? Text('—',
                        style:
                            TextStyle(fontSize: 12, color: colors.secondaryText))
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final l in dots.take(2))
                            Padding(
                              padding: const EdgeInsets.only(
                                  right: AppDimens.space2),
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
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                task.dueDate == null ? '—' : formatYmd(task.dueDate!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 11,
                  color: overdue ? colors.destructive : colors.secondaryText,
                ),
              ),
            ),
            SizedBox(
              width: 28,
              child: Align(
                alignment: Alignment.centerRight,
                child: Container(
                  width: AppDimens.colorDotSize,
                  height: AppDimens.colorDotSize,
                  decoration: BoxDecoration(
                    color: hexToColor(priorityColorHex(task.priority)),
                    borderRadius: AppShapes.small,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
