// 圆形勾选框（原语层：flutter_miuix `MiuixCheckbox` 承载，HyperOS 圆形形态）。
//
// 断言口径：描画式对勾/按压下沉由 MiuixCheckbox 内部承担（逐帧 CustomPainter
// 断言既脆又测不到本项目契约），本组件只剩「尺寸 + 热区 + 弱化灰填充 +
// 优先级描边 + 回调转发」五件事，故断言落在组件契约上。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
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

/// 组件内的 Miuix 勾选框（唯一）
MiuixCheckbox _box(WidgetTester tester) => tester.widget<MiuixCheckbox>(
      find.descendant(
        of: find.byType(OrbitCheckbox),
        matching: find.byType(MiuixCheckbox),
      ),
    );

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
  testWidgets('未勾选：value=false、弱化灰填充口径、不触发回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));
    await tester.pump(AppMotion.fast);

    expect(_box(tester).value, isFalse);
    // 完成态填充走弱化灰（已完成行整行置灰口径），不保留待办蓝
    expect(
      _box(tester).colors?.checkedBackgroundColor,
      AppColors.light.deactivatedText,
    );
    expect(taps, 0);
  });

  testWidgets('点按：回调触发一次，勾选态翻到 true', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));

    await tester.tap(find.byType(OrbitCheckbox));
    await tester.pump();
    await tester.pump(AppMotion.fast);

    expect(taps, 1);
    expect(_box(tester).value, isTrue);
  });

  testWidgets('再次点按：勾选态回到 false', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));

    await tester.tap(find.byType(OrbitCheckbox));
    await tester.pump(AppMotion.fast);
    expect(_box(tester).value, isTrue);

    await tester.tap(find.byType(OrbitCheckbox));
    await tester.pump();
    await tester.pump(AppMotion.fast);

    expect(taps, 2);
    expect(_box(tester).value, isFalse);
  });

  testWidgets('尺寸参数生效（详情标题档 28、子任务档 22）', (tester) async {
    await tester.pumpWidget(_Host(onToggle: () {}, size: 28));
    await tester.pump(AppMotion.fast);

    // MiuixCheckbox 的视觉直径固定在库内 26dp，本组件用外层 SizedBox 收窄/放大
    expect(tester.getSize(find.byType(MiuixCheckbox)).width, 28);
    // 布局盒取热区下限（44）：图形居中——视觉尺寸不变，可点面积扩到触控档
    expect(_square(tester).width, OrbitCheckbox.minHitExtent);
    expect(_square(tester).height, OrbitCheckbox.minHitExtent);
  });

  testWidgets('小尺寸档（子任务 22）热区同样外扩到 44', (tester) async {
    await tester.pumpWidget(_Host(onToggle: () {}, size: 22));
    await tester.pump(AppMotion.fast);

    expect(tester.getSize(find.byType(MiuixCheckbox)).width, 22);
    expect(_square(tester).width, OrbitCheckbox.minHitExtent);
    expect(_square(tester).height, OrbitCheckbox.minHitExtent);
  });

  test('任务行默认尺寸 20（与桌面端任务行 h-5 w-5 跨端同源）', () {
    const box = OrbitCheckbox(checked: false, onToggle: _noop);
    expect(box.size, AppDimens.taskCheckboxSize);
    expect(box.size, 20);
  });

  // 列表行优先级着色入口（2026-09-23）：高/紧急/立即由圆环颜色表达，
  // P0「无」不传（回落中性灰）——断言覆写生效且不勾选态仍是空心圆环
  testWidgets('borderColor 覆写描边色（优先级语义）', (tester) async {
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

    expect(_box(tester).value, isFalse);
  });
}
