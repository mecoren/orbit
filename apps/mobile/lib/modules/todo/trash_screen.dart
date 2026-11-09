import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_bottom_nav.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_pull_to_refresh.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../shared/widgets/shadcn/orbit_button.dart';
import '../../shared/widgets/shadcn/orbit_icon_button.dart';
import '../shell/orbit_shell_back.dart';
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
/// - 长按行弹操作菜单（恢复 / 彻底删除红色确认）；
/// - 标题栏右侧「清空」按钮：桌面同款**两段式确认**，每段 3 秒时停——第一段
///   读后果点「继续」，第二段独立再时停一次，第二击才真正执行；
/// - 彻底删除/清空可撤销（乐观隐藏 + 5s 窗口延迟提交，purge 物理
///   删除只能在提交前拦截）；
/// - 行副标题显示保留期倒计时（永久档显示删除日期）；
/// - 自动过期清理由 Rust 守护执行（startTrashScheduler，BootGate 接线）。
///
/// 页头左上返回键回退到**进站前的模块页签**（[OrbitShellBack]）：回收站通常
/// 经「更多」面板 / 侧栏行 / 设置行进来，都不在底栏，页签栏给不出回退出路；
/// 冷启动直接落在本页且无历史时按钮不渲染。
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

  Future<void> _purgeTask(TodoTask task) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '彻底删除',
      message: '确定要彻底删除「${task.title}」吗？任务及其子任务、评论、提醒将一并被清除，'
          '删除后 5 秒内可撤销。',
      confirmLabel: '彻底删除',
      destructive: true,
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

  /// 保留期倒计时副标题（永久档 → 删除日期；档位内 → N 天后自动清除）
  String _expiresLabel(TodoTask task, int retentionDays) {
    final deletedAt = task.deletedAt ?? 0;
    final dateText = _formatDate(deletedAt);
    if (retentionDays == 0) return '删除于 $dateText';
    final remain =
        ((deletedAt + retentionDays * _dayMs - DateTime.now().millisecondsSinceEpoch) /
                _dayMs)
            .ceil();
    if (remain <= 0) return '即将自动清除';
    return '$remain 天后自动清除 · 删除于 $dateText';
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
                      padding: EdgeInsets.only(
                        top: MediaQuery.of(context).padding.top +
                            OrbitPageHeader.rowHeight +
                            AppDimens.space8,
                        // 悬浮底栏净空 + 呼吸留白（末条墓碑行不被玻璃栏扣住）
                        bottom:
                            OrbitBottomNav.clearanceOf(context) +
                            AppDimens.space16,
                      ),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final task = visible[index];
                        return _TrashTaskTile(
                          task: task,
                          subtitle: _expiresLabel(task, retentionDays),
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
              // 壳内给得出回退目标才出返回键（见类文档；单页测试无壳时不出）
              showBack: OrbitShellBack.maybeOf(context)?.targetBranchIndex != null,
              onBack: () => goBackToPreviousModule(context),
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
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top +
            OrbitPageHeader.rowHeight +
            AppDimens.space8,
        bottom: AppDimens.space16,
      ),
      children: [
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space16,
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

/// 回收站行卡片：标题 + 倒计时副标题 + 右侧恢复快捷钮
class _TrashTaskTile extends StatelessWidget {
  const _TrashTaskTile({
    required this.task,
    required this.subtitle,
    required this.onLongPress,
    required this.onRestore,
    required this.onPurge,
  });

  final TodoTask task;
  final String subtitle;
  final VoidCallback onLongPress;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space4,
      ),
      onLongPress: onLongPress,
      title: Text(
        task.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: colors.titleText,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: colors.secondaryText),
      ),
      trailing: OrbitIconButton(
        icon: Icon(
          OrbitIcons.archiveRestore,
          size: AppDimens.iconSizeMd,
          color: OrbitAccents.themeAccent,
        ),
        onPressed: onRestore,
        tooltip: '恢复',
      ),
    );
  }
}


