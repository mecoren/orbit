/// 云同步状态图标（移动端标题栏左上角；对齐桌面 SyncStatusButton 口径）
///
/// - 位置：仅首页（SidebarScreen，标题「循迹」）标题栏左端（该页无返回/菜单键，
///   经 [OrbitPageHeader.leading] 插槽挂载）
/// - 未配置 / 未解锁 → 点击直达云同步配置页（/settings/sync）引导；
///   已就绪 → 点击弹出底部信息面板（状态 / 上次 / 下次同步 / 失败原因 + 立即同步）
/// - 移动端无 sync-progress / sync-finished 事件流（ADR 0003）：状态只能用
///   「await cloudSyncNow 期间本地置同步中 → 返回值落定成败」的本地态实现，
///   成功对勾短暂展示后自动回落待命
/// - 与备份无关：自动备份 / 全量备份入口仍在设置页
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../modules/shell/db_invalidation.dart';
import '../../modules/todo/providers/todo_providers.dart';
import '../utils/sync_status_text.dart';
import 'shadcn/orbit_actions_sheet.dart' show bottomSheetTopShape;
import 'shadcn/orbit_sheet_scaffold.dart';
import 'shadcn/orbit_toast.dart';
import '../../core/theme/icon_map.dart';

/// 云同步配置页路由（未配置 / 未解锁时的引导目标）
const String _syncSettingsRoute = '/settings/sync';

/// 成功态停留时长（毫秒）：对勾回弹展示后回落待命
const int _successHoldMs = 1800;

/// 图标外框尺寸（承载进度环与状态徽标）
const double _iconBox = 30;

/// 状态徽标直径（成功对勾 / 失败红点）
const double _badge = 14;

/// 同步密码状态（是否已设置 / 当前会话是否已解锁）
///
/// 独立 provider：设置页解锁后与本图标缓存各自持有，故点击时再权威刷新一次
/// （见 [_SyncStatusButtonState._onTap]），避免缓存滞后误跳配置页。
final _syncCryptoStatusProvider = FutureProvider<SyncCryptoStatus>(
  (ref) => ref.watch(orbitBridgeProvider).syncCryptoStatus(),
);

class SyncStatusButton extends ConsumerStatefulWidget {
  const SyncStatusButton({super.key});

  @override
  ConsumerState<SyncStatusButton> createState() => _SyncStatusButtonState();
}

class _SyncStatusButtonState extends ConsumerState<SyncStatusButton> {
  SyncUiStatus _runStatus = SyncUiStatus.idle;
  String? _errorMessage;
  Timer? _successTimer;

  @override
  void dispose() {
    _successTimer?.cancel();
    super.dispose();
  }

  /// 落定运行态：成功态挂尾计时回落待命；失败态保留原因到下次同步
  void _applyStatus(SyncUiStatus status, {String? error}) {
    if (!mounted) return;
    _successTimer?.cancel();
    _successTimer = null;
    setState(() {
      _runStatus = status;
      _errorMessage = error;
    });
    if (status == SyncUiStatus.success) {
      _successTimer = Timer(const Duration(milliseconds: _successHoldMs), () {
        if (mounted) setState(() => _runStatus = SyncUiStatus.idle);
      });
    }
  }

  Future<void> _onTap(SyncUiStatus status) async {
    if (status == SyncUiStatus.syncing) {
      WaitToast.info('已有同步任务在进行中');
      return;
    }
    if (status == SyncUiStatus.unconfigured) {
      context.push(_syncSettingsRoute);
      return;
    }
    // 已配置：权威复核一次解锁状态（设置页刚解锁时本图标缓存可能滞后）
    final SyncCryptoStatus crypto;
    try {
      crypto = await ref.refresh(_syncCryptoStatusProvider.future);
    } catch (_) {
      if (mounted) context.push(_syncSettingsRoute);
      return;
    }
    if (!mounted) return;
    if (!crypto.hasPassword || !crypto.isUnlocked) {
      context.push(_syncSettingsRoute);
      return;
    }
    await _showInfoSheet();
  }

