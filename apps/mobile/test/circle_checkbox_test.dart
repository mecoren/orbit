// 圆形勾选框（设计系统 v3：shadcn `Checkbox` 承载，圆形形态保留）。
//
// 断言口径随实现收敛：v3 的描边/填充/对号动画由 shadcn `Checkbox` 内部承担
// （内部是三层嵌套 AnimatedContainer，逐节点断言既脆又测不到本项目契约），
// 本组件只剩「圆形 + 尺寸 + 强调色 + 回调转发」四件事，故断言落在组件契约上。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_motion.dart';
import 'package:orbit/core/theme/orbit_accents.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_checkbox.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

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
            child: CircleCheckbox(
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

/// 组件内的 shadcn 勾选框（唯一）
sh.Checkbox _box(WidgetTester tester) => tester.widget<sh.Checkbox>(
      find.descendant(
        of: find.byType(CircleCheckbox),
        matching: find.byType(sh.Checkbox),
      ),
    );

/// 外层定尺方框（圆形直径的承载者，树序第一个即组件自身那层）
SizedBox _square(WidgetTester tester) => tester.widget<SizedBox>(
      find
          .descendant(
            of: find.byType(CircleCheckbox),
            matching: find.byType(SizedBox),
          )
          .first,
    );

void main() {
  testWidgets('未勾选：state=unchecked、形态圆形、不触发回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));
    await tester.pump(AppMotion.fast);

    expect(_box(tester).state, sh.CheckboxState.unchecked);
    expect(_box(tester).activeColor, OrbitAccents.todoAccent);
    // 圆形 = 半径取直径一半（v2 手绘版的圆形识别在 v3 由 borderRadius 表达）
    expect(_box(tester).borderRadius, BorderRadius.circular(12));
    expect(taps, 0);
  });

  testWidgets('点按：回调触发一次，勾选态翻到 checked', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));

    await tester.tap(find.byType(CircleCheckbox));
    await tester.pump();
    await tester.pump(AppMotion.fast);

    expect(taps, 1);
    expect(_box(tester).state, sh.CheckboxState.checked);
  });

  testWidgets('再次点按：勾选态回到 unchecked', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));

    await tester.tap(find.byType(CircleCheckbox));
    await tester.pump(AppMotion.fast);
    expect(_box(tester).state, sh.CheckboxState.checked);

    await tester.tap(find.byType(CircleCheckbox));
    await tester.pump();
    await tester.pump(AppMotion.fast);

    expect(taps, 2);
    expect(_box(tester).state, sh.CheckboxState.unchecked);
  });

  testWidgets('尺寸参数生效（详情标题档 28、子任务档 22）', (tester) async {
    await tester.pumpWidget(_Host(onToggle: () {}, size: 28));
    await tester.pump(AppMotion.fast);

    expect(_square(tester).width, 28);
    expect(_square(tester).height, 28);
    expect(_box(tester).size, 28);
    expect(_box(tester).borderRadius, BorderRadius.circular(14));
  });

  // 列表行优先级着色入口（2026-09-23）：高/紧急/立即由圆环颜色表达，
  // P0「无」不传（回落中性灰）——断言覆写生效且不勾选态仍是空心圆
  testWidgets('borderColor 覆写描边色（优先级语义）', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: Center(
          child: CircleCheckbox(
            checked: false,
            borderColor: const Color(0xFFF59E0B),
            onToggle: () {},
          ),
        ),
      ),
    ));
    await tester.pump(AppMotion.fast);

    expect(_box(tester).borderColor, const Color(0xFFF59E0B));
    expect(_box(tester).state, sh.CheckboxState.unchecked);
  });
}
