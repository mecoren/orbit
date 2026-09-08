import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/circle_checkbox.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/glass_fab.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/more_actions_sheet.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/wait_toast.dart';
import 'form_bottom_sheet.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';

/// 任务子列表 /todo/tasks（docs/05 §4.2 + 移动端任务书）
///
/// 入口三参数互斥：projectId > ungrouped > view（task_logic 同款优先级）。
/// 列表消费共享 filterTasks/sortTasks；空态文案按入口映射；
/// 右下 GlassFab 新建（携 defaultProjectId）；Tile 长按弹操作菜单
/// （编辑 / 星标切换 / 删除确认）。
class SubListScreen extends ConsumerStatefulWidget {
  const SubListScreen({super.key, required this.query});

  /// 路由 query 参数解析结果（view/projectId/ungrouped 三选一）
  final TaskFilterInput query;

  /// 解析路由 query → 筛选输入（projectId > ungrouped > view）
  static TaskFilterInput parseQuery(GoRouterState state) {
    final params = state.uri.queryParameters;
    final projectId = int.tryParse(params['projectId'] ?? '');
    if (projectId != null) {
      return TaskFilterInput(projectId: projectId);
    }
    if (params.containsKey('ungrouped')) {
      return const TaskFilterInput(ungrouped: true);
    }
    final viewName = params['view'];
    final view =
        QuickViewKey.values.where((k) => k.name == viewName).firstOrNull;
    return TaskFilterInput(quickView: view);
  }

  @override
  ConsumerState<SubListScreen> createState() => _SubListScreenState();
}

class _SubListScreenState extends ConsumerState<SubListScreen> {
  final _scrollController = ScrollController();

  // 排序档位（#26：会话内存态，退出即回 manual——移动端无手动拖拽，
  // 该档等价 position 拖拽顺序）
  TaskSortKey _sortKey = TaskSortKey.manual;

  static const _sortChoices = {
    TaskSortKey.manual: '拖拽顺序',
    TaskSortKey.due: '截止时间',
    TaskSortKey.priority: '优先级',
    TaskSortKey.title: '标题',
    TaskSortKey.created: '创建时间',
  };

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ── 写操作（await bridge 后 invalidate）──

