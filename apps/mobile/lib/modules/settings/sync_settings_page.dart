import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../todo/providers/todo_providers.dart';
import '../../core/theme/icon_map.dart';

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
/// - 无后台调度器：**定时同步**仅存档到配置（间隔由桌面端执行）；
///   **修改后立即同步**已在移动端生效（写路径 db-change → 5s 防抖
///   `cloudSyncPushOnly`，见 services/sync_on_change_scheduler.dart；
///   沿用桌面口径，需「定时同步」总开关同时开启）；
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
                    OrbitPageHeader.rowHeight +
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
                const SizedBox(height: AppDimens.space12),
                const _SyncHistoryCard(),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '云同步配置',
            ),
          ),
        ],
      ),
    );
  }

  String _engineLabel(String engine) =>
      engine == 's3' ? 'S3' : 'WebDAV';

  /// 定时同步间隔档位（桌面同款五档；存量配置的非档位值按分钟/小时回显）
  static const _intervalChoices = <int, String>{
    10: '每 10 分钟',
    30: '每 30 分钟',
    60: '每 60 分钟',
    120: '每 2 小时',
    360: '每 6 小时',
  };

  String _intervalLabel(int minutes) =>
      _intervalChoices[minutes] ??
      (minutes % 60 == 0 ? '每 ${minutes ~/ 60} 小时' : '每 $minutes 分钟');

  /// 引擎选择抽屉（两档）
  Future<void> _pickEngine() => showSelectBottomSheet<String>(
        context,
        title: '同步引擎',
        items: const [
          SelectItem(value: 'webdav', label: 'WebDAV'),
          SelectItem(value: 's3', label: 'S3 兼容存储'),
        ],
        current: _engine,
        onSelect: (v) {
          if (mounted) setState(() => _engine = v);
        },
      );

  /// 定时同步间隔抽屉（开关关闭时行不可点）
  Future<void> _pickInterval() => showSelectBottomSheet<int>(
        context,
        title: '定时同步间隔',
        items: [
          for (final e in _intervalChoices.entries)
            SelectItem(value: e.key, label: e.value),
        ],
        current: _intervalMin,
        onSelect: (v) {
          if (mounted) setState(() => _intervalMin = v);
        },
      );

  /// 表单选择行：只读展示当前值 + 尾箭头，点行唤起底部抽屉
  /// （选择类交互统一底部抽屉，AGENTS.md 移动端约定；装饰沿用表单
  /// InputDecorator 口径，与相邻 TextFormField 视觉一致）。
  /// [onTap] 为 null 即禁用态（值文字降为次要色）。
  Widget _selectRow({
    required AppColorSet colors,
    required String label,
    required String value,
    required VoidCallback? onTap,
    double fontSize = 15,
  }) =>
      InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fontSize,
                    color:
                        onTap == null ? colors.secondaryText : colors.bodyText,
                  ),
                ),
              ),
              Icon(
                OrbitIcons.chevronRight,
                size: AppDimens.iconSizeSm + 2,
                color: colors.secondaryText,
              ),
            ],
          ),
        ),
      );

  Widget _connectionForm(AppColorSet colors) {
    final isS3 = _engine == 's3';
    final endpointEmpty = _endpointController.text.trim().isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 引擎选择（同桌面下拉，两档）——选择类交互走底部抽屉
        _selectRow(
          colors: colors,
          label: '引擎',
          value: _engineLabel(_engine),
          onTap: _pickEngine,
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
              // 开关关闭时间隔不可点（onTap null = 禁用态）
              child: _selectRow(
                colors: colors,
                label: '定时同步',
                value: _intervalLabel(_intervalMin),
                fontSize: 14,
                onTap: _autoEnabled ? _pickInterval : null,
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
          // 门控与桌面同口径：需「定时同步」总开关同时开启（见
          // sync_on_change_scheduler.dart 的 pushNow 门控链）
          description: !_onChange
              ? '仅按定时或手动同步'
              : _autoEnabled
                  ? '编辑后约 5 秒自动推送（需已解锁同步密码）'
                  : '编辑后约 5 秒自动推送（需开启上方「定时同步」总开关）',
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
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '断开云同步？',
      message: '将清除本机保存的连接配置与凭据；本地数据与云端文件均不会删除，之后可随时重新配置。',
      confirmLabel: '断开',
      destructive: true,
    );
    if (confirmed) await _disconnect();
  }
}

