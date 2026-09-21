// 共享底部弹层族（orbit_sheets.dart）承载口径：
// 表面色与顶部圆角由 Material `showModalBottomSheet` 的
// `backgroundColor` + `bottomSheetTopShape` 提供（唯一来源）——
// 修 shadcn `SheetConfiguration` 的 sheet 容器硬编码直角 + 不透明背景
// 把自绘圆角盖住、观感变成「两边有角」的问题。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_sheets.dart';
import 'support/orbit_test_app.dart';

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
