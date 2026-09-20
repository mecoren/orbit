import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../services/local_prefs.dart';
import '../../shared/widgets/confirm_bottom_sheet.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/select_bottom_sheet.dart';
import '../../shared/widgets/wait_toast.dart';

/// 通知历史页 /settings/notifications
///
/// 类型过滤（全部/到期/推迟/完成/跳过）+ 分页（50 步进，上限 200）+
/// 清空（二次确认）+ 提醒总开关（LocalPrefs `reminder_enabled`，
/// 默认开；关后到期事件仅写历史不弹窗，见 BootGate 接线）。
class NotificationHistoryPage extends ConsumerStatefulWidget {
  const NotificationHistoryPage({super.key});

  @override
  ConsumerState<NotificationHistoryPage> createState() =>
      _NotificationHistoryPageState();
}

class _NotificationHistoryPageState
    extends ConsumerState<NotificationHistoryPage> {
  final _scrollController = ScrollController();
  String? _kind;
  int _limit = 50;
  bool _reminderOn = true;
  List<NotificationLogRow>? _rows;
  bool _loading = true;

  static const _kinds = <String?>[null, 'reminder_due', 'snooze', 'complete', 'boot_skip'];

  static String kindLabel(String? kind) {
    switch (kind) {
      case 'reminder_due':
        return '到期';
      case 'snooze':
        return '推迟';
      case 'complete':
        return '完成';
      case 'boot_skip':
        return '跳过';
      default:
        return '全部';
    }
  }

  @override
  void initState() {
    super.initState();
    _reminderOn = LocalPrefs.getBool('reminder_enabled', fallback: true);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await ref
          .read(orbitBridgeProvider)
          .notificationLogList(kind: _kind, limit: _limit);
      if (mounted) setState(() => _rows = rows);
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickKind() async {
    await showSelectBottomSheet<String?>(
      context,
      title: '类型过滤',
      current: _kind,
      items: [
        for (final k in _kinds) SelectItem(value: k, label: kindLabel(k)),
      ],
      onSelect: (v) {
        setState(() {
          _kind = v;
          _limit = 50;
        });
        _load();
      },
    );
  }

  Future<void> _clear() async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '清空通知历史',
      message: '将删除全部本地通知历史（不同步，不可恢复）。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      final n = await ref.read(orbitBridgeProvider).notificationLogClear();
      if (mounted) WaitToast.success('已清空 $n 条');
      _load();
    } catch (e) {
      if (mounted) WaitToast.destructive('清空失败');
    }
  }

  Future<void> _toggleReminder(bool v) async {
    await LocalPrefs.setBool('reminder_enabled', v);
    setState(() => _reminderOn = v);
    if (mounted) WaitToast.success(v ? '提醒已开启' : '提醒已关闭（仅记历史）');
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final rows = _rows ?? [];
    final fmt = DateFormat('MM-dd HH:mm');
    return Scaffold(
      body: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              96,
              AppDimens.space16,
              AppDimens.space24,
            ),
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('到期提醒'),
                subtitle: const Text('关闭后仅记历史，不弹窗'),
                value: _reminderOn,
                onChanged: _toggleReminder,
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickKind,
                      icon: const Icon(Icons.filter_alt_outlined, size: 18),
                      label: Text('类型：${kindLabel(_kind)}'),
                    ),
                  ),
                  const SizedBox(width: AppDimens.space8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _clear,
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('清空'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppDimens.space8),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (rows.isEmpty)
                const EmptyState(
                  icon: Icons.notifications_off_outlined,
                  message: '暂无通知历史',
                )
              else ...[
                for (final r in rows)
                  Container(
                    margin: const EdgeInsets.only(bottom: AppDimens.space8),
                    padding: const EdgeInsets.all(AppDimens.space12),
                    decoration: BoxDecoration(
                      color: colors.surfaceSecondary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colors.surface,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                kindLabel(r.kind),
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            const SizedBox(width: AppDimens.space8),
                            Expanded(
                              child: Text(
                                r.taskTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          fmt.format(
                            DateTime.fromMillisecondsSinceEpoch(r.createdAt),
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_limit < 200)
                  Center(
                    child: TextButton(
                      onPressed: () {
                        setState(() => _limit = (_limit + 50).clamp(50, 200));
                        _load();
                      },
                      child: const Text('加载更多'),
                    ),
                  ),
              ],
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: '通知历史',
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
            ),
          ),
        ],
      ),
    );
  }
}
