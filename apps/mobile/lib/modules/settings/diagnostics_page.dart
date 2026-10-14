import 'dart:io' show ProcessInfo;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';

/// 诊断页 /settings/diagnostics（docs/09 内存专项「应用内诊断分区」）
///
/// 口径与桌面「设置 → 诊断」一致：
/// - **只读**：读数来自 `OrbitBridge.diagnosticsSnapshot()`（core 只读聚合，
///   不 emit db-change、不进同步白名单），前端的进程 RSS 只在进入本页时采一次；
/// - 两类读数分开摆：**本地存储**（库体积/行数/附件缓存，Rust 侧量）与
///   **运行时**（进程 RSS，Dart 侧量 `ProcessInfo.currentRss`）——混在一起会让人
///   误判口径；
/// - 整页 ListView 滚动（AGENTS 移动端约定：不要 Column+Expanded 固定高度）。
class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  DiagnosticsSnapshot? _snapshot;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final snapshot =
          await ref.read(orbitBridgeProvider).diagnosticsSnapshot();
      if (mounted) setState(() => _snapshot = snapshot);
    } catch (_) {
      if (mounted) setState(() => _snapshot = null);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final snap = _snapshot;
    return Scaffold(
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top +
                  OrbitPageHeader.rowHeight +
                  AppDimens.space16,
              left: AppDimens.pageInline,
              right: AppDimens.pageInline,
              bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
            ),
            children: [
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (snap == null)
                Text(
                  '读数不可用',
                  style: TextStyle(fontSize: 13, color: colors.secondaryText),
                )
              else ...[
                SectionCard(
                  title: '本地存储',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _reading(colors, '数据库体积', formatBytes(snap.dbSizeBytes),
                          hint: 'page_count × page_size'),
                      _reading(colors, '墓碑行数', formatCount(snap.tombstoneRows),
                          hint: '已软删，待在回收站或同步中传播'),
                      _reading(
                        colors,
                        '附件缓存',
                        formatBytes(snap.attachmentCacheBytes),
                        hint: '${formatCount(snap.attachmentCacheFiles)} 个文件',
                      ),
                      const SizedBox(height: AppDimens.space8),
                      Wrap(
                        spacing: AppDimens.space8,
                        runSpacing: AppDimens.space4,
                        children: [
                          for (final row in snap.tableRows)
                            if (row.rows > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: colors.surfaceSecondary,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${row.table} ${formatCount(row.rows)}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colors.secondaryText,
                                  ),
                                ),
                              ),
                        ],
                      ),
                      const SizedBox(height: AppDimens.space8),
                      Text(
                        '活行数按 is_deleted = 0；库体积不含 WAL 与附件目录。',
                        style:
                            TextStyle(fontSize: 11, color: colors.secondaryText),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.cardGap),
                SectionCard(
                  title: '运行时',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _reading(
                        colors,
                        '进程 RSS',
                        formatBytes(ProcessInfo.currentRss),
                        hint: '含原生库与实际驻留',
                      ),
                      const SizedBox(height: AppDimens.space8),
                      Text(
                        '只读快照，点右上「刷新」重新采集（Rust 侧会重新查询数据库）。',
                        style:
                            TextStyle(fontSize: 11, color: colors.secondaryText),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '诊断',
              actions: [
                IconButton(
                  tooltip: '刷新',
                  onPressed:
                      _loading ? null : () => _load(),
                  icon: const Icon(OrbitIcons.refresh),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 一行读数：左标签 + 右等宽数值（对齐桌面诊断分区排布）
  Widget _reading(
    AppColorSet colors,
    String label,
    String value, {
    String? hint,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: AppDimens.space4),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 13, color: colors.secondaryText)),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: colors.bodyText,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(width: AppDimens.space8),
              Text(hint,
                  style: TextStyle(fontSize: 11, color: colors.secondaryText)),
            ],
          ],
        ),
      );
}

/// 体积格式化（1024 进制；异常值显示占位符，不出现 NaN）
String formatBytes(num? bytes) {
  if (bytes == null || bytes < 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final text = unit == 0 ? value.round().toString() : value.toStringAsFixed(1);
  return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} ${units[unit]}';
}

/// 行数格式化（千分位）
String formatCount(num? n) {
  if (n == null) return '—';
  final s = n.round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
