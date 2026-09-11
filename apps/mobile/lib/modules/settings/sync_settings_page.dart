import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/wait_toast.dart';
import '../todo/providers/todo_providers.dart';

/// 云同步配置页 /settings/sync（设置页「云同步设置」入口）
///
/// 对齐桌面端 SyncSection 的两张核心卡（v1 移动端口径）：
/// 1. 连接卡：WebDAV/S3 引擎 + endpoint/bucket/region/凭据/远端路径 +
///    定时同步开关与间隔 + 修改后立即同步 + 请求超时 + 跳过 TLS 验证 +
///    测试连接/保存/断开（确认弹窗，断开仅清本机配置不动数据）；
/// 2. 同步密码卡（E2E）：未设置 → 设置并解锁；已设置 → 解锁/锁定。
///
/// 移动端差异（crates/orbit-flutter/src/api/sync.rs 模块注释）：
/// - 无系统钥匙串：同步密码仅进程内缓存，重启后需重新解锁；
/// - 无后台调度器：定时同步/修改后立即同步仅存档到配置，手动触发为准；
/// - 无 sync-config-changed 事件流：保存后本页自行重读刷新。
class SyncSettingsPage extends ConsumerStatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  ConsumerState<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends ConsumerState<SyncSettingsPage> {
  final _scrollController = ScrollController();

  // 连接卡表单状态（对齐桌面 ConnectionCard 字段面）
  String _engine = 'webdav';
  late final _endpointController = TextEditingController();
  late final _bucketController = TextEditingController();
  late final _regionController = TextEditingController();
  late final _usernameController = TextEditingController();
  late final _passwordController = TextEditingController();
  late final _basePathController = TextEditingController(text: 'orbit');
  int _intervalMin = 60;
  bool _autoEnabled = true;
  bool _onChange = false;
  bool _skipTls = false;
  late final _timeoutController = TextEditingController(text: '30');

