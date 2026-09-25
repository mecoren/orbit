import 'dart:async';

import 'package:flutter/gestures.dart';
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
import '../../shared/widgets/shadcn/orbit_dropdown_panel.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_list_card.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../services/local_prefs.dart';
import 'form_bottom_sheet.dart';
import 'kanban_view.dart';
import 'matrix_view.dart';
import 'logic/batch_actions.dart';
// as rep：规避 Flutter widgets 自带 RepeatMode 类名冲突（同 detail_screen）
import 'logic/quick_add_context.dart';
import 'logic/repeat_logic.dart' as rep;
import 'logic/task_logic.dart';
import 'logic/undo_stack.dart';
import 'logic/view_mode.dart';
import 'providers/todo_providers.dart';
import 'providers/undo_provider.dart';
import 'quick_add_sheet.dart';
import 'table_view.dart';
import '../../core/theme/icon_map.dart';

/// 任务子列表 /todo/tasks（docs/05 §4.2 + 移动端任务书）
///
/// 入口三参数互斥：projectId > ungrouped > view（task_logic 同款优先级）。
/// 「今天」页签与页签栈内入栈共用本屏：页签根传 `showBack: false` 并以
/// `titleOverride` 换页头文案（页头自动带日期副标）；列表消费共享
/// filterTasks/sortTasks；空态文案按入口映射；Tile 长按弹操作菜单
/// （编辑 / 星标切换 / 删除确认）；manual 档长按整行拾起拖动重排
/// （#37，position midpoint 落库与桌面同口径；原地松手仍是操作菜单）。
class SubListScreen extends ConsumerStatefulWidget {
  const SubListScreen({
    super.key,
    required this.query,
    this.showBack = true,
    this.titleOverride,
  });

  /// 路由 query 参数解析结果（view/projectId/ungrouped 三选一）
  final TaskFilterInput query;

  /// 页头返回键（页签根页关闭——底部导航承担回退语义）
  final bool showBack;

  /// 页头标题覆盖（null 用入口语义名：项目名 / 未分组 / 视图名）
  final String? titleOverride;

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

  // 排序档位（#26：会话内存态，退出即回 manual；#37 manual 档下整行
  // 长按拾起拖动重排 + midpoint 落库）
  TaskSortKey _sortKey = TaskSortKey.manual;

  /// 本次长按拾起的行下标（[onReorderStart] 记，[onReorderEnd] 读后清）
  int? _dragFromIndex;

  /// 本次按下的落点（指针 down 记；位移测量的原点）
  Offset? _pressOrigin;

  /// 本次长按拾起后手指是否真的移动过（超过 [kTouchSlop]）。
  ///
  /// manual 档长按手势被拖动独占（行内 InkWell 的长按必须置空，见
  /// [TodoTaskTile.onLongPress]），操作菜单因此改由「拾起后原地松手」承接：
  /// 移动过即视为在排序，松手不弹菜单；纹丝未动才当长按菜单——两条路径共用
  /// 同一个长按，行尾不必再挂拖拽把手图标。
  ///
  /// **位移判据不问列表要**：[ReorderableListView] 只在真的换了槽位时才回调
  /// （拖开一圈又落回原槽位 → 全程无回调），且它几个回调的先后不由调用方掌握；
  /// 原始指针事件才是可靠来源（[Listener] 收事件不经手势竞技场裁决）。
  bool _pressMoved = false;

  // 已完成区展开态（列表尾部「已完成 N ⌄」折叠卡）：默认收起——与改版前
  // 「默认隐藏已完成」的观感一致（收起时列表只呈现未完成任务）。
  //
  // 旧键 `todo_hide_done`（页头 eye 开关时代）只作**一次性回落**读取：
  // 老用户上次把已完成显出来过，这次进入就记住展开；此后只读写新键。
  bool _doneExpanded = LocalPrefs.getBool(
    _doneOpenKey,
    fallback: !LocalPrefs.getBool(_legacyHideDoneKey, fallback: true),
  );

  /// 已完成区展开态持久化键（新键；语义是「展开」而非「隐藏」）
  static const _doneOpenKey = 'todo_done_section_open';

  /// 页头 eye 开关时代的旧键（只读回落一次，见 [_doneExpanded]）
  static const _legacyHideDoneKey = 'todo_hide_done';

  /// 已完成卡内联上限：展开只直显最近这么多条（完成时刻倒序），其余走卡内
  /// 「查看全部」入口进完成集视图——卡片是 Column 而非懒加载列表，必须设界
  static const _doneInlineMax = 20;

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
  // 视图档在 [initState] 播种：项目视图优先取该项目记忆的档位（`widget` 要到
  // initState 才可读，故不做字段初始值）
  late TaskViewMode _viewMode;
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
  void initState() {
    super.initState();
    _viewMode = loadViewModeForProject(widget.query.projectId);
    // 登记新建落点：底部导航中央添加钮读取本屏筛选入参做预填（退场清空）
    QuickAddContext.set(widget.query);
  }

  @override
  void dispose() {
    QuickAddContext.set(null);
    _reorderScrollController.dispose();
    _listScrollController.dispose();
    // 退场窗内直接离屏：补一次失效，避免主列表缓存残留已删行
    //（窗后 mounted 熄火，本该触发的那次 invalidate 没发生）
    if (_exitingIds.isNotEmpty) ref.invalidate(todoTasksProvider);
    super.dispose();
  }

  /// 按下：重置位移原点（时间上先于 500ms 的长按拾起）
  void _onPressDown(PointerDownEvent event) {
    _pressOrigin = event.position;
    _pressMoved = false;
  }

  /// 移动：越过 [kTouchSlop] 即认定「移动过」。
  ///
  /// 拾起前的位移不必在这里管：[DelayedMultiDragGestureRecognizer] 自身的
  /// 滑动阈值更严——超过 slop 就直接判废，拖动根本不会开始。
  void _onPressMove(PointerMoveEvent event) {
    final origin = _pressOrigin;
    if (origin == null || _pressMoved) return;
    if ((event.position - origin).distance > kTouchSlop) {
      _pressMoved = true;
    }
  }

  /// 切视图档：写「当前上下文档」——项目上下文写该项目的档位（下次进这个项目
  /// 沿用），其余视图写全局档。全局档语义 = 「非项目视图的默认值」，
  /// 项目档没设过时也以它为初值（见 `logic/view_mode.dart`）
  void _setViewMode(TaskViewMode mode) {
    if (!mounted) return;
    setState(() => _viewMode = mode);
    final projectId = widget.query.projectId;
    if (projectId != null) {
      unawaited(saveProjectViewMode(projectId, mode));
    } else {
      unawaited(LocalPrefs.setString(viewModePrefsKey, mode.name));
    }
  }

  void _setKanbanGroupBy(KanbanGroupBy by) {
    if (!mounted) return;
    setState(() => _kanbanGroupBy = by);
    unawaited(LocalPrefs.setString(kanbanGroupByPrefsKey, by.name));
  }

