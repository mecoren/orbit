// 空态主行动按钮（CTA）口径：
// actionLabel / onAction 全可选——不传必须与旧版逐字一致（只有图标 + 文案），
// 传了才多一个 OutlinedButton；按钮走主题的 outlinedButtonTheme，不是裸 TextButton。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_empty_state.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('无 CTA：只渲染图标与文案，不出现按钮', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: EmptyState(message: '空空如也')),
    ));

    expect(find.text('空空如也'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('有 CTA：渲染 OutlinedButton，点击触发回调', (tester) async {
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

    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.text('新建任务'), findsOneWidget);

    await tester.tap(find.byType(OutlinedButton));
    expect(tapped, isTrue, reason: 'CTA 点击必须透传到 onAction');
  });
}
