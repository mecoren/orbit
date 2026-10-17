import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/orbit_accents.dart';
import '../../../data/api/dto.dart';
import '../../../data/providers/bridge_provider.dart';
import '../../../shared/utils/hex_color.dart';
import '../../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../../shared/widgets/shadcn/orbit_checkbox.dart';
import '../../../core/theme/icon_map.dart';
import '../../../shared/widgets/shadcn/orbit_date_picker.dart';
import '../../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../../shared/widgets/shadcn/orbit_toast.dart';
import '../../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../form_bottom_sheet.dart';
import 'task_logic.dart';
import '../providers/todo_providers.dart';

/// 长按菜单「自定义时间…」哨兵（毫秒字符串空间不会撞）
const String menuReminderCustomKey = 'custom';

/// 任务长按操作抽屉（共享层：列表 / 看板 / 表格 / 矩阵 / 日历共用一套）。
///
/// 与桌面 `task-context-menu.tsx` 逐项对齐：日期 / 优先级 / 多选 / 标记完成 /
/// 编辑 / 我的一天 / 收藏 / 复制任务 / 更换项目 / 设置提醒 / 添加评论 /
/// 修改标签 / 删除。桌面右键菜单在移动端统一映射为底部抽屉（AGENTS
/// 「选择类/确认类交互统一底部抽屉」口径）。
///
/// 三个可覆写回调——列表档有本地专属语义（删除带 5s 撤销 + ghost 退场、
/// 完成走离场播退场），传入即覆盖共享层的默认实现；日历等只读行不传，
/// 走共享层默认（普通写库 + onChanged 刷新）。
Future<void> showTaskActionSheet(
  BuildContext context,
  WidgetRef ref, {
  required TodoTask task,
  required VoidCallback onChanged,
  VoidCallback? onEnterSelection,
  VoidCallback? onToggleDone,
  VoidCallback? onDelete,
}) {
  final bridge = ref.read(orbitBridgeProvider);

  Future<void> patch(Map<String, Object?> p, {String fail = '更新失败'}) async {
    try {
      await bridge.todoTaskUpdate(task.id, encodePatch(p));
      onChanged();
    } catch (_) {
      if (context.mounted) WaitToast.destructive(fail);
    }
  }

  void toggleDone() {
    final override = onToggleDone;
    if (override != null) {
      override();
      return;
    }
    () async {
      try {
        if (task.isDone) {
          await bridge.todoTaskUpdate(
              task.id, encodePatch(buildDoneTogglePatch(task)));
        } else {
          // 完成走单事务推进重复任务下一实例（与勾选同口径）
          await bridge.todoTaskComplete(task.id);
        }
        onChanged();
      } catch (_) {
        if (context.mounted) WaitToast.destructive('操作失败');
      }
    }();
  }

  void toggleFavorite() =>
      patch(buildFavoriteTogglePatch(task), fail: '操作失败');

  void toggleMyDay() =>
      patch(buildMyDayTogglePatch(task), fail: '操作失败');

  void duplicate() async {
    try {
      final copy = await bridge.todoTaskDuplicate(task.id);
      if (context.mounted) WaitToast.success('已复制为「${copy.title}」');
    } catch (_) {
      if (context.mounted) WaitToast.destructive('复制失败');
    }
  }

  void delete() {
    final override = onDelete;
    if (override != null) {
      override();
      return;
    }
    () async {
      final confirmed = await showConfirmBottomSheet(
        context,
        title: '删除任务',
        message: '确定要删除「${task.title}」吗？删除后可在回收站恢复。',
        confirmLabel: '删除',
        destructive: true,
      );
      if (!confirmed) return;
      try {
        await bridge.todoTaskDelete(task.id);
        onChanged();
        if (context.mounted) WaitToast.success('已删除 1 个任务');
      } catch (_) {
        if (context.mounted) WaitToast.destructive('删除失败');
      }
    }();
  }

  return showMoreActionsSheet(
    context,
    title: task.title,
    actions: [
      MoreActionItem(
        icon: OrbitIcons.calendarDays,
        label: '日期',
        onTap: () => _pickDue(context, ref, task, patch),
      ),
      MoreActionItem(
        icon: OrbitIcons.flag,
        label: '优先级',
        onTap: () => _pickPriority(context, task, patch),
      ),
      if (onEnterSelection != null)
        MoreActionItem(
          icon: OrbitIcons.listChecks,
          label: '多选',
          onTap: onEnterSelection,
        ),
      MoreActionItem(
        icon: task.isDone ? OrbitIcons.undo : OrbitIcons.success,
        label: task.isDone ? '标记未完成' : '标记完成',
        onTap: toggleDone,
      ),
      MoreActionItem(
        icon: OrbitIcons.edit,
        label: '编辑',
        onTap: () => showTodoFormSheet(context, editingTaskId: task.id),
      ),
      MoreActionItem(
        icon: OrbitIcons.sun,
        label: task.isInMyDay ? '移出我的一天' : '加入我的一天',
        color: OrbitAccents.myDayAmber,
        onTap: toggleMyDay,
      ),
      MoreActionItem(
        icon: OrbitIcons.star,
        label: task.isStarred ? '取消收藏' : '收藏',
        color: OrbitAccents.starYellow,
        onTap: toggleFavorite,
      ),
      MoreActionItem(
        icon: OrbitIcons.copy,
        label: '复制任务',
        onTap: duplicate,
      ),
      MoreActionItem(
        icon: OrbitIcons.folder,
        label: '更换项目',
        onTap: () => _pickProject(context, ref, task, patch),
      ),
      MoreActionItem(
        icon: OrbitIcons.notification,
        label: '设置提醒',
        onTap: () => _addReminder(context, ref, task, onChanged),
      ),
      MoreActionItem(
        icon: OrbitIcons.message,
        label: '添加评论',
        onTap: () => _addComment(context, ref, task, onChanged),
      ),
      MoreActionItem(
        icon: OrbitIcons.tag,
        label: '修改标签',
        onTap: () => _editLabels(context, ref, task, onChanged),
      ),
      MoreActionItem(
        icon: OrbitIcons.delete,
        label: '删除',
        color: OrbitAccents.overdueRed,
        onTap: delete,
      ),
    ],
  );
}

