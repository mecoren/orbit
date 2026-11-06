import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_bottom_nav.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_dropdown_preference.dart';
import '../../shared/widgets/shadcn/orbit_text_field.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_date_picker.dart';
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_spinner.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../shared/widgets/shadcn/orbit_icon_button.dart';
import 'logic/task_logic.dart';
import '../../shared/utils/hex_color.dart';
import 'providers/todo_providers.dart';
import '../../core/theme/icon_map.dart';

/// 保存的筛选器页 /todo/saved-filters（#35：Apple Smart List 同款）
///
/// 列表（名称 + 条件摘要 + 命中数）+ 底部新建（名称 + 条件 JSON）+ 长按删除。
/// 条件应用在行内展开即时预览（不走独立路由——移动端轻量消费形态）。
///
/// [initialConditions]：入页即弹构建抽屉并预填该条件（列表面板「保存为筛选器」
/// 把当前筛选映射进来，G1，镜像桌面 `saved-filter-dialog` 预填链）。
class SavedFiltersScreen extends ConsumerStatefulWidget {
  const SavedFiltersScreen({super.key, this.initialConditions});

  final Map<String, dynamic>? initialConditions;

  @override
  ConsumerState<SavedFiltersScreen> createState() => _SavedFiltersScreenState();
}

class _SavedFiltersScreenState extends ConsumerState<SavedFiltersScreen> {
  final _scrollController = ScrollController();
  // 行展开态：当前展开预览的筛选器 id（null = 全收起）
  int? _expandedId;

