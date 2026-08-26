import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/wait_toast.dart';
import '../todo/logic/task_logic.dart' show formatDateTime;
import '../todo/providers/todo_providers.dart';

/// 设置页 /settings（移动端任务书三卡结构）
///
/// - 同步卡：引擎摘要（脱敏 endpoint host/bucket）+ 上次同步时间 +
///   "立即同步"；未配置引擎时禁用并提示"请在桌面端完成配置"；
/// - 安全卡：只读文案——移动端暂不支持主密码迁移；
/// - 关于卡：版本 0.1.0 → push /about。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _scrollController = ScrollController();
  bool _syncing = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 立即同步：cloudSyncNow → 结果 toast；完成后刷新配置（上次同步时间）
  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final result =
          await ref.read(orbitBridgeProvider).cloudSyncNow(origin: 'manual');
      ref.invalidate(syncConfigProvider);
      WaitToast.success(
        result.skipped
            ? '已有同步任务在进行中'
            : '同步完成：推送 ${result.pushedModules} / 拉取 ${result.pulledModules} 模块',
      );
    } catch (_) {
      WaitToast.destructive('同步失败');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final config = ref.watch(syncConfigProvider).value;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              controller: _scrollController,
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top +
                    LiquidGlassTitleBar.rowHeight +
                    AppDimens.space16,
                left: AppDimens.space16,
                right: AppDimens.space16,
                bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
              ),
              children: [
                // 一、同步卡
                SectionCard(
                  title: '同步',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        config == null ? '未配置同步引擎' : engineSummary(config),
                        style: TextStyle(fontSize: 14, color: colors.bodyText),
                      ),
                      const SizedBox(height: AppDimens.space4),
                      Text(
                        config?.lastSyncedAt == null
                            ? '从未同步'
                            : '上次同步：${formatDateTime(config!.lastSyncedAt!)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                      ),
                      if (config == null) ...[
                        const SizedBox(height: AppDimens.space8),
                        Text(
                          '请在桌面端完成配置',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.secondaryText.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                      const SizedBox(height: AppDimens.space12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed:
                              (config == null || _syncing) ? null : _syncNow,
                          icon: _syncing
                              ? SizedBox(
                                  width: AppDimens.iconSizeSm,
                                  height: AppDimens.iconSizeSm,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white.withValues(alpha: 0.9),
                                  ),
                                )
                              : const Icon(Icons.sync_rounded,
                                  size: AppDimens.iconSizeSm + 2),
                          label: Text(_syncing ? '同步中…' : '立即同步'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.space12),
                // 二、安全卡（只读）
                SectionCard(
                  title: '安全',
                  child: Text(
                    '移动端暂不支持主密码迁移，相关操作请在桌面端完成。',
                    style:
                        TextStyle(fontSize: 13, color: colors.secondaryText),
                  ),
                ),
                const SizedBox(height: AppDimens.space12),
                // 三、关于卡
                SectionCard(
                  title: '关于',
                  child: InkWell(
                    borderRadius: AppShapes.medium,
                    onTap: () => context.push('/about'),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppDimens.space4),
                      child: Row(
                        children: [
                          Text(
                            '版本',
                            style: TextStyle(
                                fontSize: 14, color: colors.bodyText),
                          ),
                          const Spacer(),
                          Text(
                            '0.1.0',
                            style: TextStyle(
                              fontSize: 14,
                              color: OrbitAccents.themeAccent,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: AppDimens.iconSizeMd,
                            color: colors.secondaryText,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: '设置',
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
            ),
          ),
        ],
      ),
    );
  }
}

/// 引擎摘要（脱敏不显示凭据）：webdav → endpoint host；s3 → bucket
String engineSummary(SyncConfigView config) {
  if (config.engine == 's3') {
    return 'S3 · ${config.bucket.isEmpty ? '-' : config.bucket}';
  }
  var host = '';
  try {
    host = Uri.parse(config.endpoint).host;
  } catch (_) {
    // 非 URL 形态直接原样展示
  }
  if (host.isEmpty) host = config.endpoint;
  return 'WebDAV · $host';
}
