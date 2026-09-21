import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_fab.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/sync_status_button.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
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

/// 项目 10 色预设板（#36；与桌面端 project-sidebar PROJECT_COLORS 同序列）
const List<String> _projectColorPalette = [
  '#EF4444', '#F59E0B', '#22C55E', '#3B82F6', '#8B5CF6',
  '#EC4899', '#14B8A6', '#F97316', '#6366F1', '#6B7280',
];

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

  /// 归档项目（侧栏归档区；与主列表独立 provider）
  List<TodoProject> _archivedProjects() =>
      ref.watch(todoArchivedProjectsProvider).value ?? const [];

  List<TodoTask> _tasks() =>
      ref.watch(todoTasksProvider).value ?? const [];

  /// 侧栏计数单遍聚合（此前每个快捷视图行各跑一遍 filterTasks——
  /// 7 遍全量 + 7 次 DateTime.now()，万任务下 build 一次 8+ 遍遍历）
  SidebarCounts _counts(List<TodoTask> tasks) => computeSidebarCounts(tasks);

  /// 视图计数（badge 口径：all/today/… 未完成数；done 视图已完成数）
  int _undoneCount(SidebarCounts counts, QuickViewKey key) =>
      counts.quickView[key] ?? 0;

  /// 各项目未完成计数（单遍产物）
  Map<int, int> _undoneByProject(SidebarCounts counts) => counts.undoneByProject;

  // ── 导航 ──

  void _openView(QuickViewKey key) => context.push('/todo/tasks?view=${key.name}');

  void _openCalendar() => context.push('/todo/calendar');

  void _openStats() => context.push('/todo/stats');

  void _openSearch() => context.push('/todo/search');

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

  // ── 项目长按菜单（编辑 / 归档 / 删除保护流）──

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
          icon: Icons.archive_outlined,
          label: project.isArchived == 1 ? '取消归档' : '归档项目',
          onTap: () => _toggleArchive(project),
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

  /// 归档切换（桌面右键同口径）：is_archived 翻转经 patchJson；
  /// 双失效（主列表 + 归档区）
  Future<void> _toggleArchive(TodoProject project) async {
    final next = project.isArchived == 1 ? 0 : 1;
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoProjectUpdate(project.id, '{"is_archived":$next}');
      ref.invalidate(todoProjectsProvider);
      ref.invalidate(todoArchivedProjectsProvider);
      WaitToast.success(next == 1 ? '项目已归档' : '已恢复到项目列表');
    } catch (_) {
      WaitToast.destructive('操作失败');
    }
  }

  /// 新建项目（#36）：名称输入 + 默认色按现有项目数轮换预设板
  Future<void> _addProject() async {
    final projects = _projects();
    final defaultColor =
        _projectColorPalette[projects.length % _projectColorPalette.length];
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建项目'),
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
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    final newTitle = title;
    if (!mounted || newTitle == null || newTitle.isEmpty) return;
    try {
      await ref.read(orbitBridgeProvider).todoProjectCreate(
          TodoProjectCreateInput(title: newTitle, hexColor: defaultColor));
      ref.invalidate(todoProjectsProvider);
      WaitToast.success('项目已创建');
    } catch (_) {
      WaitToast.destructive('创建失败');
    }
  }

  Future<void> _editProject(TodoProject project) async {
    final dialogColors = AppColors.ofContext(context);
    final controller = TextEditingController(text: project.title);
    // #36：色板当前选中（初始 = 项目现色，无色回退默认蓝）
    var selectedColor =
        project.hexColor.isNotEmpty ? project.hexColor : '#3B82F6';
    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('编辑项目'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 50,
                decoration: const InputDecoration(labelText: '项目名称'),
              ),
              const SizedBox(height: AppDimens.space8),
              // 10 色预设板（#36；与桌面端 ProjectEditDialog 同序列）
              Wrap(
                spacing: AppDimens.space8,
                runSpacing: AppDimens.space8,
                children: [
                  for (final hex in _projectColorPalette)
                    GestureDetector(
                      onTap: () => setDialogState(() => selectedColor = hex),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: hexToColor(hex),
                          border: Border.all(
                            color: selectedColor.toLowerCase() == hex.toLowerCase()
                                ? dialogColors.titleText
                                : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext)
                  .pop((controller.text.trim(), selectedColor)),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    final saved = result;
    if (!mounted || saved == null) return;
    final (newTitle, newColor) = saved;
    if (newTitle.isEmpty) return;
    if (newTitle == project.title && newColor == project.hexColor) return;
    try {
      await ref.read(orbitBridgeProvider).todoProjectUpdate(project.id,
          encodePatch({
            if (newTitle != project.title) 'title': newTitle,
            if (newColor != project.hexColor) 'hex_color': newColor,
          }));
      ref.invalidate(todoProjectsProvider);
    } catch (_) {
      WaitToast.destructive('保存失败');
    }
  }

  /// 删除保护双流（docs/05 §4.1 文案）：有未完成任务拒绝；否则 destructive 确认
  Future<void> _deleteProject(TodoProject project, int undoneCount) async {
    if (undoneCount > 0) {
      // 单按钮信息抽屉（cancelLabel: null）：只告知，没有可点的「取消」
      await showConfirmBottomSheet(
        context,
        title: '无法删除',
        message: '该项目下还有 $undoneCount 条未完成任务，请先清空或移走任务后再删除。',
        confirmLabel: '我知道了',
        cancelLabel: null,
      );
      return;
    }
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '删除项目',
      message: '确定要删除项目「${project.title}」吗？该操作不可撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
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
    final counts = _counts(tasks);
    final undoneByProject = _undoneByProject(counts);
    final surfaceHighest =
        Theme.of(context).colorScheme.surfaceContainerHighest;

    return Scaffold(
      body: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top +
                  OrbitPageHeader.rowHeight +
                  AppDimens.space8,
              bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
            ),
            children: [
              // 一、快捷视图（六行 ListTile：图标 quickView 色 + 标题 + 计数 badge + chevron）
              const SectionHeader(label: '快捷视图'),
              for (final key in QuickViewKey.values)
                _buildQuickViewRow(key, counts, surfaceHighest),
              // 二、日历（月视图格内待办长条 + 节假日徽标）
              _buildCalendarRow(context),
              // 三、统计（backlog #25：总览/热力图/streak/分布）
              _buildStatsRow(context),
              // 四、搜索（backlog #26：任务/项目/评论三路聚合）
              _buildSearchRow(context),
              // 五、筛选器（#35：保存的组合条件命名视图）
              _buildSavedFiltersRow(context),
              // 六、回收站（已删除任务的恢复入口；计数 = 回收站内任务数）
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
                // 拖拽起止触感 + 抬起放大（与任务列表 manual 档同口径）
                onReorderStart: (_) => HapticFeedback.selectionClick(),
                onReorderEnd: (_) => HapticFeedback.selectionClick(),
                proxyDecorator: (child, index, animation) => AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final elevated = AppMotion.standard.transform(
                      Tween<double>(begin: 0, end: 1).evaluate(animation),
                    );
                    return Transform.scale(
                      scale: 1 + (AppMotion.dragLiftScale - 1) * elevated,
                      child: Material(
                        elevation: 6 * elevated,
                        borderRadius: AppShapes.medium,
                        color: Colors.transparent,
                        child: child,
                      ),
                    );
                  },
                  child: child,
                ),
              ),
              // 新建项目（#36：移动端此前无创建项目入口）
              ListTile(
                leading: Icon(
                  Icons.add_rounded,
                  size: AppDimens.iconSizeMd,
                  color: colors.secondaryText,
                ),
                title: Text(
                  '新建项目',
                  style: TextStyle(
                    fontSize: 15,
                    color: colors.secondaryText,
                  ),
                ),
                dense: true,
                onTap: _addProject,
              ),
              // 归档项目区（有归档才渲染；行点击进项目视图读任务，
              // 行尾恢复钮取消归档——长按菜单同款入口兜底）
              if (_archivedProjects().isNotEmpty) ...[
                const SectionHeader(label: '已归档'),
                ..._archivedProjects().map(
                  (p) => ListTile(
                    leading: Icon(
                      Icons.folder_rounded,
                      size: AppDimens.iconSizeMd,
                      color: p.hexColor.isNotEmpty
                          ? hexToColor(p.hexColor)
                          : OrbitAccents.todoAccent,
                    ),
                    title: Text(
                      p.title,
                      style: TextStyle(
                        fontSize: 15,
                        color: colors.secondaryText,
                      ),
                    ),
                    dense: true,
                    trailing: TextButton(
                      onPressed: () => _toggleArchive(p),
                      child: const Text('恢复'),
                    ),
                    onTap: () => context.push('/todo/tasks?projectId=${p.id}'),
                  ),
                ),
              ],
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
                      // 未分组未完成 = 全部未完成 − 有项目未完成之和
                      //（fold 带初值 0，空项目 Map 不崩——reduce 空集 No element）
                      n: counts.quickView[QuickViewKey.all]! -
                          counts.undoneByProject.values
                              .fold(0, (a, b) => a + b),
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
            child: OrbitPageHeader(
              title: '循迹',
              showMenu: false,
              showBack: false,
              // 左端云同步图标（未配置/未解锁直达配置页；就绪弹信息面板）
              leading: const SyncStatusButton(),
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
            child: OrbitFab(
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

  /// 保存的筛选器入口行（#35：Apple Smart List 同款，独立路由页）
  Widget _buildSavedFiltersRow(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return ListTile(
      leading: Icon(
        Icons.filter_alt_rounded,
        size: AppDimens.iconSizeMd,
        color: OrbitAccents.todoAccent,
      ),
      title: Text(
        '筛选器',
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
      onTap: () => context.push('/todo/saved-filters'),
    );
  }

  /// 搜索入口行（backlog #26：任务/项目/评论三路聚合的专属页面，同日历行模式）
  Widget _buildSearchRow(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return ListTile(
      leading: Icon(
        Icons.search_rounded,
        size: AppDimens.iconSizeMd,
        color: OrbitAccents.todoAccent,
      ),
      title: Text(
        '搜索',
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
      onTap: _openSearch,
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
    SidebarCounts counts,
    Color surfaceHighest,
  ) {
    final colors = AppColors.ofContext(context);
    final undone = _undoneCount(counts, key);
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
            // 项目固定图标（folder_rounded）按项目自选色染色，无色回退强调色
            Icon(
              Icons.folder_rounded,
              size: AppDimens.iconSizeMd,
              color: hexToColor(project.hexColor,
                  fallback: OrbitAccents.todoAccent),
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