  @override
  void initState() {
    super.initState();
    // 「保存为筛选器」预填：首帧后弹构建抽屉（等本页数据骨架就位再叠加弹层）
    final prefill = widget.initialConditions;
    if (prefill != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openBuilder(initialConditions: prefill);
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 筛选条件多选抽屉（项目/标签按名称勾选；返回 null = 取消）
  Future<Set<int>?> _pickFilterIds(
    BuildContext context, {
    required String title,
    required List<({int id, String title, String hexColor})> items,
    required Set<int> selected,
  }) async {
    if (items.isEmpty) {
      WaitToast.info('暂无可选项');
      return null;
    }
    final colors = AppColors.ofContext(context);
    final picked = {...selected};
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => OrbitSheetScaffold(
          title: title,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                InkWell(
                  onTap: () => setSheet(() {
                    picked.contains(item.id)
                        ? picked.remove(item.id)
                        : picked.add(item.id);
                  }),
                  child: SizedBox(
                    height: AppDimens.touchTarget,
                    child: Row(
                      children: [
                        Icon(
                          picked.contains(item.id)
                              ? OrbitIcons.success
                              : OrbitIcons.circle,
                          size: AppDimens.iconSizeMd,
                          color: picked.contains(item.id)
                              ? OrbitAccents.todoAccent
                              : colors.secondaryText,
                        ),
                        const SizedBox(width: AppDimens.space12),
                        Container(
                          width: AppDimens.colorDotSize,
                          height: AppDimens.colorDotSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: hexToColor(item.hexColor),
                          ),
                        ),
                        const SizedBox(width: AppDimens.space8),
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: colors.bodyText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          actions: OrbitSheetActions(
            cancelLabel: '取消',
            onCancel: () => Navigator.pop(sheetCtx),
            confirmLabel: '确定',
            onConfirm: () => Navigator.pop(sheetCtx, true),
          ),
        ),
      ),
    );
    if (confirmed != true) return null;
    return picked;
  }

  /// 十四键可视化构建抽屉（新建 + 更新共用；替代手写条件文本框）
  ///
  /// 十四键：status / priority_min / project_ids / label_ids /
  /// due_within_days / due_overdue / favorite_only / due_from / due_until /
  /// created_from / done_from / has_reminder / has_attachment /
  /// has_open_subtask。仅收纳已设置键，未设置键不写入 JSON
  /// （与桌面白名单校验口径一致）。
  ///
  /// [initialConditions]：预填条件（「保存为筛选器」把面板当前筛选映射进来，
  /// 与桌面 `toolbarToForm` 预填链同语义）；与 [existing] 互斥（编辑态忽略）。
  Future<void> _openBuilder({
    TodoSavedFilter? existing,
    Map<String, dynamic>? initialConditions,
  }) async {
    final nameCtl = TextEditingController(text: existing?.name ?? '');
    Map<String, dynamic> init = {};
    try {
      if (existing != null) {
        init = jsonDecode(existing.conditions) as Map<String, dynamic>;
      } else if (initialConditions != null) {
        init = initialConditions;
      }
    } catch (_) {}
    String? status = init['status'] as String?;
    int priorityMin = (init['priority_min'] as num?)?.toInt() ?? 0;
    List<TodoProject> projects = const [];
    List<TodoLabel> labels = const [];
    try {
      projects = await ref.read(todoProjectsProvider.future);
      labels = await ref.read(todoLabelsProvider.future);
    } catch (_) {}
    final projectIds = <int>{
      for (final v in (init['project_ids'] as List? ?? const []))
        if (v is num) v.toInt(),
    };
    final labelIds = <int>{
      for (final v in (init['label_ids'] as List? ?? const []))
        if (v is num) v.toInt(),
    };
    final withinCtl = TextEditingController(
      text: init['due_within_days']?.toString() ?? '',
    );
    bool overdue = init['due_overdue'] == true;
    bool favorite = init['favorite_only'] == true;
    int? dueFrom = (init['due_from'] as num?)?.toInt();
    int? dueUntil = (init['due_until'] as num?)?.toInt();
    int? createdFrom = (init['created_from'] as num?)?.toInt();
    int? doneFrom = (init['done_from'] as num?)?.toInt();
    bool? hasReminder = init['has_reminder'] as bool?;
    bool? hasAttachment = init['has_attachment'] as bool?;
    bool? hasOpenSubtask = init['has_open_subtask'] as bool?;

    String idsSummary(Set<int> ids, List<({int id, String title})> all) {
      if (ids.isEmpty) return '不限';
      final names = [
        for (final item in all)
          if (ids.contains(item.id)) item.title,
      ];
      return names.isEmpty ? '已选 ${ids.length} 项' : names.join('、');
    }

    if (!mounted) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => OrbitSheetScaffold(
          title: existing == null ? '新建筛选器' : '编辑筛选器',
          contentPadding: const EdgeInsets.fromLTRB(
            AppDimens.space16,
            0,
            AppDimens.space16,
            AppDimens.space16,
          ),
          // 表单滚动、底部按钮固定（长表单不再把「创建」顶出可视区）
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OrbitTextField(controller: nameCtl, label: '名称（如：本周 P0）'),
              const SizedBox(height: AppDimens.space12),
              // 状态 / 优先级走设置页同款下拉偏好行：行内常驻当前档 +
              // 上下双箭头，点行就地展开玻璃菜单。抽屉已有 16 水平内边距，
              // 行自身取 0 水平内边距与上方名称字段同线
              OrbitDropdownPreference<String?>(
                title: '状态',
                items: const [
                  SelectItem(value: null, label: '全部状态'),
                  SelectItem(value: 'pending', label: '待办'),
                  SelectItem(value: 'doing', label: '进行中'),
                  SelectItem(value: 'done', label: '已完成'),
                ],
                current: status,
                insideMargin: const EdgeInsets.symmetric(
                  vertical: AppDimens.space8,
                ),
                onSelect: (v) => setSheet(() => status = v),
              ),
              OrbitDropdownPreference<int>(
                title: '优先级',
                items: const [
                  SelectItem(value: 0, label: '全部优先级'),
                  SelectItem(value: 1, label: 'P1 及以上'),
                  SelectItem(value: 2, label: 'P2 及以上'),
                  SelectItem(value: 3, label: 'P3 及以上'),
                  SelectItem(value: 4, label: 'P4 及以上'),
                  SelectItem(value: 5, label: '仅 P5'),
                ],
                current: priorityMin,
                insideMargin: const EdgeInsets.symmetric(
                  vertical: AppDimens.space8,
                ),
                onSelect: (v) => setSheet(() => priorityMin = v),
              ),
              OrbitTextField(
                controller: withinCtl,
                keyboardType: TextInputType.number,
                label: '天内截止（留空不限，如 7）',
              ),
              // 截止区间（绝对日期；与「天内截止/已逾期」叠加恒无命中——
              // 桌面构建器在 UI 层互斥，此处靠条件摘要人工核对）
              // 行标题用白话「晚于 / 早于」，不再往标题里塞 ≥ / ＜ 这类
              // 尖括号样符号（2026-11-06 反馈：标题里不要加括号之类的记法）。
              // 用词对齐桌面构建器（那里就是「创建晚于 / 完成晚于」）
              _FilterDateRow(
                label: '截止晚于',
                value: dueFrom,
                onPick: (v) => setSheet(() => dueFrom = v),
              ),
              _FilterDateRow(
                label: '截止早于',
                value: dueUntil,
                onPick: (v) => setSheet(() => dueUntil = v),
              ),
              _FilterDateRow(
                label: '创建晚于',
                value: createdFrom,
                onPick: (v) => setSheet(() => createdFrom = v),
              ),
              _FilterDateRow(
                label: '完成晚于',
                value: doneFrom,
                onPick: (v) => setSheet(() => doneFrom = v),
              ),
              // 项目 / 标签：按名称多选（对齐桌面 chips 选择器；原裸 id 文本框
              // 要求用户自己查数据库 id，移动端不可用）。行样式与上方状态 /
              // 优先级下拉偏好行同款（标题 + 尾随当前值 + 上下双箭头）
              _FilterConditionRow(
                label: '项目',
                summary: idsSummary(projectIds, [
                  for (final p in projects) (id: p.id, title: p.title),
                ]),
                onTap: () async {
                  final picked = await _pickFilterIds(
                    ctx,
                    title: '筛选项目',
                    items: [
                      for (final p in projects)
                        (id: p.id, title: p.title, hexColor: p.hexColor),
                    ],
                    selected: projectIds,
                  );
                  if (picked == null) return;
                  setSheet(() {
                    projectIds
                      ..clear()
                      ..addAll(picked);
                  });
                },
              ),
              _FilterConditionRow(
                label: '标签',
                summary: idsSummary(labelIds, [
                  for (final l in labels) (id: l.id, title: l.title),
                ]),
                onTap: () async {
                  final picked = await _pickFilterIds(
                    ctx,
                    title: '筛选标签',
                    items: [
                      for (final l in labels)
                        (id: l.id, title: l.title, hexColor: l.hexColor),
                    ],
                    selected: labelIds,
                  );
                  if (picked == null) return;
                  setSheet(() {
                    labelIds
                      ..clear()
                      ..addAll(picked);
                  });
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('仅已逾期'),
                value: overdue,
                onChanged: (v) => setSheet(() => overdue = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('仅收藏'),
                value: favorite,
                onChanged: (v) => setSheet(() => favorite = v),
              ),
              // 三态筛选（不限 / 仅有 / 仅无）走设置页同款下拉偏好行：
              // 行内常驻当前档 + 上下双箭头，点行就地展开玻璃菜单——与上方
              // 状态 / 优先级同款，不再用「值 + 右箭头」的旧行样式
              OrbitDropdownPreference<bool?>(
                title: '提醒',
                items: const [
                  SelectItem(value: null, label: '不限'),
                  SelectItem(value: true, label: '仅有'),
                  SelectItem(value: false, label: '仅无'),
                ],
                current: hasReminder,
                insideMargin: const EdgeInsets.symmetric(
                  vertical: AppDimens.space8,
                ),
                onSelect: (v) => setSheet(() => hasReminder = v),
              ),
              OrbitDropdownPreference<bool?>(
                title: '附件',
                items: const [
                  SelectItem(value: null, label: '不限'),
                  SelectItem(value: true, label: '仅有'),
                  SelectItem(value: false, label: '仅无'),
                ],
                current: hasAttachment,
                insideMargin: const EdgeInsets.symmetric(
                  vertical: AppDimens.space8,
                ),
                onSelect: (v) => setSheet(() => hasAttachment = v),
              ),
              OrbitDropdownPreference<bool?>(
                title: '未完成子任务',
                items: const [
                  SelectItem(value: null, label: '不限'),
                  SelectItem(value: true, label: '仅有'),
                  SelectItem(value: false, label: '仅无'),
                ],
                current: hasOpenSubtask,
                insideMargin: const EdgeInsets.symmetric(
                  vertical: AppDimens.space8,
                ),
                onSelect: (v) => setSheet(() => hasOpenSubtask = v),
              ),
            ],
          ),
          actions: OrbitSheetActions(
            cancelLabel: '取消',
            onCancel: () => Navigator.pop(sheetCtx),
            confirmLabel: existing == null ? '创建' : '保存修改',
            onConfirm: () => Navigator.pop(sheetCtx, true),
          ),
        ),
      ),
    );
    if (saved != true) return;
    final name = nameCtl.text.trim();
    if (name.isEmpty) {
      if (mounted) WaitToast.destructive('名称不能为空');
      return;
    }
    final cond = <String, dynamic>{};
    if (status != null) cond['status'] = status;
    if (priorityMin > 0) cond['priority_min'] = priorityMin;
    final pids = projectIds.isEmpty ? null : projectIds.toList();
    if (pids != null) cond['project_ids'] = pids;
    final lids = labelIds.isEmpty ? null : labelIds.toList();
    if (lids != null) cond['label_ids'] = lids;
    final within = int.tryParse(withinCtl.text.trim());
    // 日期互斥：截止区间与「天内截止/已逾期」叠加恒无命中——区间优先，
    // 窗口与逾期不落键（桌面构建器在 UI 层互斥，此处在组装处收敛，
    // 条件摘要即最终口径）。创建/完成下限与其他维度正交，不参与互斥。
    final hasRange = dueFrom != null || dueUntil != null;
    if (dueFrom != null) cond['due_from'] = dueFrom;
    if (dueUntil != null) cond['due_until'] = dueUntil;
    if (!hasRange) {
      if (within != null && within > 0) cond['due_within_days'] = within;
      if (overdue) cond['due_overdue'] = true;
    }
    if (createdFrom != null) cond['created_from'] = createdFrom;
    if (doneFrom != null) cond['done_from'] = doneFrom;
    if (hasReminder != null) cond['has_reminder'] = hasReminder;
    if (hasAttachment != null) cond['has_attachment'] = hasAttachment;
    if (hasOpenSubtask != null) cond['has_open_subtask'] = hasOpenSubtask;
    if (favorite) cond['favorite_only'] = true;
    try {
      final bridge = ref.read(orbitBridgeProvider);
      if (existing == null) {
        await bridge.savedFilterCreate(name, jsonEncode(cond));
        if (mounted) WaitToast.success('已创建筛选器');
      } else {
        await bridge.savedFilterUpdate(existing.id, name, jsonEncode(cond));
        if (mounted) WaitToast.success('已更新筛选器');
      }
    } catch (e) {
      if (mounted) WaitToast.destructive('保存失败：$e');
    }
  }

  Future<void> _create() => _openBuilder();

  Future<void> _delete(TodoSavedFilter f) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '删除筛选器',
      message: '确定要删除「${f.name}」吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    await ref.read(orbitBridgeProvider).savedFilterDelete(f.id);
  }

