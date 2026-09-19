import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../data/api/orbit_bridge.dart';

/// 生物识别解锁服务（指纹闸门 + 密钥链编排）
///
/// 密钥链结构与 Rust 侧 `orbit-flutter/src/api/biometric.rs` 模块文档一致：
/// ```text
/// 指纹闸门（local_auth，本服务；不参与密钥派生）
///   └─► Secure Storage 三键（encrypted_db_key_bio / biometric_key / nonce）
///         └─► 桥 biometricUnlock：AES-256-GCM 解密 → DB Key hex
///               └─► DB 就绪进入主界面（与密码解锁同终态）
/// ```
///
/// 分层（对齐 BadgeService 注入式模式）：
/// - [BiometricGate]：指纹采集闸门（local_auth 包装；测试注入假实现）；
/// - [BiometricStore]：Secure Storage 三键读写（测试注入内存实现）；
/// - [BiometricService]：编排（本文件主体）——开关读取、启用（生成密钥链
///   → 落 Secure Storage）、解锁（读三键 → 桥解密）、关闭（密码确认 →
///   删三键）。
///
/// 本服务不做 UI：结果与错误（含 `[tag]` 前缀）上抛由调用方呈现。
/// Android 平台前提：宿主 Activity 为 FlutterFragmentActivity（已改），
/// USE_BIOMETRIC 权限已声明（manifest）。
class BiometricGate {
  BiometricGate({LocalAuthentication? plugin})
      : _plugin = plugin ?? LocalAuthentication();

  final LocalAuthentication _plugin;

  /// 设备是否具备生物识别硬件且已录入（UI 据此决定是否展示开关）
  Future<bool> isAvailable() async {
    try {
      return await _plugin.canCheckBiometrics;
    } catch (_) {
      // 平台通道异常（无平台环境）：视为不可用
      return false;
    }
  }

  /// 拉起指纹闸门（系统对话框）；用户取消/失败返回 false，
  /// 其余失败态（如锁屏超时）local_auth 抛 LocalAuthException——
  /// 同样归约为 false，不炸解锁主流程。
  Future<bool> authenticate() async {
    try {
      return await _plugin.authenticate(
        localizedReason: '验证指纹以解锁循迹数据',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}

/// Secure Storage 三键读写层（键名与启用链路一一对应；测试注入内存实现）
class BiometricStore {
  BiometricStore({FlutterSecureStorage? plugin})
      : _plugin = plugin ?? const FlutterSecureStorage();

  final FlutterSecureStorage _plugin;

  static const _kEncryptedDbKeyBio = 'encrypted_db_key_bio';
  static const _kBiometricKey = 'biometric_key';
  static const _kNonce = 'nonce';

  /// 读三件套；任一键缺失视为未启用（部分残留由 clear 收敛）
  Future<BiometricSecretBundle?> read() async {
    final enc = await _plugin.read(key: _kEncryptedDbKeyBio);
    final key = await _plugin.read(key: _kBiometricKey);
    final nonce = await _plugin.read(key: _kNonce);
    if (enc == null || key == null || nonce == null) return null;
    return BiometricSecretBundle(
      encryptedDbKeyBio: enc,
      biometricKey: key,
      nonce: nonce,
    );
  }

  /// 写三件套（启用时；覆盖语义，重复启用以最后一次为准）
  Future<void> write(BiometricSecretBundle bundle) async {
    await _plugin.write(
        key: _kEncryptedDbKeyBio, value: bundle.encryptedDbKeyBio);
    await _plugin.write(key: _kBiometricKey, value: bundle.biometricKey);
    await _plugin.write(key: _kNonce, value: bundle.nonce);
  }

  /// 删三键（关闭时；幂等）
  Future<void> clear() async {
    await _plugin.delete(key: _kEncryptedDbKeyBio);
    await _plugin.delete(key: _kBiometricKey);
    await _plugin.delete(key: _kNonce);
  }
}

/// 生物识别解锁编排服务（开关状态 = Secure Storage 是否有三件套）
///
/// 生命周期口径：启用前必须先过一次指纹闸门（防"开着开关却录不上指纹"
/// 的死配置）；关闭须密码确认（Rust `biometricDisable` 验证）后删三键。
/// 桌面端改密不换 DB Key（v2 方案：改密只重派生包裹元数据），三件套
/// 无需重置；主密码重置（重新初始化数据库）会另生新 DB Key，旧三件套
/// 解密必失败 → UnlockPage 引导回密码路径，用户重新启用。
class BiometricService {
  BiometricService({
    required this.bridge,
    BiometricGate? gate,
    BiometricStore? store,
  })  : _gate = gate ?? BiometricGate(),
        _store = store ?? BiometricStore();

  final OrbitBridge bridge;
  final BiometricGate _gate;
  final BiometricStore _store;

  /// 硬件可用性（UI 决定是否展示开关；平台异常视为不可用）
  Future<bool> isAvailable() => _gate.isAvailable();

  /// 当前是否已启用（= Secure Storage 三键齐全）
  Future<bool> isEnabled() async => await _store.read() != null;

  /// 启用：指纹闸门 → 桥生成三件套 → 落 Secure Storage
  ///
  /// 调用前提：用户刚以密码解锁（dbKeyHex 在手）。闸门不过返回 false
  ///（不落任何键）；桥失败抛错（键未写，无残留）。
  Future<bool> enable(String dbKeyHex) async {
    if (!await _gate.authenticate()) return false;
    final bundle = await bridge.biometricSetup(dbKeyHex);
    await _store.write(bundle);
    return true;
  }

  /// 解锁：指纹闸门 → 读三件套 → 桥解密出 db_key_hex
  ///
  /// 返回 null = 用户取消或未启用（UI 停留解锁页）；桥抛
  /// `[biometric_failed]` 上抛（密钥链损坏，UI 引导密码路径 + 重开关）。
  /// 成功返回 dbKeyHex，由调用方走 dbInitEncrypted 进入主界面
  ///（与密码解锁同一路径）。
  Future<String?> unlock() async {
    final bundle = await _store.read();
    if (bundle == null) return null;
    if (!await _gate.authenticate()) return null;
    return bridge.biometricUnlock(bundle);
  }

  /// 关闭：密码确认（Rust 验证）→ 删三键
  ///
  /// 密码错误抛 `[wrong_password]` 上抛；成功后 Secure Storage 无残留。
  Future<void> disable(String password) async {
    await bridge.biometricDisable(password);
    await _store.clear();
  }

  /// 仅清理本机密钥链（不做 Rust 侧校验）
  ///
  /// 用于「关闭加密库」这类主密码整体消失的场景：此时旧 DB Key 已随明文
  /// 迁移失效，三件套必然解不开，密码校验也无从谈起，直接清键避免留下
  /// 永远失败的指纹入口。
  Future<void> clearStoredSecrets() => _store.clear();
}
