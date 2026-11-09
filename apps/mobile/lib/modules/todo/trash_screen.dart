import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_bottom_nav.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_list_card.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_pull_to_refresh.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_row_toggle.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import '../../shared/widgets/shadcn/orbit_swipe_guard.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../shared/widgets/shadcn/orbit_button.dart';
import 'providers/todo_providers.dart';
import '../../core/theme/icon_map.dart';

/// 彻底删除的撤销窗口（与桌面 UNDO_DELAY_MS 同口径；窗口内数据仍在库，
/// 点撤销即取消提交）
const _undoWindowMs = 5000;

/// 清空回收站两段确认的时停秒数（与桌面 trash-page `PURGE_HOLD_SECONDS` 同口径：
/// 批量物理删除一次可清掉整站墓碑，每段各 3 秒冷静期，比全局危险操作 5s 略短）
const _purgeHoldSeconds = 3;

/// 回收站页 /todo/trash（回收站落地：删除的任务可恢复 + 保留时间可配）
///
/// 列表 = todo_tasks 墓碑行（is_deleted=1，最近删除排最前）。
/// - 行版式**对齐待办列表**（[OrbitCardSegment] 卡片分段 + 左列「标题 / 删除日期」
///   + 右列「保留期 / 动作钮」，行高与内边距同任务行）；
/// - 长按行弹操作菜单（恢复 / 彻底删除红色确认）；侧滑方向同待办列表——
///   右滑恢复（蓝）、左滑彻底删除（红）；
/// - 单条彻底删除：行内红钮 / 左滑 / 长按菜单三条入口同一份确认层，3 秒
///   时停（`_purgeHoldSeconds`，与「清空」同档），走完才可点；
/// - 标题栏右侧「清空」按钮：桌面同款**两段式确认**，每段 3 秒时停——第一段
///   读后果点「继续」，第二段独立再时停一次，第二击才真正执行；
/// - 彻底删除/清空可撤销（乐观隐藏 + 5s 窗口延迟提交，purge 物理
///   删除只能在提交前拦截）；
/// - 行右列显示保留期倒计时（永久档不显示），左列副标题显示删除日期；
/// - 自动过期清理由 Rust 守护执行（startTrashScheduler，BootGate 接线）。
///
/// 页头左上返回键回退到**进站前的模块页签**（OrbitBranchRoot +
/// OrbitShellBack）：回收站通常经「更多」面板 / 侧栏行 / 设置行进来，都不在
/// 底栏，页签栏给不出回退出路；冷启动直接落在本页且无历史时按钮不渲染。
class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  final _scrollController = ScrollController();

  /// 乐观隐藏的墓碑 id（撤销窗口内从界面过滤显示；提交/撤销后清理）
  final _hiddenIds = <int>{};

  /// 待提交的延迟删除（单槽位：新删除先 flush 上一笔，同桌面口径）
  ({Timer timer, VoidCallback fire, VoidCallback cancel})? _pending;

  static const _dayMs = 24 * 60 * 60 * 1000;

  @override
  void dispose() {
    // 窗口期未结束就离开页面 → 取消计时立即提交（同桌面卸载兜底；
    // commit 内部已处理 mounted/late-invalidate 安全面）
    final p = _pending;
    _pending = null;
    p?.timer.cancel();
    p?.fire();
    _scrollController.dispose();
    super.dispose();
  }

  // ── 可撤销删除调度 ──

  /// 乐观隐藏 ids → 撤销 toast（点撤销 = 取消提交恢复显示）→ 5s 后真提交。
  /// purge 是物理删除，撤销只能在提交前拦截（窗口内数据仍在库）。
  void _scheduleUndoablePurge(
    List<int> ids,
    String toastTitle,
    String? toastDesc,
    Future<void> Function() commit,
  ) {
    // 新删除先落库上一笔（单槽位：两笔并行时旧的不再可撤销）
    _flushPending();
    setState(() => _hiddenIds.addAll(ids));
    final hideSnapshot = Set<int>.of(ids);
    late final ({Timer timer, VoidCallback fire, VoidCallback cancel}) record;
    void fire() {
      _pending = null;
      unawaited(_commitPurge(commit, hideSnapshot));
    }

    final timer = Timer(const Duration(milliseconds: _undoWindowMs), fire);
    record = (
      timer: timer,
      fire: fire,
      cancel: () {
        timer.cancel();
        _pending = null;
        if (mounted) setState(() => _hiddenIds.removeAll(hideSnapshot));
      },
    );
    _pending = record;
    WaitToast.global(
      toastTitle,
      description: toastDesc,
      actionLabel: '撤销',
      onAction: () => _pending?.cancel(),
      // 与延迟提交窗口严格同长：窗口一过撤销已无效，浮层不该继续长驻
      autoDismissAfter: const Duration(milliseconds: _undoWindowMs),
    );
  }

  Future<void> _commitPurge(
    Future<void> Function() commit,
    Set<int> hidden,
  ) async {
    try {
      await commit();
    } catch (_) {
      if (mounted) WaitToast.destructive('删除失败');
    } finally {
      // mounted 后置失效；dispose 提交路径（离开页面兜底）下不再碰
      // ref/setState——回到回收站时 provider 重查自然拿到删除后的真值
      if (mounted) {
        ref.invalidate(todoTasksProvider);
        ref.invalidate(trashTasksProvider);
        setState(() => _hiddenIds.removeAll(hidden));
      }
    }
  }

  void _flushPending() {
    final p = _pending;
    _pending = null;
    p?.timer.cancel();
    p?.fire();
  }

  // ── 写操作（await bridge 后 invalidate）──

  Future<void> _restoreTask(TodoTask task) async {
    try {
      await ref.read(orbitBridgeProvider).trashTaskRestore(task.id);
      ref.invalidate(todoTasksProvider);
      ref.invalidate(trashTasksProvider);
      WaitToast.global('已恢复', description: '「${task.title}」已回到任务列表');
    } catch (_) {
      WaitToast.destructive('恢复失败');
    }
  }

  /// 单条彻底删除：与「清空」同档 3 秒时停（确认钮原文案后接「（Ns）」括号
  /// 秒数、同一字体），之后仍保留 5 秒撤销窗口。
  Future<void> _purgeTask(TodoTask task) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '彻底删除',
      message: '确定要彻底删除「${task.title}」吗？任务及其子任务、评论、提醒将一并被清除，'
          '删除后 5 秒内可撤销。',
      confirmLabel: '彻底删除',
      destructive: true,
      holdSeconds: _purgeHoldSeconds,
    );
    if (!confirmed || !mounted) return;
    // bridge 调度时先行捕获——commit 闭包可能在 dispose 兜底路径 fire，
    // 此时 ref 已不可用（unmounted 后 read 会抛 StateError）
    final bridge = ref.read(orbitBridgeProvider);
    _scheduleUndoablePurge(
      [task.id],
      '已彻底删除',
      task.title,
      () => bridge.trashTaskPurge(task.id),
    );
  }

  /// 清空回收站：桌面同款两段式确认，两段各 3 秒时停（`_purgeHoldSeconds`）。
  /// 第一段读后果点「继续」，第二段独立再等满 3 秒才出现可点的「清空回收站」，
  /// 第二击才真正执行（仍保留之后 5 秒撤销窗口）。
  Future<void> _purgeAll(int count, List<int> ids) async {
    final read = await showConfirmBottomSheet(
      context,
      title: '清空回收站',
      message: '确定要清空回收站中的 $count 个任务吗？任务及其子任务、评论、提醒将一并被清除。'
          '确认后还需再确认一次才会真正执行。',
      confirmLabel: '继续',
      destructive: true,
      holdSeconds: _purgeHoldSeconds,
    );
    if (!read || !mounted) return;

    final confirmed = await showConfirmBottomSheet(
      context,
      title: '再次确认：清空回收站',
      message: '即将永久删除 $count 个任务及其子任务、评论、提醒。'
          '执行后仅剩 5 秒撤销窗口（轻提示上点撤销可整批恢复）。',
      confirmLabel: '清空回收站',
      destructive: true,
      holdSeconds: _purgeHoldSeconds,
    );
    if (!confirmed || !mounted) return;
    // 同 _purgeTask：bridge 先行捕获，dispose 兜底 fire 时不再碰 ref
    final bridge = ref.read(orbitBridgeProvider);
    _scheduleUndoablePurge(
      ids,
      '已清空回收站',
      '$count 个任务',
      () => bridge.trashPurgeAll(),
    );
  }

  // ── 行长按菜单（恢复 / 彻底删除）──

  void _showTaskActions(TodoTask task) {
    showMoreActionsSheet(
      context,
      title: task.title,
      actions: [
        OrbitPanelItem(
          icon: OrbitIcons.archiveRestore,
          label: '恢复',
          color: OrbitAccents.themeAccent,
          onTap: () => _restoreTask(task),
        ),
        OrbitPanelItem(
          icon: OrbitIcons.delete,
          label: '彻底删除',
          color: OrbitAccents.overdueRed,
          onTap: () => _purgeTask(task),
        ),
      ],
    );
  }

  /// 左列副标题：删除日期（与待办列表行副标题同档 12px 次要文字色）
  String _deletedLabel(TodoTask task) => '删除于 ${_formatDate(task.deletedAt ?? 0)}';

  /// 右列保留期标签（对齐待办列表右列日期的短标签口径）：
  /// 永久档返回 null（无「何时清除」可言）；已过期 → 「即将清除」走危险色，
  /// 否侧 → 「N 天后」走主题强调色。
  ({String? label, bool urgent}) _retentionLabel(TodoTask task, int retentionDays) {
    if (retentionDays == 0) return (label: null, urgent: false);
    final deletedAt = task.deletedAt ?? 0;
    final remain =
        ((deletedAt + retentionDays * _dayMs - DateTime.now().millisecondsSinceEpoch) /
                _dayMs)
            .ceil();
    if (remain <= 0) return (label: '即将清除', urgent: true);
    return (label: '$remain 天后', urgent: false);
  }

  String _formatDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  @override
  Widget build(BuildContext context) {
    // 初次加载给骨架：`value ?? []` 会把加载帧误渲染成「回收站是空的」闪现
    final trashAsync = ref.watch(trashTasksProvider);
    final tasks = trashAsync.value ?? [];
    final trashLoading = !trashAsync.hasValue && trashAsync.isLoading;
    // 乐观隐藏：撤销窗口内的墓碑行从界面过滤（数据仍在库，撤销即恢复显示）
    final visible =
        _hiddenIds.isEmpty ? tasks : tasks.where((t) => !_hiddenIds.contains(t.id)).toList();
    final meta = ref.watch(trashMetaProvider).value;
    final retentionDays = meta?.retentionDays ?? 30;
    final colors = AppColors.ofContext(context);
    final destructive = colors.destructive;

    return Scaffold(
      // 壳内分支页不吃键盘避让：键盘场景全在弹层（根 Overlay），body 缩放会
      // 让壳层捕获树逐帧重录整页快照（toImageSync）——2026-11-08 键盘窗根因
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: trashLoading
                ? const _TrashSkeleton()
                : visible.isEmpty
                ? Padding(
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top +
                          OrbitPageHeader.rowHeight,
                    ),
                    child: const EmptyState(
                      message: '回收站是空的，删除的任务会先进入这里',
                      icon: OrbitIcons.delete,
                    ),
                  )
                : OrbitPullToRefresh(
                    // 下拉刷新（2026-11-01：RefreshIndicator → miuix 承载）：
                    // 本地重读 + 已配置时跑一轮云同步（共用回调见 pullToRefresh）。
                    // edgeOffset 下移到页头之下，否则指示条被 OrbitPageHeader 盖住。
                    onRefresh: () => pullToRefresh(ref),
                    color: OrbitAccents.themeAccent,
                    edgeOffset: MediaQuery.of(context).padding.top +
                        OrbitPageHeader.rowHeight,
                    displacement: AppDimens.space8,
                    child: ListView.builder(
                      controller: _scrollController,
                      // 左右 12 留白：卡片是「页面里的一张卡」而非通栏表格
                      //（与待办列表 cardListPadding 同口径）
                      padding: EdgeInsets.fromLTRB(
                        AppDimens.space12,
                        MediaQuery.of(context).padding.top +
                            OrbitPageHeader.rowHeight +
                            AppDimens.space8,
                        AppDimens.space12,
                        // 悬浮底栏净空 + 呼吸留白（末条墓碑行不被玻璃栏扣住）
                        OrbitBottomNav.clearanceOf(context) +
                            AppDimens.space16,
                      ),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final task = visible[index];
                        final retention = _retentionLabel(task, retentionDays);
                        return _TrashTaskTile(
                          task: task,
                          // 同卡内段位：首段圆上角、末段圆下角、段间 1px 分隔线
                          edge: OrbitCardEdge.of(index, visible.length),
                          deletedLabel: _deletedLabel(task),
                          retentionLabel: retention.label,
                          retentionUrgent: retention.urgent,
                          onLongPress: () => _showTaskActions(task),
                          onRestore: () => _restoreTask(task),
                          onPurge: () => _purgeTask(task),
                        );
                      },
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '回收站',
              // 分支根页：有页级历史时由 OrbitPageHeader 自动长出返回箭头
              showBack: false,
              actions: [
                if (visible.isNotEmpty)
                  OrbitButton.text(
                    onPressed: () => _purgeAll(
                      visible.length,
                      [for (final t in visible) t.id],
                    ),
                    child: Text(
                      '清空',
                      style: TextStyle(
                        fontSize: 14,
                        color: destructive,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 回收站初次加载骨架：行占位（标题行 + 副标题行），有旧值时不出现
class _TrashSkeleton extends StatefulWidget {
  const _TrashSkeleton();

  @override
  State<_TrashSkeleton> createState() => _TrashSkeletonState();
}

class _TrashSkeletonState extends State<_TrashSkeleton>
    with SingleTickerProviderStateMixin {
  /// 整屏单路呼吸（2026-11-08）：12 块逐块自建 controller 就是 12 路 ticker
  /// 同时逐帧驱动；共享一路同相位（口径同 `_TaskListSkeleton`）
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: AppMotion.skeletonPulse,
  )..repeat(reverse: true);

  late final Animation<double> _pulse = Tween<double>(begin: 0.45, end: 1.0)
      .animate(CurvedAnimation(parent: _ctrl, curve: AppMotion.breathe));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        AppDimens.space12,
        MediaQuery.of(context).padding.top +
            OrbitPageHeader.rowHeight +
            AppDimens.space8,
        AppDimens.space12,
        AppDimens.space16,
      ),
      children: [
        for (var i = 0; i < 6; i++)
          Padding(
            // 12 卡片留白 + 16 卡片内边距 = 骨架文字起始位与任务行标题对齐
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space12 + AppDimens.space16,
              vertical: AppDimens.space12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OrbitSkeleton.line(
                  width: 180 - (i % 3) * 30.0,
                  pulse: _pulse,
                ),
                const SizedBox(height: AppDimens.space8),
                OrbitSkeleton.line(width: 110, pulse: _pulse),
              ],
            ),
          ),
      ],
    );
  }
}

