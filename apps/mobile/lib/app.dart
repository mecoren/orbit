import 'package:flutter/material.dart';

import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/miuix_theme.dart';
import 'modules/shell/boot_gate.dart';
import 'services/appearance.dart';
import 'shared/widgets/shadcn/orbit_toast.dart';

/// OrbitApp — MaterialApp + MiuixTheme 双主题装配（设计系统 v3）
///
/// 主题模式三态（theme_mode：system/light/dark）+ 字号/字重档
/// 全走 LocalPrefs（services/appearance.dart），写后经
/// Appearance.revision 重建根部即时生效。
///
/// **主题体系（2026-11-01 起，移动端组件全量 Miuix 化后收口为双主题）**：
/// - Material 侧 [buildAppTheme] 继续喂 `MaterialApp`——`Scaffold`、
///   `showModalBottomSheet`、`TextField` 输入基建、文本选择、滚动条等
///   Material 设施仍按 token 着色（保留清单见 `docs/16`）；
/// - Miuix 侧 [OrbitMiuixTheme] 提供 `MiuixTheme`——按钮、卡片、勾选、
///   开关、进度、Snackbar、下拉刷新与 OS4 玻璃导航/页头/悬浮钮等 HyperOS
///   组件读它取色。两者都从 `core/theme` 同一份 token 派生（角色映射见
///   `miuix_theme.dart`），不存在"色板漂移"。
/// - **shadcn_flutter 退为图标字体源**：此前挂在本层的 `ShadcnLayer`
///   （ToastLayer / OverlayManagerLayer / DrawerOverlay / destructive
///   组件主题）只服务 sh.* 组件，随组件面全部换 Miuix 后已整层移除；
///   该依赖仅剩 `core/theme/icon_map.dart` 的 `LucideIcons`（与桌面端
///   lucide-react 同套线性图标，跨端一致性），不再参与任何主题装配。
///
/// 启动门控经 builder 包裹主路由：masterAuthHas? 解锁页 : 明文库直入，
/// ready 前不渲染任何路由内容。
///
/// **字号档为什么走全局 TextScaler 而不是 TextTheme**：仓库里近 300 处内联
/// `TextStyle(fontSize:)` 不经过 `ThemeData.textTheme`，只缩放 textTheme
/// 会让字号档在绝大多数文本上失效（历史遗留：外观页字号档几乎无感）。
/// 故改为在 builder 顶部注入 `MediaQuery.textScaler`——Text 绘制时统一乘一次，
/// 内联字号与 textTheme 一视同仁，同时无需逐处迁移内联样式。
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
            baseWeight: weight,
          ),
          darkTheme: buildAppTheme(
            brightness: Brightness.dark,
            baseWeight: weight,
          ),
          themeMode: mode,
          routerConfig: appRouter,
          builder: (context, child) {
            final content = OrbitMiuixTheme(
              brightness: _resolveBrightness(context, mode),
              baseWeight: weight,
              child: Stack(
                children: [
                  // BootGate 挂在 Navigator 之上：门控期间无路由内容，
                  // ready 后放行 child 并持有桥层事件流监听
                  BootGate(child: child ?? const SizedBox.shrink()),
                  // 全局 toast 宿主：浮在路由内容之上（原 ShadcnLayer
                  // ToastLayer 的层级语义）；空队列时整层不挡手势
                  const Positioned.fill(child: OrbitToastHost()),
                ],
              ),
            );

            // 字号档（小 0.9 / 标准 1.0 / 大 1.15）以 MediaQuery 注入：
            // 标准档不覆写，原样保留系统（无障碍）字号缩放；其余档在系统缩放比
            // 之上再乘一次，两者可叠加而非互相顶替。
            final scaler = _appearanceTextScaler(context, scale);
            if (scaler == null) return content;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: scaler),
              child: content,
            );
          },
        );
      },
    );
  }
}

/// 外观字号档 → 待注入的 [TextScaler]（null = 不覆写）
///
/// 标准档（1.0）返回 null，原样保留系统的 `SystemTextScaler`——系统无障碍
/// 字号设置不能被外观偏好顶掉；小/大档在**系统缩放比之上**再乘一次
/// （`scale(1.0)` 取系统当前等效倍数），两者叠加而非互相替换。
TextScaler? _appearanceTextScaler(BuildContext context, double scale) {
  if (scale == 1.0) return null;
  return TextScaler.linear(MediaQuery.textScalerOf(context).scale(1.0) * scale);
}

/// 外观三态 + 系统亮度 → 实际 [Brightness]（Miuix 主题层用）
///
/// Miuix 的 `MiuixThemeData` 只吃具体亮度（没有 system 档），故在此把
/// `ThemeMode.system` 解析成 `MediaQuery.platformBrightnessOf`。
Brightness _resolveBrightness(BuildContext context, ThemeMode mode) =>
    switch (mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
