// apps/mobile/lib/modules/todo/logic/markdown_lite.dart
//
// 轻量 Markdown 渲染器（纯 Widget 构建，零第三方渲染库）—— 同源移植桌面端
// apps/desktop/src/features/todo/shared/markdown-lite.tsx（小而美批次③）。
//
// 支持子集与桌面逐字对齐：标题(#) / 粗体 / 斜体 / 行内代码 / 链接（点击
// 走系统浏览器）/ 无序列表(-、*) / 任务列表勾选残留(- [ ] / - [x] 按原文
// 渲染) / 空行段距。不做完整 CommonMark（表格/脚注/嵌套引用等刻意不收）——
// 描述是短文本场，引 flutter_markdown 全家不划算（移动端 UI 自绘惯例）。
//
// 架构：行内解析为纯函数（parseInlineNodes 返回节点列表，可直接单测），
// Widget 构建层消费；链接因 TapGestureRecognizer 需生命周期管理，用
// StatefulWidget 承载（纯函数层不持有 recognizer）。

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

/// 描述 Markdown 渲染入口：按行解析 → Widget 列表（详情页描述区消费）。
///
/// 语义色由调用方传入（SectionCard 内 bodyText 语境）；链接色走强调色
/// （桌面 text-primary 同口径）。
List<Widget> buildMarkdownWidgets(
  String text, {
  required Color bodyColor,
  required Color accentColor,
}) {
  final out = <Widget>[];
  final listBuffer = <Widget>[];
  final lines = text.split('\n');

  void flushList() {
    if (listBuffer.isNotEmpty) {
      out.add(
        Padding(
          // 桌面 ml-4；Flutter 无原生 ul，用缩进 + 自绘圆点近似
          padding: const EdgeInsets.only(left: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: List.of(listBuffer),
          ),
        ),
      );
      listBuffer.clear();
    }
  }

  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    final trimmed = line.trimLeft();
    // 无序列表（- 与 *；- [ ] 任务列表残留按原文渲染——原文含勾选字符）
    final bullet = RegExp(r'^[-*]\s+(.*)$').firstMatch(trimmed);
    if (bullet != null) {
      listBuffer.add(
        _MarkdownBullet(
          key: ValueKey('li-$li'),
          content: bullet.group(1)!,
          bodyColor: bodyColor,
          accentColor: accentColor,
        ),
      );
      continue;
    }
    flushList();
    // 标题（# ~ ###### 前缀；桌面字号分两档 15/14，移动 15px 语境上浮 1px）
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (heading != null) {
      final level = heading.group(1)!.length;
      out.add(
        _MarkdownHeading(
          key: ValueKey('h-$li'),
          content: heading.group(2)!,
          large: level <= 2,
          bodyColor: bodyColor,
          accentColor: accentColor,
        ),
      );
      continue;
    }
    // 空行 → 段距（桌面 h-1.5 ≈ 6px）
    if (line.trim().isEmpty) {
      out.add(const SizedBox(height: 6));
      continue;
    }
    out.add(
      _MarkdownParagraph(
        key: ValueKey('p-$li'),
        content: line,
        bodyColor: bodyColor,
        accentColor: accentColor,
      ),
    );
  }
  flushList();
  return out;
}

/// 行内元素解析节点：code / bold / italic / link / 纯文本
sealed class MarkdownInlineNode {
  const MarkdownInlineNode();
}

class InlineText extends MarkdownInlineNode {
  const InlineText(this.text);
  final String text;
}

class InlineCode extends MarkdownInlineNode {
  const InlineCode(this.text);
  final String text;
}

class InlineBold extends MarkdownInlineNode {
  const InlineBold(this.text);
  final String text;
}

class InlineItalic extends MarkdownInlineNode {
  const InlineItalic(this.text);
  final String text;
}

class InlineLink extends MarkdownInlineNode {
  const InlineLink(this.label, this.url);
  final String label;
  final String url;
}

/// 行内解析：逐字符扫描（比多重 replace 稳——避免嵌套标记错配）。
/// 语义与桌面 renderInline 逐字对齐：`code` / **bold** / *italic* /
/// [text](url)；不成对/未闭合标记原样保留字符。纯函数便于单测。
List<MarkdownInlineNode> parseInlineNodes(String text) {
  final out = <MarkdownInlineNode>[];
  var buf = '';
  var i = 0;
  void flush() {
    if (buf.isNotEmpty) {
      out.add(InlineText(buf));
      buf = '';
    }
  }

  while (i < text.length) {
    final ch = text[i];
    if (ch == '`') {
      final end = text.indexOf('`', i + 1);
      if (end > i) {
        flush();
        out.add(InlineCode(text.substring(i + 1, end)));
        i = end + 1;
        continue;
      }
    }
    // 粗体先于斜体测试（** 闭合失败不吞字符，与桌面同款优先序）
    if (ch == '*' && text.startsWith('**', i)) {
      final end = text.indexOf('**', i + 2);
      if (end > i + 1) {
        flush();
        out.add(InlineBold(text.substring(i + 2, end)));
        i = end + 2;
        continue;
      }
    }
    if (ch == '*' && !text.startsWith('**', i)) {
      final end = text.indexOf('*', i + 1);
      if (end > i + 1) {
        flush();
        out.add(InlineItalic(text.substring(i + 1, end)));
        i = end + 1;
        continue;
      }
    }
    if (ch == '[') {
      final closeText = text.indexOf(']', i + 1);
      if (closeText > i &&
          closeText + 1 < text.length &&
          text[closeText + 1] == '(') {
        final closeUrl = text.indexOf(')', closeText + 2);
        if (closeUrl > closeText) {
          flush();
          out.add(InlineLink(
            text.substring(i + 1, closeText),
            text.substring(closeText + 2, closeUrl),
          ));
          i = closeUrl + 1;
          continue;
        }
      }
    }
    buf += ch;
    i += 1;
  }
  flush();
  return out;
}

