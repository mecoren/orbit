// OrbitTextField 原语回归（2026-11-02 输入框收口到 MiuixTextField）：
// 1. maxLength 由壳层截断（miuix 组件库不暴露 inputFormatters）；
// 2. validator 走 Form.validate()，错误文案画在输入框下方；
// 3. inline 形态用 hintText 当占位（详情页标题/项目名原地编辑口径）；
// 4. inline 占位随文本显隐——首字落下即隐藏、清空后回来（2026-11-06 修
//    MiuixTextField 文本变化不重建导致占位叠在正文上、输入时被提示挡住）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_text_field.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('maxLength：超出上限的部分按 grapheme 截断并回写 controller', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: OrbitTextField(controller: controller, maxLength: 5),
      ),
    ));

    await tester.enterText(find.byType(TextField), '123456789');
    await tester.pump();

    expect(controller.text, '12345');
  });

  testWidgets('validator：Form.validate 失败 → 输入框下方出现错误文案', (tester) async {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: Form(
          key: formKey,
          child: OrbitTextField(
            controller: controller,
            label: '标题',
            validator: (v) =>
                v == null || v.trim().isEmpty ? '请输入标题' : null,
          ),
        ),
      ),
    ));

    expect(formKey.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('请输入标题'), findsOneWidget);

    // 填入合法值后重新校验 → 错误文案消失
    controller.text = '任务';
    expect(formKey.currentState!.validate(), isTrue);
    await tester.pump();
    expect(find.text('请输入标题'), findsNothing);
  });

  testWidgets('inline：hintText 作为占位（标题/项目名原地编辑口径）', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(
        body: OrbitTextField(inline: true, hintText: '项目名称'),
      ),
    ));

    expect(find.text('项目名称'), findsOneWidget);
    expect(find.byType(OrbitTextField), findsOneWidget);
  });

  testWidgets('inline 占位随文本显隐：输入后隐藏、清空后回来', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: OrbitTextField(
            controller: controller,
            inline: true,
            hintText: '输入评论...',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('输入评论...'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '这是一条评论');
    await tester.pumpAndSettle();
    // 占位必须让位：不能与输入正文叠在一起
    expect(find.text('输入评论...'), findsNothing);
    expect(find.text('这是一条评论'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('输入评论...'), findsOneWidget);
  });
}
