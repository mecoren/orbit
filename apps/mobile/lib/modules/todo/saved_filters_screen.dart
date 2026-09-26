import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'logic/task_logic.dart';
import '../../shared/utils/hex_color.dart';
import 'providers/todo_providers.dart';
import '../../core/theme/icon_map.dart';

/// 保存的筛选器页 /todo/saved-filters（#35：Apple Smart List 同款）
///
/// 列表（名称 + 条件摘要 + 命中数）+ 底部新建（名称 + 条件 JSON）+ 长按删除。
/// 条件应用在行内展开即时预览（不走独立路由——移动端轻量消费形态）。
class SavedFiltersScreen extends ConsumerStatefulWidget {
  const SavedFiltersScreen({super.key});

  @override
  ConsumerState<SavedFiltersScreen> createState() => _SavedFiltersScreenState();
}

class _SavedFiltersScreenState extends ConsumerState<SavedFiltersScreen> {
  final _scrollController = ScrollController();
  // 行展开态：当前展开预览的筛选器 id（null = 全收起）
  int? _expandedId;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 七键可视化构建抽屉（新建 + 更新共用；替代手写条件文本框）
  ///
  /// 七键：status / priority_min / project_ids / label_ids /
  /// due_within_days / due_overdue / favorite_only。仅收纳已设置键，
  /// 未设置键不写入 JSON（与桌面白名单校验口径一致）。
  Future<void> _openBuilder({TodoSavedFilter? existing}) async {
    final colors = AppColors.ofContext(context);
    final nameCtl = TextEditingController(text: existing?.name ?? '');
    Map<String, dynamic> init = {};
    try {
      if (existing != null) {
        init = jsonDecode(existing.conditions) as Map<String, dynamic>;
      }
    } catch (_) {}
    String? status = init['status'] as String?;
    int priorityMin = (init['priority_min'] as num?)?.toInt() ?? 0;
    final projectCtl = TextEditingController(
      text: init['project_ids'] is List
          ? (init['project_ids'] as List).join(',')
          : '',
    );
    final labelCtl = TextEditingController(
      text: init['label_ids'] is List
          ? (init['label_ids'] as List).join(',')
          : '',
    );
    final withinCtl = TextEditingController(
      text: init['due_within_days']?.toString() ?? '',
    );
    bool overdue = init['due_overdue'] == true;
    bool favorite = init['favorite_only'] == true;

    List<int>? parseIds(String raw) {
      final ids = <int>[];
      for (final part in raw.split(',')) {
        final v = int.tryParse(part.trim());
        if (v != null) ids.add(v);
      }
      return ids.isEmpty ? null : ids;
    }

    final saved = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => OrbitSheetScaffold(
          title: existing == null ? '新建筛选器' : '编辑筛选器',
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space16,
          ),
          // 表单滚动、底部按钮固定（长表单不再把「创建」顶出可视区）
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(
                  labelText: '名称（如：本周 P0）',
                ),
              ),
              const SizedBox(height: AppDimens.space8),
              SizedBox(
                height: AppDimens.touchTarget,
                child: InkWell(
                  onTap: () => showSelectBottomSheet<String?>(
                    ctx,
                    title: '状态',
                    current: status,
                    items: const [
                      SelectItem(value: null, label: '全部状态'),
                      SelectItem(value: 'pending', label: '待办'),
                      SelectItem(value: 'done', label: '已完成'),
                    ],
                    onSelect: (v) => setSheet(() => status = v),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '状态：${status ?? '全部'}',
                          style: TextStyle(
                            fontSize: 15,
                            color: colors.bodyText,
                          ),
                        ),
                      ),
                      Icon(
                        OrbitIcons.chevronRight,
                        color: colors.secondaryText,
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: AppDimens.touchTarget,
                child: InkWell(
                  onTap: () => showSelectBottomSheet<int>(
                    ctx,
                    title: '最低优先级',
                    current: priorityMin,
                    items: const [
                      SelectItem(value: 0, label: '全部优先级'),
                      SelectItem(value: 1, label: 'P1 及以上'),
                      SelectItem(value: 2, label: 'P2 及以上'),
                      SelectItem(value: 3, label: 'P3 及以上'),
                      SelectItem(value: 4, label: 'P4 及以上'),
                      SelectItem(value: 5, label: '仅 P5'),
                    ],
                    onSelect: (v) => setSheet(() => priorityMin = v),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '优先级≥：${priorityMin == 0 ? '全部' : 'P$priorityMin'}',
                          style: TextStyle(
                            fontSize: 15,
                            color: colors.bodyText,
                          ),
                        ),
                      ),
                      Icon(
                        OrbitIcons.chevronRight,
                        color: colors.secondaryText,
                      ),
                    ],
                  ),
                ),
              ),
              TextField(
                controller: withinCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '天内截止（留空不限，如 7）',
                ),
              ),
              TextField(
                controller: projectCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '项目 id（逗号分隔，留空不限）',
                ),
              ),
              TextField(
                controller: labelCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '标签 id（逗号分隔，留空不限）',
                ),
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
    final pids = parseIds(projectCtl.text);
    if (pids != null) cond['project_ids'] = pids;
    final lids = parseIds(labelCtl.text);
    if (lids != null) cond['label_ids'] = lids;
    final within = int.tryParse(withinCtl.text.trim());
    if (within != null && within > 0) cond['due_within_days'] = within;
    if (overdue) cond['due_overdue'] = true;
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
      final parts = <String>[];
      for (final e in labels.entries) {
        if (c.containsKey(e.key)) {
          final v = c[e.key];
          parts.add(v == true ? e.value : '$e.value$v');
        }
      }
      return parts.isEmpty ? '无条件' : parts.join(' · ');
    } catch (_) {
      return '条件无效';
    }
  }

  /// 应用条件到任务（与桌面 applySavedFilter 同语义）
  List<TodoTask> _apply(List<TodoTask> tasks, String raw) {
    Map<String, dynamic> c;
    try {
      c = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return tasks;
    }
    final today = DateTime.now();
    final t0 = DateTime(
      today.year,
      today.month,
      today.day,
    ).millisecondsSinceEpoch;
    return tasks.where((t) {
      if (c['status'] != null && t.status != c['status']) return false;
      if (c['priority_min'] != null &&
          t.priority < (c['priority_min'] as num).toInt()) {
        return false;
      }
      if (c['project_ids'] != null) {
        final ids = (c['project_ids'] as List)
            .map((e) => (e as num).toInt())
            .toList();
        if (!ids.contains(t.projectId ?? -1)) return false;
      }
      if (c['due_within_days'] != null) {
        final d = t.dueDate;
        if (d == null ||
            d < t0 ||
            d >= t0 + (c['due_within_days'] as num) * 86400000) {
          return false;
        }
      }
      if (c['due_overdue'] == true) {
        final d = t.dueDate;
        if (d == null || d >= t0 || t.isDone) return false;
      }
      if (c['favorite_only'] == true && !t.isStarred) return false;
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final filters = ref.watch(savedFiltersProvider);
    final tasks = ref.watch(todoTasksProvider);

    return Scaffold(
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(AppDimens.space16),
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
                        final hit = _apply(taskList, f.conditions);
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
                                    IconButton(
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
                    child: Center(child: CircularProgressIndicator()),
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
            child: OrbitPageHeader(
              title: '筛选器',
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(OrbitIcons.add),
        label: const Text('新建筛选器'),
      ),
    );
  }
}