  /// 条件摘要（key → 中文短语的顺序展示）
  String _condSummary(String raw) {
    try {
      final c = jsonDecode(raw) as Map<String, dynamic>;
      const labels = {
        'status': '状态',
        'priority_min': '优先级≥',
        'project_ids': '项目',
        'label_ids': '标签',
        'due_within_days': '天内截止',
        'due_overdue': '已逾期',
        'favorite_only': '仅收藏',
      };
      const dateLabels = {
        'due_from': '截止晚于',
        'due_until': '截止早于',
        'created_from': '创建晚于',
        'done_from': '完成晚于',
      };
      const triLabels = {
        'has_reminder': ('有提醒', '无提醒'),
        'has_attachment': ('有附件', '无附件'),
        'has_open_subtask': ('有未完子任务', '无未完子任务'),
      };
      final parts = <String>[];
      for (final e in labels.entries) {
        if (c.containsKey(e.key)) {
          final v = c[e.key];
          parts.add(v == true ? e.value : '$e.value$v');
        }
      }
      for (final e in dateLabels.entries) {
        if (c.containsKey(e.key)) {
          final ms = (c[e.key] as num).toInt();
          // 标签已是「截止晚于」这类动宾短语，与日期之间留一空格，
          // 免得读成「截止晚于2026-11-06」一长串
          parts.add(
            '${e.value} ${OrbitDatePicker.formatDate(DateTime.fromMillisecondsSinceEpoch(ms))}',
          );
        }
      }
      for (final e in triLabels.entries) {
        if (c.containsKey(e.key)) {
          parts.add(c[e.key] == true ? e.value.$1 : e.value.$2);
        }
      }
      return parts.isEmpty ? '无条件' : parts.join(' · ');
    } catch (_) {
      return '条件无效';
    }
  }

