import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../services/app_update_service.dart';
import '../../shared/widgets/shadcn/orbit_button.dart';
import '../../shared/widgets/shadcn/orbit_progress_bar.dart';
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_sheets.dart' show bottomSheetMotion;

/// APK 下载进度弹层；成功返回落盘路径，取消/关闭返回 null。
///
/// 下载期间禁用下滑与遮罩关闭（避免误触把已下几十 MB 的包丢掉），
/// 返回键仍可退出——路由销毁时 `dispose` 会取消下载并清理半成品。
Future<String?> showApkDownloadSheet(
  BuildContext context, {
  required String version,
  required Uri url,
}) {
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    elevation: 0,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (_) => _ApkDownloadSheet(version: version, url: url),
  );
}

class _ApkDownloadSheet extends StatefulWidget {
  const _ApkDownloadSheet({required this.version, required this.url});

  final String version;
  final Uri url;

  @override
  State<_ApkDownloadSheet> createState() => _ApkDownloadSheetState();
}

class _ApkDownloadSheetState extends State<_ApkDownloadSheet> {
  UpdateDownloadCancel _cancel = UpdateDownloadCancel();
  bool _running = false;
  String? _error;
  int _received = 0;
  int _total = -1;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // 页面被系统返回或宿主销毁：中止下载，不留下半成品
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    if (_running) return;
    _running = true;
    _cancel = UpdateDownloadCancel();
    try {
      final file = await AppUpdateService.downloadApk(
        url: widget.url,
        version: widget.version,
        cancel: _cancel,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } on UpdateDownloadCancelled {
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = _displayError(e);
      });
    }
  }

  void _cancelDownload() {
    _cancel.cancel();
    Navigator.of(context).pop();
  }

  void _retry() {
    setState(() {
      _error = null;
      _received = 0;
      _total = -1;
    });
    _start();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

    return OrbitSheetScaffold(
      title: '应用内更新',
      // 无手柄：此层不能用下滑关闭，手柄会暗示可拖拽
      showHandle: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppDimens.space24),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _error == null
                ? '正在下载 ${widget.version} 安装包…'
                : '下载 ${widget.version} 失败',
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: colors.titleText,
            ),
          ),
          const SizedBox(height: AppDimens.space12),
          if (_error == null) ...[
            OrbitProgressBar(value: progress),
            const SizedBox(height: AppDimens.space8),
            Row(
              children: [
                Text(
                  progress == null
                      ? '下载中…'
                      : '${(progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 12, color: colors.secondaryText),
                ),
                const Spacer(),
                Text(
                  _total > 0
                      ? '${formatDownloadBytes(_received)} / ${formatDownloadBytes(_total)}'
                      : formatDownloadBytes(_received),
                  style: TextStyle(fontSize: 12, color: colors.secondaryText),
                ),
              ],
            ),
            const SizedBox(height: AppDimens.space12),
            Text(
              '下载完成后会调起系统安装器；请保持应用在前台，安装确认由系统接管。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: colors.secondaryText,
              ),
            ),
          ] else ...[
            Text(
              _error!,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.secondaryText,
              ),
            ),
            const SizedBox(height: AppDimens.space8),
            Text(
              '可重试下载；若仍失败，退出后从发布页手动下载安装。',
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            ),
          ],
        ],
      ),
      actions: _error == null
          ? Padding(
              padding: const EdgeInsets.fromLTRB(
                AppDimens.space24,
                AppDimens.space16,
                AppDimens.space24,
                AppDimens.space20,
              ),
              child: OrbitButton.outline(
                onPressed: _cancelDownload,
                expand: true,
                child: const Text('取消下载', textAlign: TextAlign.center),
              ),
            )
          : OrbitSheetActions(
              padding: const EdgeInsets.fromLTRB(
                AppDimens.space24,
                AppDimens.space16,
                AppDimens.space24,
                AppDimens.space20,
              ),
              cancelLabel: '取消',
              onCancel: _cancelDownload,
              confirmLabel: '重试',
              onConfirm: _retry,
            ),
    );
  }

  String _displayError(Object error) {
    if (error is AppUpdateException) return error.message;
    return '$error';
  }
}
