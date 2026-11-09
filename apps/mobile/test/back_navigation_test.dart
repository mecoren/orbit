// 返回行为回归：生产路由表 + MockOrbitBridge + 真实系统返回事件
// （tester.binding.handlePopRoute，即返回键 / 手势返回同一入口）。
//
// 判定口径：每次返回回到上一个操作页面；仅当页级历史为空、无弹层、且位于
// 分支根页时，才放行给 Flutter 框架 SystemNavigator.pop() 退系统桌面。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/routing/app_router.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/calendar_screen.dart';
import 'package:orbit/modules/todo/detail_screen.dart';
import 'package:orbit/modules/todo/matrix_screen.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/services/local_prefs.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_bottom_nav.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_panel.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_fab.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
  overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
  child: orbitTestAppRouter(routerConfig: appRouter),
);

MockOrbitBridge _bridge() => MockOrbitBridge();

Future<void> _pump(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(_wrap(bridge));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  // 生产路由是全局单例：上一个用例可能停在别的页签/子页，统一回启动首页
  appRouter.go('/today');
  await tester.pumpAndSettle();
}

/// 系统返回键 / 手势返回（走真实 WidgetsBinding.handlePopRoute 链路）
Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Finder _navIcon(IconData icon) => find.descendant(
  of: find.byType(OrbitBottomNav),
  matching: find.byIcon(icon),
);

Future<void> _tapTab(WidgetTester tester, IconData icon) async {
  await tester.tap(_navIcon(icon));
  await tester.pumpAndSettle();
}

bool _moreMenuOpen(WidgetTester tester) => tester
    .widgetList<MiuixGlassTransformPopup>(find.byType(MiuixGlassTransformPopup))
    .any((popup) => popup.show);

