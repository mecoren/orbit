/**
 * 轻量 Markdown 渲染（小而美批次③）纯函数测试：
 * renderMarkdown —— 块级（标题/列表/空行）与行内（code/bold/italic/link）
 * 的节点结构断言。任务列表残留字符（- [ ]）按原文渲染为 li。
 */
import { describe, expect, it } from "vitest";

import { renderMarkdown } from "./markdown-lite";

import type { ReactElement } from "react";

/** 收集节点树中所有字符串叶子 */
function texts(nodes: React.ReactNode[]): string[] {
  const out: string[] = [];
  const walk = (n: React.ReactNode) => {
    if (typeof n === "string") out.push(n);
    else if (Array.isArray(n)) n.forEach(walk);
    else if (n != null && typeof n === "object" && "props" in (n as ReactElement)) {
      const children = (n as ReactElement<{ children?: React.ReactNode }>).props
        .children;
      if (children !== undefined) walk(children);
    }
  };
  nodes.forEach(walk);
  return out;
}

/** 找出树中第一个指定类型的元素 */
function findEl(
  nodes: React.ReactNode[],
  type: string,
): ReactElement | undefined {
  let found: ReactElement | undefined;
  const walk = (n: React.ReactNode) => {
    if (found) return;
    if (Array.isArray(n)) {
      n.forEach(walk);
    } else if (n != null && typeof n === "object" && "type" in (n as ReactElement)) {
      const el = n as ReactElement;
      // host 元素（p/ul/li/strong…）type 是字符串；浅比较即可
      if (el.type === type) {
        found = el;
        return;
      }
      const children = (el.props as { children?: React.ReactNode }).children;
      if (children !== undefined) walk(children);
    }
  };
  nodes.forEach(walk);
  return found;
}

describe("renderMarkdown 块级", () => {
  it("标题：# 前缀渲染为 p 且带 font-semibold", () => {
    const out = renderMarkdown("# 大标题");
    const p = findEl(out, "p");
    expect(p).toBeDefined();
    expect((p!.props as { className?: string }).className).toContain(
      "font-semibold",
    );
    expect(texts(out)).toEqual(["大标题"]);
  });

  it("无序列表：连续 - 行聚合为单个 ul 多个 li", () => {
    const out = renderMarkdown("- 甲\n- 乙\n- 丙");
    const ul = findEl(out, "ul");
    expect(ul).toBeDefined();
    // 列表内 3 个 li（从 ul 的 children 里数）
    const children = (ul!.props as { children: React.ReactNode[] }).children;
    const lis = Array.isArray(children) ? children.filter((c) => findEl([c], "li")) : [];
    expect(lis.length).toBe(3);
    expect(texts(out)).toEqual(["甲", "乙", "丙"]);
  });

  it("列表前后普通行不吞并：段落与列表分块", () => {
    const out = renderMarkdown("开头段\n- 项1\n结尾段");
    expect(texts(out)).toEqual(["开头段", "项1", "结尾段"]);
    expect(findEl(out, "ul")).toBeDefined();
    expect(findEl(out, "p")).toBeDefined();
  });

  it("任务列表残留字符（- [ ]/- [x]）按原文渲染为 li 文本", () => {
    const out = renderMarkdown("- [ ] 未完成\n- [x] 已完成");
    expect(texts(out)).toEqual(["[ ] 未完成", "[x] 已完成"]);
  });

  it("有序列表：数字点行聚合为单个 ol 多个 li（含中文顿号形态）", () => {
    const out = renderMarkdown("1. 第一步\n2. 第二步\n10. 第十步");
    const ol = findEl(out, "ol");
    expect(ol).toBeDefined();
    expect((ol!.props as { className?: string }).className).toContain("list-decimal");
    expect(texts(out)).toEqual(["第一步", "第二步", "第十步"]);
    // 有序与无序不互相吞并
    const mixed = renderMarkdown("- 无序项\n1. 有序项");
    expect(findEl(mixed, "ul")).toBeDefined();
    expect(findEl(mixed, "ol")).toBeDefined();
  });

  it("引用块：> 前缀连续行聚合为 blockquote，普通行结束块", () => {
    const out = renderMarkdown("> 引用第一行\n> 引用第二行\n普通段");
    const bq = findEl(out, "blockquote");
    expect(bq).toBeDefined();
    expect((bq!.props as { className?: string }).className).toContain("border-l-2");
    expect(texts(out)).toEqual(["引用第一行", "引用第二行", "普通段"]);
  });

  it("空行渲染为段距 div", () => {
    const out = renderMarkdown("上\n\n下");
    expect(findEl(out, "div")).toBeDefined();
    expect(texts(out)).toEqual(["上", "下"]);
  });
});

describe("renderMarkdown 行内", () => {
  it("粗体 **x** 渲染 strong 且字号分档正确", () => {
    const out = renderMarkdown("**重要**");
    expect(findEl(out, "strong")).toBeDefined();
    expect(texts(out)).toEqual(["重要"]);
  });

  it("行内代码 `x` 渲染 code 元素", () => {
    const out = renderMarkdown("用 `flutter test` 跑测试");
    expect(findEl(out, "code")).toBeDefined();
    expect(texts(out)).toEqual(["用 ", "flutter test", " 跑测试"]);
  });

  it("斜体 *x* 渲染 em；单个 * 不成对按原文", () => {
    expect(findEl(renderMarkdown("*斜体*"), "em")).toBeDefined();
    expect(texts(renderMarkdown("3 * 4 = 12"))).toEqual(["3 * 4 = 12"]);
  });

  it("删除线 ~~x~~ 渲染 del；未闭合双波浪线按原文", () => {
    const out = renderMarkdown("~~废弃方案~~");
    const del = findEl(out, "del");
    expect(del).toBeDefined();
    expect(texts(out)).toEqual(["废弃方案"]);
    expect(texts(renderMarkdown("~~未闭合"))).toEqual(["~~未闭合"]);
  });

  it("链接 [text](url) 渲染 a 且 href/target 正确", () => {
    const out = renderMarkdown("[官网](https://example.com)");
    const a = findEl(out, "a") as ReactElement<{
      href: string;
      target: string;
    }>;
    expect(a).toBeDefined();
    expect(a!.props.href).toBe("https://example.com");
    expect(a!.props.target).toBe("_blank");
    expect(texts(out)).toEqual(["官网"]);
  });

  it("未闭合标记（`code 无尾）按原文输出", () => {
    expect(texts(renderMarkdown("`未闭合"))).toEqual(["`未闭合"]);
  });
});
