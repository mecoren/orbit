import 'package:flutter/material.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/core/theme/app_theme.dart';
import 'package:orbit/core/theme/shadcn_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

/// 测试用应用壳：与 `lib/app.dart` 的根装配同构（MaterialApp + ShadcnLayer）。
///
/// **为什么测试也必须包 ShadcnLayer**：设计系统 v3 的轻提示（`WaitToast` →
/// `showToast`）与三个共享弹层（`showOverlay` + `SheetConfiguration`）都依赖
/// ShadcnLayer 注入的 `ToastLayer` 与 `OverlayManagerLayer`；缺了它不是"样式不同"
/// 而是直接断言失败。测试壳与生产壳同构，才能让同名断言继续有效。
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
      builder: (context, child) => sh.ShadcnLayer(
        theme: buildShadcnTheme(brightness: brightness),
        scaling: sh.AdaptiveScaling.desktop,
        child: child ?? const SizedBox.shrink(),
      ),
    );
