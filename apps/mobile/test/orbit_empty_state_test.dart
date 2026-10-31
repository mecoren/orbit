// 空态主行动按钮（CTA）口径：
// actionLabel / onAction 全可选——不传必须与旧版逐字一致（只有图标 + 文案），
// 传了才多一个描边按钮（原语层 OrbitButton.outline，承载 = flutter_miuix
// MiuixButton，HyperOS squircle 形态）。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_button.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_empty_state.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('无 CTA：只渲染图标与文案，不出现按钮', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: EmptyState(message: '空空如也')),
    ));

    expect(find.text('空空如也'), findsOneWidget);
    expect(find.byType(OrbitButton), findsNothing);
  });

  testWidgets('有 CTA：渲染描边按钮，点击触发回调', (tester) async {
    var tapped = false;
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: EmptyState(
          message: '还没有任务',
          actionLabel: '新建任务',
          onAction: () => tapped = true,
        ),
      ),
    ));

    expect(find.byType(OrbitButton), findsOneWidget);
    expect(find.text('新建任务'), findsOneWidget);
    // 承载换成 MiuixButton（squircle 圆角 + 按压反馈）
    expect(find.byType(MiuixButton), findsOneWidget);

    await tester.tap(find.byType(OrbitButton));
    expect(tapped, isTrue, reason: 'CTA 点击必须透传到 onAction');
  });
}
