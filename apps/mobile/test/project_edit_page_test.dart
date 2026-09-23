// 「编辑项目」整页（2026-09-23：由编辑项目对话框升级为整页）：
// - 名称行预填 + 两段卡片（清单颜色 / 视图类型）；
// - 颜色行 = 无颜色 + 10 色预设 + 自定义（彩虹）；
// - 视图类型三档，选中写入「每项目视图档」（本地偏好，不动 DDL）；
// - 保存写库并返回上一页；空标题拒绝保存；⋮ 更多 = 归档 / 删除（删除走保护流）。
//
// 页面内部用 `context.pop()` / `context.go()`，故测试壳必须有 GoRouter 祖先
// （`orbitTestApp` 的 home 直挂没有路由，点了保存会直接抛
// 「No GoRouter found in context」）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/view_mode.dart';
import 'package:orbit/modules/todo/project_edit_page.dart';
import 'package:orbit/services/local_prefs.dart';
import 'package:orbit/shared/utils/hex_color.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge, int projectId) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => context.push('/edit'),
              child: const Text('返回页'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/edit',
        builder: (_, _) => ProjectEditPage(projectId: projectId),
      ),
    ],
  );
  return ProviderScope(
    overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
    child: orbitTestAppRouter(routerConfig: router),
  );
}

int _projectId(MockOrbitBridge bridge, String title) => bridge.store.projects
    .values
    .firstWhere((p) => p['title'] == title)['id'] as int;

/// 首页 → push 编辑页（pop 才有去处；直接以编辑页为 initialLocation 会
/// 「There is nothing to pop」）
Future<void> _pump(WidgetTester tester, MockOrbitBridge bridge, int id) async {
  await tester.pumpWidget(_wrap(bridge, id));
  await tester.pumpAndSettle();
  await tester.tap(find.text('返回页'));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 色板里指定色值的圆点
Finder _dotOf(String hex) => find.byWidgetPredicate((w) =>
    w is Container &&
    w.decoration is BoxDecoration &&
    (w.decoration as BoxDecoration).shape == BoxShape.circle &&
    (w.decoration as BoxDecoration).color == hexToColor(hex));

/// 保存并越过 MockOrbitBridge 的人为延迟
Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byTooltip('保存'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('渲染：名称预填 + 清单颜色 + 视图类型三档', (tester) async {
    final bridge = MockOrbitBridge();
    final id = _projectId(bridge, '工作');
    await _pump(tester, bridge, id);

    expect(find.text('编辑项目'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '工作');
    expect(find.text('清单颜色'), findsOneWidget);
    expect(find.text('视图类型'), findsOneWidget);
    for (final label in ['列表视图', '看板视图', '表格视图']) {
      expect(find.text(label), findsOneWidget);
    }
    // 颜色行：无颜色（斜杠圆）+ 10 色预设 + 自定义（彩虹）
    expect(find.byIcon(OrbitIcons.noColor), findsOneWidget);
    expect(_dotOf('#EF4444'), findsOneWidget);
    expect(_dotOf('#6B7280'), findsOneWidget);
  });

  testWidgets('改色 + 保存：写库并返回上一页', (tester) async {
    final bridge = MockOrbitBridge();
    final id = _projectId(bridge, '工作');
    await _pump(tester, bridge, id);

    await tester.tap(_dotOf('#EF4444'));
    await tester.pumpAndSettle();
    await _save(tester);

    expect(bridge.store.projects[id]!['hex_color'], '#EF4444');
    // 保存后 pop：编辑页已不在树上（下层的「返回页」是常驻的栈底路由，
    // 不能拿它当判据）
    expect(find.text('编辑项目'), findsNothing);
  });

  testWidgets('「无颜色」档：写空串（下游回落中性表现）', (tester) async {
    final bridge = MockOrbitBridge();
    final id = _projectId(bridge, '工作');
    await _pump(tester, bridge, id);

    await tester.tap(find.byIcon(OrbitIcons.noColor));
    await tester.pumpAndSettle();
    await _save(tester);

    expect(bridge.store.projects[id]!['hex_color'], '');
  });

  testWidgets('选「看板视图」+ 保存：写「每项目视图档」', (tester) async {
    final bridge = MockOrbitBridge();
    final id = _projectId(bridge, '工作');
    final key = projectViewModePrefsKey(id);
    addTearDown(() => unawaited(LocalPrefs.setString(key, '')));

    await _pump(tester, bridge, id);
    await tester.tap(find.text('看板视图'));
    await tester.pumpAndSettle();
    await _save(tester);

    expect(LocalPrefs.getString(key), 'kanban');
  });

  testWidgets('空标题拒绝保存：不写库也不返回', (tester) async {
    final bridge = MockOrbitBridge();
    final id = _projectId(bridge, '工作');
    await _pump(tester, bridge, id);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pumpAndSettle();
    await _save(tester);

    expect(bridge.store.projects[id]!['title'], '工作');
    expect(find.text('编辑项目'), findsOneWidget);
  });

  testWidgets('⋮ 更多：归档 / 删除入口；有未完成任务时删除走保护流', (tester) async {
    final bridge = MockOrbitBridge();
    final id = _projectId(bridge, '工作');
    await _pump(tester, bridge, id);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();

    expect(find.text('归档项目'), findsOneWidget);
    expect(find.text('删除项目'), findsOneWidget);

    await tester.tap(find.text('删除项目'));
    await tester.pumpAndSettle();

    // 「工作」下有未完成任务 → 删除保护流（单按钮信息抽屉）
    expect(find.text('无法删除'), findsOneWidget);
  });

  testWidgets('项目不存在（非法 id）：空态而非崩屏', (tester) async {
    final bridge = MockOrbitBridge();
    await _pump(tester, bridge, 999999);

    expect(find.text('项目不存在或已删除'), findsOneWidget);
  });
}
