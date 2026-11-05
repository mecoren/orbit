// 排程作息抽屉：Overlay 选档菜单的返回键与点选回填
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/plan_prefs_sheet.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_panel.dart';

import 'support/orbit_test_app.dart';

const _initial = DayPlanPrefs(
  workStartMinute: 480,
  workEndMinute: 1080,
  lunchStartMinute: 720,
  lunchEndMinute: 780,
  granularityMinutes: 15,
  defaultTaskMinutes: 30,
  includeOverdue: false,
);

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    orbitTestApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showPlanPrefsSheet(context, initial: _initial),
              child: const Text('开排程'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('开排程'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('返回键先关菜单、抽屉不退出；点选立即回填', (tester) async {
    await _openSheet(tester);
    expect(find.text('排程作息'), findsOneWidget);
    expect(find.text('08:00'), findsOneWidget);

    await tester.tap(find.text('工作开始'));
    await tester.pumpAndSettle();
    expect(find.byKey(orbitSelectPopupKey), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(orbitSelectPopupKey), findsNothing);
    expect(find.text('排程作息'), findsOneWidget);

    await tester.tap(find.text('工作开始'));
    await tester.pumpAndSettle();
    // 时间档列表从 00:00 起，08:00 当前档在滚动视口外；选首屏可见档即可
    await tester.tap(find.text('00:30'));
    await tester.pumpAndSettle();
    expect(find.byKey(orbitSelectPopupKey), findsNothing);
    expect(find.text('排程作息'), findsOneWidget);
    expect(find.text('00:30'), findsOneWidget);
  });
}
