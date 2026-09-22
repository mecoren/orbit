// 共享底部弹层族（orbit_sheets.dart）承载口径：
// 表面色与顶部圆角由 Material `showModalBottomSheet` 的
// `backgroundColor` + `bottomSheetTopShape` 提供（唯一来源）——
// 修 shadcn `SheetConfiguration` 的 sheet 容器硬编码直角 + 不透明背景
// 把自绘圆角盖住、观感变成「两边有角」的问题。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_sheets.dart';
import 'support/orbit_test_app.dart';

/// 标签字形的水平中心（Text 局部坐标）。
///
/// 底部按钮经 `Expanded` 拉满宽后，标签 Text 的盒子与按钮同宽，字形落位由
/// `textAlign` 决定——故只能量字形，量 Text 盒子量不出居中与否。
double glyphCenterX(WidgetTester tester, String label) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: label.length),
  );
  return boxes
      .map((box) => box.toRect())
      .reduce((a, b) => a.expandToInclude(b))
      .center
      .dx;
}

/// 取按钮实际绘制的填充色（shadcn 把按钮 decoration 落在 `OverflowDecoratedBox` 上，
/// 该组件非公开 API，只能按运行时类型名定位后读字段）。
Color buttonFillOf(WidgetTester tester, String label) {
  final box = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == 'OverflowDecoratedBox',
    ),
  );
  // ignore: avoid_dynamic_calls
  final decoration = (tester.widget(box.first) as dynamic).decoration;
  return (decoration as BoxDecoration).color!;
}

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
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
    return ctx;
  }

  testWidgets('单选弹层：顶部圆角与弹层表面色由承载提供', (tester) async {
    final ctx = await pumpHost(tester);
    showSelectBottomSheet<String>(
      ctx,
      title: '视图模式',
      items: const [SelectItem(value: 'list', label: '列表')],
      current: 'list',
      onSelect: (_) {},
    );
    await tester.pumpAndSettle();

    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.shape, bottomSheetTopShape, reason: '顶部圆角唯一来源');
    expect(sheet.backgroundColor, AppColors.light.popup, reason: '弹层表面色');
    expect(find.text('视图模式'), findsOneWidget);
  });

  testWidgets('确认弹层：底部按钮标签水平居中（贴左即 TextAlign.start 回归）',
      (tester) async {
    final ctx = await pumpHost(tester);
    showConfirmBottomSheet(ctx, title: '删除任务', message: '不可恢复');
    await tester.pumpAndSettle();

    for (final label in ['取消', '确定']) {
      expect(
        glyphCenterX(tester, label),
        moreOrLessEquals(tester.getSize(find.text(label)).width / 2,
            epsilon: 1),
        reason: '$label 应居中于按钮内',
      );
    }
  });

  testWidgets('确认弹层：删除按钮实心不透明（不是像禁用的淡粉）', (tester) async {
    final ctx = await pumpHost(tester);
    showConfirmBottomSheet(
      ctx,
      title: '删除任务',
      message: '删除后将移入回收站',
      confirmLabel: '删除',
      destructive: true,
    );
    await tester.pumpAndSettle();

    final fill = buttonFillOf(tester, '删除');
    expect(
      fill.a,
      1,
      reason: '实心填充——shadcn 默认 0.5 alpha 的白字淡粉会被用户读成"不可点"',
    );
    expect(fill, AppColors.light.destructive, reason: '取破坏性 token 实色');
  });

  testWidgets('确认弹层：长内容滚动时底部按钮固定（不被内容顶出）', (tester) async {
    final ctx = await pumpHost(tester);
    showConfirmBottomSheet(
      ctx,
      title: '长内容',
      content: Column(
        children: [for (var i = 0; i < 80; i++) Text('行 $i')],
      ),
    );
    await tester.pumpAndSettle();

    final confirm = find.text('确定');
    final before = tester.getRect(confirm);
    final sheetBottom = tester.getRect(find.byType(BottomSheet)).bottom;
    expect(
      sheetBottom - before.bottom,
      lessThan(40),
      reason: '按钮应钉在抽屉底部（间距只剩尾栏内边距）',
    );

    // 内容在内容区独立滚动（抽屉高度 85% 上限 + 80 行文本必然溢出），
    // 按钮位置不受影响
    await tester.drag(find.text('行 0'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getRect(confirm), before, reason: '内容滚动不应带动按钮');
  });

  testWidgets('确认弹层：点确认返回 true、点取消返回 false', (tester) async {
    final ctx = await pumpHost(tester);

    final confirmed = showConfirmBottomSheet(ctx, title: '删除任务', message: '不可恢复');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(await confirmed, isTrue);

    final cancelled = showConfirmBottomSheet(ctx, title: '删除任务');
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await cancelled, isFalse);
  });
}
