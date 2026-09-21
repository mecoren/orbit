// 圆形勾选框动效（对齐微软 To-Do）：未勾选无对号 → 点按后填充 + 对号呈现。
// 固定时长 pump 推进（仓库口径：动效测试不用 pumpAndSettle）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_motion.dart';
import 'package:orbit/core/theme/orbit_accents.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_checkbox.dart';
import 'support/orbit_test_app.dart';
import 'package:orbit/core/theme/icon_map.dart';

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

/// 勾选框内圈的盒子（避免命中页面其他 AnimatedContainer）
AnimatedContainer _box(WidgetTester tester) => tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(CircleCheckbox),
        matching: find.byType(AnimatedContainer),
      ),
    );

Color? _boxColor(WidgetTester tester) =>
    (_box(tester).decoration as BoxDecoration).color;

void main() {
  testWidgets('未勾选：无对号、圆底透明、不触发回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));
    await tester.pump(AppMotion.fast);

    expect(find.byIcon(OrbitIcons.check), findsNothing);
    expect(_boxColor(tester), Colors.transparent);
    expect(taps, 0);
  });

  testWidgets('点按：回调触发一次，动画结束后呈对号 + 模块强调色实底', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));

    await tester.tap(find.byType(CircleCheckbox));
    await tester.pump();
    await tester.pump(AppMotion.fast);

    expect(taps, 1);
    expect(find.byIcon(OrbitIcons.check), findsOneWidget);
    expect(_boxColor(tester), OrbitAccents.todoAccent);
  });

  testWidgets('再次点按：对号退场（取消勾选）', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onToggle: () => taps++));

    await tester.tap(find.byType(CircleCheckbox));
    await tester.pump(AppMotion.fast);

    await tester.tap(find.byType(CircleCheckbox));
    await tester.pump(); // 起帧：切回未勾选
    await tester.pump(AppMotion.fast); // 对号离场动画
    // AnimatedSwitcher 在离场动画结束（dismissed）后才 setState 移除旧子节点，
    // 需再补一帧渲染才能断言「对号已消失」
    await tester.pump();

    expect(taps, 2);
    expect(_boxColor(tester), Colors.transparent);
    expect(find.byIcon(OrbitIcons.check), findsNothing);
  });

  testWidgets('尺寸参数生效（详情标题档 28/18、子任务档 22/14）', (tester) async {
    await tester.pumpWidget(_Host(onToggle: () {}, size: 28));
    await tester.pump(AppMotion.fast);

    final box = _box(tester);
    expect(box.constraints?.maxWidth, 28);
    expect(box.constraints?.maxHeight, 28);
  });
}
