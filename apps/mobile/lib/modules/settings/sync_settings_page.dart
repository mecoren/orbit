import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/sync_status_text.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart'
    show bottomSheetMotion, bottomSheetTopShape;
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import '../../shared/widgets/shadcn/orbit_floating_sheet_card.dart';
import '../../shared/widgets/shadcn/orbit_segmented_filter.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_password_sheet.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_settings_group.dart';
import '../../shared/widgets/shadcn/orbit_dropdown_preference.dart';
import '../../shared/widgets/shadcn/orbit_spinner.dart';
import '../../shared/widgets/shadcn/orbit_text_field.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../shared/widgets/shadcn/orbit_button.dart';
import '../../shared/widgets/shadcn/orbit_divider.dart';
import '../todo/providers/todo_providers.dart';
import '../../core/theme/icon_map.dart';

/// 危险操作强制冷静期（与桌面 `DANGEROUS_HOLD_SECONDS` 同口径）
const int _dangerousHoldSeconds = 5;

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
  // F80：S3 STS 会话令牌（留空 = 沿用已存；后端不回显令牌本身）
  late final _sessionTokenController = TextEditingController();
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
    _sessionTokenController.dispose();
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
          _timeoutController.text = c.timeoutSeconds <= 0
              ? '30'
              : '${c.timeoutSeconds}';
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
    // F80：留空沿用已存令牌（与密码同语义）
    'session_token': _engine == 's3' ? _sessionTokenController.text : '',
  };

  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      final n = await ref
          .read(orbitBridgeProvider)
          .syncTestConnection(_buildInput());
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
                top:
                    MediaQuery.of(context).padding.top +
                    OrbitPageHeader.rowHeight +
                    AppDimens.space16,
                // 卡体自带 h:12 外距（OrbitSettingsGroup），列表不再加水平边距
                bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
              ),
              children: [
                // 卡外分组标题 + 行式分组卡（设置页同一口径）
                OrbitSettingsGroup.rows(
                  title: '云同步连接',
                  subtitle: _config == null
                      ? null
                      : '已配置 · ${_engineLabel(_engine)}',
                  children: _loading
                      ? [
                          Padding(
                            padding: const EdgeInsets.all(
                              AppDimens.cardPadding,
                            ),
                            child: Center(
                              child: OrbitSpinner(
                                size: AppDimens.iconSizeLg,
                                color: OrbitAccents.themeAccent,
                              ),
                            ),
                          ),
                        ]
                      : _connectionRows(colors),
                ),
                const SizedBox(height: AppDimens.space12),
                const _SyncCryptoCard(),
                const SizedBox(height: AppDimens.space12),
                const _SyncHistoryCard(),
                const SizedBox(height: AppDimens.space12),
                const _SyncLedgerCard(),
                const SizedBox(height: AppDimens.space12),
                const _SyncDiagnosticCard(),
                const SizedBox(height: AppDimens.space12),
                const _CloudCleanupCard(),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(title: '云同步配置'),
          ),
        ],
      ),
    );
  }

  String _engineLabel(String engine) => engine == 's3' ? 'S3' : 'WebDAV';

  /// 引擎档位（两档；值即保存口径）
  static const List<SelectItem<String>> _engineItems = [
    SelectItem(value: 'webdav', label: 'WebDAV'),
    SelectItem(value: 's3', label: 'S3 兼容存储'),
  ];

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

  /// 间隔下拉项（非档位配置补一项「当前」，保证尾随值与弹层对勾都在线）
  List<SelectItem<int>> get _intervalItems => [
    if (!_intervalChoices.containsKey(_intervalMin))
      SelectItem(value: _intervalMin, label: _intervalLabel(_intervalMin)),
    for (final e in _intervalChoices.entries)
      SelectItem(value: e.key, label: e.value),
  ];

  /// 连接卡行式内容（设置页口径：说明段 → 引擎 → 表单块 → 开关行 → 按钮区）
  ///
  /// 行件都自带 16 水平内边距、卡片水平内边距为零，下拉行展开时的按压灰底
  /// 才能横贯整卡；表单块由 [_formBlock] 补回 16 与行文字同线。
  List<Widget> _connectionRows(AppColorSet colors) {
    final isS3 = _engine == 's3';
    final endpointEmpty = _endpointController.text.trim().isEmpty;

    return <Widget>[
      OrbitSettingsDesc(
        isS3
            ? '连接 S3 兼容存储：Endpoint、存储桶与访问密钥只保存在本机；'
                  '上传前已做端到端加密，服务商无法读取内容。'
            : '连接 WebDAV 服务：地址与账号只保存在本机；'
                  '上传前已做端到端加密，服务商无法读取内容。',
      ),
      const OrbitSettingsDivider(),
      OrbitDropdownPreference<String>(
        title: '引擎',
        items: _engineItems,
        current: _engine,
        onSelect: (v) => setState(() => _engine = v),
        insideMargin: kSettingsRowMargin,
      ),
      const OrbitSettingsDivider(),
      _formBlock([
        OrbitTextField(
          controller: _endpointController,
          keyboardType: TextInputType.url,
          label: isS3 ? 'Endpoint' : '服务器地址',
          onChanged: (_) => setState(() {}),
        ),
        if (isS3) ...[
          const SizedBox(height: AppDimens.space12),
          OrbitTextField(controller: _bucketController, label: '存储桶'),
          const SizedBox(height: AppDimens.space12),
          OrbitTextField(controller: _regionController, label: 'Region'),
        ],
        const SizedBox(height: AppDimens.space12),
        OrbitTextField(
          controller: _usernameController,
          label: isS3 ? 'Access Key' : '用户名',
        ),
        const SizedBox(height: AppDimens.space12),
        OrbitTextField(
          controller: _passwordController,
          obscureText: true,
          label: isS3 ? 'Secret Key' : '密码',
          helperText: _config?.passwordSet == true
              ? '已保存（修改请重新输入）'
              : null,
        ),
        if (isS3) ...[
          const SizedBox(height: AppDimens.space12),
          OrbitTextField(
            controller: _sessionTokenController,
            obscureText: true,
            label: '会话令牌（STS 临时凭据专用）',
            helperText: _config?.sessionTokenSet == true ? '已设置，留空沿用' : null,
          ),
        ],
        const SizedBox(height: AppDimens.space12),
        OrbitTextField(controller: _basePathController, label: '远端路径'),
      ]),
      const OrbitSettingsDivider(),
      OrbitSettingsSwitchRow(
        '定时同步',
        // 移动端无后台调度器：间隔只存档，由桌面端执行
        summary: '按固定间隔自动同步。移动端不驻后台调度，该间隔由桌面端执行；'
            '此处配置全端共享。',
        value: _autoEnabled,
        onChanged: (v) => setState(() => _autoEnabled = v),
      ),
      OrbitDropdownPreference<int>(
        title: '同步间隔',
        items: _intervalItems,
        current: _intervalMin,
        enabled: _autoEnabled,
        onSelect: (v) => setState(() => _intervalMin = v),
        insideMargin: kSettingsRowMargin,
      ),
      const OrbitSettingsDivider(),
      OrbitSettingsSwitchRow(
        '修改后立即同步',
        // 门控与桌面同口径：需「定时同步」总开关同时开启（见
        // sync_on_change_scheduler.dart 的 pushNow 门控链）
        summary: !_onChange
            ? '仅按定时或手动同步'
            : _autoEnabled
            ? '编辑后约 5 秒自动推送（需已解锁同步密码）'
            : '编辑后约 5 秒自动推送（需开启上方「定时同步」总开关）',
        value: _onChange,
        onChanged: (v) => setState(() => _onChange = v),
      ),
      const OrbitSettingsDivider(),
      _formBlock([
        OrbitTextField(
          controller: _timeoutController,
          keyboardType: TextInputType.number,
          label: '请求超时（秒，5–600）',
        ),
      ]),
      const OrbitSettingsDivider(),
      OrbitSettingsSwitchRow(
        '跳过 TLS 验证',
        summary: _skipTls ? '自签名证书场景专用，存在中间人风险' : '校验服务器证书（推荐）',
        value: _skipTls,
        onChanged: (v) => setState(() => _skipTls = v),
      ),
      OrbitSettingsNote('数据以 AES-256-GCM 端到端加密后上传，服务商无法读取内容。'),
      const OrbitSettingsDivider(),
      OrbitSettingsActions(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: OrbitButton.outline(
                    onPressed: (_testing || _busy || endpointEmpty)
                        ? null
                        : _testConnection,
                    child: _testing
                        ? const OrbitSpinner(size: AppDimens.iconSizeSm)
                        : const Text('测试连接'),
                  ),
                ),
                const SizedBox(width: AppDimens.space8),
                Expanded(
                  child: OrbitButton.primary(
                    onPressed: (_busy || endpointEmpty) ? null : _save,
                    child: _busy
                        ? const OrbitSpinner(
                            size: AppDimens.iconSizeSm,
                            color: Colors.white,
                          )
                        : const Text('保存'),
                  ),
                ),
              ],
            ),
            if (_config != null) ...[
              const SizedBox(height: AppDimens.space8),
              OrbitButton.text(
                onPressed: _busy ? null : () => _confirmDisconnect(context),
                child: Text(
                  '断开云同步',
                  style: TextStyle(color: colors.destructive),
                ),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  /// 卡内表单块：卡片零水平内边距时补回 16，与行文字保持同线。
  /// 下拉偏好行必须留在本块之外，展开时的按压灰底才能横贯整卡。
  Widget _formBlock(List<Widget> children) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppDimens.space16,
      AppDimens.space12,
      AppDimens.space16,
      AppDimens.space12,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

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

  /// 首次设置同步密码：输入走共享抽屉（`showPasswordSheet`，与修改密码同口径，
  /// 密码类输入不落页面内联表单）；长度/一致校验在关闭后执行
  Future<void> _setup() async {
    if (_busy) return;
    final values = await showPasswordSheet(
      context,
      title: '设置同步密码',
      message: '设置后所有上传数据以该密码端到端加密，其他设备输入相同密码即可解锁同步。',
      labels: const ['同步密码', '确认密码'],
      confirmLabel: '设置并解锁',
    );
    if (values == null || !mounted) return;
    final pw = values[0];
    if (pw.length < 6) {
      WaitToast.destructive('同步密码至少 6 位');
      return;
    }
    if (pw != values[1]) {
      WaitToast.destructive('两次输入的密码不一致');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).syncCryptoInit(pw, remember: true);
      WaitToast.success('同步密码已设置，端到端加密已就绪');
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
        e.toString().contains('wrong_password') ? '同步密码错误' : _errMsg(e),
      );
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
  ///
  /// 密码输入走共享抽屉（`showPasswordSheet`）；长度/一致校验在关闭后执行。
  Future<void> _changePassword() async {
    if (_busy) return;
    try {
      final values = await showPasswordSheet(
        context,
        title: '修改同步密码',
        message:
            'v2 密钥方案下改密等于更换密钥，会把云端数据全量重传一次；'
            '其他设备在此期间请勿同步。',
        labels: const ['当前同步密码', '新同步密码', '确认新密码'],
        confirmLabel: '确认修改',
      );
      if (values == null || !mounted) return;
      final oldPw = values[0];
      final newPw = values[1];
      final confirmPw = values[2];
      if (newPw.length < 6) {
        WaitToast.destructive('同步密码至少 6 位');
        return;
      }
      if (newPw != confirmPw) {
        WaitToast.destructive('两次输入的新密码不一致');
        return;
      }
      // 换钥 + 云端全量重传不可撤销：密码填完后独立再走 5 秒时停
      // （桌面同步密码卡的 DangerousConfirmDialog 同口径）
      final ok = await showConfirmBottomSheet(
        context,
        title: '修改同步密码',
        message: '修改密码将更换数据密钥并用新密钥全量重传云端数据：'
            '传完之前请勿在其他设备同步，其他设备此后须用新密码。'
            '若旧设备仍用旧密码同步，可能造成云端数据混乱。',
        confirmLabel: '确认修改',
        destructive: true,
        holdSeconds: _dangerousHoldSeconds,
      );
      if (!ok || !mounted) return;
      setState(() => _busy = true);
      await ref
          .read(orbitBridgeProvider)
          .syncCryptoChangePassword(oldPw, newPw);
      await ref.read(orbitBridgeProvider).syncCryptoUnlock(newPw);
      WaitToast.success('同步密码已修改，云端数据已用新密钥重传');
      await _refresh();
    } catch (e) {
      WaitToast.destructive('修改失败：${_errMsg(e)}');
    } finally {
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
      message:
          '仅清除本机内存中的会话密码与已解锁状态，云端数据与密钥不受影响；'
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
    try {
      final values = await showPasswordSheet(
        context,
        title: '升级密钥方案到 v2',
        message:
            '升级后同一同步密码在任何设备都派生同一把密钥，不再需要密钥包分发，'
            '可彻底避免「密钥不一致」。升级会立即用新密钥全量重传云端数据，'
            '期间请勿在其他设备同步。此操作不可撤销。',
        labels: const ['当前同步密码'],
        confirmLabel: '确认升级',
      );
      if (values == null || !mounted) return;
      final pw = values.first;
      // 升级即换钥全量重传：密码确认后独立再走 5 秒时停（桌面同口径）
      final ok = await showConfirmBottomSheet(
        context,
        title: '升级密钥方案到 v2',
        message: '升级后同一同步密码在任何设备都派生同一把数据密钥，不再需要密钥包分发。'
            '升级会立即用新密钥全量重传云端数据，期间请勿在其他设备同步。此操作不可撤销。',
        confirmLabel: '确认升级',
        destructive: true,
        holdSeconds: _dangerousHoldSeconds,
      );
      if (!ok || !mounted) return;
      setState(() => _busy = true);
      await ref.read(orbitBridgeProvider).syncCryptoUpgradeV2(pw);
      WaitToast.success('已升级 v2 并完成云端重传。其他设备输入相同密码即可同步');
      await _refresh();
    } catch (e) {
      WaitToast.destructive('升级失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 以本机为准重置云端（危险）：当前 Data Key 全量重加密**覆盖**云端。
  /// 本机没有的记录与附件会永久丢失（桌面 sync-recovery-page 的兜底路径）。
  /// 确认钮 5 秒时停内禁用（与桌面同口径）。
  Future<void> _rekeyCloud() async {
    if (_busy) return;
    final ok = await showConfirmBottomSheet(
      context,
      title: '以本机为准重置云端',
      message:
          '将用当前设备的数据密钥重加密并覆盖云端全部数据：仅存于云端的记录与附件'
          '会永久丢失，其他设备需输入本机当前同步密码后重新同步。'
          '此操作不可撤销，请确认云端数据已无需保留。',
      confirmLabel: '确认重置云端',
      destructive: true,
      holdSeconds: _dangerousHoldSeconds,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      // 真桥返回 result_to_json 的 JSON 串（非对象），与桌面同源结构
      final raw = await ref.read(orbitBridgeProvider).cloudSyncRekey();
      final result = SyncResultJson.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
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
      // readAsString 是 async gap，弹抽屉前页面可能已销毁
      if (!mounted) return;
      // 本机已存在密钥时导入会覆盖本机现有密钥（桌面 sync-recovery-page
      // 的 forceConfirmOpen 同口径）：问密码之前先读后果并等满 5 秒
      if (_status?.hasPassword == true) {
        final force = await showConfirmBottomSheet(
          context,
          title: '本机已存在同步密钥',
          message: '导入密钥包会覆盖本机现有的同步密钥，之后需用该密钥包的密码解锁。'
              '若本机数据尚未同步到云端，建议先完成一次同步。此操作不可撤销。',
          confirmLabel: '仍然导入',
          destructive: true,
          holdSeconds: _dangerousHoldSeconds,
        );
        if (!force || !mounted) return;
      }
      final values = await showPasswordSheet(
        context,
        title: '输入该密钥包的同步密码',
        labels: const ['同步密码'],
        hints: const ['导出密钥包时使用的密码'],
        confirmLabel: '导入',
      );
      final pw = values?.firstOrNull;
      if (pw == null || pw.isEmpty) return;
      await ref
          .read(orbitBridgeProvider)
          .syncCryptoImportBundle(bundle, pw, force: true);
      WaitToast.success('密钥包已导入，请用同一密码解锁后同步');
      await _refresh();
    } catch (e) {
      WaitToast.destructive('导入失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final status = _status;

    return OrbitSettingsGroup(
      title: '同步密码（端到端加密）',
      child: status == null
          ? Text(
              '加载中…',
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!status.hasPassword) ...[
                  Text(
                    '未设置。设置后所有上传数据以该密码端到端加密；同一密码在任何设备派生同一把密钥，跨设备只需输入相同密码。',
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                  const SizedBox(height: AppDimens.space12),
                  SizedBox(
                    width: double.infinity,
                    child: OrbitButton.primary(
                      onPressed: _busy ? null : _setup,
                      child: _busy
                          ? const OrbitSpinner(
                              size: AppDimens.iconSizeSm,
                              color: Colors.white,
                            )
                          : const Text('设置密码'),
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Icon(
                        status.isUnlocked ? OrbitIcons.shield : OrbitIcons.lock,
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
                    OrbitTextField(
                      controller: _unlockController,
                      obscureText: true,
                      label: '同步密码',
                    ),
                    const SizedBox(height: AppDimens.space12),
                    SizedBox(
                      width: double.infinity,
                      child: OrbitButton.primary(
                        onPressed: _busy ? null : _unlock,
                        child: _busy
                            ? const OrbitSpinner(
                                size: AppDimens.iconSizeSm,
                                color: Colors.white,
                              )
                            : const Text('解锁'),
                      ),
                    ),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: OrbitButton.outline(
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
                    child: OrbitButton.outline(
                      onPressed: _busy ? null : _importBundle,
                      child: const Text('导入密钥包恢复（换机 / 密钥不匹配）'),
                    ),
                  ),
                  const SizedBox(height: AppDimens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: OrbitButton.outline(
                      onPressed: _busy ? null : _exportBundle,
                      child: const Text('导出密钥包（备份到本机 exports/）'),
                    ),
                  ),
                  const SizedBox(height: AppDimens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: OrbitButton.outline(
                      onPressed: _busy ? null : _changePassword,
                      child: const Text('修改同步密码'),
                    ),
                  ),
                  const SizedBox(height: AppDimens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: OrbitButton.outline(
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
                      child: OrbitButton.outline(
                        onPressed: _busy ? null : _upgradeV2,
                        child: const Text('升级密钥方案到 v2'),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppDimens.space8),
                  SizedBox(
                    width: double.infinity,
                    child: OrbitButton.outline(
                      destructive: true,
                      onPressed: _busy ? null : _rekeyCloud,
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

  // F77：键与 core sync_history.sync_type 真值对齐（engine.rs 常量
  // incremental / push_only / pull_only）——旧键 'sync_now'/'pull_then_push'
  // 是臆测值，真数据永远落不到这些标签上，回退显示原始字符串。
  static const _typeLabels = <String, String>{
    'incremental': '完整同步',
    'push_only': '仅推送',
    'pull_only': '先拉后推',
  };

  /// 筛选档键序列（与 [_scopes] 同源，只固定下标 ↔ 键的映射顺序）
  static const _scopeKeys = <String>[
    'all',
    'incremental',
    'push_only',
    'pull_only',
  ];

  String _scope = 'all';
  List<SyncHistoryRow> _rows = const [];
  bool _loading = true;

  int get _scopeIndex {
    final i = _scopeKeys.indexOf(_scope);
    return i < 0 ? 0 : i;
  }

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

    return OrbitSettingsGroup(
      title: '同步历史',
      subtitle: _loading ? null : '近 ${_rows.length} 次',
      trailing: OrbitButton.text(
        onPressed: _loading ? null : _load,
        child: const Text('刷新'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 类型筛选：连体分段控件（库内 `MiuixTabRowWithContour` 承载，
          // 见 `orbit_segmented_filter.dart`）——四档同属一个轨道，读起来是
          // 「一个筛选器的四个档位」而不是四个各自描边的独立胶囊；宽度不够
          // 时库内自动横向滚动，大字号档不再折行挤压。
          OrbitSegmentedFilter(
            tabs: [for (final e in _scopes.entries) e.value],
            selectedIndex: _scopeIndex,
            onSelect: (i) => _switchScope(_scopeKeys[i]),
          ),
          const SizedBox(height: AppDimens.space12),
          if (_loading)
            Padding(
              padding: const EdgeInsets.all(AppDimens.space16),
              child: Center(
                child: OrbitSpinner(
                  size: AppDimens.iconSizeLg,
                  color: OrbitAccents.themeAccent,
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

  Widget _row(AppColorSet colors, SyncHistoryRow r) {
    final ok = r.status == 'success';
    // N33：主动取消不是故障——灰色「已取消」，不落红色「失败」
    final cancelled = r.status == 'cancelled';
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
                ok ? '成功' : (cancelled ? '已取消' : r.status),
                style: TextStyle(
                  fontSize: 11,
                  color: ok
                      ? colors.success
                      : (cancelled ? colors.secondaryText : colors.destructive),
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
          if (r.errorMessage != null &&
              r.errorMessage!.isNotEmpty &&
              !cancelled)
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

/// 同步账本卡（对齐桌面 SyncLedgerCard；只读诊断）
///
/// 数据源 `sync_state.json`：桶指纹 + 水位线 + 本机设备 / 远端清单 epoch。
/// 为什么值得单列一卡：同步成败此前只有一个「转没转」+ 上次时间，出问题时
/// 看不到引擎认为远端长什么样；指纹是桶内容（按 uuid 排序、排除时间戳与
/// 自增 id）的 sha256，两台设备同一桶指纹相等即内容一致。
///
/// 只读聚合不 emit 事件、不进同步白名单，故不订阅 db-change，靠进入页面
/// 与「刷新」回读（同 [_SyncHistoryCard] 口径）。
class _SyncLedgerCard extends ConsumerStatefulWidget {
  const _SyncLedgerCard();

  @override
  ConsumerState<_SyncLedgerCard> createState() => _SyncLedgerCardState();
}

class _SyncLedgerCardState extends ConsumerState<_SyncLedgerCard> {
  SyncStateView? _state;
  bool _loading = true;
  Object? _error;

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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = await ref.read(orbitBridgeProvider).cloudSyncGetState();
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final state = _state;

    return OrbitSettingsGroup(
      title: '同步账本',
      subtitle: '桶指纹与水位线（排障用）',
      trailing: OrbitButton.text(
        onPressed: _loading ? null : _load,
        child: const Text('刷新'),
      ),
      child: _loading && state == null
          ? Padding(
              padding: const EdgeInsets.all(AppDimens.space16),
              child: Center(
                child: OrbitSpinner(
                  size: AppDimens.iconSizeLg,
                  color: OrbitAccents.themeAccent,
                ),
              ),
            )
          : state == null
          ? Text(
              '读取失败：${_errMsg(_error!)}',
              style: TextStyle(fontSize: 12, color: colors.destructive),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row(colors, '上次同步', formatLastSynced(state.lastSyncedAt)),
                _row(
                  colors,
                  '推送水位线',
                  formatLedgerClockMs(state.lastPushedClockMs),
                ),
                _row(
                  colors,
                  '拉取水位线',
                  formatLedgerClockMs(state.lastSyncedClockMs),
                ),
                _row(
                  colors,
                  '远端清单',
                  state.manifestEpoch > 0
                      ? 'epoch ${state.manifestEpoch}'
                      : '未建立',
                ),
                _row(
                  colors,
                  '本机设备',
                  state.deviceId.isEmpty ? '—' : state.deviceId,
                ),
                const SizedBox(height: AppDimens.space12),
                _buckets(colors, '远端数据桶', state.remoteTables),
                const SizedBox(height: AppDimens.space12),
                _buckets(colors, '远端墓碑桶', state.remoteTombstones),
                const SizedBox(height: AppDimens.space8),
                Text(
                  '指纹 = 桶内数据（按 uuid 排序、排除时间戳与自增 id）的 sha256 前 8 位；'
                  '两台设备同一桶指纹相同即该桶内容一致。',
                  style: TextStyle(fontSize: 11, color: colors.secondaryText),
                ),
              ],
            ),
    );
  }

  /// 键值行：定宽标签 + 可换行取值（设备 ID 等长串折行不撑破卡片）
  Widget _row(AppColorSet colors, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: AppDimens.space6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(fontSize: 12, color: colors.bodyText),
          ),
        ),
      ],
    ),
  );

  /// 一张桶指纹表（表名 + 桶数 + 各桶「键:指纹前 8 位」）
  Widget _buckets(
    AppColorSet colors,
    String title,
    Map<String, Map<String, String>> snapshot,
  ) {
    final modules = syncLedgerModules(snapshot);
    if (modules.isEmpty) {
      return Text(
        '$title：暂无',
        style: TextStyle(fontSize: 12, color: colors.secondaryText),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title（${modules.length} 表 / ${countBuckets(snapshot)} 桶）',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colors.bodyText,
          ),
        ),
        const SizedBox(height: AppDimens.space4),
        for (final m in modules)
          Padding(
            padding: const EdgeInsets.only(bottom: AppDimens.space4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${m.table} · ${m.buckets} 桶',
                  style: TextStyle(fontSize: 12, color: colors.bodyText),
                ),
                Text(
                  m.entries.map((e) => '${e.key}:${e.fp}').join('  '),
                  style: TextStyle(fontSize: 11, color: colors.secondaryText),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── 云端清理卡（docs/15）────────────────────────────────────────────

/// 云端存储清理（设置 → 云同步配置 → 云端清理）
///
/// 判据与兜底全在 core：云端对象集 − 云端引用集（`todo_task_attachments`
/// 云端分桶 `is_deleted = 0`）、30 天 mtime 窗口、删除前 epoch 复核。
/// 移动端只做清单勾选与确认，与桌面诊断页「云端存储」卡片同口径。
///
/// 两行两类对象，**目录互不相交**：孤儿附件清 `assets/`+`assets_parts/`，
/// 孤儿数据桶清 `tables/`（判据是清单索引，不是桶内容墓碑）。桌面把两者
/// 放同一张卡的第二、三行（#96 尾款 + #97），本页同形制。
///
/// mock 桥没有云端后端，两行都恒返回「没有可清理项」。
class _CloudCleanupCard extends ConsumerStatefulWidget {
  const _CloudCleanupCard();

  @override
  ConsumerState<_CloudCleanupCard> createState() => _CloudCleanupCardState();
}

class _CloudCleanupCardState extends ConsumerState<_CloudCleanupCard> {
  bool _scanning = false;
  bool _chunkGcBusy = false;

  String _errMsg(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final result = await ref
          .read(orbitBridgeProvider)
          .cloudUnusedAttachmentsScan();
      if (!mounted) return;
      if (result.items.isEmpty) {
        WaitToast.success('没有可清理的云端附件');
        return;
      }
      await _openList(result);
    } catch (e) {
      WaitToast.destructive('扫描云端附件失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _openList(CloudUnusedScanResult result) async {
    final colors = AppColors.ofContext(context);
    final selected = <String>{};

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (sheetContext) => OrbitFloatingSheetCard(
        child: StatefulBuilder(
          builder: (context, setSheetState) {
            final allSelected = selected.length == result.items.length;
            var bytes = 0;
            for (final item in result.items) {
              if (selected.contains(item.hash)) bytes += item.displayBytes;
            }
            final days = result.minAgeSecs ~/ 86400;

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.space16,
                  AppDimens.space16,
                  AppDimens.space16,
                  AppDimens.space12,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '清理云端孤儿附件',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.bodyText,
                      ),
                    ),
                    const SizedBox(height: AppDimens.space8),
                    Text(
                      '以下对象无任何设备引用，且写入超过 $days 天。删除的是云端密文副本；'
                      '其他设备若仍有本地副本会在下次同步自动重传。',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.secondaryText,
                      ),
                    ),
                    const SizedBox(height: AppDimens.space8),
                    Row(
                      children: [
                        OrbitButton.text(
                          onPressed: () => setSheetState(() {
                            if (allSelected) {
                              selected.clear();
                            } else {
                              selected
                                ..clear()
                                ..addAll(result.items.map((i) => i.hash));
                            }
                          }),
                          child: Text(allSelected ? '取消全选' : '全选'),
                        ),
                        const Spacer(),
                        Text(
                          '已选 ${selected.length} / 共 ${result.items.length} 项 · '
                          '${humanFileSize(bytes)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: result.items.length,
                        separatorBuilder: (_, _) =>
                            OrbitDivider(height: 1, color: colors.divider),
                        itemBuilder: (context, index) {
                          final item = result.items[index];
                          final checked = selected.contains(item.hash);
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: OrbitCheckbox(
                              checked: checked,
                              onToggle: () => setSheetState(() {
                                if (checked) {
                                  selected.remove(item.hash);
                                } else {
                                  selected.add(item.hash);
                                }
                              }),
                            ),
                            title: Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.bodyText,
                              ),
                            ),
                            subtitle: Text(
                              '${item.kindLabel} · '
                              '${humanFileSize(item.displayBytes)}'
                              '${item.isLocalCached == 1 ? ' · 本地有副本' : ''}',
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.secondaryText,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: AppDimens.space8),
                    Row(
                      children: [
                        OrbitButton.outline(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: AppDimens.space12),
                        Expanded(
                          child: OrbitButton.primary(
                            // 两步式（桌面 CloudUnusedAttachmentsDialog 同口径）：
                            // 先关列表层，再对选中集合走 5 秒时停确认——底部表单
                            // 里不叠第二层确认抽屉
                            onPressed: selected.isEmpty
                                ? null
                                : () {
                                    final hashes = selected.toList();
                                    Navigator.pop(sheetContext);
                                    unawaited(
                                      _deleteCloudUnused(hashes, result.epoch),
                                    );
                                  },
                            child: Text(
                              '删除选中${selected.isEmpty ? '' : ' (${selected.length})'}',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 删除选中的云端孤儿附件：列表层关闭后走 5 秒时停确认，再调桥执行。
  /// 文案须写清「云端密文对象被删」「其他设备有本地副本会自动重传」
  /// 「都无副本即永久丢失」（桌面 `CloudUnusedAttachmentsDialog` 同口径）。
  Future<void> _deleteCloudUnused(List<String> hashes, int epoch) async {
    final ok = await showConfirmBottomSheet(
      context,
      title: '永久删除云端附件',
      message: '将从云端删除 ${hashes.length} 个附件对象，不可恢复。'
          '其他设备若仍持有本地副本，会在下次同步时自动重新上传；'
          '所有设备都没有本地副本的附件将永久丢失。',
      confirmLabel: '删除',
      destructive: true,
      holdSeconds: _dangerousHoldSeconds,
    );
    if (!ok || !mounted) return;
    try {
      final r = await ref
          .read(orbitBridgeProvider)
          .cloudUnusedAttachmentsDelete(hashes: hashes, expectedEpoch: epoch);
      if (!mounted) return;
      if (r.staleManifest) {
        WaitToast.success('云端刚有新的同步活动，已重新扫描');
        await _scan();
        return;
      }
      if (r.deletedAssets == 0) {
        WaitToast.success('没有可清理的云端附件');
      } else if (r.errors.isNotEmpty) {
        WaitToast.destructive(
          '已清理 ${r.deletedAssets} 个（部分失败：${r.errors.first}）',
        );
      } else {
        WaitToast.success(
          '已清理 ${r.deletedAssets} 个云端附件（${r.deletedObjects} 个对象）',
        );
      }
    } catch (e) {
      if (mounted) WaitToast.destructive('清理失败：${_errMsg(e)}');
    }
  }

  /// 孤儿数据分桶回收（#96 尾款；桌面同款在诊断页「云端存储」卡第二行）
  ///
  /// 删除的桶按定义不可达（清单不再引用），且 core 侧另有 24h 保留窗口与
  /// 「服务端不回 mtime 一律跳过」两道兜底；但桌面入口仍走
  /// `DangerousConfirmDialog` 五秒时停，移动端对齐同一口径。
  Future<void> _chunkGc() async {
    final ok = await showConfirmBottomSheet(
      context,
      title: '回收孤儿数据分桶',
      message: '将删除云端 tables/ 下「同步清单已不再引用、且写入超过 24 小时」的分桶对象。'
          '清单仍在引用的数据与全部附件对象不受影响。',
      confirmLabel: '回收',
      destructive: true,
      holdSeconds: _dangerousHoldSeconds,
    );
    if (!ok || !mounted) return;
    setState(() => _chunkGcBusy = true);
    try {
      final r = await ref.read(orbitBridgeProvider).cloudOrphanChunksGc();
      if (!mounted) return;
      if (r.deletedBuckets == 0) {
        WaitToast.success('没有可回收的孤儿数据桶');
      } else if (r.errors.isNotEmpty) {
        WaitToast.destructive(
          '已回收 ${r.deletedBuckets} 个分桶（部分失败：${r.errors.first}）',
        );
      } else {
        WaitToast.success('已回收 ${r.deletedBuckets} 个孤儿数据分桶');
      }
    } catch (e) {
      WaitToast.destructive('回收孤儿数据桶失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _chunkGcBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return OrbitSettingsGroup(
      title: '云端存储',
      subtitle: '孤儿附件与孤儿数据桶',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '云端对象不会被自动回收（删除任务/卸载附件后仍留在网盘）。'
            '「清理孤儿附件」只扫 30 天前、无任何设备引用的 `assets/` 对象；'
            '「回收孤儿数据桶」清清单已不再引用的 `tables/` 分桶（24 小时窗口，'
            '刚写入的桶留给下一轮）。两处都需同步密钥已解锁，且只在你手动点击时执行。',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: AppDimens.space12),
          OrbitButton.outline(
            onPressed: _scanning ? null : _scan,
            child: _scanning
                ? const OrbitSpinner(size: 16)
                : const Text('清理云端孤儿附件'),
          ),
          const SizedBox(height: AppDimens.space8),
          OrbitButton.outline(
            onPressed: _chunkGcBusy ? null : _chunkGc,
            child: _chunkGcBusy
                ? const OrbitSpinner(size: 16)
                : const Text('回收孤儿数据桶'),
          ),
        ],
      ),
    );
  }
}

/// 单向同步排障（对齐桌面诊断页「仅推送 / 先拉后推」两钮，#107）
///
/// **只用于排障**：单向同步会跳过多端合并的一侧，连续点可能让对端改动晚一轮
/// 才可见——桌面同样把它藏在诊断分区而非同步主路径，移动端也单列一卡并写明
/// 「排障用」。两个动作都走 core 既有入口（`cloud_sync_push_only` /
/// `cloud_sync_pull_then_push`），零新协议。
class _SyncDiagnosticCard extends ConsumerStatefulWidget {
  const _SyncDiagnosticCard();

  @override
  ConsumerState<_SyncDiagnosticCard> createState() =>
      _SyncDiagnosticCardState();
}

class _SyncDiagnosticCardState extends ConsumerState<_SyncDiagnosticCard> {
  /// 'push' | 'pull' | null（null = 空闲）
  String? _busy;

  String _errMsg(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  Future<void> _run(String mode) async {
    setState(() => _busy = mode);
    final bridge = ref.read(orbitBridgeProvider);
    try {
      final r = mode == 'push'
          ? await bridge.cloudSyncPushOnly(origin: 'manual')
          : await bridge.cloudSyncPullThenPush(origin: 'manual');
      if (!mounted) return;
      if (r.skipped) {
        WaitToast.info('已有同步任务在进行中');
      } else if (r.errors.isNotEmpty) {
        WaitToast.destructive(
          '同步完成但有 ${r.errors.length} 条错误：${r.errors.first}',
        );
      } else {
        WaitToast.success(
          mode == 'push'
              ? '仅推送完成：${r.pushedModules} 个模块'
              : '先拉后推完成：拉取 ${r.pulledModules} 个模块',
        );
      }
      // 单向同步同样会改云端账本与「上次同步」，回读本页与设置页角标
      ref.invalidate(syncConfigProvider);
    } catch (e) {
      WaitToast.destructive('诊断同步失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return OrbitSettingsGroup(
      title: '同步排障',
      subtitle: '单向同步（排障用）',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '常规同步「立即同步」已包含拉取与推送两侧。这里把两侧拆开单独跑，'
            '用于判断是拉取侧还是推送侧卡住——单向同步会跳过多端合并的一侧，'
            '连续点击可能让对端改动晚一轮才可见，故不放在同步主路径。',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: AppDimens.space12),
          Row(
            children: [
              Expanded(
                child: OrbitButton.outline(
                  onPressed: _busy == null ? () => _run('push') : null,
                  child: _busy == 'push'
                      ? const OrbitSpinner(size: 16)
                      : const Text('仅推送'),
                ),
              ),
              const SizedBox(width: AppDimens.space12),
              Expanded(
                child: OrbitButton.outline(
                  onPressed: _busy == null ? () => _run('pull') : null,
                  child: _busy == 'pull'
                      ? const OrbitSpinner(size: 16)
                      : const Text('先拉后推'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
