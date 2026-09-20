import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/confirm_bottom_sheet.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/select_bottom_sheet.dart';
import '../../shared/widgets/wait_toast.dart';
import '../todo/logic/task_logic.dart' show formatDateTime;

/// 备份与恢复页 /settings/backup（数据安全兜底）
///
/// 桌面端「同步与备份」分区的 BackupCard + AutoBackupCard 在移动端的等价物：
/// - **导出**：本地 `.orfullsync`（可附云端副本）。备份内容是端到端加密的
///   全量包，密码复用已解锁的同步密码会话——未解锁时先引导去云同步设置解锁。
/// - **恢复**：本地文件 / 云端副本两条来源，均先走 `peek` 预览（备份时间、
///   来源设备、任务抽样、schema 比对），确认后才执行覆盖式导入；schema
///   不一致时追加一次强制确认（对齐桌面两段式）。
/// - **自动备份**：频率/时刻/本地与云端开关，落 `backup_prefs`（本机偏好，
///   不进同步）。移动端调度由 Rust 守护承担，进程被杀时不执行——页面文案明示。
///
/// 危险动作口径：导入会清空当前业务表再写入备份内容（事务内原子），因此
/// 全部恢复路径都必须经过预览确认，且不提供「跳过预览」的快捷入口。
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  final _scrollController = ScrollController();

  BackupPrefs _prefs = BackupPrefs.initial;
  List<BackupEntry> _local = const [];
  List<CloudBackupEntry> _cloud = const [];

  bool _loading = true;

  /// 云端清单不可用原因（未配置云同步时不阻断其余卡片）
  String? _cloudError;

  /// 进行中的动作标识（'export' / 'exportCloud' / 'restore' / 'prefs'），
  /// null = 空闲；用于按钮防重复点击
  String? _busy;

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

  String _errMsg(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  Future<void> _load() async {
    final bridge = ref.read(orbitBridgeProvider);
    try {
      final prefs = await bridge.backupPrefsGet();
      final local = await bridge.fullBackupListLocal();
      List<CloudBackupEntry> cloud = const [];
      String? cloudError;
      try {
        cloud = await bridge.fullBackupListCloud();
      } catch (e) {
        cloudError = _errMsg(e);
      }
      if (!mounted) return;
      setState(() {
        _prefs = prefs;
        _local = local;
        _cloud = cloud;
        _cloudError = cloudError;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      WaitToast.destructive('读取备份信息失败：${_errMsg(e)}');
    }
  }

  // ── 导出 ──

  Future<void> _export({required bool uploadCloud}) async {
    if (_busy != null) return;
    setState(() => _busy = uploadCloud ? 'exportCloud' : 'export');
    try {
      final r = await ref
          .read(orbitBridgeProvider)
          .fullBackupExport(uploadCloud: uploadCloud);
      if (!mounted) return;
      final size = humanFileSize(r.fileSize);
      final tables = r.manifest.tableCounts.length;
      if (r.localError != null) {
        WaitToast.destructive('本地写入失败：${r.localError}');
      } else if (uploadCloud && r.cloudError != null) {
        WaitToast.warning('本地备份已生成（$size），云端上传失败：${r.cloudError}');
      } else if (uploadCloud) {
        WaitToast.success('已备份到本机并上传云端（$size · $tables 张表）');
      } else {
        WaitToast.success('已导出本地备份（$size · $tables 张表）');
      }
      await _load();
    } catch (e) {
      if (mounted) WaitToast.destructive('导出失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  // ── 恢复 ──

  Future<void> _restoreFromFile() async {
    if (_busy != null) return;
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(withData: true);
    } catch (e) {
      if (mounted) WaitToast.destructive('选择文件失败：${_errMsg(e)}');
      return;
    }
    final file = picked?.files.singleOrNull;
    final bytes = file?.bytes;
    if (bytes == null) return;

    final bridge = ref.read(orbitBridgeProvider);
    setState(() => _busy = 'restore');
    try {
      final preview = await bridge.fullBackupPeekLocal(bytes);
      if (!mounted) return;
      setState(() => _busy = null);
      await _confirmAndRestore(
        preview: preview,
        sourceLabel: file!.name,
        run: (force) => bridge.fullBackupImport(
          bytes,
          ignoreSchemaMismatch: force,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = null);
      WaitToast.destructive('预览失败：${_errMsg(e)}');
    }
  }

  Future<void> _pickCloudAndRestore() async {
    if (_busy != null) return;
    if (_cloud.isEmpty) {
      WaitToast.info(_cloudError ?? '云端暂无备份副本');
      return;
    }
    final bridge = ref.read(orbitBridgeProvider);
    await showSelectBottomSheet<String>(
      context,
      title: '选择云端备份',
      current: null,
      items: [
        for (final e in _cloud)
          SelectItem(
            value: e.cloudPath,
            label: '${e.name} · ${humanFileSize(e.sizeBytes)} · '
                '${formatDateTime(e.modifiedAt)}',
          ),
      ],
      onSelect: (cloudPath) async {
        setState(() => _busy = 'restore');
        try {
          final preview = await bridge.fullBackupPeekCloud(cloudPath);
          if (!mounted) return;
          setState(() => _busy = null);
          await _confirmAndRestore(
            preview: preview,
            sourceLabel: cloudPath.split('/').last,
            run: (force) => bridge.fullBackupRestoreCloud(
              cloudPath,
              ignoreSchemaMismatch: force,
            ),
          );
        } catch (e) {
          if (!mounted) return;
          setState(() => _busy = null);
          WaitToast.destructive('预览失败：${_errMsg(e)}');
        }
      },
    );
  }

  /// 两段式恢复确认：预览信息 → 确认覆盖；schema 不一致再追加一次强制确认。
  Future<void> _confirmAndRestore({
    required BackupPreview preview,
    required String sourceLabel,
    required Future<BackupImportResult> Function(bool force) run,
  }) async {
    final ok = await showConfirmBottomSheet(
      context,
      title: '恢复此备份？',
      // 预览体（备份时间/来源设备/任务抽样/schema 比对）整体进抽屉，
      // 超高时由抽屉内部滚动，不再自带 SingleChildScrollView
      content: _PreviewBody(preview: preview, sourceLabel: sourceLabel),
      confirmLabel: '覆盖恢复',
      destructive: true,
    );
    if (!ok || !mounted) return;

    if (preview.schemaMismatch) {
      final forced = await showConfirmBottomSheet(
        context,
        title: '版本不一致',
        message: '备份的数据结构版本为 ${preview.manifest.schemaVersion}，'
            '本机为 ${preview.currentSchemaVersion}。'
            '强行恢复可能丢失本机新增字段的数据，且不可撤销。',
        confirmLabel: '仍然恢复',
        destructive: true,
      );
      if (!forced || !mounted) return;
    }

    setState(() => _busy = 'restore');
    try {
      final r = await run(preview.schemaMismatch);
      if (!mounted) return;
      WaitToast.success('已恢复 ${r.successCount} 条记录'
          '${r.errorCount > 0 ? '，${r.errorCount} 条失败' : ''}');
      if (r.needsRestart) {
        WaitToast.warning('建议重启应用以完成数据迁移');
      }
      await _load();
    } catch (e) {
      if (mounted) WaitToast.destructive('恢复失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _deleteLocal(BackupEntry entry) async {
    final ok = await showConfirmBottomSheet(
      context,
      title: '删除这份备份？',
      message: '${entry.filename}\n删除后无法恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(orbitBridgeProvider).fullBackupDeleteLocal(entry.filePath);
      WaitToast.success('已删除备份');
      await _load();
    } catch (e) {
      if (mounted) WaitToast.destructive('删除失败：${_errMsg(e)}');
    }
  }

  // ── 自动备份偏好 ──

  static const _scheduleLabels = <String, String>{
    'off': '关闭',
    'hourly': '每小时',
    'daily': '每天',
    'weekly': '每周',
    'monthly': '每月',
    'yearly': '每年',
  };

  static const _weekdayLabels = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

  Future<void> _savePrefs(BackupPrefs next) async {
    setState(() {
      _prefs = next;
      _busy = 'prefs';
    });
    try {
      final saved = await ref.read(orbitBridgeProvider).backupPrefsSave(next);
      if (!mounted) return;
      setState(() => _prefs = saved);
    } catch (e) {
      if (!mounted) return;
      WaitToast.destructive('保存失败：${_errMsg(e)}');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _pickScheduleType() async {
    await showSelectBottomSheet<String>(
      context,
      title: '自动备份频率',
      current: _prefs.scheduleType,
      items: [
        for (final e in _scheduleLabels.entries)
          SelectItem(value: e.key, label: e.value),
      ],
      onSelect: (v) => _savePrefs(_prefs.copyWith(scheduleType: v)),
    );
  }

  Future<void> _pickScheduleTime() async {
    final parts = _prefs.scheduleTime.split(':');
    final hour = int.tryParse(parts.first) ?? 3;
    final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;

    if (!mounted) return;
    await showSelectBottomSheet<int>(
      context,
      title: '备份时刻 · 小时',
      current: hour,
      items: [
        for (var h = 0; h < 24; h++)
          SelectItem(value: h, label: '${h.toString().padLeft(2, '0')} 时'),
      ],
      onSelect: (h) async {
        if (!mounted) return;
        await showSelectBottomSheet<int>(
          context,
          title: '备份时刻 · 分钟',
          current: minute - (minute % 15),
          items: [
            for (var m = 0; m < 60; m += 15)
              SelectItem(value: m, label: '${m.toString().padLeft(2, '0')} 分'),
          ],
          onSelect: (m) => _savePrefs(_prefs.copyWith(
            scheduleTime:
                '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}',
          )),
        );
      },
    );
  }

  Future<void> _pickWeekday() async {
    await showSelectBottomSheet<int>(
      context,
      title: '备份日 · 星期',
      current: _prefs.scheduleWeekday,
      items: [
        for (var i = 0; i < 7; i++)
          SelectItem(value: i, label: _weekdayLabels[i]),
      ],
      onSelect: (v) => _savePrefs(_prefs.copyWith(scheduleWeekday: v)),
    );
  }

  Future<void> _pickMonth() async {
    await showSelectBottomSheet<int>(
      context,
      title: '备份月',
      current: _prefs.scheduleMonth,
      items: [
        for (var i = 1; i <= 12; i++) SelectItem(value: i, label: '$i 月'),
      ],
      onSelect: (v) async {
        await _savePrefs(_prefs.copyWith(scheduleMonth: v));
        if (!mounted) return;
        await _pickDayOfMonth();
      },
    );
  }

  Future<void> _pickDayOfMonth() async {
    await showSelectBottomSheet<int>(
      context,
      title: '备份日',
      current: _prefs.scheduleDayOfMonth,
      items: [
        // 上限 28：避免月末歧义（core validate_schedule 同口径）
        for (var i = 1; i <= 28; i++) SelectItem(value: i, label: '$i 日'),
      ],
      onSelect: (v) => _savePrefs(_prefs.copyWith(scheduleDayOfMonth: v)),
    );
  }

  // ── 渲染 ──

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final busy = _busy != null;

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
                _backupCard(colors, busy),
                const SizedBox(height: AppDimens.space12),
                _restoreCard(colors, busy),
                const SizedBox(height: AppDimens.space12),
                _autoBackupCard(colors),
                const SizedBox(height: AppDimens.space12),
                _localListCard(colors),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: '备份与恢复',
              scrollOffsetListenable:
                  ScrollOffsetListenable(_scrollController),
            ),
          ),
        ],
      ),
    );
  }

  Widget _backupCard(AppColorSet colors, bool busy) {
    final last = _prefs.lastBackupAt;
    return SectionCard(
      title: '备份',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '备份是端到端加密的全量数据包（.orfullsync），只有同一同步密码'
            '才能恢复。恢复会覆盖本机全部业务数据。',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: AppDimens.space8),
          Text(
            last == 0
                ? '尚未生成过备份'
                : '上次备份：${formatDateTime(last * 1000)}',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: AppDimens.space12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => _export(uploadCloud: false),
                  icon: _busy == 'export'
                      ? const _MiniSpinner()
                      : const Icon(Icons.save_alt_rounded,
                          size: AppDimens.iconSizeSm + 2),
                  label: const Text('导出本地备份'),
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : () => _export(uploadCloud: true),
                  icon: _busy == 'exportCloud'
                      ? const _MiniSpinner()
                      : const Icon(Icons.cloud_upload_outlined,
                          size: AppDimens.iconSizeSm + 2),
                  label: const Text('备份到云端'),
                ),
              ),
            ],
          ),
          if (!_loading && _cloudError != null) ...[
            const SizedBox(height: AppDimens.space8),
            Text(
              '云端副本不可用：$_cloudError',
              style: TextStyle(
                fontSize: 11,
                color: colors.secondaryText.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _restoreCard(AppColorSet colors, bool busy) {
    return SectionCard(
      title: '恢复',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '恢复前会先展示备份内容（时间、来源设备、任务抽样），确认后才覆盖本机。',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: AppDimens.space8),
          _actionRow(
            colors,
            icon: Icons.insert_drive_file_outlined,
            label: '从本地文件恢复',
            trailing: _busy == 'restore' ? const _MiniSpinner() : null,
            onTap: busy ? null : _restoreFromFile,
          ),
          _actionRow(
            colors,
            icon: Icons.cloud_download_outlined,
            label: '从云端副本恢复',
            trailing: Text(
              _cloud.isEmpty ? '无副本' : '${_cloud.length} 份',
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            ),
            onTap: busy ? null : _pickCloudAndRestore,
          ),
        ],
      ),
    );
  }

  Widget _autoBackupCard(AppColorSet colors) {
    final showTime = _prefs.scheduleType != 'off' &&
        _prefs.scheduleType != 'hourly';
    return SectionCard(
      title: '自动备份',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '按频率自动生成加密备份。应用未运行（进程被杀）时不会执行，'
            '下次打开会补做当天缺额。',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: AppDimens.space8),
          _actionRow(
            colors,
            label: '频率',
            value: _scheduleLabels[_prefs.scheduleType] ?? '关闭',
            onTap: _pickScheduleType,
          ),
          if (_prefs.scheduleType == 'hourly')
            _actionRow(
              colors,
              label: '分钟',
              value: '${_prefs.scheduleMinute} 分',
              onTap: () async {
                await showSelectBottomSheet<int>(
                  context,
                  title: '每小时的第几分钟',
                  current: _prefs.scheduleMinute,
                  items: [
                    for (var m = 0; m < 60; m += 5)
                      SelectItem(value: m, label: '$m 分'),
                  ],
                  onSelect: (v) =>
                      _savePrefs(_prefs.copyWith(scheduleMinute: v)),
                );
              },
            ),
          if (showTime)
            _actionRow(
              colors,
              label: '时刻',
              value: _prefs.scheduleTime,
              onTap: _pickScheduleTime,
            ),
          if (_prefs.scheduleType == 'weekly')
            _actionRow(
              colors,
              label: '星期',
              value: _weekdayLabels[_prefs.scheduleWeekday.clamp(0, 6)],
              onTap: _pickWeekday,
            ),
          if (_prefs.scheduleType == 'monthly')
            _actionRow(
              colors,
              label: '日期',
              value: '${_prefs.scheduleDayOfMonth} 日',
              onTap: _pickDayOfMonth,
            ),
          if (_prefs.scheduleType == 'yearly')
            _actionRow(
              colors,
              label: '日期',
              value: '${_prefs.scheduleMonth} 月 ${_prefs.scheduleDayOfMonth} 日',
              onTap: _pickMonth,
            ),
          const SizedBox(height: AppDimens.space4),
          _switchRow(
            colors,
            label: '写入本机备份目录',
            value: _prefs.localBackupEnabled,
            onChanged: (v) => _savePrefs(_prefs.copyWith(localBackupEnabled: v)),
          ),
          _switchRow(
            colors,
            label: '上传云端副本',
            value: _prefs.cloudBackupEnabled,
            onChanged: (v) =>
                _savePrefs(_prefs.copyWith(cloudBackupEnabled: v)),
          ),
          _switchRow(
            colors,
            label: '仅保留最新一份',
            value: _prefs.keepLatest,
            onChanged: (v) => _savePrefs(_prefs.copyWith(keepLatest: v)),
          ),
          if (_prefs.nextBackupAt > 0) ...[
            const SizedBox(height: AppDimens.space8),
            Text(
              '下次自动备份：${formatDateTime(_prefs.nextBackupAt * 1000)}',
              style: TextStyle(fontSize: 11, color: colors.secondaryText),
            ),
          ],
        ],
      ),
    );
  }

  Widget _localListCard(AppColorSet colors) {
    return SectionCard(
      title: '本机备份文件',
      subtitle: _local.isEmpty ? null : '${_local.length} 份',
      child: _loading
          ? const Padding(
              padding: EdgeInsets.all(AppDimens.space16),
              child: Center(child: _MiniSpinner()),
            )
          : _local.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppDimens.space16),
                  child: Center(
                    child: Text(
                      '本机还没有备份文件。',
                      style:
                          TextStyle(fontSize: 12, color: colors.secondaryText),
                    ),
                  ),
                )
              : Column(
                  children: [for (final e in _local) _localRow(colors, e)],
                ),
    );
  }

  Widget _localRow(AppColorSet colors, BackupEntry e) {
    return Container(
      margin: const EdgeInsets.only(top: AppDimens.space8),
      padding: const EdgeInsets.all(AppDimens.space12),
      decoration: BoxDecoration(
        color: colors.surfaceSecondary,
        borderRadius: AppShapes.medium,
        border: Border.all(color: colors.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: colors.bodyText),
                ),
                const SizedBox(height: AppDimens.space2),
                Text(
                  '${humanFileSize(e.sizeBytes)} · '
                  '${formatDateTime(e.modifiedAt * 1000)}',
                  style: TextStyle(fontSize: 11, color: colors.secondaryText),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _busy != null ? null : () => _deleteLocal(e),
            icon: Icon(Icons.delete_outline_rounded,
                size: AppDimens.iconSizeMd, color: colors.destructive),
            tooltip: '删除',
          ),
        ],
      ),
    );
  }

  Widget _actionRow(
    AppColorSet colors, {
    required String label,
    String? value,
    IconData? icon,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: AppShapes.medium,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: AppDimens.iconSizeSm + 2, color: colors.bodyText),
              const SizedBox(width: AppDimens.space12),
            ],
            Text(label,
                style: TextStyle(fontSize: 14, color: colors.bodyText)),
            const Spacer(),
            if (trailing != null)
              trailing
            else ...[
              if (value != null)
                Text(
                  value,
                  style: TextStyle(fontSize: 14, color: OrbitAccents.themeAccent),
                ),
              Icon(
                Icons.chevron_right_rounded,
                size: AppDimens.iconSizeMd,
                color: colors.secondaryText,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _switchRow(
    AppColorSet colors, {
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 14, color: colors.bodyText)),
          ),
          Switch.adaptive(
            value: value,
            onChanged: _busy == null ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

/// 恢复预览正文（备份时间 / 来源设备 / 任务统计 / 抽样列表）
class _PreviewBody extends StatelessWidget {
  const _PreviewBody({required this.preview, required this.sourceLabel});

  final BackupPreview preview;
  final String sourceLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final m = preview.manifest;
    final stats = preview.taskStats;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('来源：$sourceLabel',
            style: TextStyle(fontSize: 13, color: colors.bodyText)),
        const SizedBox(height: AppDimens.space4),
        Text(
          '备份时间：${formatDateTime(m.createdAtTs * 1000)}\n'
          '来源设备：${m.deviceName?.isNotEmpty == true ? m.deviceName : m.deviceId}\n'
          '应用版本：${m.appVersion}\n'
          '任务：共 ${stats.total}（存活 ${stats.alive} · 已完成 ${stats.done} · 回收站 ${stats.deleted}）',
          style: TextStyle(fontSize: 12, color: colors.secondaryText),
        ),
        if (preview.sampleTasks.isNotEmpty) ...[
          const SizedBox(height: AppDimens.space8),
          Text('抽样任务',
              style: TextStyle(fontSize: 12, color: colors.secondaryText)),
          const SizedBox(height: AppDimens.space4),
          for (final t in preview.sampleTasks)
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimens.space2),
              child: Text(
                '· ${t.title}'
                '${t.project != null ? '（${t.project}）' : ''}'
                '${t.done ? ' ✓' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.bodyText),
              ),
            ),
        ],
        const SizedBox(height: AppDimens.space8),
        Text(
          '恢复会清空本机现有任务、项目、标签等内容后写入备份数据。',
          style: TextStyle(fontSize: 12, color: colors.destructive),
        ),
      ],
    );
  }
}

class _MiniSpinner extends StatelessWidget {
  const _MiniSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: AppDimens.iconSizeSm,
        height: AppDimens.iconSizeSm,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: OrbitAccents.themeAccent,
        ),
      );
}
