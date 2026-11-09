// 方角勾选框（原语层：自绘 4px 圆角方框 + 2px 描边 + 白勾，与桌面端同源）。
//
// 断言口径：逐帧绘制细节由自定义 painter 承担，本组件契约只剩「尺寸 + 热区 +
// 弱化灰填充 + 优先级描边 + 白勾出现/消失 + 回调转发」，断言落在组件契约上。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/core/theme/app_dimens.dart';
import 'package:orbit/core/theme/app_motion.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_checkbox.dart';

import 'support/orbit_test_app.dart';

/// 勾选态由父层驱动（组件本身无状态）
class _Host extends StatefulWidget {
  const _Host({required this.onToggle, this.size = 24});

  final VoidCallback onToggle;
  final double size;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool checked = false;

  @override
  Widget build(BuildContext context) => orbitTestApp(
        home: Scaffold(
          body: Center(
            child: OrbitCheckbox(
              checked: checked,
              size: widget.size,
              onToggle: () {
                widget.onToggle();
                setState(() => checked = !checked);
              },
            ),
          ),
        ),
      );
}

/// 方框本体（承载填充/描边/尺寸）
Finder _boxFinder() => find.descendant(
      of: find.byType(OrbitCheckbox),
      matching: find.byType(AnimatedContainer),
    );

AnimatedContainer _box(WidgetTester tester) =>
    tester.widget<AnimatedContainer>(_boxFinder());

BoxDecoration _decoration(WidgetTester tester) =>
    _box(tester).decoration! as BoxDecoration;

Color? _fill(WidgetTester tester) => _decoration(tester).color;

Color _borderColor(WidgetTester tester) =>
    (_decoration(tester).border! as Border).top.color;

BorderRadius _radius(WidgetTester tester) =>
    _decoration(tester).borderRadius! as BorderRadius;

/// 外层定尺方框（热区承载者，树序第一个即组件自身那层）
SizedBox _square(WidgetTester tester) => tester.widget<SizedBox>(
      find
          .descendant(
            of: find.byType(OrbitCheckbox),
            matching: find.byType(SizedBox),
          )
          .first,
    );

void _noop() {}

void main() {
  testWidgets('未勾选：透明底 + 中性灰描边，无白勾、不触发回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));
    await tester.pump(AppMotion.fast);

    expect(_fill(tester), Colors.transparent);
    expect(
      _borderColor(tester),
      AppColors.light.secondaryText.withValues(alpha: 0.4),
    );
    expect(find.byKey(OrbitCheckbox.checkKey), findsNothing);
    expect(taps, 0);
  });

  testWidgets('点按：回调触发一次，弱化灰实底 + 白勾出现', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));

    await tester.tap(find.byType(OrbitCheckbox));
    await tester.pump();
    await tester.pump(AppMotion.fast);

    expect(taps, 1);
    // 完成态填充走弱化灰（已完成行整行置灰口径），不保留待办蓝
    expect(_fill(tester), AppColors.light.deactivatedText);
    // 完成态描边随填充同色，不保留优先级色环
    expect(_borderColor(tester), AppColors.light.deactivatedText);
    expect(find.byKey(OrbitCheckbox.checkKey), findsOneWidget);
  });

  testWidgets('再次点按：勾选态回到 false，白勾退场', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));
    await tester.tap(find.byType(OrbitCheckbox));
    await tester.pump(AppMotion.fast);
    expect(find.byKey(OrbitCheckbox.checkKey), findsOneWidget);

    await tester.tap(find.byType(OrbitCheckbox));
    await tester.pump();
    await tester.pump(AppMotion.fast);

    expect(taps, 2);
    expect(_fill(tester), Colors.transparent);
    expect(find.byKey(OrbitCheckbox.checkKey), findsNothing);
  });

  testWidgets('尺寸参数生效（详情标题档 28、子任务档 22）', (tester) async {
    await tester.pumpWidget(_Host(onToggle: () {}, size: 28));
    await tester.pump(AppMotion.fast);

    final boxSize = tester.getSize(_boxFinder());
    expect(boxSize.width, 28);
    expect(boxSize.height, 28);
    // 布局盒取热区下限（44）：图形居中——视觉尺寸不变，可点面积扩到触控档
    expect(_square(tester).width, OrbitCheckbox.minHitExtent);
    expect(_square(tester).height, OrbitCheckbox.minHitExtent);
  });

  testWidgets('小尺寸档（子任务 22）热区同样外扩到 44', (tester) async {
    await tester.pumpWidget(_Host(onToggle: () {}, size: 22));
    await tester.pump(AppMotion.fast);

    expect(tester.getSize(_boxFinder()).width, 22);
    expect(_square(tester).width, OrbitCheckbox.minHitExtent);
    expect(_square(tester).height, OrbitCheckbox.minHitExtent);
  });

  test('任务行默认尺寸 22（2026-11-09 由 20 上调，与 16px 标题比例协调）', () {
    const box = OrbitCheckbox(checked: false, onToggle: _noop);
    expect(box.size, AppDimens.taskCheckboxSize);
    expect(box.size, 22);
  });

  test('方框圆角/描边与桌面端同值：4px 圆角 + 2px 描边', () {
    expect(OrbitCheckbox.cornerRadius, 4);
    expect(OrbitCheckbox.strokeWidth, 2);
  });

  testWidgets('borderColor 覆写空心方框描边（优先级语义）', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: Center(
          child: OrbitCheckbox(
            checked: false,
            borderColor: const Color(0xFFF59E0B),
            onToggle: () {},
          ),
        ),
      ),
    ));
    await tester.pump(AppMotion.fast);

    expect(_borderColor(tester), const Color(0xFFF59E0B));
    expect(_radius(tester).topLeft.x, OrbitCheckbox.cornerRadius);
  });
}
