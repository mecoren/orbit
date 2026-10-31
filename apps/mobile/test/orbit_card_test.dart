// OrbitCard 原语口径：1px outline 描边 + surface 填充 + medium 圆角 + 零阴影；
// 承载已换成 flutter_miuix 的 MiuixCard（squircle 超椭圆圆角，HyperOS 语言）。
// SectionCard 是其带头变体（公共 API 不变，内部复用 OrbitCard）。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/core/theme/app_shapes.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_card.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_section_card.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('OrbitCard：描边/填充/圆角走 token，无阴影', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: OrbitCard(child: Text('内容'))),
    ));

    final card = tester.widget<MiuixCard>(find.byType(MiuixCard));
    final tokens = AppColors.of(Brightness.light);
    expect(card.cornerRadius, AppShapes.radiusMedium);
    expect(card.insideMargin, const EdgeInsets.all(16));
    // 填充走 surface，内容色取 Miuix 主题的 onSurfaceContainer
    expect(card.colors?.color, tokens.surface);
    // MiuixCard 无独立描边参数：描边由 OrbitCard 的超椭圆描边层承担
    expect(find.byType(CustomPaint), findsWidgets);
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

    final card = tester.widget<MiuixCard>(find.byType(MiuixCard));
    expect(card.colors?.color, Colors.red);
    expect(card.insideMargin, EdgeInsets.zero);
    expect(card.cornerRadius, AppShapes.radiusSmall);
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
