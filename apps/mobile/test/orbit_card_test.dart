// OrbitCard 原语口径：1px outline 描边 + surface 填充 + medium 圆角 + 零阴影；
// SectionCard 是其带头变体（公共 API 不变，内部复用 OrbitCard）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/core/theme/app_shapes.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_card.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_section_card.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('OrbitCard：描边/填充/圆角走 token，无阴影', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: OrbitCard(child: Text('内容'))),
    ));

    final card = tester.widget<sh.Card>(find.byType(sh.Card));
    final tokens = AppColors.of(Brightness.light);
    expect(card.borderWidth, 1);
    expect(card.borderColor, tokens.outline);
    expect(card.fillColor, tokens.surface);
    expect(card.borderRadius, AppShapes.medium);
    expect(card.boxShadow, isNull, reason: 'v3 卡片不投阴影，深度靠描边与分层');
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('OrbitCard：填充/内边距/圆角可覆写', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: OrbitCard(
          fillColor: Colors.red,
          padding: EdgeInsets.zero,
          borderRadius: AppShapes.small,
          child: const Text('次级行'),
        ),
      ),
    ));

    final card = tester.widget<sh.Card>(find.byType(sh.Card));
    expect(card.fillColor, Colors.red);
    expect(card.padding, EdgeInsets.zero);
    expect(card.borderRadius, AppShapes.small);
  });

  testWidgets('SectionCard：带头变体，API 不变且内部复用 OrbitCard',
      (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(
        body: SectionCard(title: '标题', child: Text('区块内容')),
      ),
    ));

    expect(find.byType(OrbitCard), findsOneWidget);
    expect(find.text('标题'), findsOneWidget);
    expect(find.text('区块内容'), findsOneWidget);
  });
}