/// 同步密码卡（E2E 加密密钥管理，对齐桌面 SyncPasswordCard 核心面）
///
/// 移动端口径：设置（init）/解锁（unlock）/锁定（lock）+
/// 密钥包导入恢复（P1-20：换机/key_mismatch 场景——导出的
/// .orbitkey JSON 导入后即持有 Data Key，配合密码解锁可解云端密文）+
/// 修改密码（v2 下内部编排云端全量重传）+ 导出密钥包 + 清除本机会话缓存。
///
/// **密钥治理面**（docs/07 #55，对齐桌面 sync-recovery-page）：三条此前移动端不可达的
/// 路径——①「本机密钥方案」版本显示（`sync_crypto_meta_version`）；②v1 存量设备的
/// 「升级到 v2」迁移（同密码确定性派生 + 云端全量重传，探测到 v1 才显示入口）；
/// ③「以本机为准重置云端」（`cloud_sync_rekey`，危险操作走 destructive 二次确认）。
///
/// 与桌面的唯一残差：移动端无系统钥匙串，同步密码只在进程内缓存，
/// 应用重启后需重新输入（对应桌面「忘记此设备的同步密码缓存」的降级形态）。
class _SyncCryptoCard extends ConsumerStatefulWidget {
  const _SyncCryptoCard();

  @override
  ConsumerState<_SyncCryptoCard> createState() => _SyncCryptoCardState();
}

class _SyncCryptoCardState extends ConsumerState<_SyncCryptoCard> {
  SyncCryptoStatus? _status;
  bool _busy = false;

  /// 本机密钥方案版本（'v1' / 'v2'；未设置密码或探测失败为 null）
  String? _metaVersion;