  /// 应用条件到任务（委托 [applySavedFilterConditions] 纯函数；
  /// 标签与存在集由调用方按投影拼装传入，与桌面同口径）
  List<TodoTask> _apply(
    List<TodoTask> tasks,
    String raw, {
    Map<int, Set<int>>? labelIdsByTask,
    Set<int>? reminderTaskIds,
    Set<int>? attachmentTaskIds,
    Set<int>? openSubtaskTaskIds,
  }) {
    return applySavedFilterConditions(
      tasks,
      raw,
      labelIdsByTask: labelIdsByTask,
      reminderTaskIds: reminderTaskIds,
      attachmentTaskIds: attachmentTaskIds,
      openSubtaskTaskIds: openSubtaskTaskIds,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final filters = ref.watch(savedFiltersProvider);
    final tasks = ref.watch(todoTasksProvider);
    // 预览命中数的数据源（投影未就绪传 null——对应维度跳过，
    // 不因缺数据误杀全部行；与子列表页同源口径）
    final labelRows = ref.watch(taskLabelsProjectionProvider).value;
    final reminderRows = ref.watch(taskRemindersProjectionProvider).value;
    final attachmentIds = ref.watch(taskAttachmentFlagsProvider).value;
    final openSubtaskIds = ref.watch(taskOpenSubtaskFlagsProvider).value;
    final labelIdsByTask = labelRows == null
        ? null
        : indexLabelIdsByTask(labelRows);
    final reminderTaskIds = reminderRows == null
        ? null
        : {
            for (final r in reminderRows)
              if (r.reminders.isNotEmpty) r.taskId,
          };

    return Scaffold(
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverPadding(
                // 页头是 Stack 顶层玻璃条（不是 AppBar）：列表必须自己让出
                // 状态栏 + 页头行高，否则首行会滚到玻璃页头底下被糊住
                // （2026-11-05 实测「第一笔添加的被头部挡住」）
                padding: EdgeInsets.only(
                  top:
                      MediaQuery.of(context).padding.top +
                      OrbitPageHeader.rowHeight +
                      AppDimens.space16,
                  left: AppDimens.space16,
                  right: AppDimens.space16,
                  bottom: AppDimens.space16,
                ),
                sliver: filters.when(
                  data: (list) {
                    if (list.isEmpty) {
                      return SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: OrbitIcons.filter,
                          message: '还没有保存的筛选器——把常用组合条件（优先级/截止窗口/收藏）存为命名视图',
                          actionLabel: '新建筛选器',
                          onAction: _create,
                        ),
                      );
                    }
                    final taskList = tasks.value ?? [];
                    return SliverList(
                      delegate: SliverChildBuilderDelegate((context, i) {
                        final f = list[i];
                        final expanded = _expandedId == f.id;
                        final hit = _apply(
                          taskList,
                          f.conditions,
                          labelIdsByTask: labelIdsByTask,
                          reminderTaskIds: reminderTaskIds,
                          attachmentTaskIds: attachmentIds,
                          openSubtaskTaskIds: openSubtaskIds,
                        );
                        return Container(
                          margin: const EdgeInsets.only(
                            bottom: AppDimens.space8,
                          ),
                          decoration: BoxDecoration(
                            color: colors.surfaceSecondary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            children: [
                              ListTile(
                                leading: Icon(
                                  OrbitIcons.filter,
                                  size: AppDimens.iconSizeMd,
                                  color: OrbitAccents.todoAccent,
                                ),
                                title: Text(
                                  f.name,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: colors.titleText,
                                  ),
                                ),
                                subtitle: Text(
                                  '${_condSummary(f.conditions)} · 命中 ${hit.length}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.secondaryText,
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    OrbitIconButton(
                                      visualDensity: VisualDensity.compact,
                                      tooltip: '编辑',
                                      icon: Icon(
                                        OrbitIcons.edit,
                                        size: AppDimens.iconSizeSm,
                                        color: colors.secondaryText,
                                      ),
                                      onPressed: () =>
                                          _openBuilder(existing: f),
                                    ),
                                    Icon(
                                      expanded
                                          ? OrbitIcons.expandLess
                                          : OrbitIcons.expandMore,
                                      color: colors.secondaryText,
                                    ),
                                  ],
                                ),
                                onTap: () => setState(
                                  () => _expandedId = expanded ? null : f.id,
                                ),
                                onLongPress: () => _delete(f),
                              ),
                              if (expanded)
                                ...hit
                                    .take(20)
                                    .map(
                                      (t) => Padding(
                                        padding: const EdgeInsets.only(
                                          left: AppDimens.space16,
                                          right: AppDimens.space16,
                                          bottom: AppDimens.space4,
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 8,
                                              height: 8,
                                              decoration: BoxDecoration(
                                                color: hexToColor(
                                                  priorityColorHex(t.priority),
                                                ),
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(
                                              width: AppDimens.space8,
                                            ),
                                            Expanded(
                                              child: AnimatedStrikethrough(
                                                text: t.title,
                                                done: t.isDone,
                                                maxLines: 1,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: colors.bodyText,
                                                ),
                                                doneColor: colors.bodyText,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                            ],
                          ),
                        );
                      }, childCount: list.length),
                    );
                  },
                  loading: () => const SliverFillRemaining(
                    child: Center(
                      child: OrbitSpinner(size: AppDimens.iconSizeLg),
                    ),
                  ),
                  error: (e, _) => SliverFillRemaining(
                    child: Center(
                      child: Text(
                        '加载失败：$e',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                ), // filters.when
              ), // SliverPadding
            ], // slivers
          ), // CustomScrollView
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            // 新建入口放页头右上角（不再用本页 floatingActionButton）：
            // 壳层已有全局 [OrbitFab] 常驻右下，本页再挂一个 FAB 会叠成两个
            // 蓝钮（2026-11-05 截图实测）。上收到页头既避让全局钮，也让
            // 「新建」这个页面级动作与页头同层
            child: OrbitPageHeader(
              title: '筛选器',
              actions: [
                OrbitIconButton(
                  tooltip: '新建筛选器',
                  icon: const Icon(OrbitIcons.add),
                  onPressed: _create,
                ),
              ],
            ),
          ),
        ],
      ),
      // 本页自带 Scaffold：壳层底栏是悬浮胶囊（内容 extendBody 铺到屏底），
      // 用等高的空底栏把本页 body 顶到胶囊上沿——列表末行不会停在栏体后面。
      bottomNavigationBar: SizedBox(
        height: OrbitBottomNav.clearanceOf(context),
      ),
    );
  }
}

