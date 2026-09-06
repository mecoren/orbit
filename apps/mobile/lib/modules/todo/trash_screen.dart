import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/more_actions_sheet.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/wait_toast.dart';
import 'providers/todo_providers.dart';

/// 回收站页 /todo/trash（回收站落地：删除的任务可恢复 + 保留时间可配）
///
/// 列表 = todo_tasks 墓碑行（is_deleted=1，最近删除排最前）。
/// - 长按行弹操作菜单（恢复 / 彻底删除红色确认）；
/// - 标题栏右侧「清空」按钮（计数确认）；
/// - 行副标题显示保留期倒计时（永久档显示删除日期）；
/// - 自动过期清理由 Rust 守护执行（startTrashScheduler，BootGate 接线）。
class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  final _scrollController = ScrollController();

  static const _dayMs = 24 * 60 * 60 * 1000;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
    final destructive = AppColors.ofContext(context).destructive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text(
          '确定要彻底删除「${task.title}」吗？此操作不可恢复，任务及其子任务、评论、提醒将一并被清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: destructive),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(orbitBridgeProvider).trashTaskPurge(task.id);
      ref.invalidate(trashTasksProvider);
      WaitToast.global('已彻底删除', description: task.title);
    } catch (_) {
      WaitToast.destructive('删除失败');
    }
  }

  Future<void> _purgeAll(int count) async {
    final destructive = AppColors.ofContext(context).destructive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空回收站'),
        content: Text('确定要清空回收站中的 $count 个任务吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: destructive),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final n = await ref.read(orbitBridgeProvider).trashPurgeAll();
      ref.invalidate(todoTasksProvider);
      ref.invalidate(trashTasksProvider);
      if (mounted) WaitToast.global('已清空回收站', description: '$n 个任务');
    } catch (_) {
      WaitToast.destructive('清空失败');
    }
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
    final meta = ref.watch(trashMetaProvider).value;
    final retentionDays = meta?.retentionDays ?? 30;
    final colors = AppColors.ofContext(context);
    final destructive = colors.destructive;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: tasks.isEmpty
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
                    itemCount: tasks.length,
                    itemBuilder: (context, index) {
                      final task = tasks[index];
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
                if (tasks.isNotEmpty)
                  TextButton(
                    onPressed: () => _purgeAll(tasks.length),
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
