import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/mock_orbit_bridge.dart';
import '../api/orbit_bridge.dart';

/// OrbitBridge 注入点（omnipass omniBridgeProvider 同款模式）
///
/// 默认注入 Mock 实现（UI 可独立开发测试）；
/// Phase 5 FRB 绑定就绪后在 main 中 override：
/// ```dart
/// ProviderScope(
///   overrides: [orbitBridgeProvider.overrideWithValue(RustOrbitBridge())],
///   child: const OrbitApp(),
/// )
/// ```
final orbitBridgeProvider = Provider<OrbitBridge>((ref) {
  return MockOrbitBridge();
});