/// 筛选器构建器日期行（#71：绝对日期维度输入；点行弹日期面板，有值时行尾 X 清除）。
///
/// 行样式与项目/标签/状态/优先级同款（`_FilterConditionRow`）：标题在左、
/// 尾随日期在右、无值时上下双箭头；有值时 X **顶替**箭头位置（不并排）。
class _FilterDateRow extends StatelessWidget {
  const _FilterDateRow({
    required this.label,
    required this.value,
    required this.onPick,
  });

  final String label;
  final int? value;
  final ValueChanged<int?> onPick;

  @override
  Widget build(BuildContext context) {
    final text = value == null
        ? '不限'
        : OrbitDatePicker.formatDate(
            DateTime.fromMillisecondsSinceEpoch(value!),
          );
    return _FilterConditionRow(
      label: label,
      summary: text,
      onTap: () async {
        final picked = await OrbitDatePicker.pick(
          context,
          initialDate: value == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(value!),
        );
        if (picked == null || !context.mounted) return;
        final day = DateTime(picked.year, picked.month, picked.day);
        onPick(day.millisecondsSinceEpoch);
      },
      onClear: value == null ? null : () => onPick(null),
    );
  }
}

/// 筛选器条件行（项目 / 标签 / 日期四行共用）：**行样式**与设置页下拉偏好行
/// 同款（标题在左、尾随当前值、行尾上下双箭头），但点开后的交互各归各的——
/// 项目/标签打开多选抽屉，日期打开日期面板。
///
/// 为什么不直接用 `OrbitDropdownPreference`：那个原语的语义是「从一组值里挑
/// 一个」并自带玻璃菜单，而这里是多选集合 / 日期面板，硬套会退化成单选或丢掉
/// 日期面板。这里只复用行**外观**（`MiuixBasicComponent` + 行尾动作），交互
/// 由调用方的 `onTap` 决定。
///
/// **行尾动作规则（2026-11-05）**：无值 → 上下双箭头（可点开选择）；有值且可
/// 清除（[onClear] 非空）→ **只显示 X，覆盖箭头位置**（不并排、不占两格）。
/// 用户改完立刻能在原位清空，不必再瞄一个额外的叉号。
///
/// **行高（2026-11-06）**：与上方状态 / 优先级偏好行同为 56（库内
/// `MiuixBasicComponent` 的 `minHeight`），见 `build` 里 `insideMargin`
/// 处的注释。
class _FilterConditionRow extends StatelessWidget {
  const _FilterConditionRow({
    required this.label,
    required this.summary,
    required this.onTap,
    this.onClear,
  });

