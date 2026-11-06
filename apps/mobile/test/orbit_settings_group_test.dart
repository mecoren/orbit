// OrbitSettingsGroup 分组标题行对齐回归测试：trailing 恒贴标题行右缘
//（页面宽 - 16，与卡外标题的左缘 12+16 同一套边距）。
//
// 根因背景（2026-11-06）：标题行里标题 `Expanded`、副标题 `Flexible` 是
// **两个并列 flex 子项**，Row 把剩余空间按 flex 均分；副标题用不完的份额
// 按 mainAxisAlignment.start 堆到行尾，trailing 就悬在中间不贴右。副标题文案
// 越长越不明显（几乎吃满自己的份额），短副标题（如「近 0 次」）才彻底露馅——
// 云同步配置页「同步历史 / 同步账本」两处「刷新」一左一右正是这个原因。
// 修复：标题+副标题收进同一个 `Expanded` 内层 Row，内部各自 Flexible。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/core/theme/app_dimens.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_button.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_settings_group.dart';

import 'support/orbit_test_app.dart';

Widget _host({String title = '同步历史', String? subtitle, Widget? trailing}) =>
    orbitTestApp(
      home: Scaffold(
        body: OrbitSettingsGroup(
          title: title,
          subtitle: subtitle,
          trailing: trailing ??
              OrbitButton.text(onPressed: () {}, child: const Text('刷新')),
          child: const SizedBox(height: 10),
        ),
      ),
    );

/// trailing（按钮盒）右缘像素
double _trailingRight(WidgetTester tester) =>
    tester.getTopRight(find.widgetWithText(OrbitButton, '刷新')).dx;

/// 标题行右缘 = 页面宽 - 16（卡外标题自带 12+16 边距中的右半边）
void _expectFlushRight(WidgetTester tester) {
  final pageRight = tester.getSize(find.byType(Scaffold)).width;
  expect(_trailingRight(tester), closeTo(pageRight - AppDimens.space16, 0.5));
}

void main() {
  testWidgets('短副标题（近 0 次）时 trailing 贴右', (tester) async {
    await tester.pumpWidget(_host(subtitle: '近 0 次'));
    _expectFlushRight(tester);
  });

  testWidgets('长副标题时 trailing 贴右', (tester) async {
    await tester.pumpWidget(_host(subtitle: '桶指纹与水位线（排障用）'));
    _expectFlushRight(tester);
  });

  testWidgets('无副标题时 trailing 贴右', (tester) async {
    await tester.pumpWidget(_host());
    _expectFlushRight(tester);
  });

  testWidgets('副标题长短不影响 trailing 位置', (tester) async {
    await tester.pumpWidget(_host(subtitle: '近 0 次'));
    final short = _trailingRight(tester);

    await tester.pumpWidget(_host(subtitle: '桶指纹与水位线（排障用）'));
    final long = _trailingRight(tester);

    expect(long, closeTo(short, 0.5));
  });

  testWidgets('标题+副标题超长时截断且不溢出，trailing 仍贴右', (tester) async {
    await tester.pumpWidget(
      _host(
        title: '一个特别特别特别特别特别特别特别特别特别长的分组标题',
        subtitle: '这条副说明也特别特别特别特别特别特别特别特别特别长',
      ),
    );
    _expectFlushRight(tester);
    expect(tester.takeException(), isNull);
  });
}
