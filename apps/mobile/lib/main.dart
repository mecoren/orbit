import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// Orbit 移动端入口
///
/// 启动序列（对齐 React 版 App.tsx 门控）：
/// 竖屏锁定 → [App] 内启动门控（masterAuthHas? unlock : plaintext init）。
/// FRB 桥接初始化在 Phase 5 接入（WaitBridge.init() 同款位置）。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const ProviderScope(child: OrbitApp()));
}
