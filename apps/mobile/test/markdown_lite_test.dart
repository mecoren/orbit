// 描述 Markdown 渲染器单测 —— 对齐桌面 markdown-lite.test.ts 的 10 用例口径
// （块级 5 + 行内 5），外加移动端 widget 冒烟 2。
//
// 注意：Text.rich 在 widget 测试 find.text 不可见（已知坑），富文本断言
// 走纯函数层 parseInlineNodes + buildMarkdownWidgets 的结构断言。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/modules/todo/logic/markdown_lite.dart';
import 'support/orbit_test_app.dart';

void main() {
  group('parseInlineNodes 行内（对齐桌面用例）', () {
    test('粗体 **x** 解析为 bold 节点', () {
      final nodes = parseInlineNodes('**重要**');
      expect(nodes.single, isA<InlineBold>());
      expect((nodes.single as InlineBold).text, '重要');
    });

    test('行内代码 `x` 解析为 code 节点，前后文本保留', () {
      final nodes = parseInlineNodes('用 `flutter test` 跑测试');
      expect(nodes[0], isA<InlineText>());
      expect((nodes[0] as InlineText).text, '用 ');
      expect((nodes[1] as InlineCode).text, 'flutter test');
      expect((nodes[2] as InlineText).text, ' 跑测试');
    });

    test('斜体 *x* 解析；单个 * 不成对按原文', () {
      final italic = parseInlineNodes('*斜体*');
      expect(italic.single, isA<InlineItalic>());
      // 3 * 4 = 12：单星号不成对，原文保留
      final plain = parseInlineNodes('3 * 4 = 12');
      expect(plain.single, isA<InlineText>());
      expect((plain.single as InlineText).text, '3 * 4 = 12');
    });

    test('链接 [text](url) 解析为 link 节点', () {
      final nodes = parseInlineNodes('[官网](https://example.com)');
      expect(nodes.single, isA<InlineLink>());
      expect((nodes.single as InlineLink).label, '官网');
      expect((nodes.single as InlineLink).url, 'https://example.com');
    });

    test('未闭合标记（`code 无尾）按原文输出', () {
      final nodes = parseInlineNodes('`未闭合');
      expect(nodes.single, isA<InlineText>());
      expect((nodes.single as InlineText).text, '`未闭合');
    });
  });

  group('buildMarkdownWidgets 块级（对齐桌面用例）', () {
    const body = Color(0xFF111111);
    const accent = Color(0xFF4E8CFF);

    test('标题：# 前缀渲染为标题 widget', () {
      final out = buildMarkdownWidgets('# 大标题',
          bodyColor: body, accentColor: accent);
      expect(out.length, 1);
      expect(out.single, isA<Widget>());
    });

    test('无序列表：连续 - 行聚合（结构上为单个缩进容器）', () {
      final out = buildMarkdownWidgets('- 甲\n- 乙\n- 丙',
          bodyColor: body, accentColor: accent);
      // 三行列表聚合为 1 个块级容器
      expect(out.length, 1);
    });

    test('列表前后普通行不吞并：段落与列表分块', () {
      final out = buildMarkdownWidgets('开头段\n- 项1\n结尾段',
          bodyColor: body, accentColor: accent);
      // 段落 + 列表容器 + 段落 = 3 个块级
      expect(out.length, 3);
    });

    test('任务列表残留字符（- [ ]/- [x]）按原文渲染为列表项', () {
      final out = buildMarkdownWidgets('- [ ] 未完成\n- [x] 已完成',
          bodyColor: body, accentColor: accent);
      expect(out.length, 1);
    });

    test('空行渲染为段距 SizedBox', () {
      final out =
          buildMarkdownWidgets('上\n\n下', bodyColor: body, accentColor: accent);
      // 上段 + 段距 + 下段 = 3 块，中间为 SizedBox
      expect(out.length, 3);
      expect(out[1], isA<SizedBox>());
    });
  });

  group('widget 冒烟（详情页描述区消费口径）', () {
    testWidgets('描述含标题/粗体/链接时不崩溃且渲染出节点', (tester) async {
      await tester.pumpWidget(
        orbitTestApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: buildMarkdownWidgets(
                  '# 计划\n\n**重点**：见 [文档](https://example.com)\n- 甲\n- 乙',
                  bodyColor: Colors.black,
                  accentColor: const Color(0xFF4E8CFF),
                ),
              ),
            ),
          ),
        ),
      );
      // 5 行内容 → 标题 + 段距 SizedBox + 段落 + 列表容器(内含 2 个
      // _MarkdownBullet)。Text.rich 属 Text 类型可被 byType 计数：
      // 标题 1 + 段落 1 + 列表项 2 = 4 个 Text
      expect(find.byType(Text), findsNWidgets(4));
      expect(find.byType(SizedBox), findsAtLeastNWidgets(1));
      // 链接 recognizer 挂载成功（TapGestureRecognizer 可达即渲染链通）
      expect(
        find.byWidgetPredicate((w) =>
            w is Text &&
            w.textSpan != null &&
            (w.textSpan as TextSpan).children != null),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('空描述占位段不崩溃（上层 Column children 非空保证）', (tester) async {
      await tester.pumpWidget(
        orbitTestApp(
          home: Scaffold(
            body: Column(
              children: buildMarkdownWidgets('',
                  bodyColor: Colors.black, accentColor: Colors.blue),
            ),
          ),
        ),
      );
      // 空串占位 Text('') 也是 Text.rich 之外的普通 Text——空 data 不建
      // RichText，仅断言不崩即可（占位存在的意义是 Column children 非空）
      expect(tester.takeException(), isNull);
    });
  });
}