  /// 切排序档（#26；manual = position 拖拽顺序，档位集合 [_sortChoices] 单一口径）
  void _setSortKey(TaskSortKey key) {
    if (!mounted) return;
    setState(() => _sortKey = key);
  }

  /// 页头 ⋮ 下拉面板（2026-09-23）：两组条目——「这个列表」与「怎么操作」
  ///
  /// 页头由「返回 + 标题 + 四枚图标」收敛成「返回 + 标题 + ⋮」；视图档与排序档
  /// 在面板内**就地展开**子项（选中打勾），展开期间其余条目置灰
  /// （口径见 [showOrbitDropdownPanel]）。上下文条目按需出现：
  /// 「编辑项目」只在项目视图有，「看板分组」只在看板档有——常驻只会添噪音。
  void _showOverflowPanel() {
    final projectId = widget.query.projectId;
    showOrbitDropdownPanel(
      context,
      topInset: MediaQuery.of(context).padding.top + OrbitPageHeader.rowHeight,
      groups: [
        [
          if (projectId != null)
            OrbitPanelItem(
              icon: OrbitIcons.edit,
              label: '编辑项目',
              onTap: () => context.push('/todo/projects/$projectId/edit'),
            ),
          OrbitPanelItem(
            icon: _viewMode.icon,
            label: '视图',
            children: [
              for (final m in TaskViewMode.values)
                OrbitPanelItem(
                  icon: m.icon,
                  label: '${m.label}视图',
                  checked: m == _viewMode,
                  onTap: () => _setViewMode(m),
                ),
            ],
          ),
          if (_viewMode == TaskViewMode.kanban)
            OrbitPanelItem(
              icon: OrbitIcons.flag,
              label: '看板分组',
              children: [
                for (final g in KanbanGroupBy.values)
                  OrbitPanelItem(
                    icon: g == KanbanGroupBy.project
                        ? OrbitIcons.folder
                        : OrbitIcons.flag,
                    label: g.label,
                    checked: g == _kanbanGroupBy,
                    onTap: () => _setKanbanGroupBy(g),
                  ),
              ],
            ),
          OrbitPanelItem(
            icon: OrbitIcons.success,
            label: '隐藏已完成',
            checked: !_doneExpanded,
            onTap: _toggleDoneSection,
          ),
        ],
        [
          OrbitPanelItem(
            icon: OrbitIcons.filterList,
            label: '筛选',
            trailingLabel:
                _filters.isEmpty ? null : '已启用 ${_filters.activeCount} 项',
            onTap: _showFilterSheet,
          ),
          OrbitPanelItem(
            icon: OrbitIcons.sort,
            label: '排序方式',
            children: [
              for (final e in _sortChoices.entries)
                OrbitPanelItem(
                  icon: OrbitIcons.sort,
                  label: e.value,
                  checked: e.key == _sortKey,
                  onTap: () => _setSortKey(e.key),
                ),
            ],
          ),
          OrbitPanelItem(
            icon: OrbitIcons.listChecks,
            label: '批量选择',
            onTap: _enterSelectionFromPanel,
          ),
        ],
      ],
    );
  }

