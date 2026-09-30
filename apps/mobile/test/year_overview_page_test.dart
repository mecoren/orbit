// 年视图（YearOverviewPage）迷你月历排布口径：
// 一行 3 列、手机宽度（360）下每格仅 ~15px 宽，两位日期必须单行自适应显示
// ——窄格挤压成「1/0」竖排即回归（2026-09-26 实测）。
// 页头口径：大年份 + 农历图例 + 切年箭头直接落页头行，无返回键/标题——
// 点击年份即返回上一页（月历当时的月份）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/todo/year_overview_page.dart';
import 'support/orbit_test_app.dart';

void main() {
  testWidgets('年视图迷你月历：两位日期单行显示不竖排', (tester) async {
    // 压到手机逻辑宽度（360×780 @3x）：桌面默认 800 宽的测试窗口格宽充足，
    // 复现不了窄格挤压
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(1080, 2340);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(orbitTestApp(
      home: const YearOverviewPage(initialYear: 2026),
    ));
    await tester.pumpAndSettle();

    // 测试字体（Ahem）每个字形都是 fontSize 等宽：页头大年份在 360 宽下
    // 会假性溢出（真机数字 ~0.56em 宽不溢出，见实机截图），吞掉该伪异常，
    // 只断言迷你月历的日期排布
    tester.takeException();

    // 1月 10 日（树序第一个 '10'）：两位数必须单行（宽 > 高），
    // 竖排换行时高约为宽的两倍
    final box = tester.renderObject<RenderBox>(find.text('10').first);
    expect(box.size.width, greaterThan(box.size.height));
  });

  testWidgets('页头：年份+图例+切年箭头直达页头，点年份返回上一页', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: Center(child: Text('month-page'))),
    ));
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute(
          builder: (_) => const YearOverviewPage(initialYear: 2026),
        ));
    await tester.pumpAndSettle();

    // 无返回键、无「选择日期」标题；年份块在页头（切年箭头仍在）
    expect(find.text('选择日期'), findsNothing);
    expect(find.text('2026'), findsOneWidget);
    expect(find.byTooltip('上一年'), findsOneWidget);
    expect(find.byTooltip('下一年'), findsOneWidget);

    // 点击年份 → pop 回上一页（月历停在当时的月份）
    await tester.tap(find.text('2026'));
    await tester.pumpAndSettle();
    expect(find.text('month-page'), findsOneWidget);
  });
}

