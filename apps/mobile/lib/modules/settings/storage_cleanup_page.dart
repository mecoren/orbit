import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_spinner.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'diagnostics_page.dart' show formatBytes;

/// 存储清理页 /settings/storage（#107）
///
/// 解决「桌面临时清理对话框有、移动端只能在数据库维护里看一个汇总数」的
/// 双端不对称：逐条列出**本机未使用附件**（卸下附件后尚未被 GC 回收的
/// 二进制），可多选定向删除；云端对象不动（其他设备仍可重新拉取）。
///
/// 口径与桌面 `UnusedAttachmentsDialog` 一致：
/// - 只删本地文件 + 账本行，云端保留；未上传云端的行额外提示「删除后不可找回」；
/// - 不做五秒撤销（物理删文件不可逆），改为删除前确认抽屉列数量与体积。
class StorageCleanupPage extends ConsumerStatefulWidget {
  const StorageCleanupPage({super.key});

  @override
  ConsumerState<StorageCleanupPage> createState() => _StorageCleanupPageState();
}

class _StorageCleanupPageState extends ConsumerState<StorageCleanupPage> {
  final _scrollController = ScrollController();
  List<UnusedAttachment>? _rows;
  final Set<String> _selected = {};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(orbitBridgeProvider).unusedAttachmentsList();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _selected.removeWhere((h) => !rows.any((r) => r.hash == h));
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  int get _selectedBytes => (_rows ?? const <UnusedAttachment>[])
      .where((r) => _selected.contains(r.hash))
      .fold(0, (sum, r) => sum + r.sizeBytes);

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _busy) return;
    final count = _selected.length;
    final sizes = formatBytes(_selectedBytes);
    final ok = await showConfirmBottomSheet(
      context,
      title: '删除未使用附件',
      message:
          '将删除 $count 个本地附件文件（共 $sizes）。云端对象不受影响，'
          '其他设备仍可重新拉取；未上传云端的条目删除后不可找回。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final deleted = await ref
          .read(orbitBridgeProvider)
          .unusedAttachmentsDelete(_selected.toList());
      _selected.clear();
      await _load();
      WaitToast.success('已清理 $deleted 个本地附件');
    } catch (_) {
      WaitToast.destructive('清理失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final rows = _rows;
    return Scaffold(
      body: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: EdgeInsets.only(
              top:
                  MediaQuery.of(context).padding.top +
                  OrbitPageHeader.rowHeight +
                  AppDimens.space16,
              left: AppDimens.pageInline,
              right: AppDimens.pageInline,
              bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
            ),
            children: [
              SectionCard(
                title: '本地未使用附件',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '卸载附件后，本地二进制可能仍在缓存里等待回收。'
                      '这里列出的文件没有任何任务引用，可以安全删除。',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.secondaryText,
                      ),
                    ),
                    const SizedBox(height: AppDimens.space8),
                    Row(
                      children: [
                        Text(
                          rows == null ? '读取中…' : '共 ${rows.length} 项',
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.bodyText,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _busy ? null : () => _load(),
                          icon: Icon(
                            OrbitIcons.refresh,
                            size: AppDimens.iconSizeSm,
                          ),
                          label: const Text('刷新'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppDimens.cardGap),
              if (_error != null)
                Text(
                  '读取失败：$_error',
                  style: TextStyle(fontSize: 13, color: colors.destructive),
                )
              else if (rows == null)
                const Padding(
                  padding: EdgeInsets.all(AppDimens.space16),
                  child: Center(child: OrbitSpinner(size: AppDimens.iconSizeLg)),
                )
              else if (rows.isEmpty)
                SectionCard(
                  title: '没有可清理的附件',
                  child: Text(
                    '当前本地附件都有任务引用，或已被自动回收。',
                    style: TextStyle(fontSize: 13, color: colors.secondaryText),
                  ),
                )
              else ...[
                SectionCard(
                  title: '待清理清单',
                  child: Column(
                    children: [for (final a in rows) _row(colors, a)],
                  ),
                ),
                const SizedBox(height: AppDimens.cardGap),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy || _selected.isEmpty
                        ? null
                        : _deleteSelected,
                    child: Text(
                      _busy
                          ? '清理中…'
                          : _selected.isEmpty
                          ? '选择要清理的附件'
                          : '删除选中（${_selected.length} 项 · ${formatBytes(_selectedBytes)}）',
                    ),
                  ),
                ),
              ],
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: const OrbitPageHeader(title: '存储清理'),
          ),
        ],
      ),
    );
  }

  Widget _row(AppColorSet colors, UnusedAttachment a) {
    final selected = _selected.contains(a.hash);
    return InkWell(
      borderRadius: AppShapes.medium,
      onTap: _busy
          ? null
          : () => setState(() {
              if (selected) {
                _selected.remove(a.hash);
              } else {
                _selected.add(a.hash);
              }
            }),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    a.originalName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: colors.bodyText),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatBytes(a.sizeBytes)} · '
                    '${a.isUploaded == 0 ? "未上传云端（删除后不可找回）" : "云端仍保留"}',
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                ],
              ),
            ),
            Icon(
              selected ? OrbitIcons.check : OrbitIcons.circle,
              size: AppDimens.iconSizeMd,
              color: selected ? OrbitAccents.themeAccent : colors.secondaryText,
            ),
          ],
        ),
      ),
    );
  }
}