  late final _pwController = TextEditingController();
  late final _confirmController = TextEditingController();
  late final _unlockController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
    // 对齐桌面启动时序：先尝试静默恢复会话，失败再走手动解锁（移动端通常
    // 恒为 false——无跨重启的持久凭据库）
    _restoreSessionSilently();
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
    await _loadMetaVersion();
  }

  /// 探测本机密钥方案版本：v1 存量设备才显示迁移入口。
  /// 探测失败静默——默认不显示入口，不阻塞主路径（与桌面同语义）
  Future<void> _loadMetaVersion() async {
    try {
      final v = await ref.read(orbitBridgeProvider).syncCryptoMetaVersion();
      if (mounted) setState(() => _metaVersion = v);
    } catch (_) {
      /* 探测失败不显示迁移入口 */
    }
  }

  /// 密钥方案版本展示文案
  String get _metaVersionLabel => switch (_metaVersion) {
        'v1' => 'v1（旧版随机密钥）',
        'v2' => 'v2（同密码跨设备同 Key）',
        _ => '未知',
      };

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

  /// 启动静默恢复会话（对齐桌面 sync_crypto_restore_session）
  ///
  /// 移动端无跨重启用持久凭据库，会话密码随 lock 一并清除，故本调用通常
  /// 恒为 false；保留接线是为了在未来的持久缓存落地后自动生效，不做 UI 承诺。
  Future<void> _restoreSessionSilently() async {
    try {
      await ref.read(orbitBridgeProvider).syncCryptoRestoreSession();
    } catch (_) {
      // 静默：恢复失败即回退手动解锁路径
    }
  }

  /// 修改同步密码（v2 下即换 Key 并重传云端；失败由 Rust 侧回滚）
  Future<void> _changePassword() async {
    if (_busy) return;
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('修改同步密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'v2 密钥方案下改密等于更换密钥，会把云端数据全量重传一次；'
                '其他设备在此期间请勿同步。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: oldCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '当前同步密码'),
              ),
              TextField(
                controller: newCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新同步密码'),
              ),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '确认新密码'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认修改'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      if (newCtrl.text.length < 6) {
        WaitToast.destructive('同步密码至少 6 位');
        return;
      }
      if (newCtrl.text != confirmCtrl.text) {
        WaitToast.destructive('两次输入的新密码不一致');
        return;
      }
      setState(() => _busy = true);
      await ref
          .read(orbitBridgeProvider)
          .syncCryptoChangePassword(oldCtrl.text, newCtrl.text);
      await ref.read(orbitBridgeProvider).syncCryptoUnlock(newCtrl.text);
      WaitToast.success('同步密码已修改，云端数据已用新密钥重传');
      await _refresh();
    } catch (e) {
      WaitToast.destructive('修改失败：${_errMsg(e)}');
    } finally {
      oldCtrl.dispose();
      newCtrl.dispose();
      confirmCtrl.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导出密钥包：写入应用文档目录 exports/，供换机或 key_mismatch 恢复
  Future<void> _exportBundle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final json = await ref.read(orbitBridgeProvider).syncCryptoExportBundle();
      final dir = await getApplicationDocumentsDirectory();
      final outDir = Directory('${dir.path}/exports');
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${outDir.path}/orbit-key-$stamp.orbitkey.json');
      await file.writeAsString(json);
      WaitToast.success('密钥包已导出（exports/${file.uri.pathSegments.last}）');
    } catch (e) {
      WaitToast.destructive('导出密钥包失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 忘记本机同步密码缓存（清会话缓存与引擎挂载；云端与 crypto meta 不动）
  Future<void> _forgetSession() async {
    if (_busy) return;
    final ok = await showConfirmBottomSheet(
      context,
      title: '清除本机同步密码缓存？',
      message: '仅清除本机内存中的会话密码与已解锁状态，云端数据与密钥不受影响；'
          '下次同步前需要重新输入同步密码。',
      confirmLabel: '清除',
    );
    if (!ok) return;
    try {
      await ref.read(orbitBridgeProvider).syncCryptoForgetSession();
      WaitToast.success('已清除本机会话缓存');
      await _refresh();
    } catch (e) {
      WaitToast.destructive('清除失败：${_errMsg(e)}');
    }
  }

  /// 升级密钥方案到 v2（仅 v1 存量设备显示入口）：
  /// 同密码确定性派生新 Key + 云端全量重传，期间其他设备不要同步
  Future<void> _upgradeV2() async {
    if (_busy) return;
    final ctrl = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('升级密钥方案到 v2'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '升级后同一同步密码在任何设备都派生同一把密钥，不再需要密钥包分发，'
                '可彻底避免「密钥不一致」。升级会立即用新密钥全量重传云端数据，'
                '期间请勿在其他设备同步。此操作不可撤销。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '当前同步密码'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认升级'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      setState(() => _busy = true);
      await ref.read(orbitBridgeProvider).syncCryptoUpgradeV2(ctrl.text);
      WaitToast.success('已升级 v2 并完成云端重传。其他设备输入相同密码即可同步');
      await _refresh();
    } catch (e) {
      WaitToast.destructive('升级失败：${_errMsg(e)}');
    } finally {
      ctrl.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 以本机为准重置云端（危险）：当前 Data Key 全量重加密**覆盖**云端。
  /// 本机没有的记录与附件会永久丢失（桌面 sync-recovery-page 的兜底路径）
  Future<void> _rekeyCloud() async {
    if (_busy) return;
    final ok = await showConfirmBottomSheet(
      context,
      title: '以本机为准重置云端',
      message: '将用当前设备的数据密钥重加密并覆盖云端全部数据：仅存于云端的记录与附件'
          '会永久丢失，其他设备需输入本机当前同步密码后重新同步。'
          '此操作不可撤销，请确认云端数据已无需保留。',
      confirmLabel: '确认重置云端',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      // 真桥返回 result_to_json 的 JSON 串（非对象），与桌面同源结构
      final raw = await ref.read(orbitBridgeProvider).cloudSyncRekey();
      final result =
          SyncResultJson.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      WaitToast.success(
        '云端已重置：${result.pushedModules} 个模块、'
        '${result.uploadedAttachments} 个附件已用本机密钥重传',
      );
      await _refresh();
    } catch (e) {
      WaitToast.destructive('重置失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                            ? OrbitIcons.shield
                            : OrbitIcons.lock,
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
                  const SizedBox(height: AppDimens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _exportBundle,
                      child: const Text('导出密钥包（备份到本机 exports/）'),
                    ),
                  ),
                  const SizedBox(height: AppDimens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _changePassword,
                      child: const Text('修改同步密码'),
                    ),
                  ),
                  const SizedBox(height: AppDimens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _forgetSession,
                      child: const Text('清除本机同步密码缓存'),
                    ),
                  ),
                  const SizedBox(height: AppDimens.space16),
                  // ── 密钥治理（docs/07 #55）：版本显示 + v1 迁移 + 重置云端 ──
                  Text(
                    '本机密钥方案：$_metaVersionLabel',
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                  // v1 存量设备才显示迁移入口（探测非 v1 时整条不出现）
                  if (_metaVersion == 'v1') ...[
                    const SizedBox(height: AppDimens.space8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _busy ? null : _upgradeV2,
                        child: const Text('升级密钥方案到 v2'),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppDimens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _rekeyCloud,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.destructive,
                        side: BorderSide(color: colors.destructive),
                      ),
                      child: const Text('以本机为准重置云端'),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// 同步历史卡（对齐桌面 SyncHistoryCard；P1-17 展示面）
///
/// 数据源 sync_history 表为只读聚合（不 emit 事件、不进同步白名单），
/// 故本卡不做 db-change 订阅，靠页面进入与手动刷新回读。
class _SyncHistoryCard extends ConsumerStatefulWidget {
  const _SyncHistoryCard();

  @override
  ConsumerState<_SyncHistoryCard> createState() => _SyncHistoryCardState();
}

class _SyncHistoryCardState extends ConsumerState<_SyncHistoryCard> {
  static const _scopes = <String, String>{
    'all': '全部',
    'incremental': '完整同步',
    'push_only': '仅推送',
    'pull_only': '先拉后推',
  };

  static const _typeLabels = <String, String>{
    'sync_now': '完整同步',
    'push_only': '仅推送',
    'pull_then_push': '先拉后推',
  };

  String _scope = 'all';
  List<SyncHistoryRow> _rows = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _errMsg(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await ref
          .read(orbitBridgeProvider)
          .cloudSyncHistory(scope: _scope, limit: 20);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      WaitToast.destructive('读取同步历史失败：${_errMsg(e)}');
    }
  }

  Future<void> _switchScope(String scope) async {
    if (_scope == scope) return;
    setState(() => _scope = scope);
    await _load();
  }

  String _when(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.month}月${d.day}日 ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);

    return SectionCard(
      title: '同步历史',
      subtitle: _loading ? null : '近 ${_rows.length} 次',
      trailing: TextButton(
        onPressed: _loading ? null : _load,
        child: const Text('刷新'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final e in _scopes.entries) ...[
                _chip(e.key, e.value),
                const SizedBox(width: AppDimens.space8),
              ],
            ],
          ),
          const SizedBox(height: AppDimens.space8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(AppDimens.space16),
              child: Center(
                child: SizedBox(
                  width: AppDimens.iconSizeLg,
                  height: AppDimens.iconSizeLg,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: OrbitAccents.themeAccent,
                  ),
                ),
              ),
            )
          else if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppDimens.space16),
              child: Center(
                child: Text(
                  '暂无同步记录；每次同步完成后会在这里留档。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: colors.secondaryText),
                ),
              ),
            )
          else
            for (final r in _rows) _row(colors, r),
        ],
      ),
    );
  }

  Widget _chip(String key, String label) {
    final colors = AppColors.ofContext(context);
    final selected = _scope == key;
    return GestureDetector(
      onTap: () => _switchScope(key),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space12,
          vertical: AppDimens.space6,
        ),
        decoration: BoxDecoration(
          color: selected
              ? OrbitAccents.themeAccent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: AppShapes.small,
          border: Border.all(
            color: selected ? OrbitAccents.themeAccent : colors.divider,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? OrbitAccents.themeAccent : colors.bodyText,
          ),
        ),
      ),
    );
  }

  Widget _row(AppColorSet colors, SyncHistoryRow r) {
    final ok = r.status == 'success';
    return Padding(
      padding: const EdgeInsets.only(top: AppDimens.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _typeLabels[r.syncType] ?? r.syncType,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: colors.bodyText,
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              Text(
                ok ? '成功' : r.status,
                style: TextStyle(
                  fontSize: 11,
                  color: ok ? colors.success : colors.destructive,
                ),
              ),
              const Spacer(),
              Text(
                _when(r.startedAt),
                style: TextStyle(fontSize: 11, color: colors.secondaryText),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space2),
          Text(
            '拉取 ${r.pulledCount} · 推送 ${r.pushedCount} · '
            '冲突 ${r.conflictCount} · 耗时 ${(r.elapsedMs / 1000).toStringAsFixed(1)}s',
            style: TextStyle(fontSize: 11, color: colors.secondaryText),
          ),
          if (r.errorMessage != null && r.errorMessage!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppDimens.space2),
              child: Text(
                r.errorMessage!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.destructive),
              ),
            ),
        ],
      ),
    );
  }
}
