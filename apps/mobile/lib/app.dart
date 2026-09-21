import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/shadcn_theme.dart';
import 'modules/shell/boot_gate.dart';
import 'services/appearance.dart';

/// OrbitApp — MaterialApp + ShadcnLayer 装配（设计系统 v3）
///
/// 主题模式三态（theme_mode：system/light/dark）+ 字号/字重档
/// 全走 LocalPrefs（services/appearance.dart），写后经
/// Appearance.revision 重建根部即时生效。
///
/// **双主题并存（有意为之）**：
/// - Material 侧 [buildAppTheme] 继续喂 `MaterialApp`——`Scaffold`、
///   `showModalBottomSheet`、文本选择、滚动条等 Material 设施仍按 token 着色，
///   未迁移的页面不会观感割裂；
/// - shadcn 侧 [buildShadcnTheme] 喂 [sh.ShadcnLayer]——由 `core/theme` 同一份
///   token 派生，两套主题数值同源，因此不存在"色板漂移"。
///
/// **接入方式为什么是 ShadcnLayer 而不是 ShadcnApp**：`ShadcnApp` 自带
/// `WidgetsApp`，会与 `MaterialApp` 形成双 Navigator/Overlay；且在锁定工具链
/// （Flutter 3.44.2）上 `shadcn_flutter_material`（`MaterialShadcnApp` 所在包）
/// 无法解析。`ShadcnLayer` 包在 `MaterialApp.builder` 中位于 Navigator 之上，
/// 是 shadcn 官方对「已有 MaterialApp」场景的推荐接法，
/// 浮层（Sheet/Popover/Toast）定位依赖它。
///
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
          builder: (context, child) => sh.ShadcnLayer(
            theme: buildShadcnTheme(
              brightness: Brightness.light,
              fontScale: scale,
              baseWeight: weight,
            ),
            darkTheme: buildShadcnTheme(
              brightness: Brightness.dark,
              fontScale: scale,
              baseWeight: weight,
            ),
            themeMode: _shadcnThemeMode(mode),
            // 关闭 shadcn 的移动端 1.25× 自动放大：仓库 token（字号阶梯 /
            // AppShapes 圆角 / AppDimens 触控尺寸）已按移动端标定，再乘一次会让
            // 圆角与字号双双漂移。触控尺寸由 shared/widgets/shadcn/ 原语用
            // AppDimens.touchTarget 显式保证。
            scaling: sh.AdaptiveScaling.desktop,
            // DrawerOverlay 是 SheetConfiguration 系弹层的落点（`orbit_sheets.dart`
            // 三个共享弹层 = 确认/单选/更多操作，全站 50+ 调用点走 showOverlay）。
            // shadcn 只在**自家的** Scaffold 内挂这一层（`scaffold.dart` 的
            // _buildContent），本项目页面用 Material Scaffold，所以必须在根部统一
            // 挂一次——缺了不是样式差异，是 `openRawDrawer` 直接断言
            // 「No DrawerOverlay found in the widget tree」整屏红。
            // 挂在 ShadcnLayer 之内、Navigator 之上：页面 context 向上能查到这里，
            // InheritedTheme/Data 的 capture 也以这一层为终点。
            child: sh.DrawerOverlay(
              // BootGate 挂在 shadcn 层与 Navigator 之间：门控期间无路由内容，
              // ready 后放行 child 并持有桥层事件流监听
              child: BootGate(child: child ?? const SizedBox.shrink()),
            ),
          ),
        );
      },
    );
  }
}

/// Material 的 ThemeMode → shadcn 的 ThemeMode
///
/// shadcn_flutter 自带一个**同名不同源**的 `ThemeMode`
/// （`shadcn_flutter/src/theme/theme.dart`），三个枚举值与 Material 完全一致，
/// 但类型不同不能直接赋值，需显式转换。
sh.ThemeMode _shadcnThemeMode(ThemeMode mode) => switch (mode) {
      ThemeMode.light => sh.ThemeMode.light,
      ThemeMode.dark => sh.ThemeMode.dark,
      ThemeMode.system => sh.ThemeMode.system,
    };
