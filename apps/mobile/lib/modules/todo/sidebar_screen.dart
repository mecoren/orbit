import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/glass_fab.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/more_actions_sheet.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/wait_toast.dart';
import 'form_bottom_sheet.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';

/// 侧栏首屏 /todo（docs/05 §4.1 + 移动端任务书）
///
/// 三段结构：快捷视图六行（今天/本周/全部/已完成/收藏/无日期，带未完成计数
/// badge）→ 项目段（色点 + 标题 + 未完成数，右侧把手可拖拽重排）→ 未分组行。
/// 行点击 push 子列表；长按项目弹 MoreActions 底部菜单（编辑 / 删除保护流）。
class SidebarScreen extends ConsumerStatefulWidget {
  const SidebarScreen({super.key});

  @override
  ConsumerState<SidebarScreen> createState() => _SidebarScreenState();
}

class _SidebarScreenState extends ConsumerState<SidebarScreen> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ── 数据 ──

  List<TodoProject> _projects() =>
      ref.watch(todoProjectsProvider).value ?? const [];

  List<TodoTask> _tasks() =>
      ref.watch(todoTasksProvider(const TaskListQuery())).value ?? const [];

  /// 视图未完成计数（badge 展示口径：该视图下未完成任务数）
  int _undoneCount(List<TodoTask> tasks, TaskFilterInput input) =>
      filterTasks(tasks, input).where((t) => !t.isDone).length;

  /// 各项目未完成计数（全量任务单遍聚合）
  Map<int, int> _undoneByProject(List<TodoTask> tasks) {
    final map = <int, int>{};
    for (final t in tasks) {
      if (!t.isDone && t.projectId != null) {
        map[t.projectId!] = (map[t.projectId!] ?? 0) + 1;
      }
    }
    return map;
  }

  // ── 导航 ──

  void _openView(QuickViewKey key) => context.push('/todo/tasks?view=${key.name}');

  void _openCalendar() => context.push('/todo/calendar');

  void _openStats() => context.push('/todo/stats');

  void _openTrash() => context.push('/todo/trash');

  void _openProject(TodoProject p) =>
      context.push('/todo/tasks?projectId=${p.id}');

  void _openUngrouped() => context.push('/todo/tasks?ungrouped=1');

  // ── 项目拖拽重排（Phase 7）──

  /// onReorderItem（newIndex 已归一化为语义插入位）：本地重排 → 逐条落库
  /// sortOrder（单条失败忽略，继续其余）→ 完成后 invalidate 项目 provider
  /// 以服务端权威顺序刷新。
  Future<void> _reorderProjects(int oldIndex, int newIndex) async {
    final reordered =
        reorderItems(ref.read(todoProjectsProvider).value ?? const [], oldIndex, newIndex);
    final bridge = ref.read(orbitBridgeProvider);
    for (var i = 0; i < reordered.length; i++) {
      try {
        await bridge.todoProjectUpdateSortOrder(reordered[i].id, i);
      } catch (_) {
        // 忽略单条失败：继续落剩余排序，最后统一 invalidate 兜底
      }
    }
    ref.invalidate(todoProjectsProvider);
  }

  // ── 项目长按菜单（编辑 / 删除保护流）──

  void _showProjectActions(TodoProject project, int undoneCount) {
    showMoreActionsSheet(
      context,
      title: project.title,
      actions: [
        MoreActionItem(
          icon: Icons.edit_rounded,
          label: '编辑',
          onTap: () => _editProject(project),
        ),
        MoreActionItem(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          color: OrbitAccents.overdueRed,
          onTap: () => _deleteProject(project, undoneCount),
        ),
      ],
    );
  }

  Future<void> _editProject(TodoProject project) async {
    final controller = TextEditingController(text: project.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑项目'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(labelText: '项目名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final newTitle = title;
    controller.dispose();
    if (!mounted || newTitle == null || newTitle.isEmpty) return;
    if (newTitle == project.title) return;
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoProjectUpdate(project.id, encodePatch({'title': newTitle}));
      ref.invalidate(todoProjectsProvider);
    } catch (_) {
      WaitToast.destructive('保存失败');
    }
  }

  /// 删除保护双流（docs/05 §4.1 文案）：有未完成任务拒绝；否则 destructive 确认
  Future<void> _deleteProject(TodoProject project, int undoneCount) async {
    if (undoneCount > 0) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('无法删除'),
          content: Text(
            '该项目下还有 $undoneCount 条未完成任务，请先清空或移走任务后再删除。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
      return;
    }
    final destructive = AppColors.ofContext(context).destructive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除项目'),
        content: Text('确定要删除项目「${project.title}」吗？该操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: destructive),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(orbitBridgeProvider).todoProjectDelete(project.id);
      WaitToast.success('项目已删除');
    } catch (_) {
      WaitToast.destructive('删除失败');
    }
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final tasks = _tasks();
    final projects = _projects();
    final undoneByProject = _undoneByProject(tasks);
    final surfaceHighest =
        Theme.of(context).colorScheme.surfaceContainerHighest;

    return Scaffold(
      body: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top +
                  LiquidGlassTitleBar.rowHeight +
                  AppDimens.space8,
              bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
            ),
            children: [
              // 一、快捷视图（六行 ListTile：图标 quickView 色 + 标题 + 计数 badge + chevron）
              const SectionHeader(label: '快捷视图'),
              for (final key in QuickViewKey.values)
                _buildQuickViewRow(key, tasks, surfaceHighest),
              // 二、日历（月视图格内待办长条 + 节假日徽标）
              _buildCalendarRow(context),
              // 三、统计（backlog #25：总览/热力图/streak/分布）
              _buildStatsRow(context),
              // 四、回收站（已删除任务的恢复入口；计数 = 回收站内任务数）
              _buildTrashRow(context, surfaceHighest),
              // 四、项目（色块 + 名称 + 未完成计数；长按菜单；右侧把手拖拽重排）
              const SectionHeader(label: '项目'),
              ReorderableListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: projects.length,
                itemBuilder: (context, index) => _buildProjectRow(
                  projects[index],
                  undoneByProject,
                  index,
                ),
                onReorderItem: _reorderProjects,
              ),
              // 三、未分组
              ListTile(
                leading: Icon(
                  Icons.inbox_rounded,
                  size: AppDimens.iconSizeMd,
                  color: colors.secondaryText,
                ),
                title: Text(
                  '未分组',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: colors.titleText,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CountBadge.wrap(
                      n: _undoneCount(
                          tasks, const TaskFilterInput(ungrouped: true)),
                      background: surfaceHighest,
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: AppDimens.iconSizeMd,
                      color: colors.secondaryText,
                    ),
                  ],
                ),
                onTap: _openUngrouped,
              ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: '循迹',
              showMenu: false,
              showBack: false,
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings_rounded,
                      size: AppDimens.iconSizeMd),
                  onPressed: () => context.push('/settings'),
                ),
              ],
            ),
          ),
          // FAB：右下，一级页面直达新建任务（不携带默认项目，表单内自选）
          Positioned(
            right: AppDimens.space16,
            bottom: AppDimens.gestureInsetFallback + AppDimens.space16,
            child: GlassFab(
              accentColor: OrbitAccents.themeAccent,
              onPressed: () => showTodoFormSheet(context),
            ),
          ),
        ],
      ),
    );
  }

  /// 日历入口行（独立于快捷视图：月历格内待办长条 + 节假日徽标的专属页面）
  Widget _buildCalendarRow(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return ListTile(
      leading: Icon(
        Icons.calendar_month_rounded,
        size: AppDimens.iconSizeMd,
        color: OrbitAccents.todoAccent,
      ),
      title: Text(
        '日历',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: colors.titleText,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: AppDimens.iconSizeMd,
        color: colors.secondaryText,
      ),
      onTap: _openCalendar,
    );
  }

  /// 统计入口行（backlog #25：总览/热力图/连续天数/分布的专属页面，同日历行模式）
  Widget _buildStatsRow(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return ListTile(
      leading: Icon(
        Icons.insights_rounded,
        size: AppDimens.iconSizeMd,
        color: OrbitAccents.todoAccent,
      ),
      title: Text(
        '统计',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: colors.titleText,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: AppDimens.iconSizeMd,
        color: colors.secondaryText,
      ),
      onTap: _openStats,
    );
  }

  /// 回收站入口行（已删除任务的恢复入口；独立路由页，同日历行模式）
  Widget _buildTrashRow(BuildContext context, Color badgeBackground) {
    final colors = AppColors.ofContext(context);
    final trashedCount = ref.watch(trashTasksProvider).value?.length ?? 0;
    return ListTile(
      leading: Icon(
        Icons.delete_outline_rounded,
        size: AppDimens.iconSizeMd,
        color: colors.secondaryText,
      ),
      title: Text(
        '回收站',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: colors.titleText,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CountBadge.wrap(n: trashedCount, background: badgeBackground),
          Icon(
            Icons.chevron_right_rounded,
            size: AppDimens.iconSizeMd,
            color: colors.secondaryText,
          ),
        ],
      ),
      onTap: _openTrash,
    );
  }

  Widget _buildQuickViewRow(
    QuickViewKey key,
    List<TodoTask> tasks,
    Color surfaceHighest,
  ) {
    final colors = AppColors.ofContext(context);
    final input = TaskFilterInput(quickView: key);
    final undone = _undoneCount(tasks, input);
    return ListTile(
      leading: Icon(
        key.icon,
        size: AppDimens.iconSizeMd,
        color: hexToColor(key.colorHex),
      ),
      title: Text(
        key.label,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: colors.titleText,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CountBadge.wrap(n: undone, background: surfaceHighest),
          Icon(
            Icons.chevron_right_rounded,
            size: AppDimens.iconSizeMd,
            color: colors.secondaryText,
          ),
        ],
      ),
      onTap: () => _openView(key),
    );
  }

  Widget _buildProjectRow(
    TodoProject project,
    Map<int, int> undoneByProject,
    int index,
  ) {
    final colors = AppColors.ofContext(context);
    final undone = undoneByProject[project.id] ?? 0;
    return InkWell(
      key: ValueKey(project.id),
      borderRadius: AppShapes.medium,
      onTap: () => _openProject(project),
      onLongPress: () => _showProjectActions(project, undone),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space16,
          vertical: AppDimens.space12,
        ),
        child: Row(
          children: [
            // 12×12 圆角色块（hex_color||强调色）
            Container(
              width: AppDimens.colorDotSize,
              height: AppDimens.colorDotSize,
              decoration: BoxDecoration(
                color: hexToColor(project.hexColor,
                    fallback: OrbitAccents.todoAccent),
                borderRadius: AppShapes.of(4),
              ),
            ),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: Text(
                project.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: colors.titleText,
                ),
              ),
            ),
            if (undone > 0) ...[
              CountBadge(
                n: undone,
                background:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              const SizedBox(width: AppDimens.space8),
            ],
            // 拖拽把手（仅把手可拖，行体点击仍进列表不冲突）
            ReorderableDragStartListener(
              index: index,
              child: SizedBox(
                width: AppDimens.iconSizeMd + AppDimens.space8,
                height: AppDimens.touchTarget - AppDimens.space12,
                child: Icon(
                  Icons.drag_handle_rounded,
                  size: AppDimens.iconSizeMd,
                  color: colors.secondaryText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分区头（docs/05 §4.1）：L16/R8/T12/B4、12px/w600/sub
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space16,
        AppDimens.space12,
        AppDimens.space8,
        AppDimens.space4,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.secondaryText,
          ),
        ),
      ),
    );
  }
}

/// 未完成计数 badge（docs/05 §4.1）：radius 8、padding h8/v2、字 12，仅 >0 显示
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.n, required this.background});

  /// 便捷构造：n <= 0 时渲染占位空块（保持行尾 chevron 对齐稳定）
  factory CountBadge.wrap({required int n, required Color background}) {
    return CountBadge(n: n, background: background);
  }

  final int n;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 仅 >0 显示；为 0 时以零宽占位避免 trailing 布局跳动
    if (n <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space8,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppShapes.small,
      ),
      child: Text(
        '$n',
        style: TextStyle(
          fontSize: 12,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: colors.secondaryText,
        ),
      ),
    );
  }
}
