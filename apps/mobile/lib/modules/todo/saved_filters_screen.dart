import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/wait_toast.dart';
import 'logic/task_logic.dart';
import '../../shared/utils/hex_color.dart';
import 'providers/todo_providers.dart';

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

  Future<void> _create() async {
    final nameCtl = TextEditingController();
    final condCtl = TextEditingController(text: '{"due_overdue":true}');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建筛选器'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称（如：本周 P0）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: condCtl,
              decoration: const InputDecoration(
                labelText: '条件 JSON',
                hintText: '{"priority_min":4,"due_within_days":7}',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(orbitBridgeProvider)
          .savedFilterCreate(nameCtl.text.trim(), condCtl.text.trim());
      if (mounted) WaitToast.success('已创建筛选器');
    } catch (e) {
      if (mounted) WaitToast.destructive('创建失败：$e');
    }
  }

  Future<void> _delete(TodoSavedFilter f) async {
    final destructive = AppColors.ofContext(context).destructive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除筛选器'),
        content: Text('确定要删除「${f.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: destructive),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
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
    final tasks = ref.watch(todoTasksProvider(const TaskListQuery()));

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
                      return const SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: Icons.filter_alt_outlined,
                          message: '还没有保存的筛选器——把常用组合条件（优先级/截止窗口/收藏）存为命名视图',
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
                                  Icons.filter_alt_rounded,
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
                                trailing: Icon(
                                  expanded
                                      ? Icons.expand_less_rounded
                                      : Icons.expand_more_rounded,
                                  color: colors.secondaryText,
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
                                              child: Text(
                                                t.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: colors.bodyText,
                                                  decoration: t.isDone
                                                      ? TextDecoration
                                                            .lineThrough
                                                      : null,
                                                ),
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
            child: LiquidGlassTitleBar(
              title: '筛选器',
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('新建筛选器'),
      ),
    );
  }
}