/// 回收站行（版式对齐待办列表 [TodoTaskTile]，2026-11-09）
///
/// 左列读「是什么 / 什么时候删的」：标题（16px，与任务行同档）+「删除于 日期」；
/// 右列读「还剩多久 / 能做什么」：保留期短标签（主题蓝，已过期转危险色）压在
/// 两枚行内动作钮（恢复 / 彻底删除）之上，与任务行右列的「日期 + 状态开关对」
/// 同一信息层级。
///
/// 卡片分段（[OrbitCardSegment]）由列表按 index 传入：首段圆上角、末段圆下角、
/// 段间 1px `divider`——与待办列表同一张卡的拼法（懒加载列表仍逐行虚拟化）。
///
/// 侧滑方向同待办列表：右滑露「恢复」（蓝），左滑露「彻底删除」（红，
/// 仍需二次确认）；长按仍弹整行操作菜单。
class _TrashTaskTile extends StatelessWidget {
  const _TrashTaskTile({
    required this.task,
    required this.edge,
    required this.deletedLabel,
    required this.retentionLabel,
    required this.retentionUrgent,
    required this.onLongPress,
    required this.onRestore,
    required this.onPurge,
  });

  final TodoTask task;
  final OrbitCardEdge edge;

  /// 左列副标题：删除日期
  final String deletedLabel;

