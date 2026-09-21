import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/core/theme/app_theme.dart';
import 'package:orbit/core/theme/shadcn_theme.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_toast.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

/// 测试用应用壳：与 `lib/app.dart` 的根装配同构（MaterialApp + ShadcnLayer
/// + DrawerOverlay，见 [_orbitRootLayers]）。
///
/// **为什么测试也必须包这两层**：设计系统 v3 的轻提示（`WaitToast` →
/// `showToast`）依赖 ShadcnLayer 注入的 `ToastLayer`；shadcn 的
/// `Tooltip`/`Sheet`/`Drawer` 系浮层依赖 `OverlayManagerLayer`（+ 根
/// `DrawerOverlay` 作落点，见 `orbit_sheets.dart` 的承载口径说明）。
/// 缺了任何一层都不是"样式不同"而是直接断言失败。测试壳与生产壳同构，
/// 才能让同名断言继续有效。
///
/// 同时提供 [navigatorKey]（沿用 `rootNavigatorKey`）：WaitToast 经全局 Navigator
/// 取 context，测试与生产必须指向同一个 key。
Widget orbitTestApp({
  required Widget home,
  Brightness brightness = Brightness.light,
  Locale? locale,
}) =>
    MaterialApp(
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: brightness),
      locale: locale,
      home: home,
      builder: (context, child) => _orbitRootLayers(
        brightness: brightness,
        child: child ?? const SizedBox.shrink(),
      ),
    );

/// 路由形态的测试壳（GoRouter 用）：与 [orbitTestApp] 同构，同样包浮层两层。
Widget orbitTestAppRouter({
  required RouterConfig<Object> routerConfig,
  Brightness brightness = Brightness.light,
}) =>
    MaterialApp.router(
      routerConfig: routerConfig,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: brightness),
      builder: (context, child) => _orbitRootLayers(
        brightness: brightness,
        child: child ?? const SizedBox.shrink(),
      ),
    );

/// 浮层根装配（`lib/app.dart` 同款）：ShadcnLayer（主题 + ToastLayer +
/// OverlayManagerLayer）→ DrawerOverlay（`SheetConfiguration` 弹层落点）。
Widget _orbitRootLayers({
  required Widget child,
  required Brightness brightness,
}) =>
    sh.ShadcnLayer(
      theme: buildShadcnTheme(brightness: brightness),
      scaling: sh.AdaptiveScaling.desktop,
      child: sh.DrawerOverlay(child: child),
    );

/// 收尾：推掉 shadcn toast 的停留计时器，并收敛残留动画。
///
/// **为什么必须显式收尾**：测试壳与生产壳同构后（`navigatorKey` 指向
/// `rootNavigatorKey`），页面里的 `WaitToast` 会**真的插入浮层**；而 shadcn
/// `showToast` 把停留时长落成库内 `Timer` 且在条目 dispose 时不取消——用例若在
/// 它触发前结束，就会命中 flutter_test 的「A Timer is still pending」断言。
///
/// [holdForever] = true 用于「不自动收」的 toast（`WaitToast.holdForever` 档），
/// 其余（纯提示 / 撤销类）推 [WaitToast.undoDwell] 即可覆盖最长有限档。
Future<void> drainToastTimers(
  WidgetTester tester, {
  bool holdForever = false,
}) async {
  await tester.pump(
    holdForever ? WaitToast.holdForever : WaitToast.undoDwell,
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}
