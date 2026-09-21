import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'data/api/rust_orbit_bridge.dart';
import 'data/providers/bridge_provider.dart';
import 'services/local_prefs.dart';

/// Orbit 移动端入口
///
/// 启动序列（对齐 React 版 App.tsx 门控）：
/// 竖屏锁定 → intl 日期本地化数据 → FRB 运行时初始化 → 启动门控
/// （masterAuthHas? unlock : plaintext）。
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

  // 月历（table_calendar）与 zh_CN 日期格式依赖 intl 的语言数据，
  // 必须在 runApp 前装载完成，否则首帧日历会抛 LocaleDataException。
  // en_US 一并装载：intl 的默认 locale 是 en_US，未装载时 DateFormat 默认构造会报错。
  await initializeDateFormatting('zh_CN');
  await initializeDateFormatting('en_US');

  const useMock = bool.fromEnvironment('ORBIT_USE_MOCK_BRIDGE');
  if (!useMock) {
    await initRustBridge();
  }

  // 本机 UI 偏好（隐藏已完成等视图态）：首帧前载入，失败静默走默认值
  await LocalPrefs.load();

  runApp(
    ProviderScope(
      overrides: [
        if (!useMock) orbitBridgeProvider.overrideWithValue(RustOrbitBridge()),
      ],
      child: const OrbitApp(),
    ),
  );
}
