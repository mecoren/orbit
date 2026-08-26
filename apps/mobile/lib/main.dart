import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/api/rust_orbit_bridge.dart';
import 'data/providers/bridge_provider.dart';

/// Orbit 移动端入口
///
/// 启动序列（对齐 React 版 App.tsx 门控）：
/// 竖屏锁定 → FRB 运行时初始化 → 启动门控（masterAuthHas? unlock : plaintext）。
///
/// 桥接切换：默认注入 RustOrbitBridge（真 Rust 后端）；
/// 纯 UI 开发可用 `flutter run --dart-define=ORBIT_USE_MOCK_BRIDGE=true`
/// 切回内存 Mock（MockOrbitBridge，无需 Rust 工具链/NDK）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  const useMock = bool.fromEnvironment('ORBIT_USE_MOCK_BRIDGE');
  if (!useMock) {
    await initRustBridge();
  }

  runApp(
    ProviderScope(
      overrides: [
        if (!useMock) orbitBridgeProvider.overrideWithValue(RustOrbitBridge()),
      ],
      child: const OrbitApp(),
    ),
  );
}
