import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/api/orbit_bridge.dart'
    show CsvImportPreview, CsvImportStats, DbMaintenanceResult;
import '../../data/providers/biometric_provider.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/select_bottom_sheet.dart';
import '../../shared/widgets/wait_toast.dart';
import '../todo/logic/task_logic.dart' show formatDateTime;
import '../todo/providers/todo_providers.dart';

/// 设置页 /settings（移动端任务书卡片结构）
///
/// - 同步卡：引擎摘要（脱敏 endpoint host/bucket）+ 上次同步时间 +
///   "立即同步" + "云同步设置"入口行（→ /settings/sync 配置页）；
/// - 回收站卡：保留时间档位 + 回收站入口；
/// - 安全卡：指纹解锁开关（密码确认 + 指纹闸门两段式；无指纹硬件
///   回退只读提示）+ 桌面端迁移说明；
/// - 数据导出/CSV 导入卡（07 报告 #15）；
/// - 关于卡：版本 → push /about。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _scrollController = ScrollController();
  bool _syncing = false;

  /// 数据库维护进行中（性能批次；防重复点击）
  bool _maintaining = false;

  /// 上次维护量化结果（null = 未执行过）
  DbMaintenanceResult? _maintenanceResult;

  /// 生物识别：硬件可用性（null=探测中）与启用状态（null=未启用/未知）
  bool? _bioAvailable;
  bool? _bioEnabled;

  /// 生物识别开关交互中（防重复点击）
  bool _bioBusy = false;

  /// 数据导出进行中的格式（'json' / 'csv'），null 空闲
  String? _exporting;

  /// CSV 导入：选中的预设档（orbit/todoist/ticktick）与文件名
  String _importPreset = 'orbit';
  String? _importFileName;
  String? _importContent;

  /// 导入进行中阶段（'preview' / 'execute'），null 空闲
  String? _importing;

  /// 预览结果（null = 未预览）
  CsvImportPreview? _importPreview;

  /// 执行结果统计（null = 未执行）
  CsvImportStats? _importResult;

  @override
  void initState() {
    super.initState();
    _loadBioState();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 明文数据导出（07 报告 #15）：桥导出 → 应用文档目录落盘 → toast 告知路径。
  ///
  /// 移动端无系统"另存为"对话框（MVP 不引 file_picker），固定写入
  /// `getApplicationDocumentsDirectory()/exports/`；未加密明文已在
  /// 卡头文案明示（PRIVACY.md §七口径）。
  Future<void> _exportData(String kind) async {
    if (_exporting != null) return;
    // 二次确认：明示未加密属性
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出明文数据'),
        content: const Text(
          '导出内容为未加密明文，任何拿到该文件的人都能读取。确定继续？',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('继续')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _exporting = kind);
    try {
      final bridge = ref.read(orbitBridgeProvider);
      final result = kind == 'json'
          ? await bridge.plaintextExportJson()
          : await bridge.plaintextExportCsv();

      final docs = await getApplicationDocumentsDirectory();
      final exportsDir = Directory('${docs.path}${Platform.pathSeparator}exports');
      await exportsDir.create(recursive: true);
      final file = File(
        '${exportsDir.path}${Platform.pathSeparator}${result.suggestedFilename}',
      );
      await file.writeAsString(result.content, flush: true);

      final tasks = result.tableCounts['todo_tasks'] ?? 0;
      WaitToast.success('已导出 ${kind.toUpperCase()}（任务 $tasks 条）到 ${file.path}');
    } catch (_) {
      WaitToast.destructive('导出失败');
    } finally {
      if (mounted) setState(() => _exporting = null);
    }
  }

  // ── 数据库维护（性能批次）：WAL checkpoint / 附件 GC / 查询统计 / VACUUM ──

  /// 一键维护：回收 WAL 日志与磁盘碎片、清理无引用附件、更新查询统计。
  /// 只读维护（不触发 db-change、不触碰同步数据），量化结果就地展示。
  Future<void> _runMaintenance() async {
    if (_maintaining) return;
    setState(() => _maintaining = true);
    try {
      final bridge = ref.read(orbitBridgeProvider);
      final r = await bridge.dbMaintenance();
      if (mounted) setState(() => _maintenanceResult = r);
      WaitToast.success('数据库维护完成');
    } catch (_) {
      WaitToast.destructive('维护失败');
    } finally {
      if (mounted) setState(() => _maintaining = false);
    }
  }

  // ── CSV 导入（迁移路径）：file_picker 选文件 → 预览（不写库）→ 确认执行 ──

  static const _importPresets = {
    'orbit': 'Orbit 导出格式',
    'todoist': 'Todoist 模板',
    'ticktick': 'TickTick 模板',
  };

  Future<void> _pickImportFile() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: '选择要导入的 CSV 文件',
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt'],
        withData: true,
      );
      if (picked == null) return; // 用户取消
      final content = String.fromCharCodes(picked.files.single.bytes ?? []);
      if (content.trim().isEmpty) {
        WaitToast.destructive('文件内容为空');
        return;
      }
      setState(() {
        _importFileName = picked.files.single.name;
        _importContent = content;
        _importPreview = null;
        _importResult = null;
      });
    } catch (_) {
      WaitToast.destructive('读取文件失败');
    }
  }

  Future<void> _previewImport() async {
    final content = _importContent;
    if (content == null || _importing != null) return;
    setState(() => _importing = 'preview');
    try {
      final preview = await ref
          .read(orbitBridgeProvider)
          .csvImportPreview(content, _importPreset, 10);
      setState(() {
        _importPreview = preview;
        _importResult = null;
      });
      if (preview.stats.success == 0 && preview.stats.skipped > 0) {
        WaitToast.destructive('未识别到可导入行，请检查预设档位');
      }
    } catch (_) {
      WaitToast.destructive('预览失败：文件格式无法解析');
    } finally {
      if (mounted) setState(() => _importing = null);
    }
  }

  Future<void> _executeImport() async {
    final content = _importContent;
    if (content == null || _importing != null) return;
    final preview = _importPreview;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认导入'),
        content: Text(
          '将导入 ${preview?.stats.success ?? 0} 条任务'
          '（跳过 ${preview?.stats.skipped ?? 0} 行）。'
          '项目不存在会自动创建。确定继续？',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('导入')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _importing = 'execute');
    try {
      final stats = await ref
          .read(orbitBridgeProvider)
          .csvImportExecute(content, _importPreset);
      invalidateBusinessCaches(ref);
      setState(() {
        _importResult = stats;
        _importPreview = null;
      });
      final parts = ['成功 ${stats.success} 条'];
      if (stats.skipped > 0) parts.add('跳过 ${stats.skipped} 行');
      if (stats.failed > 0) parts.add('失败 ${stats.failed} 条');
      if (stats.failed > 0) {
        WaitToast.destructive('导入完成：${parts.join("，")}');
      } else {
        WaitToast.success('导入完成：${parts.join("，")}');
      }
    } catch (_) {
      WaitToast.destructive('导入失败');
    } finally {
      if (mounted) setState(() => _importing = null);
    }
  }

  /// 立即同步：cloudSyncNow → 结果 toast；完成后刷新配置（上次同步时间）
  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final result =
          await ref.read(orbitBridgeProvider).cloudSyncNow(origin: 'manual');
      ref.invalidate(syncConfigProvider);
      // 同步结果经返回值直达（ADR 0003）：拉取到数据时失效业务缓存，
      // 原行为由 BootGate 的 syncFinished 订阅承担，流移除后在此兜住
      if (result.pulledModules > 0) invalidateBusinessCaches(ref);
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

  /// 设置回收站保留档位（7/30/90/永久；本地偏好不同步）
  Future<void> _pickTrashRetention() async {
    final bridge = ref.read(orbitBridgeProvider);
    final current = ref.read(trashMetaProvider).value?.retentionDays ?? 30;
    await showSelectBottomSheet<int>(
      context,
      title: '回收站保留时间',
      items: const [
        SelectItem(value: 7, label: '7 天'),
        SelectItem(value: 30, label: '30 天'),
        SelectItem(value: 90, label: '90 天'),
        SelectItem(value: 0, label: '永久'),
      ],
      current: current,
      onSelect: (days) async {
        if (days == current) return;
        try {
          await bridge.trashSetRetentionDays(days);
          ref.invalidate(trashMetaProvider);
          WaitToast.success(days == 0 ? '回收站已设为永久保留' : '保留时间已设为 $days 天');
        } catch (_) {
          WaitToast.destructive('保存失败');
        }
      },
    );
  }

  /// 生物识别状态探测（build 期一次；开关翻转后手动 setState 刷新）
  Future<void> _loadBioState() async {
    final service = ref.read(biometricServiceProvider);
    final available = await service.isAvailable();
    if (!mounted) return;
    if (!available) {
      setState(() => _bioAvailable = false);
      return;
    }
    final enabled = await service.isEnabled();
    if (mounted) {
      setState(() {
        _bioAvailable = true;
        _bioEnabled = enabled;
      });
    }
  }

  /// 主密码确认弹窗（生物识别开关两向共用；返回输入的密码或 null 取消）
  Future<String?> _askPassword(String title, String hint) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(labelText: '主密码', hintText: hint),
          onSubmitted: (_) => Navigator.pop(ctx, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  /// 开启生物识别：密码确认（Rust 验证拿 db_key_hex）→ 指纹闸门 → 落键
  ///
  /// 密码错误/指纹取消均中断，不落任何键；成功 toast 提示。
  Future<void> _bioEnable() async {
    if (_bioBusy) return;
    final password = await _askPassword('开启指纹解锁', '请输入主密码确认');
    if (password == null || password.isEmpty) return;
    setState(() => _bioBusy = true);
    try {
      final bridge = ref.read(orbitBridgeProvider);
      // 先验证密码再解锁取 key：解锁本身即可校验密码，错误即中断
      final dbKeyHex = await bridge.masterAuthUnlock(password);
      final service = ref.read(biometricServiceProvider);
      final ok = await service.enable(dbKeyHex);
      if (!mounted) return;
      if (ok) {
        setState(() => _bioEnabled = true);
        WaitToast.success('已开启指纹解锁');
      }
      // ok=false：用户取消指纹，静默返回（开关不翻转）
    } catch (e) {
      if (mounted) WaitToast.destructive(_bioErrMsg(e));
    } finally {
      if (mounted) setState(() => _bioBusy = false);
    }
  }

  /// 关闭生物识别：密码确认（Rust biometricDisable 验证）→ 删三键
  Future<void> _bioDisable() async {
    if (_bioBusy) return;
    final password = await _askPassword('关闭指纹解锁', '请输入主密码确认');
    if (password == null || password.isEmpty) return;
    setState(() => _bioBusy = true);
    try {
      await ref.read(biometricServiceProvider).disable(password);
      if (!mounted) return;
      setState(() => _bioEnabled = false);
      WaitToast.success('已关闭指纹解锁');
    } catch (e) {
      if (mounted) WaitToast.destructive(_bioErrMsg(e));
    } finally {
      if (mounted) setState(() => _bioBusy = false);
    }
  }

  /// 桥错误 → 用户文案（与 UnlockPage.errMsg 同口径）
  static String _bioErrMsg(Object e) {
    var msg = e.toString();
    msg = msg.replaceFirst(RegExp(r'^Exception:\s*'), '');
    msg = msg.replaceAll(RegExp(r'^\[[^\]]*\]\s*'), '');
    return msg.isEmpty ? '操作失败' : msg;
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
                      // 云同步设置入口（未配置/已配置均可进入，移动端可本机完成配置）
                      InkWell(
                        borderRadius: AppShapes.medium,
                        onTap: () => context.push('/settings/sync'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space8),
                          child: Row(
                            children: [
                              Text(
                                '云同步设置',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: OrbitAccents.themeAccent,
                                ),
                              ),
                              const Spacer(),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: AppDimens.iconSizeMd,
                                color: colors.secondaryText,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppDimens.space4),
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
                // 二、回收站卡（保留时间档位 + 回收站入口）
                SectionCard(
                  title: '回收站',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '删除的任务进入回收站，超过保留时间后自动清除。',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                      ),
                      const SizedBox(height: AppDimens.space4),
                      Text(
                        '保留时间为本机设置，不随云同步。',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: AppDimens.space4),
                      InkWell(
                        borderRadius: AppShapes.medium,
                        onTap: _pickTrashRetention,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space8),
                          child: Row(
                            children: [
                              Text(
                                '保留时间',
                                style: TextStyle(
                                    fontSize: 14, color: colors.bodyText),
                              ),
                              const Spacer(),
                              Text(
                                _trashRetentionLabel(
                                    ref.watch(trashMetaProvider).value?.retentionDays),
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
                      const SizedBox(height: AppDimens.space4),
                      InkWell(
                        borderRadius: AppShapes.medium,
                        onTap: () => context.push('/todo/trash'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space8),
                          child: Row(
                            children: [
                              Text(
                                '查看回收站',
                                style: TextStyle(
                                    fontSize: 14, color: colors.bodyText),
                              ),
                              const Spacer(),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: AppDimens.iconSizeMd,
                                color: colors.secondaryText,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.space12),
                // 三、安全卡：生物识别开关（无指纹硬件回退只读提示）
                SectionCard(
                  title: '安全',
                  child: _buildSecurityCard(context),
                ),
                const SizedBox(height: AppDimens.space12),
                // 数据导出卡（07 报告 #15）：明文 JSON/CSV，保存到应用文档目录
                SectionCard(
                  title: '数据导出（明文）',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '将待办数据导出为开放格式（未加密明文，请妥善保管）：'
                        'JSON 为 8 张业务表结构化全量；CSV 为任务主视图，'
                        'Excel 可直接打开。文件保存到应用文档目录。',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                      ),
                      const SizedBox(height: AppDimens.space12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _exporting != null ? null : () => _exportData('json'),
                              icon: _exporting == 'json'
                                  ? SizedBox(
                                      width: AppDimens.iconSizeSm,
                                      height: AppDimens.iconSizeSm,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: colors.secondaryText),
                                    )
                                  : const Icon(Icons.data_object_rounded, size: AppDimens.iconSizeSm),
                              label: const Text('导出 JSON'),
                            ),
                          ),
                          const SizedBox(width: AppDimens.space8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _exporting != null ? null : () => _exportData('csv'),
                              icon: _exporting == 'csv'
                                  ? SizedBox(
                                      width: AppDimens.iconSizeSm,
                                      height: AppDimens.iconSizeSm,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: colors.secondaryText),
                                    )
                                  : const Icon(Icons.table_view_rounded, size: AppDimens.iconSizeSm),
                              label: const Text('导出 CSV'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.space12),
                // 数据库维护卡（性能批次）：一键 WAL checkpoint / 附件 GC /
                // 查询统计 / VACUUM，量化结果就地展示
                SectionCard(
                  title: '数据库维护',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '一键优化本地数据库：回收 WAL 日志与磁盘碎片、清理无引用'
                        '附件文件、更新查询统计（列表/搜索提速）。不改动任何'
                        '数据与同步状态，建议偶发卡顿时手动执行。',
                        style: TextStyle(fontSize: 12, color: colors.secondaryText),
                      ),
                      const SizedBox(height: AppDimens.space12),
                      if (_maintenanceResult != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppDimens.space12),
                          child: Text(
                            '回收碎片页 ${_maintenanceResult!.pagesReclaimed} ·'
                            ' 附件清理 ${_maintenanceResult!.attachmentsCleaned} ·'
                            ' WAL 残留 ${_maintenanceResult!.walBytesAfterCheckpoint} B',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.secondaryText,
                            ),
                          ),
                        ),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _maintaining ? null : _runMaintenance,
                          icon: _maintaining
                              ? SizedBox(
                                  width: AppDimens.iconSizeSm,
                                  height: AppDimens.iconSizeSm,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: colors.secondaryText,
                                  ),
                                )
                              : const Icon(Icons.build_circle_outlined,
                                  size: AppDimens.iconSizeSm),
                          label: const Text('立即维护'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.space12),
                // CSV 导入卡（迁移路径）：与其他应用迁入任务
                SectionCard(
                  title: '导入 CSV（迁移）',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '从其他应用迁入任务：支持 Orbit 导出格式、Todoist 与'
                        ' TickTick 模板。导入前先预览；项目不存在会自动创建。',
                        style: TextStyle(fontSize: 12, color: colors.secondaryText),
                      ),
                      const SizedBox(height: AppDimens.space12),
                      // 预设档位选择
                      Wrap(
                        spacing: AppDimens.space8,
                        runSpacing: AppDimens.space8,
                        children: [
                          for (final entry in _importPresets.entries)
                            ChoiceChip(
                              label: Text(entry.value),
                              selected: _importPreset == entry.key,
                              onSelected: _importing != null
                                  ? null
                                  : (_) => setState(() {
                                        _importPreset = entry.key;
                                        _importPreview = null;
                                        _importResult = null;
                                      }),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppDimens.space12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _importing != null ? null : _pickImportFile,
                              icon: const Icon(Icons.upload_file_rounded,
                                  size: AppDimens.iconSizeSm),
                              label: Text(
                                _importFileName ?? '选择文件',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppDimens.space8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _importContent == null || _importing != null
                                  ? null
                                  : _previewImport,
                              icon: _importing == 'preview'
                                  ? SizedBox(
                                      width: AppDimens.iconSizeSm,
                                      height: AppDimens.iconSizeSm,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: colors.secondaryText,
                                      ),
                                    )
                                  : const Icon(Icons.visibility_rounded,
                                      size: AppDimens.iconSizeSm),
                              label: const Text('预览'),
                            ),
                          ),
                        ],
                      ),
                      // 执行按钮：预览有待导入行时出现
                      if (_importPreview != null && _importPreview!.stats.success > 0) ...[
                        const SizedBox(height: AppDimens.space8),
                        FilledButton.icon(
                          onPressed: _importing != null ? null : _executeImport,
                          icon: _importing == 'execute'
                              ? SizedBox(
                                  width: AppDimens.iconSizeSm,
                                  height: AppDimens.iconSizeSm,
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.download_rounded,
                                  size: AppDimens.iconSizeSm),
                          label: Text(
                              '导入 ${_importPreview!.stats.success} 条任务'),
                        ),
                      ],
                      // 预览结果
                      if (_importPreview != null) ...[
                        const SizedBox(height: AppDimens.space8),
                        Text(
                          '待导入 ${_importPreview!.stats.success} 条 · '
                          '跳过 ${_importPreview!.stats.skipped} 行',
                          style: TextStyle(
                              fontSize: 12, color: colors.secondaryText),
                        ),
                        for (final row in _importPreview!.rows.take(5))
                          Padding(
                            padding: const EdgeInsets.only(top: AppDimens.space4),
                            child: Text(
                              row.skipReason != null
                                  ? '· ${row.title.isEmpty ? "（空行）" : row.title} — 跳过：${row.skipReason}'
                                  : '· ${row.title}'
                                      '${row.projectTitle != null ? " → ${row.projectTitle}" : ""}'
                                      '${row.done ? "（已完成）" : ""}',
                              style: TextStyle(
                                  fontSize: 12, color: colors.secondaryText),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      // 执行结果
                      if (_importResult != null) ...[
                        const SizedBox(height: AppDimens.space8),
                        Text(
                          '导入完成：成功 ${_importResult!.success} 条'
                          '${_importResult!.skipped > 0 ? " · 跳过 ${_importResult!.skipped} 行" : ""}'
                          '${_importResult!.failed > 0 ? " · 失败 ${_importResult!.failed} 条" : ""}',
                          style: TextStyle(fontSize: 12, color: colors.secondaryText),
                        ),
                      ],
                    ],
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
  /// 安全卡内容：指纹硬件可用 → 指纹解锁开关；否则只读提示
  ///（探测中空白占位避免闪烁；开关翻转动画期 _bioBusy 防重复触发）
  Widget _buildSecurityCard(BuildContext context) {
    final colors = AppColors.ofContext(context);
    if (_bioAvailable == null) {
      return const SizedBox(height: 20);
    }
    if (_bioAvailable != true) {
      return Text(
        '本机未检测到指纹硬件，无法开启指纹解锁；主密码相关操作请在桌面端完成。',
        style: TextStyle(fontSize: 13, color: colors.secondaryText),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '指纹解锁',
                style: TextStyle(fontSize: 14, color: colors.bodyText),
              ),
            ),
            Switch(
              value: _bioEnabled == true,
              onChanged: (_bioBusy || _bioEnabled == null)
                  ? null
                  : (v) => v ? _bioEnable() : _bioDisable(),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.space4),
        Text(
          _bioEnabled == true
              ? '开启后可在解锁页用指纹代替主密码（密钥链存于系统安全存储，不离开本机）。'
              : '用指纹代替主密码解锁加密库；密钥链存于系统安全存储，不参与云同步。主密码修改/迁移仍请在桌面端完成。',
          style: TextStyle(fontSize: 12, color: colors.secondaryText),
        ),
      ],
    );
  }
}

/// 回收站保留档位文案（0 = 永久；缺省 30）
String _trashRetentionLabel(int? days) {  if (days == null || days == 30) return '30 天';
  return days == 0 ? '永久' : '$days 天';
}

/// 引擎摘要（脱敏不显示凭据）：webdav → endpoint host；s3 → bucket
String engineSummary(SyncConfigView config) {  if (config.engine == 's3') {
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
