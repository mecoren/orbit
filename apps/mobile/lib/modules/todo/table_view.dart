import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import 'logic/task_logic.dart';

/// 表格视图（对齐桌面 `task-table-view.tsx` 的七列概览）
///
/// 移动端形态取舍：
/// - 桌面七列 `完成 / 标题 / 项目 / 标签 / 截止 / 时长 / 优先级` 在 360dp
///   宽度下放不下七栏文本，故按**权重压缩**：完成（视觉 20，热区 44 盒）、
///   标题 flex 4、项目 flex 2、标签 36（色点列）、截止 76、时长 44——
///   优先级由勾选框描边环承载（2026-09-25 与列表/看板同口径），不再单设
///   色点列，信息不丢且不折行。
/// - 标题列内嵌只读指示（桌面表格行同位置）：星标 / 我的一天（Sunrise）
///   在标题前、子任务进度在标题后；截止列跟随铃铛（提醒存在的信号）。
///   桌面这三处是 hover 浮现的开关钮，移动无 hover、行内也不做微交互，
///   只示态——写入口径留在长按菜单与详情页。
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
    this.remindersByTask = const {},
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

  /// 任务 → 提醒投影（截止列铃铛数据源；投影未就绪时为空，不渲染铃铛）
  final Map<int, List<ProjectedReminder>> remindersByTask;

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
    // 列宽/弹性必须与 [_row] 逐项一致（表头行不参与滚动，漂移即列错位）：
    // 勾选框布局盒是热区下限 `OrbitCheckbox.minHitExtent`（视觉 20 居中），
    // 表头首格必须按**布局盒**占位——按视觉宽 24/20 占位曾致整表列错位约 20px
    return Row(
      children: [
        const SizedBox(width: OrbitCheckbox.minHitExtent),
        const SizedBox(width: AppDimens.space8),
        Expanded(flex: 4, child: Text('标题', style: style)),
        Expanded(flex: 2, child: Text('项目', style: style)),
        // 固定列宽的表头受字号档保护：全局 TextScaler 生效后字号会变，
        // FittedBox 只在放不下时等比缩小，保证任何档位都单行不换列高
        SizedBox(
          width: 36,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Text('标签', style: style),
          ),
        ),
        SizedBox(
          width: 76,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text('截止', style: style),
          ),
        ),
        SizedBox(
          width: 44,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text('时长', style: style),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, TodoTask task) {
    final colors = AppColors.ofContext(context);
    final overdue = isOverdue(task);
    final dots = labelDotsByTask[task.id] ?? const <ProjectedTaskLabel>[];
    final projectTitle = projectTitleOf?.call(task);
    // 行内提醒徽标：未来最近一条 / 全过期最早一条（列表行 displayReminder 同口径）
    final reminder = displayReminder(
      remindersByTask[task.id] ?? const <ProjectedReminder>[],
      DateTime.now().millisecondsSinceEpoch,
      taskDone: task.isDone,
    );
    final pct = task.percentDone;

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
            OrbitCheckbox(
              checked: task.isDone,
              size: AppDimens.taskCheckboxSize,
              // 优先级由描边环承载（列表行/看板卡同口径），不再另立方点列
              borderColor: task.priority > 0
                  ? hexToColor(priorityRingHex(task.priority)!)
                  : null,
              onToggle: () => onToggleDone(task),
            ),
            const SizedBox(width: AppDimens.space8),
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  // 星标 / 我的一天：只读指示（桌面表格行同位但为 hover 开关，
                  // 移动无 hover，写入留在长按菜单/详情，行内只示态）
                  if (task.isStarred) ...[
                    Icon(OrbitIcons.star,
                        size: 11, color: OrbitAccents.starYellow),
                    const SizedBox(width: AppDimens.space2),
                  ],
                  if (task.isInMyDay) ...[
                    Icon(OrbitIcons.sunrise,
                        size: 11, color: OrbitAccents.myDayAmber),
                    const SizedBox(width: AppDimens.space2),
                  ],
                  Flexible(
                    child: AnimatedStrikethrough(
                      text: task.title,
                      done: task.isDone,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.bodyText,
                      ),
                      // 完成态全口径统一：划线 + 置灰一档
                      doneColor: colors.secondaryText,
                    ),
                  ),
                  // 子任务进度（percent_done 0/100 不显示，桌面表格同口径）
                  if (pct > 0 && pct < 100) ...[
                    const SizedBox(width: AppDimens.space4),
                    Text(
                      '${pct.round()}%',
                      style: TextStyle(
                          fontSize: 11, color: colors.secondaryText),
                    ),
                  ],
                ],
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
              width: 76,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(
                      task.dueDate == null
                          ? '—'
                          : formatDueShort(task.dueDate!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 11,
                        // 逾期红统一 OrbitAccents 口径（任务行/看板/多选行同源）
                        color: overdue
                            ? OrbitAccents.overdueRed
                            : colors.secondaryText,
                      ),
                    ),
                  ),
                  // 提醒信号（桌面截止列尾 ReminderChip；76px 格放不下 HH:mm，
                  // 只落铃铛，时刻在列表/看板/详情可读）
                  if (reminder != null) ...[
                    const SizedBox(width: AppDimens.space2),
                    Icon(
                      OrbitIcons.notification,
                      size: 11,
                      color: reminder.fired
                          ? OrbitAccents.overdueRed
                          : colors.secondaryText,
                    ),
                  ],
                ],
              ),
            ),
            // 时长列（对齐桌面 task-table-view；未设置显示占位保持列对齐）
            SizedBox(
              width: 44,
              child: Text(
                formatDurationMinutes(task.durationMinutes) ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, color: colors.secondaryText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
