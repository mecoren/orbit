// 下拉偏好行：共享锚定原语的玻璃卡、返回键与点选回调
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_preference.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_glass_surface.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('返回键先关菜单；点选立即回调并播回收', (tester) async {
    var picked = 30;
    var current = 30;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Center(
              child: OrbitDropdownPreference<int>(
                title: '保留时间',
                items: const [
                  SelectItem(value: 7, label: '7 天'),
                  SelectItem(value: 30, label: '30 天'),
                  SelectItem(value: 90, label: '90 天'),
                  SelectItem(value: 0, label: '永久'),
                ],
                current: current,
                onSelect: (v) {
                  picked = v;
                  setState(() => current = v);
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('保留时间'));
    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsOneWidget);
    expect(find.byType(MiuixGlassPanel), findsOneWidget);
    expect(find.byType(MiuixGlassDropdownPopup), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsNothing);
    expect(find.text('保留时间'), findsOneWidget);

    await tester.tap(find.text('保留时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 天'));
    await tester.pump();
    expect(picked, 7);
    expect(find.byKey(orbitDropdownPopupKey), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsNothing);
    expect(find.text('7 天'), findsOneWidget);
  });

  testWidgets('OrbitGlassPage 下弹层拿到背景采样器', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: OrbitGlassPage(
          child: Scaffold(
            body: Center(
              child: OrbitDropdownPreference<int>(
                title: '类型',
                items: const [
                  SelectItem(value: 0, label: '全部'),
                  SelectItem(value: 1, label: '到期'),
                ],
                current: 0,
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('类型'));
    await tester.pumpAndSettle();
    final popup = tester.widget<MiuixGlassDropdownPopup>(
      find.byType(MiuixGlassDropdownPopup),
    );
    expect(popup.backdrop, isNotNull, reason: '根级页必须能取到 OrbitGlassScope');
    expect(popup.backdrop!.snapshot, isNotNull, reason: '页面背景快照已就绪');
  });
}