  Future<void> _patchTask(
    int id,
    Map<String, Object?> patch, {
    String failMessage = '更新失败',
  }) async {
    try {
      await ref.read(orbitBridgeProvider).todoTaskUpdate(id, encodePatch(patch));
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider);
    } catch (_) {
      WaitToast.destructive(failMessage);
    }
  }

  /// 完成/取消统一入口：完成走 todoTaskComplete（Rust 单事务推进重复
  /// 任务下一实例——引擎下沉后与桌面同口径）；取消完成仍走普通 patch
  Future<void> _toggleDone(TodoTask task) async {
    if (task.isDone) return _patchTask(task.id, buildDoneTogglePatch(task));
    try {
      await ref.read(orbitBridgeProvider).todoTaskComplete(task.id);
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider);
    } catch (_) {
      WaitToast.destructive('完成失败');
    }
  }

  void _toggleFavorite(TodoTask task) => _patchTask(
        task.id,
        {'is_favorite': task.isStarred ? 0 : 1},
      );

  /// 我的一天：加入今天（本地零点）/ 移出（null）——与桌面同口径
  void _toggleMyDay(TodoTask task) {
    final now = DateTime.now();
    final todayZero = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    _patchTask(
      task.id,
      {'my_day_date': task.isInMyDay ? null : todayZero},
    );
  }

  Future<void> _deleteTask(TodoTask task) async {
    final destructive = AppColors.ofContext(context).destructive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除任务'),
        content: Text('确定要删除任务「${task.title}」吗？删除后将移入回收站，可在回收站中恢复。'),
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
      await ref.read(orbitBridgeProvider).todoTaskDelete(task.id);
      ref.invalidate(todoTasksProvider);
    } catch (_) {
      WaitToast.destructive('删除失败');
    }
  }

  // ── Tile 长按菜单（编辑 / 星标切换 / 删除确认）──

  void _showTaskActions(TodoTask task) {
    showMoreActionsSheet(
      context,
      title: task.title,
      actions: [
        MoreActionItem(
          icon: Icons.edit_rounded,
          label: '编辑',
          onTap: () => showTodoFormSheet(context, editingTaskId: task.id),
        ),
        MoreActionItem(
          icon: Icons.wb_sunny_rounded,
          label: task.isInMyDay ? '移出我的一天' : '加入我的一天',
          color: OrbitAccents.myDayAmber,
          onTap: () => _toggleMyDay(task),
        ),
        MoreActionItem(
          icon: Icons.star_rounded,
          label: task.isStarred ? '取消收藏' : '收藏',
          color: OrbitAccents.starYellow,
          onTap: () => _toggleFavorite(task),
        ),
        MoreActionItem(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          color: OrbitAccents.overdueRed,
          onTap: () => _deleteTask(task),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks =
        ref.watch(todoTasksProvider(const TaskListQuery())).value ?? [];
    final projects = ref.watch(todoProjectsProvider).value ?? [];

    final visible = sortTasks(filterTasks(tasks, widget.query), _sortKey);
    final projectTitleById = {for (final p in projects) p.id: p.title};

    // 动态标题：项目名 / 未分组 / 视图名
    final title = switch (widget.query) {
      TaskFilterInput(projectId: final id?) => projectTitleById[id] ?? '项目',
      TaskFilterInput(ungrouped: true) => '未分组',
      _ => widget.query.quickView?.label ?? '任务',
    };
    final emptyMessage = emptyMessageFor(widget.query);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: visible.isEmpty
                ? Padding(
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top +
                          LiquidGlassTitleBar.rowHeight,
                    ),
                    child: EmptyState(message: emptyMessage),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top +
                          LiquidGlassTitleBar.rowHeight +
                          AppDimens.space8,
                      bottom:
                          AppDimens.gestureInsetFallback + AppDimens.space32,
                    ),
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final task = visible[index];
                      return TodoTaskTile(
                        task: task,
                        projectTitle: task.projectId != null
                            ? projectTitleById[task.projectId]
                            : null,
                        onOpen: () => context.push('/todo/${task.id}'),
                        onToggleDone: () => _toggleDone(task),
                        onLongPress: () => _showTaskActions(task),
                        onDelete: () => _deleteTask(task),
                      );
                    },
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: title,
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
              actions: [
                // 排序档位菜单（#26；manual = position 拖拽顺序）
                PopupMenuButton<TaskSortKey>(
                  initialValue: _sortKey,
                  onSelected: (k) => setState(() => _sortKey = k),
                  itemBuilder: (_) => [
                    for (final e in _sortChoices.entries)
                      PopupMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  icon: Icon(
                    Icons.sort_rounded,
                    size: AppDimens.iconSizeMd,
                    color: AppColors.ofContext(context).titleText,
                  ),
                ),
              ],
            ),
          ),
          // FAB：右下，新建携 defaultProjectId=当前 projectId
          Positioned(
            right: AppDimens.space16,
            bottom: AppDimens.gestureInsetFallback + AppDimens.space16,
            child: GlassFab(
              accentColor: OrbitAccents.themeAccent,
              onPressed: () => showTodoFormSheet(
                context,
                defaultProjectId: widget.query.projectId,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 任务行卡片（docs/05 §4.5）：24px 圆 checkbox + 标题 + 副标题行
/// （优先级色点 8px + 项目名 + 日期，逾期 #F44436）+ 收藏星标。
/// 侧滑手势（07 #18）：面板露出操作按钮（TickTick 式）——
/// 右滑露「完成」（已完成态变「恢复」，行保留不删）、
/// 左滑露「删除」（既有确认弹窗 + 回收站语义）。
class TodoTaskTile extends StatelessWidget {
  const TodoTaskTile({
    super.key,
    required this.task,
    required this.onToggleDone,
    required this.onLongPress,
    required this.onOpen,
    this.projectTitle,
    this.onDelete,
  });

  final TodoTask task;

  /// 副标题项目名；无项目（未分组）不渲染该段
  final String? projectTitle;
  final VoidCallback onToggleDone;
  final VoidCallback onLongPress;
  final VoidCallback onOpen;

  /// 右滑「删除」动作回调（null 时隐藏删除面板——搜索页等只读场景复用 Tile）
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final priorityHex = priorityColorHex(task.priority);
    final overdue = isOverdue(task);

    return Slidable(
      // 每行独立 key，避免虚拟化复用时动作面板串行
      key: ValueKey('slidable-task-${task.id}'),
      endActionPane: onDelete == null
          ? null
          : ActionPane(
              motion: const BehindMotion(),
              extentRatio: 0.26,
              children: [
                SlidableAction(
                  onPressed: (_) => onDelete?.call(),
                  backgroundColor: colors.destructive,
                  foregroundColor: Colors.white,
                  icon: Icons.delete_outline_rounded,
                  label: '删除',
                  borderRadius: AppShapes.medium,
                ),
              ],
            ),
      startActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.26,
        children: [
          SlidableAction(
            onPressed: (_) => onToggleDone(),
            backgroundColor: OrbitAccents.todoAccent,
            foregroundColor: Colors.white,
            icon: task.isDone ? Icons.undo_rounded : Icons.check_rounded,
            label: task.isDone ? '恢复' : '完成',
            borderRadius: AppShapes.medium,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space12, vertical: 4),
        child: Material(
        color: colors.surface.withValues(alpha: 0.5),
        borderRadius: AppShapes.medium,
        child: InkWell(
          borderRadius: AppShapes.medium,
          onTap: onOpen,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space12,
              vertical: AppDimens.space8,
            ),
            child: Row(
              children: [
                // 24px 圆形 checkbox（check 16）
                CircleCheckbox(
                  checked: task.isDone,
                  onToggle: onToggleDone,
                ),
                const SizedBox(width: AppDimens.space12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: colors.titleText,
                          decoration:
                              task.isDone ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      // 副标题恒渲染：优先级色点六档全显（P0「无」浅灰也参与）
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Wrap(
                            spacing: AppDimens.space4,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              // 8px 优先级色点（六档全显，含 P0 浅灰）
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: hexToColor(priorityHex),
                                ),
                              ),
                              if (projectTitle != null &&
                                  task.projectId != null)
                                Text(
                                  projectTitle!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.secondaryText,
                                  ),
                                ),
                              // 日期段：逾期 #F44336
                              if (task.dueDate != null)
                                Text(
                                  formatYmd(task.dueDate!),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: overdue
                                        ? OrbitAccents.overdueRed
                                        : colors.secondaryText,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (task.isStarred) ...[
                  const SizedBox(width: AppDimens.space8),
                  Icon(
                    Icons.star_rounded,
                    size: AppDimens.iconSizeLg,
                    color: OrbitAccents.starYellow,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}
