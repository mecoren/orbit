import 'package:flutter/material.dart';

import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'modules/shell/boot_gate.dart';
import 'services/appearance.dart';

/// OrbitApp — MaterialApp 装配
///
/// 主题模式三态（theme_mode：system/light/dark）+ 字号/字重档
/// 全走 LocalPrefs（services/appearance.dart），写后经
/// Appearance.revision 重建 MaterialApp 即时生效；
/// 主题由 [buildAppTheme] 工厂生成（wait-home 同款 M3 + 固定表面角色）。
/// 启动门控经 builder 包裹主路由：masterAuthHas? 解锁页 : 明文库直入，
/// ready 前不渲染任何路由内容。
class OrbitApp extends StatelessWidget {
  const OrbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: Appearance.revision,
      builder: (context, value, cacheChild) {
        final mode = Appearance.themeMode();
        final scale = Appearance.fontScale();
        final weight = Appearance.fontWeight();
        return MaterialApp.router(
          title: '循迹',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            fontScale: scale,
            baseWeight: weight,
          ),
          darkTheme: buildAppTheme(
            brightness: Brightness.dark,
            fontScale: scale,
            baseWeight: weight,
          ),
          themeMode: mode,
          routerConfig: appRouter,
          // BootGate 挂在 MaterialApp 与 Navigator 之间：门控期间无路由内容，
          // ready 后放行 child 并持有桥层事件流监听
          builder: (context, child) =>
              BootGate(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