  /// 面板「批量选择」入口：多选态以「选中集非空」为准，故先选上当前视图的
  /// 首条未完成任务——与长按菜单「多选」同语义（那里选的是被长按的那行）
  void _enterSelectionFromPanel() {
    final tasks = ref.read(todoTasksProvider).value ?? const <TodoTask>[];
    final first = sortTasks(filterTasks(tasks, widget.query), _sortKey)
        .where((t) => !t.isDone)
        .firstOrNull;
    if (first == null) {
      WaitToast.info('没有可多选的任务');
      return;
    }
    setState(() => _selected.add(first.id));
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
        builder: (sheetContext, setSheetState) => OrbitSheetScaffold(
          maxHeightFactor: 0.7,
          // 三段筛选 chip 自管滚动，「清除全部筛选」固定在尾部（见 build 尾部）
          contentScrollable: false,
          content: ListView(
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
                SizedBox(height: AppDimens.gestureInsetFallback / 2),
              ],
            ),
          // 清除动作固定在抽屉底部（有筛选时才出现）；chip 即点即生效，无需确认钮
          actions: _filters.isEmpty
              ? null
              : OrbitSheetActions(
                  confirmLabel: '清除全部筛选',
                  onConfirm: () {
                    setSheetState(() {});
                    _setFilters(TaskListFilters.empty);
                  },
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
  ///
  /// 标准分支内的离场型切换播退场（[_removeRowWithExit]）；在原地的
  /// （勾选确认/完成划线）保持现状不动——docs/05 §9.2 的其余边界不碰。
  Future<void> _toggleDone(TodoTask task) async {
    if (_exitApplies && _toggleWillLeave(task)) {
      try {
        if (task.isDone) {
          await ref.read(orbitBridgeProvider).todoTaskUpdate(
                task.id,
                encodePatch(buildDoneTogglePatch(task)),
              );
        } else {
          final res = await ref.read(orbitBridgeProvider).todoTaskComplete(task.id);
          _notifyNextInstance(res);
        }
        unawaited(_removeRowWithExit(task.id));
      } catch (_) {
        WaitToast.destructive('完成失败');
      }
      return;
    }
    if (task.isDone) return _patchTask(task.id, buildDoneTogglePatch(task));
    try {
      final res = await ref.read(orbitBridgeProvider).todoTaskComplete(task.id);
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider);
      _notifyNextInstance(res);
    } catch (_) {
      WaitToast.destructive('完成失败');
    }
  }

  /// 重复任务推进提示：明确告知「列表里多出来的那条」从哪来（与桌面同文案）
  void _notifyNextInstance(CompleteTaskResult res) {
    final next = res.nextInstance;
    if (next != null && next.dueDate != null) {
      WaitToast.success('已完成，已生成下一期：${rep.formatCnDate(next.dueDate!)}');
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

  /// 退场动画生效 gate：仅标准列表分支（[_withEntrance] 那一支）。
  /// 看板/表格/Logbook/手动重排/多选态全部走即时失效——行组件与
  /// 手势体系不同，不掺和（批量删除同样即时，见 [_onBatchAction]）。
  bool get _exitApplies =>
      !_selectionMode &&
      _viewMode == TaskViewMode.list &&
      widget.query.quickView != QuickViewKey.done &&
      _sortKey != TaskSortKey.manual;

  /// 标准分支内：切换完成态导致行离场 ⟺ 开了状态筛选（改写 status 即失配），
  /// 或「完成」动作本身——未完成任务区只承载未完成行，勾完即离场（改由尾部
  /// 已完成卡承载）。取消完成是**进**未完成区而非离场，不播 ghost。
  bool _toggleWillLeave(TodoTask task) =>
      _filters.status != null || !task.isDone;

  /// 已完成区展开 / 收起（本机偏好持久化，下次进入沿用上次档位）
  void _toggleDoneSection() {
    final next = !_doneExpanded;
    setState(() => _doneExpanded = next);
    unawaited(LocalPrefs.setBool(_doneOpenKey, next));
  }

  /// 写后退场（删除 / 离场型完成共用）：
  ///
  /// 1. 写操作由调用方先行 await 落库（ADR 0005：不延迟提交），失败直接
  ///    抛错 toast，不进退场、不失效——列表原样不动；
  /// 2. 成功后立即失效除主列表外的缓存——徽标/详情/统计/回收站即时更新
  ///    （option A：计数先行，只留行晚 300ms）；
  /// 3. 主列表延迟失效：ghost 行（旧对象）先播 300ms 退场（[_RowExit]），
  ///    再 invalidate，主列表即收敛；
  /// 4. 延迟窗内撤销恢复（[_undoLast]）会先摘掉 ghost，后续失效照常——
  ///    列表显示恢复后的行，不闪；
  /// 5. 退场窗内直接离屏：dispose 补一次失效，避免缓存残留已删行。
  Future<void> _removeRowWithExit(int taskId) async {
    setState(() => _exitingIds.add(taskId));
    // 与 invalidateBusinessCaches 同清单，唯独不碰 todoTasksProvider
    ref.invalidate(todoProjectsProvider);
    ref.invalidate(todoArchivedProjectsProvider);
    ref.invalidate(todoLabelsProvider);
    ref.invalidate(taskLabelsProjectionProvider);
    ref.invalidate(taskDetailProvider);
    ref.invalidate(taskActivityProvider);
    ref.invalidate(syncConfigProvider);
    ref.invalidate(trashTasksProvider);
    ref.invalidate(statsProvider);
    ref.invalidate(savedFiltersProvider);
    ref.invalidate(searchProvider);
    await Future.delayed(AppMotion.slow);
    if (!mounted) return;
    setState(() => _exitingIds.remove(taskId));
    ref.invalidate(todoTasksProvider);
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
      if (_exitApplies) {
        // 标准分支：ghost 退场（其余缓存已在 runner 内即时失效）
        unawaited(_removeRowWithExit(task.id));
      } else {
        ref.invalidate(todoTasksProvider);
      }
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
    var spawnedRepeats = 0; // 批量完成里推进出下一期的重复任务条数

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
                final res = await bridge.todoTaskComplete(task.id);
                if (res.nextInstance != null) spawnedRepeats++;
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
      ),
      // 重复任务推进提示并入撤销浮层副文案（单槽 toast，避免互相顶掉）
      extraDescription: spawnedRepeats > 0 ? '已为 $spawnedRepeats 条重复任务生成下一期' : null,
      );
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  /// 把反向补丁入栈并挂出「撤销」浮层（停留 = 5s 撤销窗口，到期自动收起）；
  /// [extraDescription] 可选副文案（批量完成混有重复任务时告知已生成下一期）
  void _offerUndo(UndoEntry entry, {String? extraDescription}) {
    ref.read(undoStackProvider).push(entry);
    WaitToast.global(
      entry.label,
      variant: WaitToastVariant.warning,
      // 回收站恢复指引只对删除类撤销成立（其余动作没有回收站语义）
      description: entry.restoreTaskIds.isNotEmpty
          ? '已移入回收站的任务可在回收站恢复'
          : extraDescription,
      actionLabel: '撤销',
      onAction: _undoLast,
      autoDismissAfter: WaitToast.undoDwell,
    );
  }

  /// 撤销最近一条：逐条应用反向补丁（串行）→ 单次收敛刷新
  Future<void> _undoLast() async {
    final entry = ref.read(undoStackProvider).pop();
    if (entry == null) return;
    // 先摘 ghost：延迟窗内的撤销恢复必须立刻显示回行，不能等退场播完
    //（后到的延迟失效照常触发，届时只是重读一次，无闪）
    if (mounted) {
      setState(() {
        _exitingIds.removeWhere(entry.restoreTaskIds.contains);
        for (final p in entry.patches) {
          _exitingIds.remove(p.taskId);
        }
      });
    }
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
  /// 落位邻居必须与 build 的可重排分支同口径（仅未完成任务、同排序档）——
  /// 否则 UI 行数与计算索引错位，中值取到错误的相邻行。
  /// 重排档渲染流：逾期置顶**平铺**（与标准分支的逾期置顶段同序）。
  /// 头行/分隔行若插进流会打破 ReorderableListView 的槽位索引，
  /// 故只排序不插行；无逾期时原样返回（重排落库数学与旧口径一致）。
  List<TodoTask> _manualReorderStream(List<TodoTask> undone) {
    final grouped = groupOverdueFirst(undone);
    return grouped.overdue.isEmpty
        ? undone
        : [...grouped.overdue, ...grouped.rest];
  }

  Future<void> _reorderTasks(int oldIndex, int newIndex) async {
    final tasks =
        ref.read(todoTasksProvider).value ?? const <TodoTask>[];
    final visible = sortTasks(filterTasks(tasks, widget.query), _sortKey)
        .where((t) => !t.isDone)
        .toList();
    final reordered = reorderItems(_manualReorderStream(visible), oldIndex, newIndex);
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

  /// 正在退场的行 id（ghost：失效延迟 300ms 内仍用旧对象渲染 [_RowExit]；
  /// 写操作照常立即落库，延迟的只是主列表失效——见 [_removeRowWithExit]）
  final Set<int> _exitingIds = {};

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
  ///
  /// 退场 ghost 也挂在这里：失效延迟窗内，旧对象仍在 `visible` 里，
  /// 直接播 [_RowExit]——无需快照、不碰索引口径（逾期分组的 od 偏移
  /// 曾经出过 rest[-1] 崩屏，不另起一套索引映射）。
  Widget _withEntrance(TodoTask task, Widget tile) {
    if (_exitingIds.contains(task.id)) {
      // 窗内点击穿透禁掉：300ms 里重复点勾选/删除会打乱 ghost 与写入的对应
      return _RowExit(child: IgnorePointer(child: tile));
    }
    return _RowEntrance(
      play: _appearedTaskIds.contains(task.id),
      child: tile,
    );
  }

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

    // 提醒投影（A4 只读聚合）：行内提醒徽标数据源；同样在未就绪时回落空表
    final reminderRows = ref.watch(taskRemindersProjectionProvider).value ??
        const <TaskRemindersProjection>[];
    final remindersByTask = {
      for (final r in reminderRows) r.taskId: r.reminders,
    };

    // 关联计数投影（A4 只读聚合）：行内「有关联」徽标数据源；
    // 未就绪时回落空表（不渲染徽标，不阻塞列表）
    final dependencyRows = ref.watch(taskDependencyFlagsProvider).value ??
        const <TaskDependencyFlags>[];
    final relationCountByTask = {
      for (final r in dependencyRows) r.taskId: r.relationCount,
    };

    final visible = applyTaskListFilters(
      isLogbook
          ? filterTasks(tasks, widget.query)
          : sortTasks(
              // 列表档：完成行交给尾部「已完成」折叠卡承接（不再是页头开关
              // 一刀切隐藏）；看板 / 表格没有承接位，维持改版前的隐藏口径——
              // 完成历史混进卡片墙/表格会淹掉这两档的工作面板语义
              filterTasks(tasks, widget.query,
                  hideDone: _viewMode != TaskViewMode.list),
              _sortKey),
      _filters,
      labelIdsByTask: labelIdsByTask,
    );
    final projectById = {for (final p in projects) p.id: p};

    _trackTaskAppearance(visible);

    // 未完成区（列表本体；逾期置顶只作用于这一段）
    final undone =
        isLogbook ? const <TodoTask>[] : visible.where((t) => !t.isDone).toList();

    // 已完成区（列表尾部折叠卡的数据源；Logbook 本身即完成集，不重复一份）：
    // 完成时刻倒序——卡内直显最近 [_doneInlineMax] 条，其余走「查看全部」
    final done = isLogbook
        ? const <TodoTask>[]
        : (visible.where((t) => t.isDone).toList()
          ..sort((a, b) =>
              (b.doneAt ?? b.createdAt).compareTo(a.doneAt ?? a.createdAt)));

    // 逾期置顶分组（性能批次 UX 优化，与桌面同口径）：逾期行渲染在列表
    // 顶部的红调区块，其余照旧——长按拖拽语义不受影响（重排走下方
    // manualUndone 同口径平铺流）
    final overdueGroups = groupOverdueFirst(undone);
    final manualUndone = _manualReorderStream(undone);

    // Logbook 分组（done 视图）：按完成日倒序，组内完成时刻倒序
    final doneGroups = isLogbook ? groupDoneByDay(visible) : <DoneDayGroup>[];

    // 动态标题：页头覆盖文案（页签根）优先，否则按入口取项目名 / 未分组 / 视图名
    final title = widget.titleOverride ??
        switch (widget.query) {
          TaskFilterInput(projectId: final id?) =>
            projectById[id]?.title ?? '项目',
          TaskFilterInput(ungrouped: true) => '未分组',
          _ => widget.query.quickView?.label ?? '任务',
        };
    // 日期副标只在「今天」页签根出现（页签栈内的今天截止视图不带，与项目
    // 列表页头同构——有覆盖标题且无返回键即页签根）
    final showDateSubtitle =
        widget.query.quickView == QuickViewKey.today && !widget.showBack;
    // 筛选生效时给出更贴切的空态文案（否则用户会以为是数据丢了）
    final filteredEmpty = !_filters.isEmpty && tasks.isNotEmpty;
    final emptyMessage =
        filteredEmpty ? '没有符合筛选条件的任务' : emptyMessageFor(widget.query);
    final colors = AppColors.ofContext(context);
    // 长按拖拽（#37）：仅 manual 档（拖拽顺序档）启用重排；其余档
    // 顺序由排序键决定，拖了也会被覆盖（与桌面 sortable 同口径）。
    // 选择态强制回落普通列表：整行长按拾起与「点行切换选中」抢同一手势
    final reorderable = _sortKey == TaskSortKey.manual && !_selectionMode;
    // 看板/表格/矩阵仅在非 Logbook 态生效：完成历史按日分组的语义在分列/
    // 表格/象限里会丢失（桌面同口径——done 档列表被 LogbookView 接管）
    final showKanban = _viewMode == TaskViewMode.kanban && !isLogbook;
    final showTable = _viewMode == TaskViewMode.table && !isLogbook;
    final showMatrix = _viewMode == TaskViewMode.matrix && !isLogbook;

    // 命中上限条幅（A5，桌面 task-panel 同口径）：单份缓存拉取被截断时
    // 明确告知列表不完整；条幅常驻标题栏下沿，列表顶部让出同高，
    // 收窄范围后结果集低于上限即自动消失
    final truncated = tasks.length >= taskListPageSize;
    final topInset =
        MediaQuery.of(context).padding.top + OrbitPageHeader.rowHeight;
    // 底栏页签常驻（分支内容在其上方）：页尾只留呼吸留白；选择态另让出
    // 批量工具条整段占位（条体 + 底距 + 呼吸），末行不被浮动工具条遮住
    final listPadding = EdgeInsets.only(
      top: topInset +
          AppDimens.space8 +
          (truncated ? _TruncationBanner.height : 0),
      bottom: AppDimens.space16 +
          (_selectionMode ? _batchToolbarClearance : 0),
    );
    // 卡片列表（标准列表 / 重排档 / 骨架）在满幅 padding 上再让出卡片外缘：
    // 卡片是「页面里的一张卡」而非通栏表格；看板 / 表格 / Logbook 维持满幅。
    // 显式取四边（不用 add：ReorderableListView.padding 要求 EdgeInsets 而非
    // EdgeInsetsGeometry，链式调用的静态类型会退化成后者）
    final cardListPadding = EdgeInsets.fromLTRB(
      AppDimens.space12,
      listPadding.top,
      AppDimens.space12,
      listPadding.bottom,
    );

    Widget buildTile(TodoTask task,
        {bool draggable = false, OrbitCardEdge edge = OrbitCardEdge.none}) {
      final project =
          task.projectId != null ? projectById[task.projectId] : null;
      // 项目视图内行内不再重复项目名（页头已是该项目，行内重述是噪音）；
      // 快捷视图 / 未分组 / 搜索等跨项目语境保留项目名着色段
      final projectTitle =
          widget.query.projectId != null ? null : project?.title;
      // 行内提醒徽标：未来最近一条 / 全过期最早一条（完成实例不警示）
      final reminder = displayReminder(
        remindersByTask[task.id] ?? const <ProjectedReminder>[],
        DateTime.now().millisecondsSinceEpoch,
        taskDone: task.isDone,
      );
      // 选择态换用选区行：不复用 TodoTaskTile 是因为它的勾选框语义是
      // 「完成」，选择态下同一个圆圈的勾选含义会变成「选中」，语义冲突
      if (_selectionMode) {
        return _SelectionRow(
          task: task,
          selected: _selected.contains(task.id),
          projectTitle: projectTitle,
          onTap: () => _toggleSelect(task.id),
          edge: edge,
        );
      }
      return TodoTaskTile(
        task: task,
        projectTitle: projectTitle,
        projectColorHex: project?.hexColor,
        labels: labelsByTask[task.id] ?? const <ProjectedTaskLabel>[],
        reminder: reminder,
        // 行内关联徽标（C7）：投影未命中即 0（不渲染），> 0 才出徽标
        relationCount: relationCountByTask[task.id] ?? 0,
        onOpen: () => context.push('/todo/${task.id}'),
        onToggleDone: () => _toggleDone(task),
        // manual 档长按让位给整行拖动（原地松手由 _reorderEnd 兜回来弹菜单）
        onLongPress: draggable ? null : () => _showTaskActions(task),
        onDelete: () => _deleteTask(task),
        // 卡片段位（扁平行传 none，保持看板/表格/搜索口径）
        edge: edge,
      );
    }

    /// 已完成折叠卡（列表尾部独立卡片）
    ///
    /// 头行「已完成 N ⌄」+ 展开后的完成行 + 超出上限时的「查看全部」尾行，
    /// 三段共用同一张卡的段位（首段圆上角 / 末段圆下角）。
    ///
    /// 卡内行是 `Column`（整卡只能整体成段，套不进懒加载列表），故直显条数
    /// 必须设界——[_doneInlineMax] 之外的完成行交给完成集视图，万行完成历史
    /// 不会在展开瞬间全部实例化。
    Widget buildDoneCard() {
      final shown = _doneExpanded
          ? done.take(_doneInlineMax).toList()
          : const <TodoTask>[];
      final hasMore = _doneExpanded && done.length > shown.length;
      final segments = 1 + shown.length + (hasMore ? 1 : 0);
      var seg = 0;
      Widget next(Widget child) => OrbitCardSegment(
            edge: OrbitCardEdge.of(seg++, segments),
            child: child,
          );
      return Padding(
        // 与未完成任务区拉开一档卡距（同卡内段间不设距，靠 1px 分隔线）
        padding: const EdgeInsets.only(top: AppDimens.cardGap),
        child: AnimatedSize(
          duration: AppMotion.normal,
          curve: AppMotion.standard,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              next(_doneCardHeader(colors, done.length)),
              for (final t in shown) next(buildTile(t)),
              if (hasMore) next(_doneCardMore(colors, done.length)),
            ],
          ),
        ),
      );
    }

    // 标准列表条目表（懒加载：itemBuilder 按下标取一条构造，不预建行）
    //
    // 表化取代旧版「按下标反算 od / rest 归属」的算术：区块头与「其余任务」
    // 分隔行各自成条（旧版头行随 od[0] 同项渲染，段位只能落在任务行上），
    // 也因此不存在 od 为空时 rest[-1] 那类越界隐患。
    final entries = <_TaskListEntry>[
      if (overdueGroups.overdue.isNotEmpty) ...[
        const _TaskListEntry.overdueHead(),
        for (final t in overdueGroups.overdue) _TaskListEntry.task(t),
        // 「其余任务」只在真的还有其余行时才出来（旧版恒出，全部逾期时
        // 会在列表尾部留一个孤零零的分隔标签）
        if (overdueGroups.rest.isNotEmpty) const _TaskListEntry.restDivider(),
      ],
      for (final t in overdueGroups.rest) _TaskListEntry.task(t),
    ];

    final Widget list = tasksLoading
        // 初次加载骨架：8 行任务行占位（复选圆 + 标题行 + 元信息行）
        ? _TaskListSkeleton(padding: cardListPadding)
        : visible.isEmpty
            ? Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top +
                      OrbitPageHeader.rowHeight,
                ),
                // 空态给出口：筛选没结果就清筛选，否则直接开快速添加面板
                //（与底部导航中央添加钮同一入口）
                child: EmptyState(
                  message: emptyMessage,
                  actionLabel: filteredEmpty ? '清除筛选' : '新建任务',
                  onAction: filteredEmpty
                      ? () => _setFilters(TaskListFilters.empty)
                      : () => showQuickAddSheet(
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
                // 列卡与标准列表卡同让位：左右 12 页边（列间 12 由卡间距承担）
                padding: cardListPadding,
                onToggleDone: _toggleDone,
                onOpen: (t) => context.push('/todo/${t.id}'),
                onLongPress: _showTaskActions,
                // 按状态分组时列头不代表项目，卡片补一行项目名
                //（项目视图内页头已表达，行内不再重复）
                projectTitleOf: _kanbanGroupBy == KanbanGroupBy.status &&
                        widget.query.projectId == null
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
                : showMatrix
                    ? EisenhowerMatrixBoard(
                        tasks: visible,
                        // 象限卡/下钻卡与标准列表卡同让位：左右 12 页边
                        padding: cardListPadding,
                        buildTile: buildTile,
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
                padding: cardListPadding,
                buildDefaultDragHandles: false,
                // 重排只作用于未完成任务：已完成行在尾部折叠卡里（footer），
                // 全列可拖的约束下不能让它们混进 item。渲染流逾期置顶平铺，
                // 与标准分支同序（今天/近7天视图含逾期后，manual 档也先看到逾期）
                itemCount: manualUndone.length,
                footer: done.isEmpty ? null : buildDoneCard(),
                onReorderItem: (oldIndex, newIndex) {
                  _reorderTasks(oldIndex, newIndex);
                },
                // 拾起 / 落位各一次轻触感反馈（对齐微软 To-Do 拖动确认）
                onReorderStart: (index) {
                  HapticFeedback.selectionClick();
                  _dragFromIndex = index;
                },
                onReorderEnd: (index) {
                  HapticFeedback.selectionClick();
                  final from = _dragFromIndex;
                  _dragFromIndex = null;
                  // 拾起后原地松手（手指没动）= 长按菜单：manual 档行内长按已
                  // 让位给拖动，操作菜单入口由这里兜住，功能与样式两边不欠账
                  if (!_pressMoved &&
                      from != null &&
                      from < manualUndone.length) {
                    _showTaskActions(manualUndone[from]);
                  }
                },
                proxyDecorator: (child, index, animation) => AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final elevated = AppMotion.standard.transform(
                      Tween<double>(begin: 0, end: 1).evaluate(animation),
                    );
                    // 抬起：轻微放大 + 阴影加深（抬手即销毁，不驻留）。
                    // 底面给 surface：行本身是扁平透明行，抬起时要靠这层才
                    // 看得出「拿起来的是一张卡」，否则阴影会落空。
                    final scale = 1 + (AppMotion.dragLiftScale - 1) * elevated;
                    return Transform.scale(
                      scale: scale,
                      child: Material(
                        elevation: 6 * elevated,
                        borderRadius: AppShapes.medium,
                        clipBehavior: Clip.antiAlias,
                        color: Color.lerp(
                          Colors.transparent,
                          colors.surface,
                          elevated,
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: child,
                ),
                itemBuilder: (context, index) {
                  final task = manualUndone[index];
                  // 整行皆可长按拾起（无行尾把手图标）：500ms 长按后退化为
                  // 普通拖动，滚动与左右滑不受影响
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey('reorder-task-${task.id}'),
                    index: index,
                    // 原始指针监听（不参与手势竞争）只为记位移：列表自身
                    // 的回调给不出「拾起后动没动」，见 [_pressMoved]
                    child: Listener(
                      onPointerDown: _onPressDown,
                      onPointerMove: _onPressMove,
                      child: buildTile(
                        task,
                        draggable: true,
                        edge: OrbitCardEdge.of(index, undone.length),
                      ),
                    ),
                  );
                },
              )
            : ListView.builder(
                controller: _listScrollController,
                padding: cardListPadding,
                // 标准分支：条目表逐条懒加载（条目构造见 build 内 [entries]），
                // 尾部多一项 = 已完成折叠卡（各自成卡，不在同一张卡内）
                itemCount: entries.length + (done.isEmpty ? 0 : 1),
                itemBuilder: (context, index) {
                  if (index >= entries.length) return buildDoneCard();
                  final edge = OrbitCardEdge.of(index, entries.length);
                  final entry = entries[index];
                  final task = entry.task;
                  if (task != null) {
                    return _withEntrance(task, buildTile(task, edge: edge));
                  }
                  // 区块头 /「其余任务」分隔行：与任务行同卡，段位同源
                  return OrbitCardSegment(
                    edge: edge,
                    child: entry.isHead
                        ? _overdueHeadRow(colors, overdueGroups.overdue.length)
                        : _restDividerRow(colors, _restDividerLabel),
                  );
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
              showBack: widget.showBack,
              title: _selectionMode ? '已选 ${_selected.length} 项' : title,
              // 非选择态：标题旁挂未完成计数，页签根（今天）再带日期副标；
              // Logbook 态 undone 恒空，不渲染计数。count 与 Flexible 同行
              // 防长标题溢出
              titleWidget: _selectionMode
                  ? null
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: colors.titleText,
                                ),
                              ),
                            ),
                            if (undone.isNotEmpty) ...[
                              const SizedBox(width: AppDimens.space6),
                              Text(
                                '${undone.length}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colors.secondaryText,
                                ),
                              ),
                            ],
                          ],
                        ),
                        // 「今天」页签的日期副标（M月D日 周X）：页签根才出现
                        if (showDateSubtitle)
                          Text(
                            todayHeaderLabel(DateTime.now()),
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.2,
                              color: colors.secondaryText,
                            ),
                          ),
                      ],
                    ),
              // 完成进度线：只在「既有未完成又有已完成」时出现——看板/表格
              // 档隐藏完成行（done 空）、Logbook 恒为完成集（undone 空），
              // 进度线在这些档位只会误导
              progress: !_selectionMode && undone.isNotEmpty && done.isNotEmpty
                  ? done.length / (done.length + undone.length)
                  : null,
              actions: _selectionMode
                  ? [
                      TextButton(
                        onPressed: _batchBusy
                            ? null
                            : () => setState(() {
                                  _selected
                                    ..clear()
                                    // 全选只选**看得见**的：未完成任务区恒在；
                                    // 已完成卡收起时卡内行不在树上，展开时也只
                                    // 算直显的前 [_doneInlineMax] 条（否则批量
                                    // 删除会连带清掉屏上根本没出现的完成行）
                                    ..addAll(undone.map((t) => t.id))
                                    ..addAll(_doneExpanded
                                        ? done
                                            .take(_doneInlineMax)
                                            .map((t) => t.id)
                                        : const <int>[]);
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
                // 视图 / 筛选 / 排序三档收进 ⋮ 溢出菜单：四枚图标并排会把
                // 动态标题挤到只剩半行；筛选生效时 ⋮ 挂角标（否则列表莫名
                // 变少没有出处）。选择类交互仍走底部抽屉，非 PopupMenu
                IconButton(
                  onPressed: _showOverflowPanel,
                  tooltip: '更多操作',
                  icon: _filters.isEmpty
                      ? Icon(
                          OrbitIcons.moreVertical,
                          size: AppDimens.iconSizeMd,
                          color: colors.titleText,
                        )
                      : Badge(
                          label: Text('${_filters.activeCount}'),
                          // 计数/警示角标全项目统一逾期红（底栏页签角标同口径）
                          backgroundColor: OrbitAccents.overdueRed,
                          child: Icon(
                            OrbitIcons.moreVertical,
                            size: AppDimens.iconSizeMd,
                            color: colors.titleText,
                          ),
                        ),
                ),
              ],
            ),
          ),
          // 一级新建入口在底部导航中央添加钮（落点经 QuickAddContext 预填
          // 为当前视图）；选择态下底部是批量工具条
          if (_selectionMode) _batchToolbar(colors),
        ],
      ),
    );
  }

  /// 批量工具条在页尾的占位高度：条体（触控高 + 上下 8）+ 底距 + 呼吸各 8
  static const double _batchToolbarClearance =
      AppDimens.touchTarget + AppDimens.space8 * 4;

  /// 批量动作工具条（底部浮动，从下沿上滑进入）
  ///
  /// 六个一级动作横排 + 横向滚动：一屏放不下时横滑而非折行，避免工具条
  /// 高度随动作数增加挤压列表可视区。
  Widget _batchToolbar(AppColorSet colors) {
    return Positioned(
      left: AppDimens.space12,
      right: AppDimens.space12,
      bottom: AppDimens.space8,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
          decoration: BoxDecoration(
            color: colors.popup,
            borderRadius: AppShapes.medium,
            border: Border.all(color: colors.outline),
            // 浮空工具条：阴影走 e3（底部浮层档，向上投影压住列表）；
            // 原手写单阴影向下，在条下无内容处浪费、条上列表处缺投影
            boxShadow: AppElevation.ofContext(context, level: 3),
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

  // ── 卡片化列表的行内构件 ──

  /// 逾期区块头行（卡片首段）：警示图标 + 「逾期 · N」，红色为区块主信号
  Widget _overdueHeadRow(AppColorSet colors, int count) {
    return Container(
      constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(OrbitIcons.warning,
              size: AppDimens.iconSizeSm, color: OrbitAccents.overdueRed),
          const SizedBox(width: AppDimens.space4),
          Text(
            '逾期 · $count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: OrbitAccents.overdueRed,
            ),
          ),
        ],
      ),
    );
  }

  /// 「其余任务」分隔行的语境文案：today/week 视图的分隔线以下是**当日/近 7 天**
  /// 到期任务（逾期段在其上），按视图命名；项目等其余入口维持「其余任务」
  String get _restDividerLabel => switch (widget.query.quickView) {
        QuickViewKey.today => '今天',
        QuickViewKey.week => '近7天',
        _ => '其余任务',
      };

  /// 「其余任务」分隔行（卡内段）：逾期区与普通区的分界
  Widget _restDividerRow(AppColorSet colors, String label) {
    return Container(
      constraints: const BoxConstraints(minHeight: AppDimens.space32),
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space8,
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: colors.secondaryText),
      ),
    );
  }

  /// 已完成卡头行：左「已完成」+ 总数，右展开 / 收起箭头；整行即开关
  Widget _doneCardHeader(AppColorSet colors, int total) {
    return InkWell(
      onTap: _toggleDoneSection,
      child: Container(
        constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
        alignment: Alignment.center,
        child: Row(
          children: [
            Text(
              '已完成',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: colors.secondaryText,
              ),
            ),
            const SizedBox(width: AppDimens.space8),
            Text(
              '$total',
              style: TextStyle(fontSize: 13, color: colors.iconText),
            ),
            const Spacer(),
            Icon(
              _doneExpanded ? OrbitIcons.expandLess : OrbitIcons.expandMore,
              size: AppDimens.iconSizeMd,
              color: colors.iconText,
            ),
          ],
        ),
      ),
    );
  }

  /// 已完成卡尾行：进完成集视图（卡内只直显最近 [_doneInlineMax] 条）
  Widget _doneCardMore(AppColorSet colors, int total) {
    return InkWell(
      onTap: () => context.push('/todo/tasks?view=${QuickViewKey.done.name}'),
      child: Container(
        constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
        alignment: Alignment.centerLeft,
        child: Text(
          '查看全部 $total 条已完成',
          style: TextStyle(fontSize: 13, color: colors.accent),
        ),
      ),
    );
  }
}

