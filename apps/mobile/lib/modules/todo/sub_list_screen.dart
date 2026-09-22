import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_elevation.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_fab.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../services/local_prefs.dart';
import 'form_bottom_sheet.dart';
import 'kanban_view.dart';
import 'logic/batch_actions.dart';
import 'logic/task_logic.dart';
import 'logic/template_apply.dart';
import 'logic/undo_stack.dart';
import 'logic/view_mode.dart';
import 'providers/todo_providers.dart';
import 'providers/undo_provider.dart';
import 'table_view.dart';
import '../../core/theme/icon_map.dart';

/// 任务子列表 /todo/tasks（docs/05 §4.2 + 移动端任务书）
///
/// 入口三参数互斥：projectId > ungrouped > view（task_logic 同款优先级）。
/// 列表消费共享 filterTasks/sortTasks；空态文案按入口映射；
/// 右下 OrbitFab 新建（携 defaultProjectId）；Tile 长按弹操作菜单
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

  // 隐藏已完成（Logbook 治理）：与桌面同默认开；本机偏好持久化
  //（LocalPrefs，键值同桌面 localStorage `todo_hide_done`，退出重进保持档位）。
  // done 视图下不参与过滤（完成集入口），开关图标同步置灰
  bool _hideDone = LocalPrefs.getBool(_hideDoneKey, fallback: true);

  /// 隐藏已完成持久化键（与桌面 constants.ts LS_HIDE_DONE 同值）
  static const _hideDoneKey = 'todo_hide_done';

  static const _sortChoices = {
    TaskSortKey.manual: '拖拽顺序',
    TaskSortKey.due: '截止时间',
    TaskSortKey.priority: '优先级',
    TaskSortKey.title: '标题',
    TaskSortKey.created: '创建时间',
  };

  /// 优先级下限档位（对齐桌面 task-panel 的优先级筛选下拉；null = 不限）
  static const _priorityChoices = <int, String>{
    1: '低及以上',
    2: '中及以上',
    3: '高及以上',
    4: '紧急及以上',
    5: '仅立即处理',
  };

  // 视图模式与看板分组（本机偏好持久化，键名对齐桌面 localStorage）
  TaskViewMode _viewMode = loadViewMode();
  KanbanGroupBy _kanbanGroupBy = loadKanbanGroupBy();

  // 列表内附加过滤（对齐桌面工具栏三枚筛选；会话态不持久化——语义是
  // "临时收窄当前视图"，持久化会让用户下次进入看到莫名变少的列表）
  TaskListFilters _filters = TaskListFilters.empty;

  // 多选选中集（会话态，依附当前筛选结果；见 undo_provider 注释说明为何
  // 刻意不做全局 Provider）。非空即选择模式。
  final Set<int> _selected = {};

  /// 批量动作进行中（防重复触发；批量期间串行写库）
  bool _batchBusy = false;

  @override
  void dispose() {
    _reorderScrollController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  /// 视图模式抽屉（视图三档 + 看板分组两段式同屉分区，避免嵌套弹层）
  void _showViewSheet() {
    final colors = AppColors.ofContext(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            _sheetSectionTitle(sheetContext, '视图模式'),
            for (final m in TaskViewMode.values)
              _sheetRow(
                sheetContext,
                icon: m.icon,
                label: m.label,
                selected: m == _viewMode,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _setViewMode(m);
                },
              ),
            if (_viewMode == TaskViewMode.kanban) ...[
              Divider(
                height: AppDimens.space12,
                color: colors.divider,
              ),
              _sheetSectionTitle(sheetContext, '看板分组'),
              for (final g in KanbanGroupBy.values)
                _sheetRow(
                  sheetContext,
                  icon: g == KanbanGroupBy.project
                      ? OrbitIcons.folder
                      : OrbitIcons.flag,
                  label: g.label,
                  selected: g == _kanbanGroupBy,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _setKanbanGroupBy(g);
                  },
                ),
            ],
            SizedBox(height: AppDimens.gestureInsetFallback / 2),
          ],
        ),
      ),
    );
  }

  void _setViewMode(TaskViewMode mode) {
    if (!mounted) return;
    setState(() => _viewMode = mode);
    unawaited(LocalPrefs.setString(viewModePrefsKey, mode.name));
  }

  void _setKanbanGroupBy(KanbanGroupBy by) {
    if (!mounted) return;
    setState(() => _kanbanGroupBy = by);
    unawaited(LocalPrefs.setString(kanbanGroupByPrefsKey, by.name));
  }

  /// 列表内过滤抽屉（状态 / 优先级下限 / 标签三档，chip 即点即生效）
  ///
  /// 单屉三段而非「主屉→子屉」两段：三个维度可组合，多开一层会让用户
  /// 看不到已选项之间的联动；chip 行高满足热区且一屏容纳。
  void _showFilterSheet() {
    final colors = AppColors.ofContext(context);
    final labels = ref.read(todoLabelsProvider).value ?? const <TodoLabel>[];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                _sheetSectionTitle(sheetContext, '状态'),
                _chipRow([
                  _filterChip('全部', _filters.status == null, () {
                    setSheetState(() {});
                    _setFilters(_filters.copyWith(status: null));
                  }),
                  for (final s in const ['pending', 'doing', 'done'])
                    _filterChip(statusLabel(s), _filters.status == s, () {
                      setSheetState(() {});
                      _setFilters(_filters.copyWith(status: s));
                    }),
                ]),
                _sheetSectionTitle(sheetContext, '优先级下限'),
                _chipRow([
                  _filterChip('全部', _filters.priorityMin == null, () {
                    setSheetState(() {});
                    _setFilters(_filters.copyWith(priorityMin: null));
                  }),
                  for (final e in _priorityChoices.entries)
                    _filterChip(e.value, _filters.priorityMin == e.key, () {
                      setSheetState(() {});
                      _setFilters(_filters.copyWith(priorityMin: e.key));
                    }),
                ]),
                _sheetSectionTitle(sheetContext, '标签'),
                if (labels.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppDimens.space16),
                    child: Text(
                      '还没有标签可筛选',
                      style:
                          TextStyle(fontSize: 12, color: colors.secondaryText),
                    ),
                  )
                else
                  _chipRow([
                    _filterChip('全部', _filters.labelId == null, () {
                      setSheetState(() {});
                      _setFilters(_filters.copyWith(labelId: null));
                    }),
                    for (final l in labels)
                      _filterChip(
                        l.title,
                        _filters.labelId == l.id,
                        () {
                          setSheetState(() {});
                          _setFilters(_filters.copyWith(labelId: l.id));
                        },
                        dotHex: l.hexColor,
                      ),
                  ]),
                if (!_filters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: AppDimens.space16,
                      right: AppDimens.space16,
                      top: AppDimens.space12,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () {
                          setSheetState(() {});
                          _setFilters(TaskListFilters.empty);
                        },
                        child: const Text('清除全部筛选'),
                      ),
                    ),
                  ),
                SizedBox(height: AppDimens.gestureInsetFallback / 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setFilters(TaskListFilters next) {
    if (!mounted) return;
    setState(() => _filters = next);
  }

  Widget _sheetSectionTitle(BuildContext ctx, String title) {
    final colors = AppColors.ofContext(ctx);
    return Padding(
      padding: const EdgeInsets.only(
        left: AppDimens.space16,
        right: AppDimens.space16,
        top: AppDimens.space16,
        bottom: AppDimens.space8,
      ),
      child: Text(
        title,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: colors.titleText),
      ),
    );
  }

  Widget _sheetRow(
    BuildContext ctx, {
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = AppColors.ofContext(ctx);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: AppDimens.touchTarget,
        child: Row(
          children: [
            const SizedBox(width: AppDimens.space16),
            Icon(icon, size: AppDimens.iconSizeMd, color: colors.bodyText),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 15, color: colors.bodyText),
              ),
            ),
            if (selected)
              Icon(OrbitIcons.check,
                  size: AppDimens.iconSizeMd, color: colors.accent),
            const SizedBox(width: AppDimens.space16),
          ],
        ),
      ),
    );
  }

  Widget _chipRow(List<Widget> chips) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
        child: Wrap(
          spacing: AppDimens.space8,
          runSpacing: AppDimens.space8,
          children: chips,
        ),
      );

  Widget _filterChip(String label, bool selected, VoidCallback onTap,
      {String? dotHex}) {
    final colors = AppColors.ofContext(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space12,
          vertical: AppDimens.space8,
        ),
        decoration: BoxDecoration(
          color: selected
              ? OrbitAccents.themeAccent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: AppShapes.small,
          border: Border.all(
            color: selected ? OrbitAccents.themeAccent : colors.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotHex != null) ...[
              Container(
                width: AppDimens.colorDotSize - 4,
                height: AppDimens.colorDotSize - 4,
                decoration: BoxDecoration(
                  color: hexToColor(dotHex),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppDimens.space6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: selected
                    ? OrbitAccents.themeAccent
                    : colors.bodyText,
              ),
            ),
          ],
        ),
      ),
    );
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
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '删除任务',
      message: '确定要删除任务「${task.title}」吗？删除后将移入回收站，可在回收站中恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(orbitBridgeProvider).todoTaskDelete(task.id);
      ref.invalidate(todoTasksProvider);
      // 删除可撤销（桌面 use-undoable-delete 同语义）：撤销 = 从回收站恢复
      _offerUndo(UndoEntry(
        label: '已删除 1 个任务',
        restoreTaskIds: [task.id],
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (_) {
      WaitToast.destructive('删除失败');
    }
  }

  // ── 多选与批量操作（对齐桌面 batch-actions 的动作集裁剪版）──

  bool get _selectionMode => _selected.isNotEmpty;

  /// 长按菜单「多选」进入选择态：列表档专用（看板/表格的卡片热区与
  /// 分组语义下多选会与横滑/列内滚动抢手势，桌面看板同样无多选）
  void _enterSelection(TodoTask task) {
    setState(() => _selected.add(task.id));
  }

  void _toggleSelect(int taskId) {
    setState(() {
      if (!_selected.remove(taskId)) _selected.add(taskId);
    });
  }

  void _exitSelection() {
    setState(_selected.clear);
  }

  /// 选中集（按当前缓存快照取，保证批量 patch 的「原值」与落库一致）
  List<TodoTask> _selectedTasks() {
    final tasks = ref.read(todoTasksProvider).value ?? const <TodoTask>[];
    return tasks.where((t) => _selected.contains(t.id)).toList();
  }

  /// 批量动作统一入口：串行写库 + 单次收敛刷新 + 可撤销浮层
  ///
  /// 性能口径（AGENTS 内存/性能纪律）：批量期间**不逐条 invalidate**，
  /// 全部完成后失效一次并单次 refetch——N 条写各自刷一遍列表在万任务下
  /// 会触发 N 次全量重建。
  Future<void> _runBatch(
    BatchAction action, {
    int? priority,
    int? dueMs,
    int? projectId,
    TodoLabel? label,
  }) async {
    if (_selected.isEmpty || _batchBusy) return;
    final targets = _selectedTasks();
    if (targets.isEmpty) return;

    if (action == BatchAction.delete) {
      final ok = await showConfirmBottomSheet(
        context,
        title: '删除 ${targets.length} 个任务？',
        message: '删除后移入回收站，可在回收站中恢复。',
        confirmLabel: '删除',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }

    setState(() => _batchBusy = true);
    final bridge = ref.read(orbitBridgeProvider);
    final patches = <UndoTaskPatch>[];
    final linkIds = <int>[];
    var changed = 0;
    var failures = 0;

    try {
      for (final task in targets) {
        try {
          switch (action) {
            case BatchAction.delete:
              await bridge.todoTaskDelete(task.id);
              changed++;
            case BatchAction.toggleDone:
              final done = batchToggleDoneTarget(targets);
              final patch = batchDonePatch(task, done: done);
              if (patch == null) break;
              // 完成走 complete（重复任务单事务推进）；取消走普通 patch
              if (done) {
                await bridge.todoTaskComplete(task.id);
              } else {
                await bridge.todoTaskUpdate(task.id, encodePatch(patch));
              }
              // 反向补丁覆盖 done/done_at/status 三键：只回滚 done 会留下
              // 「未完成但 status=done」的不一致行
              patches.add(inversePatchOf(task, patch));
              changed++;
            case BatchAction.priority:
            case BatchAction.reschedule:
            case BatchAction.moveProject:
              final patch = batchFieldPatch(
                task,
                action: action,
                priority: priority,
                dueMs: dueMs,
                projectId: projectId,
              );
              if (patch == null) break;
              await bridge.todoTaskUpdate(task.id, encodePatch(patch));
              patches.add(inversePatchOf(task, patch));
              changed++;
            case BatchAction.addLabel:
              if (label == null) break;
              final link = await bridge.todoTaskLabelCreate(
                TodoTaskLabelCreateInput(taskId: task.id, labelId: label.id),
              );
              linkIds.add(link.taskLabelId);
              changed++;
          }
        } catch (_) {
          failures++;
        }
      }

      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider);
      if (action == BatchAction.addLabel) {
        ref.invalidate(taskLabelsProjectionProvider);
      }

      if (!mounted) return;
      _exitSelection();
      if (changed == 0) {
        WaitToast.info(failures > 0 ? '批量操作失败' : '选中项无需变更');
        return;
      }
      _offerUndo(UndoEntry(
        label: failures > 0
            ? '${batchUndoLabel(action, changed)}（$failures 条失败）'
            : batchUndoLabel(action, changed),
        patches: patches,
        restoreTaskIds:
            action == BatchAction.delete ? targets.map((t) => t.id).toList() : const [],
        detachLinkIds: linkIds,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  /// 把反向补丁入栈并挂出「撤销」浮层（停留 = 5s 撤销窗口，到期自动收起）
  void _offerUndo(UndoEntry entry) {
    ref.read(undoStackProvider).push(entry);
    WaitToast.global(
      entry.label,
      variant: WaitToastVariant.warning,
      // 回收站恢复指引只对删除类撤销成立（其余动作没有回收站语义）
      description: entry.restoreTaskIds.isNotEmpty
          ? '已移入回收站的任务可在回收站恢复'
          : null,
      actionLabel: '撤销',
      onAction: _undoLast,
      autoDismissAfter: WaitToast.undoDwell,
    );
  }

  /// 撤销最近一条：逐条应用反向补丁（串行）→ 单次收敛刷新
  Future<void> _undoLast() async {
    final entry = ref.read(undoStackProvider).pop();
    if (entry == null) return;
    final bridge = ref.read(orbitBridgeProvider);
    var ok = 0;
    try {
      for (final p in entry.patches) {
        try {
          await bridge.todoTaskUpdate(p.taskId, encodePatch(p.patch));
          ok++;
        } catch (_) {
          /* 单条失败不阻断其余回滚 */
        }
      }
      for (final id in entry.restoreTaskIds) {
        try {
          await bridge.trashTaskRestore(id);
          ok++;
        } catch (_) {
          /* 已被彻底删除则跳过 */
        }
      }
      for (final linkId in entry.detachLinkIds) {
        try {
          await bridge.todoTaskLabelDelete(linkId);
          ok++;
        } catch (_) {
          /* 关联已不存在则跳过 */
        }
      }
    } finally {
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider);
      ref.invalidate(taskLabelsProjectionProvider);
      ref.invalidate(trashTasksProvider);
    }
    if (!mounted) return;
    WaitToast.success(ok > 0 ? '已撤销（$ok 项）' : '撤销失败');
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
    final tasks =
        ref.read(todoTasksProvider).value ?? const <TodoTask>[];
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
        // 多选入口（仅有列表档长按手势的语境；看板/表格的卡片长按留给
        // 单条操作，与桌面看板无多选同口径）
        if (_viewMode == TaskViewMode.list)
          MoreActionItem(
            icon: OrbitIcons.listChecks,
            label: '多选',
            onTap: () => _enterSelection(task),
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
          onTap: () => _toggleMyDay(task),
        ),
        MoreActionItem(
          icon: OrbitIcons.star,
          label: task.isStarred ? '取消收藏' : '收藏',
          color: OrbitAccents.starYellow,
          onTap: () => _toggleFavorite(task),
        ),
        MoreActionItem(
          icon: OrbitIcons.copy,
          label: '复制任务',
          onTap: () => _duplicateTask(task),
        ),
        MoreActionItem(
          icon: OrbitIcons.delete,
          label: '删除',
          color: OrbitAccents.overdueRed,
          onTap: () => _deleteTask(task),
        ),
      ],
    );
  }

  // ── 批量动作的参数抽屉（选择类交互统一底部抽屉） ──

  Future<void> _batchPickPriority() async {
    await showSelectBottomSheet<int>(
      context,
      title: '批量设置优先级',
      current: null,
      items: [
        for (var p = 0; p <= 5; p++)
          SelectItem(
            value: p,
            label: priorityLabel(p),
            colorDot: hexToColor(priorityColorHex(p)),
          ),
      ],
      onSelect: (p) => _runBatch(BatchAction.priority, priority: p),
    );
  }

  Future<void> _batchPickReschedule() async {
    await showSelectBottomSheet<BatchReschedule>(
      context,
      title: '批量改期',
      current: null,
      items: [
        for (final c in BatchReschedule.values)
          SelectItem(value: c, label: c.label),
      ],
      onSelect: (c) => _runBatch(BatchAction.reschedule,
          dueMs: batchRescheduleMs(c)),
    );
  }

  Future<void> _batchPickProject() async {
    final projects = ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
    await showSelectBottomSheet<int?>(
      context,
      title: '移动到项目',
      current: null,
      items: [
        const SelectItem<int?>(value: null, label: '未分组'),
        for (final p in projects)
          SelectItem<int?>(
            value: p.id,
            label: p.title,
            colorDot: hexToColor(p.hexColor),
          ),
      ],
      onSelect: (id) => _runBatch(BatchAction.moveProject, projectId: id),
    );
  }

  Future<void> _batchPickLabel() async {
    final labels = ref.read(todoLabelsProvider).value ?? const <TodoLabel>[];
    if (labels.isEmpty) {
      WaitToast.info('还没有标签，先在任务详情里创建一个');
      return;
    }
    await showSelectBottomSheet<TodoLabel>(
      context,
      title: '批量加标签',
      current: null,
      items: [
        for (final l in labels)
          SelectItem(
            value: l,
            label: l.title,
            colorDot: hexToColor(l.hexColor),
          ),
      ],
      onSelect: (l) => _runBatch(BatchAction.addLabel, label: l),
    );
  }

  void _onBatchAction(BatchAction action) {
    switch (action) {
      case BatchAction.toggleDone:
        _runBatch(BatchAction.toggleDone);
      case BatchAction.priority:
        _batchPickPriority();
      case BatchAction.reschedule:
        _batchPickReschedule();
      case BatchAction.moveProject:
        _batchPickProject();
      case BatchAction.addLabel:
        _batchPickLabel();
      case BatchAction.delete:
        _runBatch(BatchAction.delete);
    }
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

  // ── 行入场动画（仅标准列表分支，见 [_withEntrance]）──

  /// 上一次 build 已见的任务 id（首次为 null = 尚未播种）
  Set<int>? _knownTaskIds;

  /// 本次 build 新出现的任务 id（本次播放行入场）
  Set<int> _appearedTaskIds = const {};

  /// 追踪新出现任务；在 build 内直改字段（不 setState，不触发重建）。
  ///
  /// 播种时机取**首次拿到非空数据**的那一帧（不是首次 build）：provider 首帧
  /// 通常仍在加载（`value ?? []` 为空），若此时就播种，数据到达后整表都会播
  /// 入场（观感是列表整体撑开）。同样地，滚动出场不重播——虚拟化复用重建时
  /// id 已在集合中；清空视图后重新出现的行会正常播一次。
  void _trackTaskAppearance(List<TodoTask> tasks) {
    final ids = {for (final t in tasks) t.id};
    final known = _knownTaskIds;
    if (known == null) {
      if (tasks.isEmpty) return; // 数据未就绪：保持未播种
      _knownTaskIds = ids;
      _appearedTaskIds = const {};
      return;
    }
    _appearedTaskIds = ids.difference(known);
    _knownTaskIds = ids;
  }

  /// 标准列表分支的行入场包装。manual 重排档与 Logbook 分组档有意不做：
  /// 二者共用同一 buildTile，逐行追加入场需镜像数据源，回归面过大
  /// （边界记 docs/05 §九）。
  Widget _withEntrance(TodoTask task, Widget tile) => _RowEntrance(
        play: _appearedTaskIds.contains(task.id),
        child: tile,
      );

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(todoTasksProvider);
    final tasks = tasksAsync.value ?? [];
    // 初次加载（无旧值可守）才给骨架：重查/下拉刷新走旧内容，不闪骨架
    final tasksLoading = !tasksAsync.hasValue && tasksAsync.isLoading;
    final projects = ref.watch(todoProjectsProvider).value ?? [];

    // done 快捷视图 → Logbook 分组态（按完成日倒序，与桌面同口径）；
    // 隐藏开关不参与（完成集入口）。其余视图照旧平铺 + 逾期置顶
    final isLogbook = widget.query.quickView == QuickViewKey.done;

    // 标签投影（A4 只读聚合）：列表内标签筛选与看板/表格标签色点共用；
    // 投影未就绪时回落空表（标签档不生效、色点不渲染，不阻塞列表）
    final labelRows = ref.watch(taskLabelsProjectionProvider).value ??
        const <TaskLabelsProjection>[];
    final labelIdsByTask = indexLabelIdsByTask(labelRows);
    final labelsByTask = {for (final r in labelRows) r.taskId: r.labels};

    final visible = applyTaskListFilters(
      isLogbook
          ? filterTasks(tasks, widget.query)
          : sortTasks(
              filterTasks(tasks, widget.query, hideDone: _hideDone), _sortKey),
      _filters,
      labelIdsByTask: labelIdsByTask,
    );
    final projectById = {for (final p in projects) p.id: p};

    _trackTaskAppearance(visible);

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
    // 筛选生效时给出更贴切的空态文案（否则用户会以为是数据丢了）
    final filteredEmpty = !_filters.isEmpty && tasks.isNotEmpty;
    final emptyMessage =
        filteredEmpty ? '没有符合筛选条件的任务' : emptyMessageFor(widget.query);
    final colors = AppColors.ofContext(context);
    // 长按拖拽（#37）：仅 manual 档（拖拽顺序档）启用重排；其余档
    // 顺序由排序键决定，拖了也会被覆盖（与桌面 sortable 同口径）。
    // 选择态强制回落普通列表：拖拽把手与「点行切换选中」抢同一手势
    final reorderable = _sortKey == TaskSortKey.manual && !_selectionMode;
    // 看板/表格仅在非 Logbook 态生效：完成历史按日分组的语义在分列/表格
    // 里会丢失（桌面同口径——done 档列表被 LogbookView 接管）
    final showKanban = _viewMode == TaskViewMode.kanban && !isLogbook;
    final showTable = _viewMode == TaskViewMode.table && !isLogbook;

    // 命中上限条幅（A5，桌面 task-panel 同口径）：单份缓存拉取被截断时
    // 明确告知列表不完整；条幅常驻标题栏下沿，列表顶部让出同高，
    // 收窄范围后结果集低于上限即自动消失
    final truncated = tasks.length >= taskListPageSize;
    final topInset =
        MediaQuery.of(context).padding.top + OrbitPageHeader.rowHeight;
    final listPadding = EdgeInsets.only(
      top: topInset +
          AppDimens.space8 +
          (truncated ? _TruncationBanner.height : 0),
      bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
    );

    Widget buildTile(TodoTask task, {required Widget? dragHandle}) {
      final project =
          task.projectId != null ? projectById[task.projectId] : null;
      // 选择态换用选区行：不复用 TodoTaskTile 是因为它的勾选框语义是
      // 「完成」，选择态下同一个圆圈的勾选含义会变成「选中」，语义冲突
      if (_selectionMode) {
        return _SelectionRow(
          task: task,
          selected: _selected.contains(task.id),
          projectTitle: project?.title,
          onTap: () => _toggleSelect(task.id),
        );
      }
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

    final Widget list = tasksLoading
        // 初次加载骨架：8 行任务行占位（复选圆 + 标题行 + 元信息行）
        ? _TaskListSkeleton(padding: listPadding)
        : visible.isEmpty
            ? Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top +
                      OrbitPageHeader.rowHeight,
                ),
                // 空态给出口：筛选没结果就清筛选，否则直接开新建表单（与右下
                // OrbitFab 同一入口，列表空时 FAB 仍可见但离拇指更远）
                child: EmptyState(
                  message: emptyMessage,
                  actionLabel: filteredEmpty ? '清除筛选' : '新建任务',
                  onAction: filteredEmpty
                      ? () => _setFilters(TaskListFilters.empty)
                      : () => showTodoFormSheet(
                            context,
                            defaultProjectId: widget.query.projectId,
                            quickView: widget.query.quickView,
                          ),
                ),
            )
        : showKanban
            ? KanbanBoard(
                columns:
                    groupTasksForKanban(visible, _kanbanGroupBy, projects),
                padding: listPadding,
                onToggleDone: _toggleDone,
                onOpen: (t) => context.push('/todo/${t.id}'),
                onLongPress: _showTaskActions,
                // 按状态分组时列头不代表项目，卡片补一行项目名
                projectTitleOf: _kanbanGroupBy == KanbanGroupBy.status
                    ? (t) => t.projectId == null
                        ? null
                        : projectById[t.projectId]?.title
                    : null,
                labelDotsByTask: labelsByTask,
              )
            : showTable
                ? TaskTableView(
                    tasks: visible,
                    padding: listPadding,
                    onToggleDone: _toggleDone,
                    onOpen: (t) => context.push('/todo/${t.id}'),
                    onLongPress: _showTaskActions,
                    projectTitleOf: (t) => t.projectId == null
                        ? null
                        : projectById[t.projectId]?.title,
                    labelDotsByTask: labelsByTask,
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
                // 拖拽起止各一次轻触感反馈（对齐微软 To-Do 拖动确认）
                onReorderStart: (_) => HapticFeedback.selectionClick(),
                onReorderEnd: (_) => HapticFeedback.selectionClick(),
                proxyDecorator: (child, index, animation) => AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final elevated = AppMotion.standard.transform(
                      Tween<double>(begin: 0, end: 1).evaluate(animation),
                    );
                    // 抬起：轻微放大 + 阴影加深（抬手即销毁，不驻留）
                    final scale = 1 + (AppMotion.dragLiftScale - 1) * elevated;
                    return Transform.scale(
                      scale: scale,
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
                itemBuilder: (context, index) {
                  final task = visible[index];
                  return ReorderableDragStartListener(
                    key: ValueKey('reorder-task-${task.id}'),
                    index: index,
                    child: buildTile(
                      task,
                      dragHandle: Icon(
                        OrbitIcons.drag,
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
                // 逾期置顶（非重排档）：逾期区头行（与首条逾期行同行）+ 逾期行 +
                // 「其余任务」分隔行算作前置 item，后接 rest 任务行——单一 builder
                // 保持懒加载，不额外组 chunk。
                //
                // 索引口径（od 非空时）：item 0 = 区块头 + od[0]，
                // item 1..od.length-1 = od[1..]，item od.length = 分隔行，
                // 其后 = rest[0..]；**od 为空时必须直接映射 rest[index]**——
                // 曾经的 `index - od.length - 1` 在无逾期任务时算得 rest[-1]，
                // 只在非 manual 档 / 多选态（回落到本 ListView.builder 分支）
                // 触发 RangeError 崩屏（2026-09-20 多选崩溃修复）。
                itemCount: overdueGroups.overdue.isNotEmpty
                    ? overdueGroups.overdue.length + 1 + overdueGroups.rest.length
                    : overdueGroups.rest.length,
                itemBuilder: (context, index) {
                  final od = overdueGroups.overdue;
                  final rest = overdueGroups.rest;
                  if (od.isEmpty) {
                    return _withEntrance(
                        rest[index], buildTile(rest[index], dragHandle: null));
                  }
                  if (index == 0) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space4),
                          child: Row(
                            children: [
                              Icon(OrbitIcons.warning,
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
                        _withEntrance(od[0], buildTile(od[0], dragHandle: null)),
                      ],
                    );
                  }
                  if (index < od.length) {
                    return _withEntrance(
                        od[index], buildTile(od[index], dragHandle: null));
                  }
                  if (index == od.length) {
                    // 逾期区尾部即为「其余」分隔（区块头随首行渲染在 index 0 前）
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
                  final task = rest[index - od.length - 1];
                  return _withEntrance(task, buildTile(task, dragHandle: null));
                },
              );

    // 下拉刷新：只接标准列表 / Logbook / 手动重排分支——看板是横滑、表格是定表头
    // 横滚列，RefreshIndicator 会与横向拖拽抢同一手势；空态无 Scrollable 也触发不了。
    // 指示条用 edgeOffset 下移到 OrbitPageHeader 之下，否则被页头盖住看不见。
    final Widget body = visible.isEmpty || showKanban || showTable
        ? list
        : RefreshIndicator(
            onRefresh: () => pullToRefresh(ref),
            color: OrbitAccents.themeAccent,
            edgeOffset: topInset,
            displacement: AppDimens.space8,
            child: list,
          );

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            // 视图切换过渡：列表 / 看板 / 表格三态用淡入 + 轻微上滑衔接
            //（viewSwitch 200ms；key 只跟视图走——任务增删、骨架落定、
            // 下拉刷新都不触发，仍是瞬时替换，避免整列表无谓重播）
            child: AnimatedSwitcher(
              duration: AppMotion.viewSwitch,
              switchInCurve: AppMotion.decelerate,
              switchOutCurve: AppMotion.accelerate,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.03),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: KeyedSubtree(
                key: ValueKey('view-${_viewMode.name}'),
                child: body,
              ),
            ),
          ),
          if (truncated)
            Positioned(
              top: topInset,
              left: 0,
              right: 0,
              child: const _TruncationBanner(),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              // 选择态下标题栏让位给「已选 N 项」，与桌面多选头部同口径
              title: _selectionMode ? '已选 ${_selected.length} 项' : title,
              actions: _selectionMode
                  ? [
                      TextButton(
                        onPressed: _batchBusy
                            ? null
                            : () => setState(() {
                                  _selected
                                    ..clear()
                                    ..addAll(visible.map((t) => t.id));
                                }),
                        child: const Text('全选'),
                      ),
                      IconButton(
                        onPressed: _batchBusy ? null : _exitSelection,
                        tooltip: '退出多选',
                        icon: Icon(
                          OrbitIcons.close,
                          size: AppDimens.iconSizeMd,
                          color: colors.titleText,
                        ),
                      ),
                    ]
                  : [
                // 视图模式（列表/看板/表格；看板态下同屉追加分组切换）。
                // 选择类交互统一底部抽屉（AGENTS.md 移动端约定），非 PopupMenu
                IconButton(
                  onPressed: _showViewSheet,
                  tooltip: '视图模式',
                  icon: Icon(
                    _viewMode.icon,
                    size: AppDimens.iconSizeMd,
                    color: colors.titleText,
                  ),
                ),
                // 列表内过滤（状态/优先级下限/标签三档；已启用档数出角标）
                IconButton(
                  onPressed: _showFilterSheet,
                  tooltip: '筛选',
                  icon: _filters.isEmpty
                      ? Icon(
                          OrbitIcons.filterList,
                          size: AppDimens.iconSizeMd,
                          color: colors.titleText,
                        )
                      : Badge(
                          label: Text('${_filters.activeCount}'),
                          backgroundColor: OrbitAccents.todoAccent,
                          child: Icon(
                            OrbitIcons.filterList,
                            size: AppDimens.iconSizeMd,
                            color: colors.titleText,
                          ),
                        ),
                ),
                // 隐藏已完成开关（Logbook 治理，默认开；done 视图置灰——
                // 完成集入口开关无意义）。图标态：隐藏=实心可见性，显示=划线。
                // 切换即落本机偏好（LocalPrefs），下次进入沿用上次档位
                IconButton(
                  onPressed: isLogbook
                      ? null
                      : () {
                          final next = !_hideDone;
                          setState(() => _hideDone = next);
                          unawaited(LocalPrefs.setBool(_hideDoneKey, next));
                        },
                  tooltip: _hideDone ? '显示已完成任务' : '隐藏已完成任务',
                  icon: Icon(
                    _hideDone
                        ? OrbitIcons.eyeOff
                        : OrbitIcons.eye,
                    size: AppDimens.iconSizeMd,
                    color: isLogbook
                        ? colors.titleText.withValues(alpha: 0.3)
                        : colors.titleText,
                  ),
                ),
                // 排序档位抽屉（#26；manual = position 拖拽顺序）——
                // 选择类交互统一底部抽屉（AGENTS.md 移动端约定），不用 PopupMenu
                IconButton(
                  onPressed: () => showSelectBottomSheet<TaskSortKey>(
                    context,
                    title: '排序方式',
                    items: [
                      for (final e in _sortChoices.entries)
                        SelectItem(value: e.key, label: e.value),
                    ],
                    current: _sortKey,
                    onSelect: (k) {
                      if (mounted) setState(() => _sortKey = k);
                    },
                  ),
                  tooltip: '排序方式',
                  icon: Icon(
                    OrbitIcons.sort,
                    size: AppDimens.iconSizeMd,
                    color: AppColors.ofContext(context).titleText,
                  ),
                ),
              ],
            ),
          ),
          // FAB：右下，新建携 defaultProjectId=当前 projectId；
          // 快捷视图入口携 view（#39 视图内新建自动带标记）。
          // 选择态下让位给批量工具条（两者同占右下角，重叠会误触）
          if (!_selectionMode)
            Positioned(
              right: AppDimens.space16,
              bottom: AppDimens.gestureInsetFallback + AppDimens.space16,
              child: OrbitFab(
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
          if (_selectionMode) _batchToolbar(colors),
        ],
      ),
    );
  }

  /// 批量动作工具条（底部浮动，从下沿上滑进入）
  ///
  /// 六个一级动作横排 + 横向滚动：一屏放不下时横滑而非折行，避免工具条
  /// 高度随动作数增加挤压列表可视区。
  Widget _batchToolbar(AppColorSet colors) {
    return Positioned(
      left: AppDimens.space12,
      right: AppDimens.space12,
      bottom: AppDimens.gestureInsetFallback + AppDimens.space8,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
          decoration: BoxDecoration(
            color: colors.popup,
            borderRadius: AppShapes.medium,
            border: Border.all(color: colors.outline),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF101828).withValues(alpha: 0.16),
                blurRadius: 24,
                offset: const Offset(0, 8),
                spreadRadius: -4,
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppDimens.space8),
                  child: Row(
                    children: [
                      for (final a in BatchAction.values) ...[
                        _batchButton(a),
                        const SizedBox(width: AppDimens.space4),
                      ],
                    ],
                  ),
                ),
              ),
              if (_batchBusy)
                const Padding(
                  padding: EdgeInsets.only(right: AppDimens.space12),
                  child: SizedBox(
                    width: AppDimens.iconSizeSm,
                    height: AppDimens.iconSizeSm,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: OrbitAccents.themeAccent,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _batchButton(BatchAction action) {
    final colors = AppColors.ofContext(context);
    final destructive = action == BatchAction.delete;
    final tint = destructive ? colors.destructive : colors.bodyText;
    return InkWell(
      borderRadius: AppShapes.small,
      onTap: _batchBusy ? null : () => _onBatchAction(action),
      child: SizedBox(
        width: 64,
        height: AppDimens.touchTarget,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(action.icon, size: AppDimens.iconSizeMd, color: tint),
            const SizedBox(height: AppDimens.space2),
            // 64×48 定宽格里的按钮文案：字号档放大（或系统无障碍放大）时
            // 由 FittedBox 等比缩小，不撑破格宽
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                action.label,
                style: TextStyle(fontSize: 11, color: tint),
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主列表初次加载骨架：8 行任务行占位（复选圆 + 标题行 + 元信息行）
///
/// 只在"无旧值可守"的初次加载出现（tasksLoading 见 build）；重查/下拉刷新
/// 走旧内容，不闪骨架。行高贴近真实任务行，落定替换时跳变最小。
class _TaskListSkeleton extends StatelessWidget {
  const _TaskListSkeleton({required this.padding});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: padding,
      itemCount: 8,
      itemBuilder: (context, index) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppDimens.space12),
        child: Row(
          children: [
            OrbitSkeleton.circle(size: 22),
            SizedBox(width: AppDimens.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OrbitSkeleton.line(width: 180, height: 15),
                  SizedBox(height: AppDimens.space6),
                  OrbitSkeleton.line(width: 130, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 行入场过渡（仅标准列表分支）：新行高度展开 + 淡入
///
/// [play] 为假时原样返回子组件——绝大多数行不引入任何额外层级，
/// 虚拟化复用与滚动出场因此既无额外开销也无视觉扰动。
class _RowEntrance extends StatelessWidget {
  const _RowEntrance({required this.play, required this.child});

  final bool play;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!play) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      builder: (context, t, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: t,
          child: Opacity(opacity: t, child: child),
        ),
      ),
      child: child,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
                  onPressed: (_) {
                    HapticFeedback.mediumImpact();
                    onDelete?.call();
                  },
                  backgroundColor: colors.destructive,
                  foregroundColor: Colors.white,
                  icon: OrbitIcons.delete,
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
            onPressed: (_) {
              HapticFeedback.mediumImpact();
              onToggleDone();
            },
            backgroundColor: OrbitAccents.todoAccent,
            foregroundColor: Colors.white,
            icon: task.isDone ? OrbitIcons.undo : OrbitIcons.check,
            label: task.isDone ? '恢复' : '完成',
            borderRadius: AppShapes.medium,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space12, vertical: 4),
        child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppShapes.medium,
          side: isDark
              ? BorderSide(color: colors.outline)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        elevation: isDark ? 0 : 1,
        shadowColor: AppElevation.shadowColor,
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
                      AnimatedStrikethrough(
                        text: task.title,
                        done: task.isDone,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: colors.titleText,
                        ),
                        doneColor: colors.titleText,
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
                    OrbitIcons.star,
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
                  Icon(OrbitIcons.success,
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

/// 命中上限条幅（A5）：单份任务缓存命中 taskListPageSize 时列表不完整——
/// 文案与桌面 task-panel 条幅同口径，收窄范围（搜索/项目/快捷视图）后
/// 结果集低于上限即自动消失。固定高度（定值），列表顶部按其让位。
class _TruncationBanner extends StatelessWidget {
  const _TruncationBanner();

  /// 条幅高度（固定值）：列表 padding 与 Positioned 共用，改这里即两处同步
  static const height = 44.0;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Container(
      height: height,
      color: colors.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space4,
      ),
      child: Row(
        children: [
          Icon(
            OrbitIcons.warning,
            size: AppDimens.iconSizeSm,
            color: colors.warning,
          ),
          const SizedBox(width: AppDimens.space4),
          Expanded(
            child: Text(
              '任务数超过单次加载上限 ${_withThousands(taskListPageSize)} 条，'
              '当前列表不完整——请用搜索、项目或快捷视图收窄范围',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.warning),
            ),
          ),
        ],
      ),
    );
  }

  /// 千分位（与桌面 toLocaleString("zh-CN") 同观感；仅用于上限常量展示）
  static String _withThousands(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}

/// 多选态任务行（行高与列表档 56 对齐，整行可点即切换选中）
///
/// 刻意不复用 [TodoTaskTile]：后者的圆形勾选框语义是「完成」，选择态下
/// 同一个控件的勾选含义会变成「选中」——用独立行把两种语义彻底分开，
/// 也顺带屏蔽了行内侧滑/勾选在批量语境下的误触。
class _SelectionRow extends StatelessWidget {
  const _SelectionRow({
    required this.task,
    required this.selected,
    required this.onTap,
    this.projectTitle,
  });

  final TodoTask task;
  final bool selected;
  final VoidCallback onTap;
  final String? projectTitle;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final overdue = isOverdue(task);

    return InkWell(
      onTap: onTap,
      child: Container(
        height: AppDimens.listItemHeight,
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
        decoration: BoxDecoration(
          color: selected
              ? OrbitAccents.todoAccent.withValues(alpha: 0.10)
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(color: colors.divider),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? OrbitIcons.success
                  : OrbitIcons.circle,
              size: AppDimens.iconSizeLg,
              color: selected ? OrbitAccents.todoAccent : colors.secondaryText,
            ),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedStrikethrough(
                    text: task.title,
                    done: task.isDone,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 15,
                      color: colors.bodyText,
                    ),
                    doneColor: colors.bodyText,
                  ),
                  if (projectTitle != null || task.dueDate != null) ...[
                    const SizedBox(height: AppDimens.space2),
                    Text(
                      [
                        ?projectTitle,
                        if (task.dueDate != null) formatYmd(task.dueDate!),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: overdue
                            ? colors.destructive
                            : colors.secondaryText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              width: AppDimens.colorDotSize / 2,
              height: AppDimens.colorDotSize,
              decoration: BoxDecoration(
                color: hexToColor(priorityColorHex(task.priority)),
                borderRadius: AppShapes.small,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