  /// 行标题（项目 / 标签 / 截止晚于 …；一律白话，不带 ≥ / ＜ 之类的符号）
  final String label;

  /// 尾随当前值文案（「不限」或已选名称 / 日期）
  final String summary;

  /// 打开选择（多选抽屉 / 日期面板）
  final VoidCallback onTap;

  /// 清除当前值（null = 无值或该维度不可清除，行尾显示箭头）
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final actionColor = theme.colors.onSurfaceVariantActions;

    // 尾随块（值 + 行尾动作）与 `OrbitDropdownPreference` 同构：值紧贴动作、
    // 动作槽只按双箭头的绘制宽（10）占位，整块按内在宽度收在行右沿。
    //
    // 2026-11-06 反馈「这些个『不限』应该右对齐」：动作槽原先按 48 触控宽
    // 占位，值被挤到右侧 56 之外，比上面状态行的「全部状态」左出一大截。
    // 热区不再用布局宽度换——X 的 48 热区改走下方透明覆盖层。
    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          flex: 1,
          fit: FlexFit.loose,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: AppDimens.space8),
            child: MiuixText(
              summary,
              fontSize: theme.textStyles.body2.fontSize,
              color: actionColor,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        // 动作槽：10 宽（= 双箭头绘制宽）× 18 高，整体贴行右沿。
        // X 图标 18 经 `OverflowBox` 撑出槽外各 4px，**中心落在右沿内 5**，
        // 与箭头同一条竖线（2026-11-05 的口径不变，见下方几何用例）。
        SizedBox(
          width: 10,
          height: AppDimens.iconSizeSm,
          child: onClear != null
              ? OverflowBox(
                  minWidth: AppDimens.iconSizeSm,
                  maxWidth: AppDimens.iconSizeSm,
                  minHeight: AppDimens.iconSizeSm,
                  maxHeight: AppDimens.iconSizeSm,
                  child: Icon(
                    OrbitIcons.close,
                    size: AppDimens.iconSizeSm,
                    color: actionColor,
                  ),
                )
              : Center(
                  child: MiuixDropdownArrowEndAction(actionColor: actionColor),
                ),
        ),
      ],
    );

    final row = MiuixBasicComponent(
      title: label,
      // 与偏好行同口径 8：行高由库内 `minHeight: 56` 兜平（文字约 20 + 8×2），
      // 动作槽只有 18 高、不再把行撑到 64——六行与上方状态 / 优先级逐行等高
      insideMargin: const EdgeInsets.symmetric(vertical: AppDimens.space8),
      endActions: [trailing],
      role: MiuixBasicComponentRole.dropdownList,
      onClick: onTap,
    );
    if (onClear == null) return row;

    // X 的 a11y 热区（48 宽 × 整行高）走**透明覆盖层**：布局上不占位，
    // 值才能贴到行右沿（值右缘距右沿 18 = 8 间隙 + 10 动作槽），
    // 而 X 中心仍与箭头重合。点右沿这 48 清空，点其余位置打开选择。
    return Stack(
      // X 图标比动作槽宽 8，向右溢出到行内边距里属预期，不能被 Stack 裁掉
      clipBehavior: Clip.none,
      children: [
        row,
        PositionedDirectional(
          top: 0,
          bottom: 0,
          end: 0,
          width: AppDimens.touchTarget,
          child: Semantics(
            button: true,
            label: '清除',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClear,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }
}