/// 标准列表条目（表化索引口径；懒加载靠 itemBuilder 按下标现取现建）
///
/// 三种条目共处一张卡：逾期区块头 / 任务行 / 「其余任务」分隔行——段位由
/// 「条目下标 + 条目总数」推出（[OrbitCardEdge.of]），与卡片分段描边一一对应。
class _TaskListEntry {
  const _TaskListEntry.task(this.task)
      : isHead = false,
        isDivider = false;

  const _TaskListEntry.overdueHead()
      : task = null,
        isHead = true,
        isDivider = false;

  const _TaskListEntry.restDivider()
      : task = null,
        isHead = false,
        isDivider = true;

  /// 任务行载荷（头行 / 分隔行为 null）
  final TodoTask? task;

  /// 逾期区块头
  final bool isHead;

  /// 「其余任务」分隔行
  final bool isDivider;
}

/// 主列表初次加载骨架：8 行任务行占位（复选圆 + 标题行 + 元信息行）
///
/// 只在"无旧值可守"的初次加载出现（tasksLoading 见 build）；重查/下拉刷新
/// 走旧内容，不闪骨架。内边距与下沿分隔线与真实行（`TodoTaskTile` 扁平行）
/// 同口径，落定替换时跳变最小。
class _TaskListSkeleton extends StatelessWidget {
  const _TaskListSkeleton({required this.padding});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: padding,
      itemCount: 8,
      itemBuilder: (context, index) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space16,
          vertical: AppDimens.space8,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.divider)),
        ),
        child: const Row(
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

/// 行退场过渡（[_RowEntrance] 的镜像：仅标准列表分支的删除 / 离场型完成）
///
/// 300ms（[AppMotion.slow]）高度收起 + 淡出，曲线用退场加速
///（[AppMotion.accelerate]）。由 [_removeRowWithExit] 在失效延迟窗内挂载，
/// 窗后 invalidate 即卸载——存在期恒定一帧动画长度，不常驻。
class _RowExit extends StatelessWidget {
  const _RowExit({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 0),
      duration: AppMotion.slow,
      curve: AppMotion.accelerate,
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

/// 任务行（docs/05 §4.5，2026-09-23 版式改写）
///
/// 版式：24px 圆 checkbox +「标题 /（标签 + 项目名）」左列 +「截止日期 /
/// 元信息图标」右列（右对齐）。
/// - **优先级落在勾选框描边上**（高/紧急/立即 = 橙红圆环，P0「无」回落中性灰，
///   见 `task_logic.priorityRingHex`）——同一信息不再于副标题重复一枚 8px 色点；
/// - **日期右对齐并相对化**（今天 / 明天 / 昨天 / M月D日，未来主题蓝、逾期红），
///   提醒铃铛、重复、子任务进度、关联、星标等元信息图标压在日期下方右对齐——
///   与竞品列表页的信息层级一致（左列读「是什么」，右列读「什么时候 / 什么状态」）；
/// - **卡片分段**（[OrbitCardSegment]）：列表档每行是一张卡的一段（首段圆上角、
///   末段圆下角、段间 1px `divider`）；[OrbitCardEdge.none]（看板 / 表格 /
///   搜索等复用场景）仍是扁平行（仅下沿 1px 分隔线）；
/// - 无行尾拖拽把手：拖动排序由整行长按拾起承担（见 [SubListScreen.buildTile]）。
///
/// 侧滑手势（07 #18）：面板露出操作按钮——
/// 右滑露「完成」（已完成态变「恢复」，行保留不删）、
/// 左滑露「删除」（既有确认弹窗 + 回收站语义）。
class TodoTaskTile extends StatelessWidget {
  const TodoTaskTile({
    super.key,
    required this.task,
    required this.onToggleDone,
    required this.onOpen,
    this.onLongPress,
    this.projectTitle,
    this.projectColorHex,
    this.labels = const <ProjectedTaskLabel>[],
    this.reminder,
    this.relationCount = 0,
    this.onDelete,
    this.edge = OrbitCardEdge.none,
  });

  final TodoTask task;

  /// 卡片段位（列表档的卡片化；默认扁平行，看板 / 表格 / 搜索不受影响）
  final OrbitCardEdge edge;

  /// 副标题项目名；无项目（未分组）不渲染该段
  final String? projectTitle;

  /// 项目名着色 hex（#36：项目名按项目色渲染；空串回退次要文本色）
  final String? projectColorHex;

  /// 行内标签段数据源（任务→标签投影）；空表不渲染该段
  final List<ProjectedTaskLabel> labels;

  /// 行内提醒徽标载荷；null（无存活提醒）不渲染该段
  final DisplayReminder? reminder;

  /// 出边关联条数（C7 投影）；0 = 无关联，不渲染徽标段
  final int relationCount;
  final VoidCallback onToggleDone;

  /// 长按回调（弹操作菜单）。manual 档（拖拽顺序）传 null：长按让位给
  /// 整行拾起拖动——`ReorderableDelayedDragStartListener` 与行内 InkWell 的
  /// 长按识别器同按 500ms 竞争，行内（更靠叶子）先注册先赢，故拖动档必须
  /// 摘掉这里的长按，否则拖动永远起不来。
  final VoidCallback? onLongPress;
  final VoidCallback onOpen;

  /// 右滑「删除」动作回调（null 时隐藏删除面板——搜索页等只读场景复用 Tile）
  final VoidCallback? onDelete;

  /// 行内标签段：色点 + 标签名，最多 3 个，超出折叠 +N
  /// （与桌面 `LabelChips` 同口径——点色分辨、文字回归安静层级）
  List<Widget> _labelChips(AppColorSet colors) {
    if (labels.isEmpty) return const [];
    const max = 3;
    return [
      for (final l in labels.take(max))
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hexToColor(l.hexColor, fallback: colors.secondaryText),
              ),
            ),
            const SizedBox(width: 2),
            Text(
              l.title,
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            ),
          ],
        ),
      if (labels.length > max)
        Text(
          '+${labels.length - max}',
          style: TextStyle(fontSize: 12, color: colors.secondaryText),
        ),
    ];
  }

  /// 行右侧元信息图标列（日期下方、右对齐）
  ///
  /// 顺序：重复 → 提醒（铃铛 + HH:mm，到期未完转逾期红）→ 子任务进度
  /// （percent_done 0/100 不显示）→ 关联（C7 投影 > 0 才出）→ 星标（黄色）。
  /// 逐项为空则整列不渲染（右列宽度对标题的挤压随之让出）。
  List<Widget> _metaIcons(AppColorSet colors) {
    final chips = <Widget>[];
    void add(Widget w) {
      if (chips.isNotEmpty) chips.add(const SizedBox(width: AppDimens.space6));
      chips.add(w);
    }

    // 重复：repeat_mode > 0 才算真规则（repeat_after 是间隔，无规则时恒 1）
    if (task.repeatMode > 0) {
      add(Icon(OrbitIcons.repeat, size: 12, color: colors.iconText));
    }
    final r = reminder;
    if (r != null) {
      // 桌面用 Bell / BellRing 双图标区分，移动图标集无 bellRing——以颜色为主信号
      final color = r.fired ? OrbitAccents.overdueRed : colors.secondaryText;
      add(Icon(OrbitIcons.notification, size: 12, color: color));
      add(Text(r.clock, style: TextStyle(fontSize: 12, color: color)));
    }
    // 子任务进度（MS To Do Steps 同款体验；percent_done 由后端按勾选回算）
    final pct = task.percentDone;
    if (pct > 0 && pct < 100) {
      add(Icon(OrbitIcons.listChecks, size: 12, color: colors.secondaryText));
      add(Text(
        '${pct.round()}%',
        style: TextStyle(fontSize: 12, color: colors.secondaryText),
      ));
    }
    // 关联（C7）：只做「这任务挂着别的任务」提示（详情页关联区才是编辑入口）
    if (relationCount > 0) {
      add(Icon(OrbitIcons.link, size: 12, color: colors.secondaryText));
    }
    if (task.isStarred) {
      // 星标与同列其余元信息图标同尺寸档（12），色走星标黄——
      // 与看板卡星标同口径，不再比邻项大一圈
      add(Icon(
        OrbitIcons.star,
        size: 12,
        color: OrbitAccents.starYellow,
      ));
    }
    return chips;
  }

  /// 勾选框描边：优先级 1–5 取语义色，P0「无」回落组件默认中性灰
  Color? _priorityRingColor() {
    final hex = priorityRingHex(task.priority);
    return hex == null ? null : hexToColor(hex);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final overdue = isOverdue(task);
    // 截止日期短标签（右列；未来主题蓝、逾期红）
    final dueLabel =
        task.dueDate == null ? null : formatDueShort(task.dueDate!);
    final meta = _metaIcons(colors);
    // 副标题（标签 / 项目名）有无：无则整行只留标题
    final hasSubtitle =
        labels.isNotEmpty || (projectTitle != null && task.projectId != null);

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
              // 触感只给「完成」确认；滑回来恢复不震（与勾选框同口径）
              if (!task.isDone) HapticFeedback.mediumImpact();
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
      child: InkWell(
        onTap: onOpen,
        onLongPress: onLongPress,
        child: OrbitCardSegment(
          edge: edge,
          child: Container(
            // 单行行也有完整热区高度（卡片里行高不随元信息有无跳动）
            constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space16,
              vertical: AppDimens.space8,
            ),
            decoration: edge == OrbitCardEdge.none
                // 扁平行（卡片外复用：看板 / 表格 / 搜索）：仅下沿 1px 分隔线
                ? BoxDecoration(
                    border: Border(bottom: BorderSide(color: colors.divider)),
                  )
                : null,
            child: Row(
              children: [
                // 24px 圆形 checkbox（check 16）：描边承载优先级语义
                CircleCheckbox(
                  checked: task.isDone,
                  onToggle: onToggleDone,
                  borderColor: _priorityRingColor(),
                ),
                const SizedBox(width: AppDimens.space12),
                // 左列：标题 +（标签 / 项目名）——读「这是什么」
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
                        // 完成态全口径统一：划线 + 置灰一档（日历卡同款）
                        doneColor: colors.secondaryText,
                      ),
                      // 副标题只在有标签 / 项目名时出现：优先级已由勾选框描边
                      // 表达，不再占一枚色点，纯标题行因此更紧凑
                      if (hasSubtitle)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Wrap(
                            spacing: AppDimens.space4,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              // 标签段：色点 + 名（最多 3 个，超出折叠 +N）
                              ..._labelChips(colors),
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
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                // 右列：截止日期 + 元信息图标——读「什么时候 / 什么状态」
                if (dueLabel != null || meta.isNotEmpty) ...[
                  const SizedBox(width: AppDimens.space8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (dueLabel != null)
                        Text(
                          dueLabel,
                          style: TextStyle(
                            fontSize: 12,
                            // 未来与今天走主题蓝，逾期转红
                            color: overdue
                                ? OrbitAccents.overdueRed
                                : OrbitAccents.themeAccent,
                          ),
                        ),
                      if (meta.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: meta,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
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
  final Widget Function(TodoTask task) buildTile;

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
        if (!item.isHead) return buildTile(item.task!);
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
            buildTile(item.task!),
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
    this.edge = OrbitCardEdge.none,
  });

  final TodoTask task;
  final bool selected;
  final VoidCallback onTap;
  final String? projectTitle;

  /// 卡片段位（同 [TodoTaskTile.edge]：列表档卡片化，看板 / 表格用 none）
  final OrbitCardEdge edge;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final overdue = isOverdue(task);

    return OrbitCardSegment(
      edge: edge,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppDimens.listItemHeight),
          padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
          decoration: BoxDecoration(
            color: selected
                ? OrbitAccents.todoAccent.withValues(alpha: 0.10)
                : Colors.transparent,
            // 卡内段不画横线（分隔线由 OrbitCardSegment 承担）
            border: edge == OrbitCardEdge.none
                ? Border(bottom: BorderSide(color: colors.divider))
                : null,
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? OrbitIcons.success
                    : OrbitIcons.circle,
                size: AppDimens.iconSizeLg,
                color:
                    selected ? OrbitAccents.todoAccent : colors.secondaryText,
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
                      // 完成态全口径统一：划线 + 置灰一档
                      doneColor: colors.secondaryText,
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
                          // 逾期红统一 OrbitAccents 口径（任务行/看板/表格同源）
                          color: overdue
                              ? OrbitAccents.overdueRed
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
      ),
    );
  }
}
