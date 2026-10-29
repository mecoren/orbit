/// 云同步状态图标（移动端标题栏左上角；对齐桌面 SyncStatusButton 口径）
///
/// - 位置：仅首页（SidebarScreen，标题「循迹」）标题栏左端（该页无返回/菜单键，
///   经 [OrbitPageHeader.leading] 插槽挂载）
/// - 未配置 / 未解锁 → 点击直达云同步配置页（/settings/sync）引导；
///   已就绪 → 点击弹出底部信息面板（状态 / 上次 / 下次同步 / 失败原因 + 立即同步）
/// - **同步进度（2026-10-28）**：core 的 `SyncProgress` 经 FRB `StreamSink` 到
///   [syncProgressProvider]，面板在 `_runSync` 期间订阅它显示阶段文案 + 进度条。
///   此前只有「await cloudSyncNow 期间置同步中」的本地态——大附件同步时用户
///   看到的是一个不动的转环，无法判断是在推进还是卡住。
///   图标本身仍用本地态驱动（它挂在标题栏、不在面板里，跨页面存活）；
///   进度只影响面板内文案，两者不互相等待。
/// - 成功对勾短暂展示后自动回落待命；与备份无关（自动备份入口在设置页）
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
import 'shadcn/orbit_spinner.dart';
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
      SyncUiStatus.unconfigured ||
      SyncUiStatus.locked => colors.deactivatedText,
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
            OrbitSpinner(size: _iconBox, color: OrbitAccents.themeAccent),
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
                  child: const Icon(
                    OrbitIcons.check,
                    size: 10,
                    color: Colors.white,
                  ),
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

  /// N33：已下达取消、正在等在途分片收尾（最长约一片 ~5MiB）
  bool _cancelling = false;

  /// 本次手动同步的最后一条进度（null = 尚未收到任何进度事件）
  ///
  /// 只认 `origin == 'manual'`：后台自动同步（定时 / 改后即同步）的进度不该
  /// 出现在用户点开的面板里——用户点「立即同步」看到的应当是**这一次**的推进。
  SyncProgress? _progress;

  /// 错误消息去 `[tag] ` 前缀（Rust 侧 `[category] message` 约定）
  String _errMsg(Object err) =>
      err.toString().replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  Future<void> _runSync() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      // 清掉上一轮残留：新一次同步从「准备同步」重新开始推进
      _progress = null;
    });
    widget.onStatusChanged(SyncUiStatus.syncing);
    try {
      final result = await ref
          .read(orbitBridgeProvider)
          .cloudSyncNow(origin: 'manual');
      ref.invalidate(syncConfigProvider);
      // 拉取合并写入不走 db-change 事件，需在此失效业务缓存（F42：按真正
      // 写入的表精确失效，口径同桌面 useSyncInvalidation）
      invalidateAfterSyncCaches(ref, result);
      widget.onStatusChanged(
        result.skipped ? SyncUiStatus.idle : SyncUiStatus.success,
      );
      WaitToast.success(
        syncResultSummary(
          pushedModules: result.pushedModules,
          pulledModules: result.pulledModules,
          skipped: result.skipped,
          errorCount: result.errors.length,
        ),
      );
      if (mounted && !result.skipped) Navigator.of(context).pop();
    } catch (e) {
      final msg = _errMsg(e);
      // N33：用户主动取消不是故障——回待命态 + 中性提示，不留红色错误
      if (syncErrorTag(e.toString()) == 'cancelled') {
        widget.onStatusChanged(SyncUiStatus.idle);
        WaitToast.info('已取消同步');
        return;
      }
      widget.onStatusChanged(SyncUiStatus.error, error: msg);
      WaitToast.destructive(msg);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancelling = false;
        });
      }
    }
  }

  /// 取消同步（N33 协作式分片取消）
  ///
  /// 命中后保持「取消中」直到 `_runSync` 的 `cloudSyncNow` 拒绝返回；
  /// 命中失败（当前没有在跑的同步）才把按钮弹回「立即同步」。
  Future<void> _cancelSync() async {
    if (!_busy || _cancelling) return;
    setState(() => _cancelling = true);
    try {
      final hit = await ref.read(orbitBridgeProvider).cloudSyncCancel();
      if (!mounted) return;
      if (!hit) {
        setState(() => _cancelling = false);
        WaitToast.info('当前没有进行中的同步');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancelling = false);
      WaitToast.destructive('取消失败：${_errMsg(e)}');
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
    // 订阅进度流并把 manual 档的最新一条收进本地态。
    //
    // 用 `ref.listen` 而不是在 build 里直接读值：`StreamProvider` 的 `value`
    // 只反映「最后一条」，`listen` 才能在到达时 `setState` 并区分 origin。
    // 订阅本身由 provider 持有，面板关闭（本 State dispose）后自动取消。
    ref.listen<AsyncValue<SyncProgress>>(syncProgressProvider, (_, next) {
      final p = next.value;
      if (p == null || !p.isManual) return;
      // 同步已结束（终态）时不再刷 UI：终态由 `_runSync` 的返回值落定，
      // 进度只负责「进行中」这一段
      if (!_busy || p.isTerminal) return;
      if (!mounted) return;
      setState(() => _progress = p);
    });
    final progress = _progress;
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
            Icon(
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
      contentPadding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _infoRow(colors, '状态', syncStatusLabel(widget.status)),
          // 进行中才显示进度：没有事件时退回「正在同步…」的既有文案（不占位）
          if (_busy && progress != null) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimens.space8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress.percent / 100,
                      minHeight: 4,
                      backgroundColor: colors.surfaceSecondary,
                      color: OrbitAccents.themeAccent,
                    ),
                  ),
                  const SizedBox(height: AppDimens.space6),
                  Text(
                    progress.displayText,
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                ],
              ),
            ),
          ],
          _infoRow(colors, '上次同步', formatLastSynced(config?.lastSyncedAt)),
          _infoRow(colors, '下次自动同步', formatNextSync(nextAt)),
          if (widget.errorMessage != null)
            _infoRow(colors, '失败原因', widget.errorMessage!),
        ],
      ),
      actions: OrbitSheetActions(
        // N33：运行中把主按钮换成「取消同步」——进度条只说明在推进，
        // 大附件分片上传时用户仍需要一个「停下」的出口
        confirmLabel: _busy
            ? (_cancelling ? '取消中…' : '取消同步')
            : '立即同步',
        onConfirm: _busy
            ? (_cancelling ? null : () => unawaited(_cancelSync()))
            : () => unawaited(_runSync()),
        confirmChild: _cancelling
            ? const OrbitSpinner(size: AppDimens.iconSizeSm, color: Colors.white)
            : null,
      ),
    );
  }
}
