// 重复规则抽屉（repeat_edit_sheet.dart）宽度口径：
// 面板必须铺满屏宽——`showModalBottomSheet` 给内容的是**宽松约束**，本面板全是
// Wrap/Text 这类收缩组件，不显式撑开时抽屉宽度会收缩到内容宽度
// （预设档实测 309.75 / 360，即"太窄"；其它底部抽屉因内含撑满元素天然全宽）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// as rep：规避 Flutter widgets 自带 RepeatMode 类名冲突（与源文件同口径）
import 'package:orbit/modules/todo/logic/repeat_logic.dart' as rep;
import 'package:orbit/modules/todo/repeat_edit_sheet.dart';
import 'support/orbit_test_app.dart';

void main() {
  /// 手机视口（逻辑 360×800）：宽屏下 Flutter 内置的 M3 底部抽屉 640 限宽会
  /// 掩盖收缩（此时内容自然宽可能已 ≥ 可用宽，看不出差异）
  Future<void> pumpSheet(
    WidgetTester tester, {
    required int mode,
    required int after,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    showRepeatEditSheet(ctx, mode: mode, after: after);
    await tester.pumpAndSettle();
  }

  /// 抽屉内容根（`_RepeatEditSheet` 私有类型，按 runtimeType 定位）
  double contentWidth(WidgetTester tester) => tester
      .getSize(find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_RepeatEditSheet',
      ))
      .width;

  double screenWidth(WidgetTester tester) =>
      tester.view.physicalSize.width / tester.view.devicePixelRatio;

  testWidgets('预设档（内容最少）：抽屉仍铺满屏宽', (tester) async {
    await pumpSheet(tester, mode: rep.RepeatMode.daily, after: 1);

    expect(contentWidth(tester), screenWidth(tester),
        reason: '不得收缩到 chips 行宽度（预设档最易暴露）');
    expect(find.text('重复'), findsOneWidget);
  });

  testWidgets('自定义档（面板展开）：抽屉同样铺满屏宽', (tester) async {
    await pumpSheet(tester, mode: rep.RepeatMode.weekly, after: 3);

    expect(find.byKey(const ValueKey('repeat_custom_panel')), findsOneWidget);
    expect(contentWidth(tester), screenWidth(tester));
  });
}
