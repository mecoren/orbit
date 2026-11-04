// SectionCard 头行对齐回归测试：trailing 必须贴内容区右缘（卡右缘 - 内边距 16，
// 与卡内其他内容同一条对齐线）
//
// 根因背景（2026-11-04）：头行曾是「Flexible(标题) + Spacer」两个并列
// flex 子项，剩余空间对半分，标题用不完的份额按 mainAxisAlignment.start
// 堆到行尾，trailing（如云同步配置页两处「刷新」）悬在中间不贴右。
// 修复后标题+副标题集群整体 Expanded、内部各自 Flexible，trailing 恒贴右。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/shared/widgets/shadcn/orbit_button.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_section_card.dart';

Widget _host(Widget? trailing) => MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SectionCard(
            title: '同步历史',
            subtitle: '近 0 次',
            trailing: trailing == null
                ? null
                : OrbitButton.text(onPressed: () {}, child: trailing),
            child: const SizedBox(height: 10),
          ),
        ),
      ),
    );

void main() {
  testWidgets('有 trailing 时按钮右缘应与卡片右缘重合', (tester) async {
    await tester.pumpWidget(_host(const Text('刷新')));

    final cardRight = tester.getTopRight(find.byType(SectionCard)).dx;
    final btnRight =
        tester.getTopRight(find.widgetWithText(OrbitButton, '刷新')).dx;
    expect(btnRight, closeTo(cardRight - 16, 0.5));
  });

  testWidgets('标题很长被截断时 trailing 仍贴右', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SectionCard(
              title: '一个特别特别特别特别特别特别特别特别特别长的卡片标题',
              subtitle: '桶指纹与水位线（排障用）',
              trailing:
                  OrbitButton.text(onPressed: () {}, child: const Text('刷新')),
              child: const SizedBox(height: 10),
            ),
          ),
        ),
      ),
    );

    final cardRight = tester.getTopRight(find.byType(SectionCard)).dx;
    final btnRight =
        tester.getTopRight(find.widgetWithText(OrbitButton, '刷新')).dx;
    expect(btnRight, closeTo(cardRight - 16, 0.5));
    // 标题超长必须截断而不是把副标题/trailing 挤出卡片
    expect(tester.takeException(), isNull);
  });

  testWidgets('无 trailing 时头行正常渲染不报溢出', (tester) async {
    await tester.pumpWidget(_host(null));
    expect(tester.takeException(), isNull);
  });
}
