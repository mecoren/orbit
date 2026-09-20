import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/confirm_bottom_sheet.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/more_actions_sheet.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/wait_toast.dart';
import 'providers/todo_providers.dart';

/// 彻底删除的撤销窗口（与桌面 UNDO_DELAY_MS 同口径；窗口内数据仍在库，
/// 点撤销即取消提交）
const _undoWindowMs = 5000;

/// 回收站页 /todo/trash（回收站落地：删除的任务可恢复 + 保留时间可配）
///
/// 列表 = todo_tasks 墓碑行（is_deleted=1，最近删除排最前）。
/// - 长按行弹操作菜单（恢复 / 彻底删除红色确认）；
/// - 标题栏右侧「清空」按钮（计数确认）；
/// - 彻底删除/清空可撤销（乐观隐藏 + 5s 窗口延迟提交，purge 物理
///   删除只能在提交前拦截）；
/// - 行副标题显示保留期倒计时（永久档显示删除日期）；
/// - 自动过期清理由 Rust 守护执行（startTrashScheduler，BootGate 接线）。
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

  Future<void> _purgeAll(int count, List<int> ids) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '清空回收站',
      message: '确定要清空回收站中的 $count 个任务吗？删除后 5 秒内可整批撤销。',
      confirmLabel: '清空',
      destructive: true,
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
        MoreActionItem(
          icon: Icons.restore_from_trash_outlined,
          label: '恢复',
          color: OrbitAccents.themeAccent,
          onTap: () => _restoreTask(task),
        ),
        MoreActionItem(
          icon: Icons.delete_forever_outlined,
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
    final tasks = ref.watch(trashTasksProvider).value ?? [];
    // 乐观隐藏：撤销窗口内的墓碑行从界面过滤（数据仍在库，撤销即恢复显示）
    final visible =
        _hiddenIds.isEmpty ? tasks : tasks.where((t) => !_hiddenIds.contains(t.id)).toList();
    final meta = ref.watch(trashMetaProvider).value;
    final retentionDays = meta?.retentionDays ?? 30;
    final colors = AppColors.ofContext(context);
    final destructive = colors.destructive;

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
                    child: const EmptyState(
                      message: '回收站是空的，删除的任务会先进入这里',
                      icon: Icons.delete_outline_rounded,
                    ),
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
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: '回收站',
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
              actions: [
                if (visible.isNotEmpty)
                  TextButton(
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
      trailing: IconButton(
        icon: Icon(
          Icons.restore_from_trash_outlined,
          size: AppDimens.iconSizeMd,
          color: OrbitAccents.themeAccent,
        ),
        onPressed: onRestore,
        tooltip: '恢复',
      ),
    );
  }
}