/// 行内节点 → TextSpan 树；链接节点交给 [onLinkSpan] 构造
/// （recognizer 需生命周期，由 StatefulWidget 侧注入）。
List<TextSpan> buildInlineSpans(
  String text, {
  required Color bodyColor,
  required Color accentColor,
  double fontSize = 15,
  FontWeight fontWeight = FontWeight.w400,
  required TextSpan Function(String label, String url) onLinkSpan,
}) {
  final nodes = parseInlineNodes(text);
  return [
    for (final n in nodes)
      switch (n) {
        InlineText(:final text) => TextSpan(text: text),
        InlineCode(:final text) => TextSpan(
            text: text,
            style: TextStyle(
              fontSize: fontSize - 1,
              fontFamily: 'monospace',
              // 桌面 bg-muted 弱底近似：span 无背景，用次级色+等宽区分
              color: bodyColor.withValues(alpha: 0.8),
            ),
          ),
        InlineBold(:final text) =>
          TextSpan(text: text, style: const TextStyle(fontWeight: FontWeight.w600)),
        InlineItalic(:final text) => TextSpan(
            text: text,
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: bodyColor.withValues(alpha: 0.85),
            ),
          ),
        InlineLink(:final label, :final url) => onLinkSpan(label, url),
      },
  ];
}

/// 无序列表项：自绘圆点 + 行内内容（含链接）
class _MarkdownBullet extends StatefulWidget {
  const _MarkdownBullet({
    super.key,
    required this.content,
    required this.bodyColor,
    required this.accentColor,
  });

  final String content;
  final Color bodyColor;
  final Color accentColor;

  @override
  State<_MarkdownBullet> createState() => _MarkdownBulletState();
}

class _MarkdownBulletState extends State<_MarkdownBullet> {
  final Map<String, TapGestureRecognizer> _linkTaps = {};

  @override
  void dispose() {
    for (final r in _linkTaps.values) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 自绘圆点（桌面 list-disc 近似）：顶对齐首行基线上方
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 8),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: widget.bodyColor.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: _RichInlineText(
              content: widget.content,
              bodyColor: widget.bodyColor,
              accentColor: widget.accentColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// 标题：字号两档（# / ## → 16 w600；更深 → 15 w600）
class _MarkdownHeading extends StatefulWidget {
  const _MarkdownHeading({
    super.key,
    required this.content,
    required this.large,
    required this.bodyColor,
    required this.accentColor,
  });

  final String content;
  final bool large;
  final Color bodyColor;
  final Color accentColor;

  @override
  State<_MarkdownHeading> createState() => _MarkdownHeadingState();
}

class _MarkdownHeadingState extends State<_MarkdownHeading> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: _RichInlineText(
        content: widget.content,
        bodyColor: widget.bodyColor,
        accentColor: widget.accentColor,
        fontSize: widget.large ? 16 : 15,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// 普通段落：行内解析 + 上下 1px 间距近似桌面 space-y-0.5
class _MarkdownParagraph extends StatefulWidget {
  const _MarkdownParagraph({
    super.key,
    required this.content,
    required this.bodyColor,
    required this.accentColor,
  });

  final String content;
  final Color bodyColor;
  final Color accentColor;

  @override
  State<_MarkdownParagraph> createState() => _MarkdownParagraphState();
}

class _MarkdownParagraphState extends State<_MarkdownParagraph> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: _RichInlineText(
        content: widget.content,
        bodyColor: widget.bodyColor,
        accentColor: widget.accentColor,
      ),
    );
  }
}

/// 行内富文本宿主：持有本段全部链接 recognizer 的生命周期
/// （build 中惰性创建、dispose 统一释放；同段重建前清旧防泄漏）。
class _RichInlineText extends StatefulWidget {
  const _RichInlineText({
    required this.content,
    required this.bodyColor,
    required this.accentColor,
    this.fontSize = 15,
    this.fontWeight = FontWeight.w400,
  });

  final String content;
  final Color bodyColor;
  final Color accentColor;
  final double fontSize;
  final FontWeight fontWeight;

  @override
  State<_RichInlineText> createState() => _RichInlineTextState();
}

class _RichInlineTextState extends State<_RichInlineText> {
  final Map<String, TapGestureRecognizer> _linkTaps = {};

  @override
  void dispose() {
    for (final r in _linkTaps.values) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _linkTaps.clear();
    final spans = buildInlineSpans(
      widget.content,
      bodyColor: widget.bodyColor,
      accentColor: widget.accentColor,
      fontSize: widget.fontSize,
      fontWeight: widget.fontWeight,
      onLinkSpan: (label, url) {
        final recognizer = TapGestureRecognizer()
          ..onTap = () => _openUrl(url);
        _linkTaps[url] = recognizer;
        return TextSpan(
          text: label,
          recognizer: recognizer,
          style: TextStyle(
            color: widget.accentColor,
            decoration: TextDecoration.underline,
            decorationColor: widget.accentColor,
          ),
        );
      },
    );
    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: widget.fontSize,
          fontWeight: widget.fontWeight,
          color: widget.bodyColor,
          height: 1.5,
        ),
        children: spans,
      ),
    );
  }

  /// 打开链接：url_launcher 系统浏览器（scheme 白名单外静默 toast 不可行
  /// ——纯组件层无 context 语境的 toast 约定，失败静默即可，与桌面
  /// target=_blank 行为差异：桌面浏览器自行处理无效 URL）
  void _openUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
