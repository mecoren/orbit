// 底部弹层玻璃形变期闸门：三个窗口的行为契约
//
// 钉住三件事（对应 `orbit_sheet_glass_motion.dart` 文件头的三条）：
// 1. 入场窗口内必须是实色（晚一帧就会先录一次背景快照，白烧一轮模糊）；
// 2. 窗口结束同帧切回真玻璃；
// 3. 退场（路由反向）与键盘抬升都必须重新回到实色。
//
// 另钉 `OrbitGlassSurface.solid` 的实现口径：实色档必须给 `MiuixGlassPanel`
// 传 `backdrop: null`（走库内「无快照 → 填色」分支），否则缓存键仍随
// origin/size 逐帧失效。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_glass_surface.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_popup_glass.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_sheet_glass_motion.dart';

import '../support/orbit_test_app.dart';

/// 打开一个最小的底部弹层，内容直接暴露闸门的 `solid` 档
Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    orbitTestApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            builder: (_) => OrbitSheetGlassMotion(
              builder: (context, solid) =>
                  Text(solid ? 'solid' : 'glass', textDirection: TextDirection.ltr),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  // 起播一帧，再推到入场中段（220ms 入场，320ms 窗口）
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 220));
}

void main() {
  testWidgets('入场窗口内是实色，窗口结束切真玻璃', (tester) async {
    await _openSheet(tester);
    expect(find.text('solid'), findsOneWidget);
    expect(find.text('glass'), findsNothing);

    // 窗口剩余 ~100ms：再推满一个窗口必然已过点
    await tester.pump(OrbitPopupGlass.morphWindow);
    expect(find.text('glass'), findsOneWidget);
    expect(find.text('solid'), findsNothing);
  });

  testWidgets('退场（路由反向）立刻回实色', (tester) async {
    await _openSheet(tester);
    await tester.pump(OrbitPopupGlass.morphWindow);
    expect(find.text('glass'), findsOneWidget);

    Navigator.of(tester.element(find.text('glass'))).pop();
    // 反向动画起播一帧：status 变 reverse，同帧就该切回实色
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('solid'), findsOneWidget);
  });

  testWidgets('键盘抬升会重新开窗（卡面高度变了，纹理键也失效）', (tester) async {
    await _openSheet(tester);
    await tester.pump(OrbitPopupGlass.morphWindow);
    expect(find.text('glass'), findsOneWidget);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('solid'), findsOneWidget);

    // 抬升结束同样要回到玻璃（否则键盘弹完卡面就永远停在实色）
    await tester.pump(OrbitPopupGlass.morphWindow);
    expect(find.text('glass'), findsOneWidget);
  });

  testWidgets('无采样器时的 solid 档：不建玻璃面板、表面色走实色', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: const OrbitGlassSurface(
          solid: true,
          borderRadius: BorderRadius.zero,
          child: SizedBox(width: 10, height: 10),
        ),
      ),
    );

    expect(
      find.byType(MiuixGlassPanel),
      findsNothing,
      reason: '无采样器时两档都走实时模糊路径（同类型树，避免子树重挂）',
    );
    final surface = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(OrbitGlassSurface),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(surface.color, OrbitPopupGlass.fill(false));
  });
}