void main() {
  late int popToDesktop;

  setUp(() {
    LocalPrefs.resetForTest();
    popToDesktop = 0;
    // 框架在无人消费返回事件时调 SystemNavigator.pop()；测试里拦下平台调用
    // 计数，才能断言「无上一页 → 退系统桌面」而非页面白屏 / 测试报错。
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') popToDesktop++;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('无上一个页面：按返回交框架退系统桌面，仍停在启动首页', (tester) async {
    await _pump(tester, _bridge());

    expect(find.text('今天'), findsOneWidget);
    await _back(tester);

    expect(popToDesktop, 1);
    expect(find.text('今天'), findsOneWidget);
  });

  testWidgets('A→B→C 连续三次返回依次到 B→A→首页，第四次退系统桌面', (tester) async {
    await _pump(tester, _bridge());

    await _tapTab(tester, OrbitIcons.list);
    await _tapTab(tester, OrbitIcons.calendarDays);
    await _tapTab(tester, OrbitIcons.grid);
    expect(find.byType(MatrixScreen), findsOneWidget);

    await _back(tester);
    expect(find.byType(CalendarScreen), findsOneWidget);
    expect(popToDesktop, 0);

    await _back(tester);
    expect(find.byType(SidebarScreen), findsOneWidget);
    expect(popToDesktop, 0);

    await _back(tester);
    expect(find.text('今天'), findsOneWidget);
    expect(popToDesktop, 0);

    await _back(tester);
    expect(popToDesktop, 1);
  });

  testWidgets('分支根页按历史长出返回箭头，点击回进站前的模块', (tester) async {
    await _pump(tester, _bridge());
    // 冷启动无历史：启动首页不渲染返回箭头
    expect(find.byTooltip('返回'), findsNothing);

    await _tapTab(tester, OrbitIcons.list);
    await tester.tap(_navIcon(OrbitIcons.more));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(OrbitDropdownPanelView),
        matching: find.text('统计'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('总任务'), findsOneWidget);

    expect(find.byTooltip('返回'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.byType(SidebarScreen), findsOneWidget);
    expect(popToDesktop, 0);
  });

  testWidgets('「更多」面板展开时首次返回只关面板，第二次才退系统桌面', (tester) async {
    await _pump(tester, _bridge());

    await tester.tap(_navIcon(OrbitIcons.more));
    await tester.pumpAndSettle();
    expect(_moreMenuOpen(tester), isTrue);
    expect(find.byType(OrbitDropdownPanelView), findsOneWidget);

    await _back(tester);
    expect(_moreMenuOpen(tester), isFalse);
    expect(find.text('今天'), findsOneWidget);
    expect(popToDesktop, 0);

    await _back(tester);
    expect(popToDesktop, 1);
  });

  testWidgets('根级推入页优先由 go_router 原生栈 pop，不误触壳层模块回退', (tester) async {
    await _pump(tester, _bridge());
    await _tapTab(tester, OrbitIcons.list); // 历史 [今天, 清单]

    await tester.tap(_navIcon(OrbitIcons.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('功能模块'), findsOneWidget);

    await _back(tester);
    expect(find.text('功能模块'), findsNothing);
    expect(find.byType(SidebarScreen), findsOneWidget);
    expect(popToDesktop, 0);

    // 推入页退完后，下一次返回才按页级历史回「今天」
    await _back(tester);
    expect(find.text('今天'), findsOneWidget);
    expect(popToDesktop, 0);
  });

  testWidgets('快速连点三次返回逐层回退、不越级也不重复退桌面', (tester) async {
    await _pump(tester, _bridge());
    await _tapTab(tester, OrbitIcons.list);
    await _tapTab(tester, OrbitIcons.calendarDays);
    await _tapTab(tester, OrbitIcons.grid);

    for (var i = 0; i < 3; i++) {
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    expect(find.text('今天'), findsOneWidget);
    expect(popToDesktop, 0);
  });

  testWidgets('底部表单打开时返回只关弹层，不回退模块也不退桌面', (tester) async {
    await _pump(tester, _bridge());
    await _tapTab(tester, OrbitIcons.list); // 历史 [今天, 清单]

    await tester.tap(find.byType(OrbitFab));
    await tester.pumpAndSettle();
    expect(find.text('准备做什么？'), findsOneWidget);

    await _back(tester);
    expect(find.text('准备做什么？'), findsNothing);
    expect(find.byType(SidebarScreen), findsOneWidget);
    expect(popToDesktop, 0);

    // 弹层关完再返回才按页级历史回「今天」
    await _back(tester);
    expect(find.text('今天'), findsOneWidget);
    expect(popToDesktop, 0);
  });

  testWidgets('清单分支根（带自定义 leading）仍显示返回箭头', (tester) async {
    await _pump(tester, _bridge());
    expect(find.byTooltip('返回'), findsNothing);

    await _tapTab(tester, OrbitIcons.list);
    expect(find.byType(SidebarScreen), findsOneWidget);
    // 清单页头左侧是云同步状态钮，不能因此吞掉返回入口
    expect(find.byTooltip('返回'), findsOneWidget);
  });

  testWidgets('分支内 push 页 + 「更多」菜单：首次返回只关菜单、不 pop 子页', (tester) async {
    await _pump(tester, _bridge());
    await _tapTab(tester, OrbitIcons.list);
    appRouter.push('/todo/tasks?view=all');
    await tester.pumpAndSettle();
    expect(find.byType(SubListScreen), findsOneWidget);

    await tester.tap(_navIcon(OrbitIcons.more));
    await tester.pumpAndSettle();
    expect(_moreMenuOpen(tester), isTrue);

    await _back(tester);
    // 菜单关掉，页栈不动：仍在 /todo/tasks 子页
    expect(_moreMenuOpen(tester), isFalse);
    expect(find.byType(SubListScreen), findsOneWidget);
    expect(popToDesktop, 0);

    // 再返回才由 go_router 原生栈 pop 掉子页
    await _back(tester);
    expect(find.byType(SidebarScreen), findsOneWidget);
    expect(popToDesktop, 0);
  });

  testWidgets('「今天 ▾」视图菜单打开时返回只关菜单，不退系统桌面', (tester) async {
    await _pump(tester, _bridge());

    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    expect(find.text('近7天'), findsOneWidget);

    await _back(tester);
    expect(find.text('近7天'), findsNothing);
    expect(find.text('今天'), findsOneWidget);
    expect(popToDesktop, 0);

    await _back(tester);
    expect(popToDesktop, 1);
  });

  testWidgets('启动门控期（解锁/白屏）按返回：无上一页，交框架退系统桌面', (tester) async {
    // BootGate 挂在 MaterialApp.router 的 builder 上、位于 Navigator 之上，
    // 门控期不渲染任何路由内容；此时不存在「上一个操作页面」，返回必须交
    // 框架默认，而不是被门控层吞掉（门控层刻意不挂 PopScope）。
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: Text('解锁页')),
        builder: (context, child) => child ?? const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();

    await _back(tester);
    expect(popToDesktop, 1);
    expect(find.text('解锁页'), findsOneWidget);
  });

  testWidgets('关于 → 开源组件列表 → 详情：返回逐层回关于页', (tester) async {
    await _pump(tester, _bridge());

    appRouter.push('/about');
    await tester.pumpAndSettle();
    expect(find.text('关于'), findsOneWidget);

    appRouter.push('/about/oss-components');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('开源组件'), findsOneWidget);

    appRouter.push(
      '/about/oss-components/detail?name=${Uri.encodeQueryComponent('@scope/demo')}',
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('组件详情'), findsOneWidget);

    await _back(tester); // 详情 → 列表
    expect(find.text('开源组件'), findsOneWidget);
    expect(find.text('组件详情'), findsNothing);

    await _back(tester); // 列表 → 关于
    expect(find.text('关于'), findsOneWidget);

    await _back(tester); // 关于 → 启动首页
    expect(find.text('今天'), findsOneWidget);
    expect(popToDesktop, 0);
  });

  testWidgets('外部直达子页（通知/小组件冷启动）：返回回首页，再返回退桌面', (tester) async {
    final bridge = _bridge();
    await _pump(tester, bridge);

    // 与 BootGate._pushTaskDetail 同口径：根 Navigator push 详情
    appRouter.push('/todo/5');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsOneWidget);

    await _back(tester);
    expect(find.byType(DetailScreen), findsNothing);
    expect(find.text('今天'), findsOneWidget);
    expect(popToDesktop, 0);

    await _back(tester);
    expect(popToDesktop, 1);
  });
}