  SyncConfigView? _config;
  bool _loading = true;
  bool _busy = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _endpointController.dispose();
    _bucketController.dispose();
    _regionController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _basePathController.dispose();
    _timeoutController.dispose();
    super.dispose();
  }

  /// 回读激活配置填表单（密码不回显：留空 = 沿用已存凭据）；
  /// 断开后（配置为 null）连同清空表单控制器，回到全新配置态
  Future<void> _load() async {
    try {
      final c = await ref.read(orbitBridgeProvider).syncConfigGet();
      if (!mounted) return;
      setState(() {
        _config = c;
        _loading = false;
        if (c != null) {
          _engine = c.engine == 's3' ? 's3' : 'webdav';
          _endpointController.text = c.endpoint;
          _bucketController.text = c.bucket;
          _regionController.text = c.region;
          _usernameController.text = c.username;
          _basePathController.text = c.basePath.isEmpty ? 'orbit' : c.basePath;
          _intervalMin = c.intervalMinutes;
          _autoEnabled = c.autoSyncEnabled;
          _onChange = c.syncOnChange;
          _skipTls = c.skipTlsVerify;
          _timeoutController.text =
              c.timeoutSeconds <= 0 ? '30' : '${c.timeoutSeconds}';
        } else {
          _engine = 'webdav';
          _endpointController.clear();
          _bucketController.clear();
          _regionController.clear();
          _usernameController.clear();
          _passwordController.clear();
          _basePathController.text = 'orbit';
          _intervalMin = 60;
          _autoEnabled = true;
          _onChange = false;
          _skipTls = false;
          _timeoutController.text = '30';
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 错误消息转用户文案（去 [tag] 前缀，对齐桌面 errMsg）
  String _errMsg(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  /// 保存载荷（snake_case 键，同桌面 buildInput 语义：密码留空沿用已存凭据）
  Map<String, Object?> _buildInput() => {
        'engine': _engine,
        'endpoint': _endpointController.text.trim(),
        'bucket': _engine == 's3' ? _bucketController.text.trim() : '',
        'region': _engine == 's3' ? _regionController.text.trim() : '',
        'username': _usernameController.text,
        'password': _passwordController.text,
        'base_path': _basePathController.text.trim().isEmpty
            ? 'orbit'
            : _basePathController.text.trim(),
        'interval_minutes': _autoEnabled ? _intervalMin : 0,
        'auto_sync_enabled': _autoEnabled,
        'sync_on_change': _onChange,
        'skip_tls_verify': _skipTls,
        'timeout_seconds': int.tryParse(_timeoutController.text) ?? 30,
      };

  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      final n =
          await ref.read(orbitBridgeProvider).syncTestConnection(_buildInput());
      WaitToast.success('连接成功（根目录 $n 个条目）');
    } catch (e) {
      WaitToast.destructive('连接失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).syncConfigSave(_buildInput());
      WaitToast.success('同步配置已保存');
      await _load();
      ref.invalidate(syncConfigProvider);
    } catch (e) {
      WaitToast.destructive(_errMsg(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).syncDisconnect();
      WaitToast.success('已断开云同步（本地数据与云端文件均未删除）');
      await _load();
      ref.invalidate(syncConfigProvider);
    } catch (e) {
      WaitToast.destructive(_errMsg(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);

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
                SectionCard(
                  title: '云同步连接',
                  subtitle: _config == null ? null : '已配置 · ${_engineLabel(_engine)}',
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(AppDimens.space16),
                          child: Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: OrbitAccents.themeAccent,
                              ),
                            ),
                          ),
                        )
                      : _connectionForm(colors),
                ),
                const SizedBox(height: AppDimens.space12),
                const _SyncCryptoCard(),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: '云同步配置',
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
            ),
          ),
        ],
      ),
    );
  }

  String _engineLabel(String engine) =>
      engine == 's3' ? 'S3' : 'WebDAV';

  Widget _connectionForm(AppColorSet colors) {
    final isS3 = _engine == 's3';
    final endpointEmpty = _endpointController.text.trim().isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 引擎选择（同桌面下拉，两档）
        DropdownButtonFormField<String>(
          initialValue: _engine,
          style: TextStyle(fontSize: 15, color: colors.bodyText),
          dropdownColor: colors.popup,
          decoration: const InputDecoration(labelText: '引擎'),
          items: const [
            DropdownMenuItem(value: 'webdav', child: Text('WebDAV')),
            DropdownMenuItem(value: 's3', child: Text('S3 兼容存储')),
          ],
          onChanged: (v) => setState(() => _engine = v ?? 'webdav'),
        ),
        const SizedBox(height: AppDimens.space12),
        TextFormField(
          controller: _endpointController,
          keyboardType: TextInputType.url,
          style: TextStyle(fontSize: 15, color: colors.bodyText),
          decoration: InputDecoration(
            labelText: isS3 ? 'Endpoint' : '服务器地址',
            hintText: isS3 ? 'https://s3.example.com' : 'https://dav.example.com/dav',
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (isS3) ...[
          const SizedBox(height: AppDimens.space12),
          TextFormField(
            controller: _bucketController,
            style: TextStyle(fontSize: 15, color: colors.bodyText),
            decoration: const InputDecoration(labelText: '存储桶'),
          ),
          const SizedBox(height: AppDimens.space12),
          TextFormField(
            controller: _regionController,
            style: TextStyle(fontSize: 15, color: colors.bodyText),
            decoration: const InputDecoration(
              labelText: 'Region',
              hintText: 'us-east-1',
            ),
          ),
        ],
        const SizedBox(height: AppDimens.space12),
        TextFormField(
          controller: _usernameController,
          style: TextStyle(fontSize: 15, color: colors.bodyText),
          decoration:
              InputDecoration(labelText: isS3 ? 'Access Key' : '用户名'),
        ),
        const SizedBox(height: AppDimens.space12),
        TextFormField(
          controller: _passwordController,
          obscureText: true,
          style: TextStyle(fontSize: 15, color: colors.bodyText),
          decoration: InputDecoration(
            labelText: isS3 ? 'Secret Key' : '密码',
            hintText: _config?.passwordSet == true ? '已保存（修改请重新输入）' : null,
          ),
        ),
        const SizedBox(height: AppDimens.space12),
        TextFormField(
          controller: _basePathController,
          style: TextStyle(fontSize: 15, color: colors.bodyText),
          decoration: const InputDecoration(labelText: '远端路径'),
        ),
        const SizedBox(height: AppDimens.space12),
        // 定时同步：开关 + 间隔（移动端无调度器，仅存档；桌面端生效）
        Row(
          children: [
            Switch(
              value: _autoEnabled,
              onChanged: (v) => setState(() => _autoEnabled = v),
            ),
            const SizedBox(width: AppDimens.space8),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _intervalMin,
                style: TextStyle(fontSize: 14, color: colors.bodyText),
                dropdownColor: colors.popup,
                decoration: const InputDecoration(labelText: '定时同步'),
                items: const [
                  DropdownMenuItem(value: 10, child: Text('每 10 分钟')),
                  DropdownMenuItem(value: 30, child: Text('每 30 分钟')),
                  DropdownMenuItem(value: 60, child: Text('每 60 分钟')),
                  DropdownMenuItem(value: 120, child: Text('每 2 小时')),
                  DropdownMenuItem(value: 360, child: Text('每 6 小时')),
                ],
                // 开关关闭时间隔不可选（onChanged null = 交互禁用）
                onChanged:
                    _autoEnabled ? (v) => setState(() => _intervalMin = v ?? 60) : null,
              ),
            ),
          ],
        ),
        if (_autoEnabled)
          Padding(
            padding: const EdgeInsets.only(top: AppDimens.space4),
            child: Text(
              '移动端不驻后台调度，该间隔由桌面端执行；此处配置全端共享。',
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            ),
          ),
        const SizedBox(height: AppDimens.space12),
        _switchRow(
          colors: colors,
          label: '修改后立即同步',
          value: _onChange,
          onChanged: (v) => setState(() => _onChange = v),
          description: _onChange ? '编辑/删除任务后自动推送（桌面端生效）' : '仅按定时或手动同步',
        ),
        const SizedBox(height: AppDimens.space12),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _timeoutController,
                keyboardType: TextInputType.number,
                style: TextStyle(fontSize: 15, color: colors.bodyText),
                decoration: const InputDecoration(
                  labelText: '请求超时（秒，5–600）',
                  counterText: '',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.space12),
        _switchRow(
          colors: colors,
          label: '跳过 TLS 验证',
          value: _skipTls,
          onChanged: (v) => setState(() => _skipTls = v),
          description: _skipTls ? '自签名证书场景专用，存在中间人风险' : '校验服务器证书（推荐）',
          warning: _skipTls,
        ),
        const SizedBox(height: AppDimens.space4),
        Text(
          '数据以 AES-256-GCM 端到端加密后上传，服务商无法读取内容。',
          style: TextStyle(fontSize: 12, color: colors.secondaryText),
        ),
        const SizedBox(height: AppDimens.space12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_config != null)
              TextButton(
                onPressed: _busy ? null : () => _confirmDisconnect(context),
                child: Text(
                  '断开',
                  style: TextStyle(color: colors.destructive),
                ),
              ),
            const SizedBox(width: AppDimens.space8),
            OutlinedButton(
              onPressed:
                  (_testing || _busy || endpointEmpty) ? null : _testConnection,
              child: _testing
                  ? const SizedBox(
                      width: AppDimens.iconSizeSm,
                      height: AppDimens.iconSizeSm,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('测试连接'),
            ),
            const SizedBox(width: AppDimens.space8),
            FilledButton(
              onPressed: (_busy || endpointEmpty) ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: AppDimens.iconSizeSm,
                      height: AppDimens.iconSizeSm,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('保存'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _switchRow({
    required AppColorSet colors,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    required String description,
    bool warning = false,
  }) {
    return Row(
      children: [
        Switch(value: value, onChanged: onChanged),
        const SizedBox(width: AppDimens.space8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 14, color: colors.bodyText),
              ),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: warning ? colors.warning : colors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 断开确认：断开仅清除本机连接配置，不删本地数据与云端文件
  Future<void> _confirmDisconnect(BuildContext context) async {
    final destructive = AppColors.ofContext(context).destructive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('断开云同步？'),
        content: const Text(
          '将清除本机保存的连接配置与凭据；本地数据与云端文件均不会删除，之后可随时重新配置。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('断开', style: TextStyle(color: destructive)),
          ),
        ],
      ),
    );
    if (confirmed == true) await _disconnect();
  }
}

/// 同步密码卡（E2E 加密密钥管理，对齐桌面 SyncPasswordCard 核心面）
///
/// 移动端口径：设置（init）/解锁（unlock）/锁定（lock）+
/// 密钥包导入恢复（P1-20：换机/key_mismatch 场景——桌面导出的
/// .orbitkey JSON 导入后即持有 Data Key，配合密码解锁可解云端密文；
/// 修改密码与密钥包导出仍为桌面专属）。
class _SyncCryptoCard extends ConsumerStatefulWidget {
  const _SyncCryptoCard();

  @override
  ConsumerState<_SyncCryptoCard> createState() => _SyncCryptoCardState();
}

class _SyncCryptoCardState extends ConsumerState<_SyncCryptoCard> {
  SyncCryptoStatus? _status;
  bool _busy = false;

  late final _pwController = TextEditingController();
  late final _confirmController = TextEditingController();
  late final _unlockController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _pwController.dispose();
    _confirmController.dispose();
    _unlockController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await ref.read(orbitBridgeProvider).syncCryptoStatus();
      if (mounted) setState(() => _status = s);
    } catch (_) {
      // 状态查询失败保持原状（桌面同语义静默）
    }
  }

  String _errMsg(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  Future<void> _setup() async {
    final pw = _pwController.text;
    if (pw.length < 6) {
      WaitToast.destructive('同步密码至少 6 位');
      return;
    }
    if (pw != _confirmController.text) {
      WaitToast.destructive('两次输入的密码不一致');
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).syncCryptoInit(pw, remember: true);
      WaitToast.success('同步密码已设置，端到端加密已就绪');
      _pwController.clear();
      _confirmController.clear();
      await _refresh();
    } catch (e) {
      WaitToast.destructive(_errMsg(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(orbitBridgeProvider)
          .syncCryptoUnlock(_unlockController.text, remember: true);
      WaitToast.success('已解锁');
      _unlockController.clear();
      await _refresh();
    } catch (e) {
      WaitToast.destructive(
          e.toString().contains('wrong_password') ? '同步密码错误' : _errMsg(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lock() async {
    try {
      await ref.read(orbitBridgeProvider).syncCryptoLock();
    } catch (_) {
      // 锁定失败静默（桌面同语义）
    }
    await _refresh();
  }

  /// 导入密钥包恢复（P1-20）：桌面「导出密钥包」产出的 JSON 文件
  /// （salt + encrypted_data_key + data_key_nonce + iterations），
  /// 配合当初设置的同步密码导入本机——换机/key_mismatch 后的恢复路径。
  Future<void> _importBundle() async {
    if (_busy) return;
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['json', 'orbitkey', 'txt'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    // FilePicker 弹系统选择器是 async gap，回来时页面可能已销毁
    if (!mounted) return;
    setState(() => _busy = true);
    final pwController = TextEditingController();
    try {
      // 两段式：先读文件校验结构，再问密码（避免密码输完才发现文件坏了）
      final raw = await File(path).readAsString();
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic> ||
          j['salt'] == null ||
          j['encrypted_data_key'] == null) {
        WaitToast.destructive('不是有效的密钥包文件（缺少 salt / encrypted_data_key 字段）');
        return;
      }
      final bundle = SyncCryptoBundle.fromJson(j);
      // readAsString 是 async gap，showDialog 前页面可能已销毁
      if (!mounted) return;
      final pw = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('输入该密钥包的同步密码'),
          content: TextField(
            controller: pwController,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: '同步密码', hintText: '导出密钥包时使用的密码'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, pwController.text),
                child: const Text('导入')),
          ],
        ),
      );
      if (pw == null || pw.isEmpty) return;
      await ref
          .read(orbitBridgeProvider)
          .syncCryptoImportBundle(bundle, pw, force: true);
      WaitToast.success('密钥包已导入，请用同一密码解锁后同步');
      await _refresh();
    } catch (e) {
      WaitToast.destructive('导入失败：${_errMsg(e)}');
    } finally {
      pwController.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final status = _status;

    return SectionCard(
      title: '同步密码（端到端加密）',
      child: status == null
          ? Text('加载中…',
              style: TextStyle(fontSize: 12, color: colors.secondaryText))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!status.hasPassword) ...[
                  Text(
                    '未设置。设置后所有上传数据以该密码端到端加密；同一密码在任何设备派生同一把密钥，跨设备只需输入相同密码。',
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                  const SizedBox(height: AppDimens.space12),
                  TextFormField(
                    controller: _pwController,
                    obscureText: true,
                    style: TextStyle(fontSize: 15, color: colors.bodyText),
                    decoration: const InputDecoration(labelText: '同步密码'),
                  ),
                  const SizedBox(height: AppDimens.space12),
                  TextFormField(
                    controller: _confirmController,
                    obscureText: true,
                    style: TextStyle(fontSize: 15, color: colors.bodyText),
                    decoration: const InputDecoration(labelText: '确认密码'),
                  ),
                  const SizedBox(height: AppDimens.space12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _setup,
                      child: _busy
                          ? const SizedBox(
                              width: AppDimens.iconSizeSm,
                              height: AppDimens.iconSizeSm,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('设置并解锁'),
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Icon(
                        status.isUnlocked
                            ? Icons.verified_user_rounded
                            : Icons.lock_rounded,
                        size: AppDimens.iconSizeMd,
                        color: status.isUnlocked
                            ? colors.success
                            : colors.secondaryText,
                      ),
                      const SizedBox(width: AppDimens.space8),
                      Text(
                        status.isUnlocked ? '已解锁' : '已锁定',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: colors.bodyText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppDimens.space4),
                  Text(
                    status.isUnlocked
                        ? 'Data Key 在内存中，可执行同步与备份'
                        : '输入同步密码解锁后才能同步',
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                  const SizedBox(height: AppDimens.space12),
                  if (!status.isUnlocked) ...[
                    TextFormField(
                      controller: _unlockController,
                      obscureText: true,
                      style: TextStyle(fontSize: 15, color: colors.bodyText),
                      decoration: const InputDecoration(labelText: '同步密码'),
                    ),
                    const SizedBox(height: AppDimens.space12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy ? null : _unlock,
                        child: _busy
                            ? const SizedBox(
                                width: AppDimens.iconSizeSm,
                                height: AppDimens.iconSizeSm,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('解锁'),
                      ),
                    ),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _lock,
                        child: const Text('锁定'),
                      ),
                    ),
                  const SizedBox(height: AppDimens.space8),
                  Text(
                    '移动端不缓存同步密码，应用重启后需重新输入解锁。',
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                  const SizedBox(height: AppDimens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _importBundle,
                      child: const Text('导入密钥包恢复（换机 / 密钥不匹配）'),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
