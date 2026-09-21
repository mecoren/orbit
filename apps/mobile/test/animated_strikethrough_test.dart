// 完成态标题动效（对齐微软 To-Do）：删除线绘制进度 + 文字色过渡。
// 固定时长 pump 推进；不用 pumpAndSettle。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_motion.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_strikethrough.dart';
import 'support/orbit_test_app.dart';

const TextStyle _baseStyle = TextStyle(fontSize: 16, color: Color(0xFF1A1D26));
const Color _doneColor = Color(0xFF6B7685);

Widget _harness(ValueNotifier<bool> done, String text) => orbitTestApp(
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: done,
          builder: (context, value, _) => AnimatedStrikethrough(
            text: text,
            done: value,
            style: _baseStyle,
            doneColor: _doneColor,
            maxLines: 1,
          ),
        ),
      ),
    );

Color? _textColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

/// 划线层（进度 > 0 时才挂载）
Finder _strikeLayer() => find.descendant(
      of: find.byType(AnimatedStrikethrough),
      matching: find.byType(CustomPaint),
    );

void main() {
  testWidgets('未完成：保留真实 Text 节点、无划线层、用未完成态配色', (tester) async {
    final done = ValueNotifier<bool>(false);
    addTearDown(done.dispose);
    await tester.pumpWidget(_harness(done, '未完成任务'));
    await tester.pump(AppMotion.strikethrough);

    // find.text 必须可见（不得改为 Text.rich/CustomPaint 整体绘制）
    expect(find.text('未完成任务'), findsOneWidget);
    expect(_textColor(tester, '未完成任务'), _baseStyle.color);
    expect(_strikeLayer(), findsNothing);
  });

  testWidgets('挂载即完成：首帧就是完成态（不重播入场动画）', (tester) async {
    final done = ValueNotifier<bool>(true);
    addTearDown(done.dispose);
    await tester.pumpWidget(_harness(done, '已完成任务'));
    await tester.pump();

    expect(_textColor(tester, '已完成任务'), _doneColor);
    expect(_strikeLayer(), findsOneWidget);
  });

  testWidgets('切换完成态：文字色由主色过渡到完成色，划线层出现', (tester) async {
    final done = ValueNotifier<bool>(false);
    addTearDown(done.dispose);
    await tester.pumpWidget(_harness(done, '切换任务'));
    await tester.pump(AppMotion.strikethrough);
    expect(_textColor(tester, '切换任务'), _baseStyle.color);

    done.value = true;
    await tester.pump();
    // 起帧：进度 0，仍是未完成态配色（验证是过渡而非瞬切）
    expect(_textColor(tester, '切换任务'), _baseStyle.color);

    await tester.pump(AppMotion.strikethrough);
    expect(_textColor(tester, '切换任务'), _doneColor);
    expect(_strikeLayer(), findsOneWidget);
  });

  testWidgets('取消完成：颜色回落且划线层移除', (tester) async {
    final done = ValueNotifier<bool>(true);
    addTearDown(done.dispose);
    await tester.pumpWidget(_harness(done, '回退任务'));
    await tester.pump(AppMotion.strikethrough);

    done.value = false;
    await tester.pump();
    await tester.pump(AppMotion.strikethrough);

    expect(_textColor(tester, '回退任务'), _baseStyle.color);
    expect(_strikeLayer(), findsNothing);
  });

  testWidgets('不限行（maxLines null）：多行文本仍可绘制划线', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: AnimatedStrikethrough(
              text: '很长的标题需要折行显示以验证多行度量',
              done: true,
              style: _baseStyle,
              doneColor: _doneColor,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('很长的标题'), findsOneWidget);
    expect(_strikeLayer(), findsOneWidget);
  });
}