  /// 右列保留期标签；null = 永久保留档（无「何时清除」可言）
  final String? retentionLabel;

  /// 保留期已到（文案转危险色）
  final bool retentionUrgent;

  final VoidCallback onLongPress;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final muted = colors.deactivatedText;
    final retention = retentionLabel;

    return OrbitSwipeGuard(
      // 与行内 Slidable 同 key：列表复用换任务时连 controller 一起重建，
      // 避免上一行的开合姿态残留到新行
      key: ValueKey('trash-swipe-guard-${task.id}'),
      builder: (context, swipeEnabled, slidableController) => Slidable(
        key: ValueKey('trash-slidable-${task.id}'),
        controller: slidableController,
        enabled: swipeEnabled,
        // 右滑 → 恢复（回收站的主操作，蓝同待办列表「完成」）
        startActionPane: ActionPane(
          motion: const BehindMotion(),
          extentRatio: 0.26,
          children: [
            SlidableAction(
              onPressed: (_) => onRestore(),
              backgroundColor: OrbitAccents.todoAccent,
              foregroundColor: Colors.white,
              icon: OrbitIcons.archiveRestore,
              label: '恢复',
              borderRadius: AppShapes.medium,
            ),
          ],
        ),
        // 左滑 → 彻底删除（红同待办列表「删除」，仍需二次确认）
        endActionPane: ActionPane(
          motion: const BehindMotion(),
          extentRatio: 0.26,
          children: [
            SlidableAction(
              onPressed: (_) {
                HapticFeedback.mediumImpact();
                onPurge();
              },
              backgroundColor: colors.destructive,
              foregroundColor: Colors.white,
              icon: OrbitIcons.delete,
              label: '彻底删除',
              borderRadius: AppShapes.medium,
            ),
          ],
        ),
        child: InkWell(
          onLongPress: onLongPress,
          child: OrbitCardSegment(
            edge: edge,
            child: Container(
              // 单行行也有完整热区高度（卡片里行高不随副标题有无跳动）
              constraints: const BoxConstraints(
                minHeight: AppDimens.touchTarget,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space16,
                vertical: AppDimens.space8,
              ),
              child: Row(
                children: [
                  // 左列：标题 + 删除日期
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
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            deletedLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.secondaryText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppDimens.space8),
                  // 右列：保留期标签 + 行内动作钮（右对齐）
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (retention != null)
                        Text(
                          retention,
                          style: TextStyle(
                            fontSize: 12,
                            color: retentionUrgent
                                ? colors.destructive
                                : OrbitAccents.themeAccent,
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OrbitRowToggle(
                              icon: OrbitIcons.archiveRestore,
                              active: true,
                              activeColor: OrbitAccents.themeAccent,
                              inactiveColor: muted,
                              tooltip: '恢复到任务列表',
                              onTap: onRestore,
                              iconSize: 14,
                              hitExtent: 32,
                            ),
                            const SizedBox(width: AppDimens.space4),
                            OrbitRowToggle(
                              icon: OrbitIcons.delete,
                              active: true,
                              activeColor: colors.destructive,
                              inactiveColor: muted,
                              tooltip: '彻底删除（5 秒内可撤销）',
                              onTap: onPurge,
                              iconSize: 14,
                              hitExtent: 32,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


