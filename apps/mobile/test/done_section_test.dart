// 已完成折叠卡（2026-09-23 列表版式改写）：完成行不再由页头 eye 开关整体
// 隐藏，而是收进列表尾部的独立卡片（竞品列表页版式）。
// - 默认收起（等价改版前「默认隐藏已完成」的观感），只出头行「已完成 N ⌄」；
// - 点头行展开 → 完成行内联进卡（完成时刻倒序），再点收起；
// - 页头只有 ⋮ 溢出菜单，不再有 eye 开关；
// - 展开态持久化在 LocalPrefs 新键，旧键 `todo_hide_done` 只作一次性回落；
// - manual 重排档下卡挂 footer：完成行不与可拖行混排。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/services/local_prefs.dart';

import 'support/orbit_test_app.dart';

/// mock 种子里的完成行（见 `mock_store.dart`）
const _doneTitle = '已完成的周报提交';

/// 新键（展开态）/ 旧键（eye 开关时代的「隐藏已完成」）
const _openKey = 'todo_done_section_open';
const _legacyKey = 'todo_hide_done';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(
        home: const SubListScreen(
          query: TaskFilterInput(quickView: QuickViewKey.all),
        ),
      ),
    );

Future<void> _pumpList(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(_wrap(bridge));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    // 两个键都清回「从未设置过」（setString 空串即删键）——否则残留的新键会让
    // 旧键回落用例失效（新键一存在，回落分支就不会走）。内存态同步生效，
    // 写盘在测试环境必失败且不阻断，故不 await。
    unawaited(LocalPrefs.setString(_openKey, ''));
    unawaited(LocalPrefs.setString(_legacyKey, ''));
  });

  testWidgets('默认收起：只出头行计数，完成行不进列表', (tester) async {
    await _pumpList(tester, MockOrbitBridge());

    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: '头行计数 = 完成行数');
    expect(find.text(_doneTitle), findsNothing);
    expect(find.byIcon(OrbitIcons.expandMore), findsOneWidget);

    // 页头收敛成 ⋮：eye 开关已由折叠卡承接
    expect(find.byIcon(OrbitIcons.eye), findsNothing);
    expect(find.byTooltip('更多操作'), findsOneWidget);
  });

  testWidgets('点头行展开：完成行内联进卡，再点收起', (tester) async {
    await _pumpList(tester, MockOrbitBridge());
    expect(find.text(_doneTitle), findsNothing);

    await tester.tap(find.text('已完成'));
    await tester.pumpAndSettle();

    expect(find.text(_doneTitle), findsOneWidget);
    expect(find.byIcon(OrbitIcons.expandLess), findsOneWidget);
    // 展开态落本机偏好（下次进入沿用）
    expect(LocalPrefs.getBool(_openKey, fallback: false), isTrue);

    await tester.tap(find.text('已完成'));
    await tester.pumpAndSettle();

    expect(find.text(_doneTitle), findsNothing);
    expect(LocalPrefs.getBool(_openKey, fallback: false), isFalse);
  });

  testWidgets('旧键回落：上次把已完成显出来过，首次进入即展开', (tester) async {
    // 老用户偏好的迁移口径：hideDone=false（当时是「显示已完成」）→ 本次展开；
    // 前提是新键从未写过（tearDown 已清空）。
    //
    // **不 await**：testWidgets 的假时钟下平台通道响应（测试环境无 path_provider
    // → 写盘必失败）不走真实事件循环，await 会挂死整场用例；LocalPrefs 的内存态
    // 在 await 之前就已写入，fire-and-forget 足够驱动这条断言。
    unawaited(LocalPrefs.setBool(_legacyKey, false));

    await _pumpList(tester, MockOrbitBridge());

    expect(find.text(_doneTitle), findsOneWidget);
  });

  testWidgets('manual 重排档：已完成卡挂 footer，完成行不与可拖行混排', (tester) async {
    await _pumpList(tester, MockOrbitBridge());
    expect(find.byType(ReorderableListView), findsOneWidget);

    await tester.tap(find.text('已完成'));
    await tester.pumpAndSettle();
    expect(find.text(_doneTitle), findsOneWidget);

    // 完成行不在可拖列表内（footer 承载）：它没有拾起监听器
    expect(
      find.ancestor(
        of: find.text(_doneTitle),
        matching: find.byType(ReorderableDelayedDragStartListener),
      ),
      findsNothing,
    );
  });
}