/// 日期快捷档（对齐桌面任务菜单日期图标行）：一小时后 / 今晚 / 明天 / 下周 +
/// 选择日期和时间 + 清除截止（已有截止时）
Future<void> _pickDue(
  BuildContext context,
  WidgetRef ref,
  TodoTask task,
  Future<void> Function(Map<String, Object?>, {String fail}) patch,
) async {
  final options = quickDateTimeOptions();
  await showSelectBottomSheet<String>(
    context,
    title: '设置截止时间',
    items: [
      for (final o in options)
        SelectItem(
            value: o.key, label: o.label, hint: o.hint, icon: dueQuickIcon(o.key)),
      const SelectItem(
          value: 'custom', label: '选择日期和时间', icon: OrbitIcons.calendarDays),
      if (task.dueDate != null)
        const SelectItem(
            value: 'clear', label: '清除截止', icon: OrbitIcons.calendarBlocked),
    ],
    onSelect: (v) async {
      if (v == 'custom') {
        final picked = await OrbitDatePicker.pick(
          context,
          initialDate: task.dueDate != null
              ? DateTime.fromMillisecondsSinceEpoch(task.dueDate!)
              : null,
          showTime: true,
        );
        if (picked != null) {
          await patch({'due_date': picked.millisecondsSinceEpoch},
              fail: '设置截止失败');
        }
        return;
      }
      if (v == 'clear') {
        await patch({'due_date': null}, fail: '清除失败');
        return;
      }
      final o = options.firstWhere((x) => x.key == v);
      await patch({'due_date': o.ms}, fail: '设置截止失败');
    },
  );
}

/// 优先级六档色点（对齐桌面任务菜单优先级图标行）
Future<void> _pickPriority(
  BuildContext context,
  TodoTask task,
  Future<void> Function(Map<String, Object?>, {String fail}) patch,
) async {
  await showSelectBottomSheet<int>(
    context,
    title: '设置优先级',
    current: task.priority,
    items: [
      for (var p = 0; p <= 5; p++)
        SelectItem(
            value: p,
            label: priorityLabel(p),
            colorDot: hexToColor(priorityColorHex(p))),
    ],
    onSelect: (p) => patch({'priority': p}, fail: '设置优先级失败'),
  );
}

/// 更换项目（未分组 + 各项目，当前项打勾）
Future<void> _pickProject(
  BuildContext context,
  WidgetRef ref,
  TodoTask task,
  Future<void> Function(Map<String, Object?>, {String fail}) patch,
) async {
  final projects = ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
  await showSelectBottomSheet<int?>(
    context,
    title: '更换项目',
    current: task.projectId,
    items: [
      const SelectItem<int?>(value: null, label: '未分组'),
      for (final p in projects)
        SelectItem<int?>(
            value: p.id, label: p.title, colorDot: hexToColor(p.hexColor)),
    ],
    onSelect: (id) => patch({'project_id': id}, fail: '更换项目失败'),
  );
}

