import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/biometric_service.dart';
import 'bridge_provider.dart';

/// BiometricService 注入点（orbitBridgeProvider 同款模式）
///
/// 服务持有平台插件（local_auth / flutter_secure_storage），进程内单例
/// 即可（开关状态实时读 Secure Storage，无缓存态需失效）。
final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService(bridge: ref.watch(orbitBridgeProvider));
});
