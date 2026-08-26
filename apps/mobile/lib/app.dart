import 'package:flutter/material.dart';

import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'modules/shell/boot_gate.dart';

/// OrbitApp — MaterialApp 装配
///
/// 亮暗跟随系统（platformBrightness），不做应用内切换——与 React 版一致；
/// 主题由 [buildAppTheme] 工厂生成（wait-home 同款 M3 + 固定表面角色）。
/// 启动门控经 builder 包裹主路由：masterAuthHas? 解锁页 : 明文库直入，
/// ready 前不渲染任何路由内容。
class OrbitApp extends StatelessWidget {
  const OrbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    final brightness = MediaQuery.platformBrightnessOf(context);
    return MaterialApp.router(
      title: '循迹',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      routerConfig: appRouter,
      // BootGate 挂在 MaterialApp 与 Navigator 之间：门控期间无路由内容，
      // ready 后放行 child 并持有桥层事件流监听
      builder: (context, child) => BootGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
