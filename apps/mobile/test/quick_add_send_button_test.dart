// 快速添加发送钮的可用态必须由按钮自己订阅 controller
//
// 回归锚点（2026-11-08）：面板原先在 `OrbitTextField.onChanged` 里
// `setState(() {})`，敲一个字就重建整面板（含玻璃壳与工具栏）。改成
// `ListenableBuilder(listenable: _titleController)` 后，若有人删掉订阅又
// 没有恢复 `onChanged`，这颗钮会永远停在置灰态——本用例就是拦这个的。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/quick_add_sheet.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('输入标题后发送钮立即可用（按钮自订阅，不靠整面板重建）', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
        child: orbitTestApp(
          home: const SubListScreen(
            query: TaskFilterInput(quickView: QuickViewKey.all),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    showQuickAddSheet(tester.element(find.byType(SubListScreen)));
    await tester.pumpAndSettle();

    InkWell sendInk() => tester.widget<InkWell>(
      find
          .ancestor(
            of: find.byIcon(OrbitIcons.send),
            matching: find.byType(InkWell),
          )
          .first,
    );

    expect(sendInk().onTap, isNull, reason: '空标题时发送钮必须置灰不可点');

    await tester.enterText(find.byType(TextField).first, '写周报');
    await tester.pump();

    expect(
      sendInk().onTap,
      isNotNull,
      reason: '输入后按钮必须自己变可用（订阅丢了就会一直置灰）',
    );
  });
}
