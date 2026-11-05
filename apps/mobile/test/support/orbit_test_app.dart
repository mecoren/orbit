import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/core/theme/app_theme.dart';
import 'package:orbit/core/theme/miuix_theme.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_tile.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_select_popup.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_toast.dart';

/// 测试用应用壳：与 `lib/app.dart` 的根装配同构（MaterialApp + MiuixTheme
/// + OrbitToastHost，见 [_orbitRootLayers]）。
///
/// **为什么测试也必须包这几层**：设计系统 v3 的轻提示（`WaitToast`）依赖
/// 根部挂载的 [OrbitToastHost]（全局 miuix Snackbar 队列）；`MiuixCard` /
/// `MiuixButton` / `MiuixInfiniteProgressIndicator` / OS4 玻璃组件靠
/// `MiuixTheme.of(context)` 取色（未命中回退浅色默认值，会与 token 漂移）。
/// 缺了任何一层都不是"样式不同"而是直接断言失败或配色错位。测试壳与生产壳
/// 同构，才能让同名断言继续有效。
///
/// 同时提供 [navigatorKey]（沿用 `rootNavigatorKey`）：服务层仍经全局
/// Navigator 取 context，测试与生产必须指向同一个 key。
Widget orbitTestApp({
  required Widget home,
  Brightness brightness = Brightness.light,
  Locale? locale,
}) => MaterialApp(
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

/// 路由形态的测试壳（GoRouter 用）：与 [orbitTestApp] 同构。
Widget orbitTestAppRouter({
  required RouterConfig<Object> routerConfig,
  Brightness brightness = Brightness.light,
}) => MaterialApp.router(
  routerConfig: routerConfig,
  debugShowCheckedModeBanner: false,
  theme: buildAppTheme(brightness: brightness),
  builder: (context, child) => _orbitRootLayers(
    brightness: brightness,
    child: child ?? const SizedBox.shrink(),
  ),
);

/// 浮层根装配（`lib/app.dart` 同款）：MiuixTheme（HyperOS 组件取色）
/// → 路由内容 + 全局 toast 宿主（浮层，原 ShadcnLayer 的层级语义）。
///
/// 2026-11-01 起移动端组件面全量 Miuix 化，shadcn_flutter 退为图标字体源，
/// ShadcnLayer / DrawerOverlay / destructive 组件主题整层移除（同批生产壳）。
Widget _orbitRootLayers({
  required Widget child,
  required Brightness brightness,
}) => OrbitMiuixTheme(
  brightness: brightness,
  child: Stack(
    children: [
      child,
      const Positioned.fill(child: OrbitToastHost()),
    ],
  ),
);

/// 单选浮层（OS4 玻璃菜单）finder
///
/// 2026-11-03 起单选不再走底部抽屉：`showSelectBottomSheet` 内部改为
/// OS4 玻璃锚定浮层（`orbit_select_popup.dart`）。测试要限定「弹层内的选项
/// 文本/选中态」时用本 finder，不要再用 `find.byType(BottomSheet)`——那是
/// 确认/更多操作/表单抽屉的承载。
Finder selectPopup() => find.byKey(orbitSelectPopupKey);

/// 下拉偏好行的玻璃面板 finder（`OrbitDropdownTile` 展开后库内
/// `MiuixGlassDropdownPopup` 的内容节点）
Finder dropdownPopup() => find.byKey(orbitDropdownPopupKey);

/// 下拉偏好行（[OrbitDropdownPreference]）展开后的弹层选项行 finder
///
/// 2026-11-05 起弹层与「今天」页头 ⋮ 菜单同一套承载：条目是
/// `MiuixGlassPopupItem`，挂在 [orbitDropdownPopupKey] 内容节点里（弹层
/// 收起后节点随 OverlayPortal 移除）。
Finder dropdownPreferencePopupRows() => find.descendant(
  of: dropdownPopup(),
  matching: find.byType(MiuixGlassPopupItem),
);

/// 下拉偏好弹层里打勾的条目文案
///
/// 行是 `MiuixGlassPopupItem`，选中态在 `selected` 上（勾本身是图标，
/// 直接按 icon 数断言拿不到），故读行数据。
Iterable<String> selectedDropdownPreferenceLabels(WidgetTester tester) => tester
    .widgetList<MiuixGlassPopupItem>(dropdownPreferencePopupRows())
    .where((row) => row.selected)
    .map((row) => row.text);

/// 下拉面板里打勾的条目文案
///
/// 行是 miuix 的 `MiuixGlassPopupItem`，选中态在 `selected` 上（勾本身是
/// 图标，直接按 icon 数断言拿不到），故读行数据。
Iterable<String> selectedDropdownLabels(WidgetTester tester) => tester
    .widgetList<MiuixGlassPopupItem>(
      find.descendant(
        of: dropdownPopup(),
        matching: find.byType(MiuixGlassPopupItem),
      ),
    )
    .where((row) => row.selected)
    .map((row) => row.text);

/// 单选浮层里打勾的条目文案
///
/// 行是 miuix 的 `MiuixGlassPopupItem`（与 ⋮ 菜单同款），选中态在
/// `selected` 上（勾本身是图标，直接按 icon 数断言拿不到），故读行数据。
/// 限定在浮层内找，避免页面其它下拉/菜单的同型行混入。
Iterable<String> selectedPopupLabels(WidgetTester tester) => tester
    .widgetList<MiuixGlassPopupItem>(
      find.descendant(
        of: selectPopup(),
        matching: find.byType(MiuixGlassPopupItem),
      ),
    )
    .where((row) => row.selected)
    .map((row) => row.text);

/// 收尾：推掉 toast 的停留计时器与残留动画，并清空全局队列。
///
/// **为什么必须显式收尾**：测试壳与生产壳同构后（`navigatorKey` 指向
/// `rootNavigatorKey`），页面里的 `WaitToast` 会**真的插入浮层**；有限停留
/// 档在宿主条目内落成 `Timer`，用例若在它触发前结束，就会命中 flutter_test
/// 的「A Timer is still pending」断言。
///
/// [holdForever] = true 用于「不自动收」的 toast（旧 `WaitToast.holdForever`
/// 档，新承载用 indefinite 表达、无 Timer，推它无害），其余（纯提示 /
/// 撤销类）推 [WaitToast.undoDwell] 即可覆盖最长有限档。
///
/// 最后的 [WaitToast.debugFlushForTest]：miuix 宿主状态是**静态跨用例存活**
/// 的，把仍可见的条目全部撤下并让退场动画走完、条目出队，否则上一用例的
/// toast 文案会浮进下一用例的 find 断言。
Future<void> drainToastTimers(
  WidgetTester tester, {
  bool holdForever = false,
}) async {
  await tester.pump(holdForever ? WaitToast.holdForever : WaitToast.undoDwell);
  await tester.pump(const Duration(milliseconds: 500));
  await WaitToast.debugFlushForTest();
  await tester.pumpAndSettle();
}