  Future<void> _showInfoSheet() async {
    final colors = AppColors.ofContext(context);
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      builder: (_) => _SyncInfoSheet(
        status: _runStatus,
        errorMessage: _errorMessage,
        onStatusChanged: _applyStatus,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final configAsync = ref.watch(syncConfigProvider);
    final cryptoAsync = ref.watch(_syncCryptoStatusProvider);
    final config = configAsync.value;
    final crypto = cryptoAsync.value;
    // 查询未落定前按待命态渲染，避免首帧闪一次「未配置 / 已锁定」
    final loading = !configAsync.hasValue || !cryptoAsync.hasValue;
    final status = loading
        ? SyncUiStatus.idle
        : deriveSyncUiStatus(
            hasConfig: config != null,
            hasPassword: crypto?.hasPassword ?? false,
            isUnlocked: crypto?.isUnlocked ?? false,
            runStatus: _runStatus,
          );
    final statusText = syncStatusLabel(
      status,
      hasPassword: crypto?.hasPassword ?? false,
    );

    return Semantics(
      button: true,
      label: '云同步：$statusText',
      child: IconButton(
        onPressed: () => unawaited(_onTap(status)),
        icon: _buildIcon(status, colors),
        tooltip: statusText,
      ),
    );
  }

  /// 五态图标：待命/未就绪弱化、同步中转环、成功对勾回弹、失败红点常驻
  Widget _buildIcon(SyncUiStatus status, AppColorSet colors) {
    final Color color = switch (status) {
      SyncUiStatus.syncing => OrbitAccents.themeAccent,
      SyncUiStatus.success => colors.success,
      SyncUiStatus.error => colors.destructive,
      SyncUiStatus.unconfigured || SyncUiStatus.locked => colors.deactivatedText,
      SyncUiStatus.idle => colors.iconText,
    };
    return SizedBox(
      width: _iconBox,
      height: _iconBox,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Icon(OrbitIcons.cloud, size: AppDimens.iconSizeMd, color: color),
          if (status == SyncUiStatus.syncing)
            const SizedBox(
              width: _iconBox,
              height: _iconBox,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: OrbitAccents.themeAccent,
              ),
            ),
          if (status == SyncUiStatus.success)
            Positioned(
              right: 0,
              top: 0,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.4, end: 1),
                duration: AppMotion.slow,
                curve: AppMotion.bounce,
                builder: (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Container(
                  width: _badge,
                  height: _badge,
                  decoration: BoxDecoration(
                    color: colors.success,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(OrbitIcons.check,
                      size: 10, color: Colors.white),
                ),
              ),
            ),
          if (status == SyncUiStatus.error)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: colors.destructive,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 云同步信息面板：状态 / 上次 / 下次同步 / 失败原因 + 「立即同步」
///
/// 同步动作在面板内执行（面板自带 busy 态），结果经 [onStatusChanged] 回传图标，
/// 使图标与面板状态一致；成功后自动收起面板（忙时跳过不收起）。
class _SyncInfoSheet extends ConsumerStatefulWidget {
  const _SyncInfoSheet({
    required this.status,
    required this.errorMessage,
    required this.onStatusChanged,
  });

  final SyncUiStatus status;
  final String? errorMessage;
  final void Function(SyncUiStatus status, {String? error}) onStatusChanged;

  @override
  ConsumerState<_SyncInfoSheet> createState() => _SyncInfoSheetState();
}

class _SyncInfoSheetState extends ConsumerState<_SyncInfoSheet> {
  bool _busy = false;

  /// 错误消息去 `[tag] ` 前缀（Rust 侧 `[category] message` 约定）
  String _errMsg(Object err) =>
      err.toString().replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  Future<void> _runSync() async {
    if (_busy) return;
    setState(() => _busy = true);
    widget.onStatusChanged(SyncUiStatus.syncing);
    try {
      final result =
          await ref.read(orbitBridgeProvider).cloudSyncNow(origin: 'manual');
      ref.invalidate(syncConfigProvider);
      // 拉取合并写入不走 db-change 事件，需在此失效业务缓存（F42：按真正
      // 写入的表精确失效，口径同桌面 useSyncInvalidation）
      invalidateAfterSyncCaches(ref, result);
      widget.onStatusChanged(
        result.skipped ? SyncUiStatus.idle : SyncUiStatus.success,
      );
      WaitToast.success(syncResultSummary(
        pushedModules: result.pushedModules,
        pulledModules: result.pulledModules,
        skipped: result.skipped,
        errorCount: result.errors.length,
      ));
      if (mounted && !result.skipped) Navigator.of(context).pop();
    } catch (e) {
      final msg = _errMsg(e);
      widget.onStatusChanged(SyncUiStatus.error, error: msg);
      WaitToast.destructive(msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _infoRow(AppColorSet colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.space8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: colors.secondaryText),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 14, color: colors.bodyText),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final config = ref.watch(syncConfigProvider).value;
    final nextAt = config == null
        ? null
        : estimateNextSyncAt(
            autoSyncEnabled: config.autoSyncEnabled,
            intervalMinutes: config.intervalMinutes,
            lastSyncedAtMs: config.lastSyncedAt,
          );

    // 信息区可滚、「立即同步」固定在骨架尾栏（口径见 orbit_sheet_scaffold.dart）
    return OrbitSheetScaffold(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.space16,
          AppDimens.space16,
          AppDimens.space16,
          AppDimens.space16,
        ),
        child: Row(
          children: [
            const Icon(
              OrbitIcons.cloud,
              size: AppDimens.iconSizeMd,
              color: OrbitAccents.themeAccent,
            ),
            const SizedBox(width: AppDimens.space8),
            Text(
              '云同步',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.titleText,
              ),
            ),
          ],
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _infoRow(colors, '状态', syncStatusLabel(widget.status)),
          _infoRow(colors, '上次同步', formatLastSynced(config?.lastSyncedAt)),
          _infoRow(colors, '下次自动同步', formatNextSync(nextAt)),
          if (widget.errorMessage != null)
            _infoRow(colors, '失败原因', widget.errorMessage!),
        ],
      ),
      actions: OrbitSheetActions(
        confirmLabel: '立即同步',
        onConfirm: _busy ? null : () => unawaited(_runSync()),
        confirmChild: _busy
            ? const SizedBox(
                width: AppDimens.iconSizeSm,
                height: AppDimens.iconSizeSm,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : null,
      ),
    );
  }
}
