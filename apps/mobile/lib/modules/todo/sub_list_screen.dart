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
import 'logic/template_apply.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';

/// 任务子列表 /todo/tasks（docs/05 §4.2 + 移动端任务书）
///
/// 入口三参数互斥：projectId > ungrouped > view（task_logic 同款优先级）。
/// 列表消费共享 filterTasks/sortTasks；空态文案按入口映射；
/// 右下 GlassFab 新建（携 defaultProjectId）；Tile 长按弹操作菜单
/// （编辑 / 星标切换 / 删除确认）；manual 档行尾拖拽把手长按拖拽重排
/// （#37，position midpoint 落库与桌面同口径）。
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
  // 两个滚动控制器分列两档列表形态（#37）：ReorderableListView 与普通
  // ListView 切换排序档时新旧树同帧交替，共用单控制器会触发
  // "attached to multiple scroll views" 断言——分体即各自最多一挂载。
  final _reorderScrollController = ScrollController();
  final _listScrollController = ScrollController();

  // 排序档位（#26：会话内存态，退出即回 manual；#37 manual 档下行
  // 长按拖拽把手重排 + midpoint 落库）
  TaskSortKey _sortKey = TaskSortKey.manual;

  // 隐藏已完成（Logbook 治理）：与桌面同默认开；会话内存态（与 _sortKey
  // 同模式先例——视图态不跨页持久，退出即回默认）。done 视图下不参与
  // 过滤（完成集入口），开关图标同步置灰
  bool _hideDone = true;

  static const _sortChoices = {
    TaskSortKey.manual: '拖拽顺序',
    TaskSortKey.due: '截止时间',
    TaskSortKey.priority: '优先级',
    TaskSortKey.title: '标题',
    TaskSortKey.created: '创建时间',
  };

  @override
  void dispose() {
    _reorderScrollController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  /// 长按 FAB：拉模板列表弹选择，选中后 payload 预填新建表单
  ///（模板选择是低频入口，长按避免与点击新建抢占；无模板静默无反应）
  Future<void> _pickTemplateAndCreate() async {
    try {
      final templates =
          await ref.read(orbitBridgeProvider).templatesList();
      if (!mounted || templates.isEmpty) return;
      final colors = AppColors.ofContext(context);
      final tpl = await showModalBottomSheet<TodoTemplate>(
        context: context,
        backgroundColor: colors.popup,
        shape: bottomSheetTopShape,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppDimens.space16),
                child: Text('从模板新建',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.titleText)),
              ),
              for (final t in templates)
                ListTile(
                  title: Text(t.name,
                      style:
                          TextStyle(fontSize: 14, color: colors.bodyText)),
                  onTap: () => Navigator.pop(ctx, t),
                ),
            ],
          ),
        ),
      );
      if (tpl == null || !mounted) return;
      await showTodoFormSheet(
        context,
        defaultProjectId: widget.query.projectId,
        quickView: widget.query.quickView,
        presetTemplate: parseTemplatePayload(tpl.payload),
      );
    } catch (_) {
      /* 模板拉取失败：静默（长按入口可选，不炸主流程） */
    }
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

  // ── 长按拖拽重排（#37；仅 manual 档）──

  /// 拖拽落位：以语义插入位的相邻两条 position 取中值落库（midpointPosition
  /// 纯函数与桌面 midpoint 同口径：前缺省 0、后缺省 100000），完成后
  /// invalidate 以服务端权威顺序刷新；拖拽期间行序由 ReorderableListView
  /// 自管，落库失败 invalidate 兜底回原序。
  ///
  /// 落位邻居必须与 build 的 visible 同口径（含 hideDone 过滤）——
  /// 否则 UI 行数与计算索引错位，中值取到错误的相邻行。
  Future<void> _reorderTasks(int oldIndex, int newIndex) async {
    final tasks = ref.watch(todoTasksProvider(const TaskListQuery())).value ??
        const <TodoTask>[];
    final visible = sortTasks(
        filterTasks(tasks, widget.query, hideDone: _hideDone), _sortKey);
    final reordered = reorderItems(visible, oldIndex, newIndex);
    final dragged = reordered[newIndex];
    final prevPos = newIndex > 0 ? reordered[newIndex - 1].position : null;
    final nextPos =
        newIndex + 1 < reordered.length ? reordered[newIndex + 1].position : null;
    final mid = midpointPosition(prevPos, nextPos);
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoTaskUpdatePosition(dragged.id, mid.round());
    } catch (_) {
      WaitToast.destructive('排序失败');
    } finally {
      ref.invalidate(todoTasksProvider);
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
          icon: Icons.copy_rounded,
          label: '复制任务',
          onTap: () => _duplicateTask(task),
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

  // #37 复制任务：克隆后 toast + 刷新
  Future<void> _duplicateTask(TodoTask task) async {
    try {
      final copy = await ref.read(orbitBridgeProvider).todoTaskDuplicate(task.id);
      if (mounted) WaitToast.success('已复制为「${copy.title}」');
    } catch (_) {
      if (mounted) WaitToast.destructive('复制失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks =
        ref.watch(todoTasksProvider(const TaskListQuery())).value ?? [];
    final projects = ref.watch(todoProjectsProvider).value ?? [];

    // done 快捷视图 → Logbook 分组态（按完成日倒序，与桌面同口径）；
    // 隐藏开关不参与（完成集入口）。其余视图照旧平铺 + 逾期置顶
    final isLogbook = widget.query.quickView == QuickViewKey.done;

    final visible = isLogbook
        ? filterTasks(tasks, widget.query)
        : sortTasks(
            filterTasks(tasks, widget.query, hideDone: _hideDone), _sortKey);
    final projectById = {for (final p in projects) p.id: p};

    // 逾期置顶分组（性能批次 UX 优化，与桌面同口径）：逾期行渲染在列表
    // 顶部的红调区块，其余照旧——长按拖拽语义不受影响（重排仍走原序数组）
    final overdueGroups = groupOverdueFirst(visible);

    // Logbook 分组（done 视图）：按完成日倒序，组内完成时刻倒序
    final doneGroups = isLogbook ? groupDoneByDay(visible) : <DoneDayGroup>[];

    // 动态标题：项目名 / 未分组 / 视图名
    final title = switch (widget.query) {
      TaskFilterInput(projectId: final id?) =>
          projectById[id]?.title ?? '项目',
      TaskFilterInput(ungrouped: true) => '未分组',
      _ => widget.query.quickView?.label ?? '任务',
    };
    final emptyMessage = emptyMessageFor(widget.query);
    final colors = AppColors.ofContext(context);
    // 长按拖拽（#37）：仅 manual 档（拖拽顺序档）启用重排；其余档
    // 顺序由排序键决定，拖了也会被覆盖（与桌面 sortable 同口径）
    final reorderable = _sortKey == TaskSortKey.manual;

    final listPadding = EdgeInsets.only(
      top: MediaQuery.of(context).padding.top +
          LiquidGlassTitleBar.rowHeight +
          AppDimens.space8,
      bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
    );

    Widget buildTile(TodoTask task, {required Widget? dragHandle}) {
      final project =
          task.projectId != null ? projectById[task.projectId] : null;
      return TodoTaskTile(
        task: task,
        projectTitle: project?.title,
        projectColorHex: project?.hexColor,
        onOpen: () => context.push('/todo/${task.id}'),
        onToggleDone: () => _toggleDone(task),
        onLongPress: () => _showTaskActions(task),
        onDelete: () => _deleteTask(task),
        dragHandle: dragHandle,
      );
    }

    final Widget list = visible.isEmpty
        ? Padding(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top +
                  LiquidGlassTitleBar.rowHeight,
            ),
            child: EmptyState(message: emptyMessage),
          )
        : isLogbook
            ? _LogbookList(
                groups: doneGroups,
                padding: listPadding,
                buildTile: buildTile,
              )
            : reorderable
            ? ReorderableListView.builder(
                key: const ValueKey('reorderable-task-list'),
                scrollController: _reorderScrollController,
                padding: listPadding,
                buildDefaultDragHandles: false,
                itemCount: visible.length,
                onReorderItem: (oldIndex, newIndex) =>
                    _reorderTasks(oldIndex, newIndex),
                proxyDecorator: (child, index, animation) => AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final elevated = Curves.easeOut.transform(
                      Tween<double>(begin: 0, end: 1).evaluate(animation),
                    );
                    return Material(
                      elevation: 6 * elevated,
                      borderRadius: AppShapes.medium,
                      color: Colors.transparent,
                      child: child,
                    );
                  },
                  child: child,
                ),
                itemBuilder: (context, index) {
                  final task = visible[index];
                  return ReorderableDragStartListener(
                    key: ValueKey('reorder-task-${task.id}'),
                    index: index,
                    child: buildTile(
                      task,
                      dragHandle: Icon(
                        Icons.drag_handle_rounded,
                        size: AppDimens.iconSizeMd,
                        color: colors.secondaryText,
                      ),
                    ),
                  );
                },
              )
            : ListView.builder(
                controller: _listScrollController,
                padding: listPadding,
                // 逾期置顶（非重排档）：逾期行 + 区块头算作前置 item，
                // 后接 rest 任务行——单一 builder 保持懒加载，不额外组 chunk
                itemCount: overdueGroups.overdue.isNotEmpty
                    ? overdueGroups.overdue.length + 1 + overdueGroups.rest.length
                    : overdueGroups.rest.length,
                itemBuilder: (context, index) {
                  final od = overdueGroups.overdue;
                  if (od.isNotEmpty && index == od.length) {
                    // 逾期区尾部即为「其余」分隔（区块头随首行渲染在 index 0 前，
                    // 见下方 header 判定）；此处渲染 rest 区标题行
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppDimens.space4),
                      child: Text(
                        '  其余任务',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                      ),
                    );
                  }
                  final isOverdueZone = od.isNotEmpty && index <= od.length;
                  if (od.isNotEmpty && index == 0) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space4),
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  size: AppDimens.iconSizeSm,
                                  color: colors.destructive),
                              const SizedBox(width: AppDimens.space4),
                              Text(
                                '逾期 · ${od.length}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: colors.destructive,
                                ),
                              ),
                            ],
                          ),
                        ),
                        buildTile(od[0], dragHandle: null),
                      ],
                    );
                  }
                  final task = isOverdueZone
                      ? od[index - 1]
                      : overdueGroups.rest[index - od.length - 1];
                  return buildTile(task, dragHandle: null);
                },
              );

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: list),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: title,
              // 跟随当前档位的活跃列表控制器（#37 双控制器分体后按档取用）
              scrollOffsetListenable: ScrollOffsetListenable(
                reorderable ? _reorderScrollController : _listScrollController,
              ),
              actions: [
                // 隐藏已完成开关（Logbook 治理，默认开；done 视图置灰——
                // 完成集入口开关无意义）。图标态：隐藏=实心可见性，显示=划线
                IconButton(
                  onPressed: isLogbook
                      ? null
                      : () => setState(() => _hideDone = !_hideDone),
                  tooltip: _hideDone ? '显示已完成任务' : '隐藏已完成任务',
                  icon: Icon(
                    _hideDone
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: AppDimens.iconSizeMd,
                    color: isLogbook
                        ? colors.titleText.withValues(alpha: 0.3)
                        : colors.titleText,
                  ),
                ),
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
          // FAB：右下，新建携 defaultProjectId=当前 projectId；
          // 快捷视图入口携 view（#39 视图内新建自动带标记）
          Positioned(
            right: AppDimens.space16,
            bottom: AppDimens.gestureInsetFallback + AppDimens.space16,
            child: GlassFab(
              accentColor: OrbitAccents.themeAccent,
              onPressed: () => showTodoFormSheet(
                context,
                defaultProjectId: widget.query.projectId,
                quickView: widget.query.quickView,
              ),
              // 长按 = 从模板新建（有模板才有此入口；选择后 payload 预填表单）
              onLongPress: _pickTemplateAndCreate,
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
    this.projectColorHex,
    this.onDelete,
    this.dragHandle,
  });

  final TodoTask task;

  /// 副标题项目名；无项目（未分组）不渲染该段
  final String? projectTitle;

  /// 项目名着色 hex（#36：项目名按项目色渲染；空串回退次要文本色）
  final String? projectColorHex;
  final VoidCallback onToggleDone;
  final VoidCallback onLongPress;
  final VoidCallback onOpen;

  /// 右滑「删除」动作回调（null 时隐藏删除面板——搜索页等只读场景复用 Tile）
  final VoidCallback? onDelete;

  /// 长按拖拽把手（#37；侧栏项目行同款形制）：ReorderableDragStartListener
  /// 包装的拖拽图标，点击/长按启动重排；null（非 manual 档/只读场景）不渲染
  final Widget? dragHandle;

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
                                    // #36：项目名按项目色着字（无色回退次要色）
                                    color: (projectColorHex != null &&
                                            projectColorHex!.isNotEmpty)
                                        ? hexToColor(projectColorHex!,
                                            fallback: colors.secondaryText)
                                        : colors.secondaryText,
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
                // 拖拽把手（#37）：仅 manual 档渲染（传入方已 ReorderableDragStartListener 包装）
                if (dragHandle != null) ...[
                  const SizedBox(width: AppDimens.space8),
                  dragHandle!,
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

/// Logbook 分组列表（done 视图专用）：完成日头 + 任务行打平进单一
/// ListView.builder 保持懒加载（手法同上方逾期置顶分组——区块头
/// 随该组首行一起渲染，不额外组 chunk）
class _LogbookList extends StatelessWidget {
  final List<DoneDayGroup> groups;
  final EdgeInsets padding;
  final Widget Function(TodoTask task, {required Widget? dragHandle}) buildTile;

  const _LogbookList({
    required this.groups,
    required this.padding,
    required this.buildTile,
  });

  static const _weekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final now = DateTime.now();
    final todayKey = _dayKeyOf(now);
    // 打平：每项 = 组头（随首行渲染）或任务行
    final flat = <({DoneDayGroup g, TodoTask? task, bool isHead})>[];
    for (final g in groups) {
      for (var i = 0; i < g.tasks.length; i++) {
        flat.add((g: g, task: g.tasks[i], isHead: i == 0));
      }
    }
    return ListView.builder(
      controller: ScrollController(),
      padding: padding,
      itemCount: flat.length,
      itemBuilder: (context, index) {
        final item = flat[index];
        if (!item.isHead) return buildTile(item.task!, dragHandle: null);
        final g = item.g;
        final isToday = g.key == todayKey;
        final label = isToday
            ? '今天'
            : '${g.date.month}月${g.date.day}日 ${_weekdayNames[g.date.weekday - 1]}';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppDimens.space4),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline_rounded,
                      size: AppDimens.iconSizeSm,
                      color: OrbitAccents.doneGreen),
                  const SizedBox(width: AppDimens.space4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isToday ? OrbitAccents.todoAccent : colors.secondaryText,
                    ),
                  ),
                  const SizedBox(width: AppDimens.space4),
                  Text(
                    '${g.tasks.length} 条',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.secondaryText.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            buildTile(item.task!, dragHandle: null),
          ],
        );
      },
    );
  }

  static String _dayKeyOf(DateTime d) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p2(d.month)}-${p2(d.day)}';
  }
}