/// 设置提醒：相对档快捷 + 自定义时间
Future<void> _addReminder(
  BuildContext context,
  WidgetRef ref,
  TodoTask task,
  VoidCallback onChanged,
) async {
  await showSelectBottomSheet<String>(
    context,
    title: '提醒时间',
    items: [
      for (final p in reminderPresets(
        dueDate: task.dueDate,
        startDate: task.startDate,
        durationMinutes: task.durationMinutes,
      ))
        SelectItem<String>(value: '${p.ms}', label: p.label),
      const SelectItem<String>(
          value: menuReminderCustomKey, label: '自定义时间…'),
    ],
    onSelect: (v) async {
      int? ms;
      if (v == menuReminderCustomKey) {
        final picked = await OrbitDatePicker.pick(
          context,
          initialDate: DateTime.now().add(const Duration(hours: 1)),
          showTime: true,
          accent: OrbitAccents.todoAccent,
        );
        ms = picked?.millisecondsSinceEpoch;
      } else {
        ms = int.parse(v);
      }
      if (ms == null) return;
      try {
        await ref.read(orbitBridgeProvider).todoReminderCreate(
            TodoReminderCreateInput(taskId: task.id, remindAt: ms));
        ref.invalidate(taskRemindersProjectionProvider);
        ref.invalidate(taskDetailProvider(task.id));
        onChanged();
        if (context.mounted) WaitToast.success('提醒已创建');
      } catch (_) {
        if (context.mounted) WaitToast.destructive('设置提醒失败');
      }
    },
  );
}

/// 添加评论：输入型底部抽屉（onChanged 取值，无 controller 生命周期负担）
Future<void> _addComment(
  BuildContext context,
  WidgetRef ref,
  TodoTask task,
  VoidCallback onChanged,
) async {
  final colors = AppColors.ofContext(context);
  String draft = '';
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: colors.popup,
    shape: bottomSheetTopShape,
    builder: (sheetCtx) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetCtx).bottom),
      child: OrbitSheetScaffold(
        title: '添加评论',
        contentPadding: const EdgeInsets.fromLTRB(
            AppDimens.space16, 0, AppDimens.space16, AppDimens.space16),
        content: TextField(
          onChanged: (v) => draft = v,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(hintText: '输入评论...'),
        ),
        actions: OrbitSheetActions(
          confirmLabel: '保存',
          onConfirm: () => Navigator.pop(sheetCtx),
          cancelLabel: '取消',
          onCancel: () => Navigator.pop(sheetCtx),
        ),
      ),
    ),
  );
  final content = draft.trim();
  if (content.isEmpty) return;
  try {
    await ref.read(orbitBridgeProvider).todoCommentCreate(
        TodoCommentCreateInput(taskId: task.id, content: content));
    ref.invalidate(taskDetailProvider(task.id));
    onChanged();
    if (context.mounted) WaitToast.success('评论已添加');
  } catch (_) {
    if (context.mounted) WaitToast.destructive('添加评论失败');
  }
}

/// 修改标签：多选抽屉（勾选即建/删关联，抽屉不关可连选）
Future<void> _editLabels(
  BuildContext context,
  WidgetRef ref,
  TodoTask task,
  VoidCallback onChanged,
) async {
  final bridge = ref.read(orbitBridgeProvider);
  Map<int, int> linked;
  try {
    final detail = await ref.read(taskDetailProvider(task.id).future);
    linked = {for (final l in detail.labels) l.id: l.taskLabelId};
  } catch (_) {
    if (context.mounted) WaitToast.destructive('标签加载失败');
    return;
  }
  var labels = ref.read(todoLabelsProvider).value ?? const <TodoLabel>[];
  if (labels.isEmpty) {
    try {
      labels = await ref.read(todoLabelsProvider.future);
    } catch (_) {
      labels = const <TodoLabel>[];
    }
  }
  if (labels.isEmpty) {
    if (context.mounted) {
      WaitToast.info('还没有标签，可在设置 → 标签管理中新建');
    }
    return;
  }
  if (!context.mounted) return;
  final colors = AppColors.ofContext(context);
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: colors.popup,
    shape: bottomSheetTopShape,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (ctx, setSheet) => OrbitSheetScaffold(
        title: '修改标签',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final label in labels)
              InkWell(
                onTap: () async {
                  final linkId = linked[label.id];
                  try {
                    if (linkId != null) {
                      await bridge.todoTaskLabelDelete(linkId);
                      setSheet(() => linked.remove(label.id));
                    } else {
                      final row = await bridge.todoTaskLabelCreate(
                          TodoTaskLabelCreateInput(
                              taskId: task.id, labelId: label.id));
                      setSheet(() => linked[label.id] = row.taskLabelId);
                    }
                    ref.invalidate(taskLabelsProjectionProvider);
                    ref.invalidate(taskDetailProvider(task.id));
                    onChanged();
                  } catch (_) {
                    if (ctx.mounted) WaitToast.destructive('操作失败');
                  }
                },
                child: SizedBox(
                  height: AppDimens.touchTarget,
                  child: Row(
                    children: [
                      const SizedBox(width: AppDimens.space16),
                      OrbitCheckbox(
                        checked: linked.containsKey(label.id),
                        size: AppDimens.iconSizeMd + 2,
                        onToggle: () {},
                      ),
                      const SizedBox(width: AppDimens.space12),
                      Container(
                        width: AppDimens.colorDotSize,
                        height: AppDimens.colorDotSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: hexToColor(label.hexColor),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space8),
                      Expanded(
                        child: Text(
                          label.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(fontSize: 15, color: colors.bodyText),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
