/**
 * 轻量 Markdown 渲染（小而美批次③；描述只读态）
 *
 * 零依赖纯函数子集：标题(#) / 粗体 / 斜体 / 行内代码 / 链接 / 无序列表(-、*)
 * / 任务列表勾选残留(- [ ] / - [x] 原样保留字符) / 换行。
 * 不做完整 CommonMark（表格/脚注/嵌套引用等刻意不收）——描述是短文本场，
 * 引 react-markdown+remark 全家（~100KB）不划算。
 */
import type { ReactNode } from "react";

/** 行内元素解析：`code` / **bold** / *italic* / [text](url) */
function renderInline(text: string, keyPrefix: string): ReactNode[] {
  const out: ReactNode[] = [];
  // 逐字符扫描比多重 replace 稳（避免嵌套标记错配）
  let i = 0;
  let buf = "";
  let k = 0;
  const flush = () => {
    if (buf) {
      out.push(buf);
      buf = "";
    }
  };
  while (i < text.length) {
    const rest = text.slice(i);
    if (rest.startsWith("`")) {
      const end = text.indexOf("`", i + 1);
      if (end > i) {
        flush();
        out.push(
          <code
            key={`${keyPrefix}-c${k++}`}
            className="rounded bg-muted px-1 py-0.5 font-mono text-[12px]"
          >
            {text.slice(i + 1, end)}
          </code>,
        );
        i = end + 1;
        continue;
      }
    }
    if (rest.startsWith("**")) {
      const end = text.indexOf("**", i + 2);
      if (end > i + 1) {
        flush();
        out.push(
          <strong key={`${keyPrefix}-b${k++}`} className="font-semibold">
            {text.slice(i + 2, end)}
          </strong>,
        );
        i = end + 2;
        continue;
      }
    }
    if (rest.startsWith("*") && !rest.startsWith("**")) {
      const end = text.indexOf("*", i + 1);
      if (end > i + 1) {
        flush();
        out.push(
          <em key={`${keyPrefix}-i${k++}`}>{text.slice(i + 1, end)}</em>,
        );
        i = end + 1;
        continue;
      }
    }
    if (rest.startsWith("[")) {
      const closeText = text.indexOf("]", i + 1);
      if (closeText > i && text[closeText + 1] === "(") {
        const closeUrl = text.indexOf(")", closeText + 2);
        if (closeUrl > closeText) {
          flush();
          const label = text.slice(i + 1, closeText);
          const url = text.slice(closeText + 2, closeUrl);
          out.push(
            <a
              key={`${keyPrefix}-a${k++}`}
              href={url}
              target="_blank"
              rel="noopener noreferrer"
              className="text-primary underline underline-offset-2"
            >
              {label}
            </a>,
          );
          i = closeUrl + 1;
          continue;
        }
      }
    }
    buf += text[i];
    i += 1;
  }
  flush();
  return out;
}

/** 块级渲染：按行解析 → React 节点数组（纯展示，无 dangerouslySetInnerHTML） */
export function renderMarkdown(text: string): ReactNode[] {
  const lines = text.split("\n");
  const out: ReactNode[] = [];
  let listBuffer: ReactNode[] = [];
  let k = 0;
  const flushList = () => {
    if (listBuffer.length > 0) {
      out.push(
        <ul key={`ul-${k++}`} className="ml-4 list-disc space-y-0.5">
          {listBuffer}
        </ul>,
      );
      listBuffer = [];
    }
  };
  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    const trimmed = line.trimStart();
    // 无序列表（- 与 *；- [ ] 任务列表残留按原文渲染）
    const bullet = trimmed.match(/^[-*]\s+(.*)$/);
    if (bullet) {
      listBuffer.push(<li key={`li-${li}`}>{renderInline(bullet[1], `l${li}`)}</li>);
      continue;
    }
    flushList();
    // 标题（# ~ ###### 前缀，字号分两档防溢出行高）
    const heading = trimmed.match(/^(#{1,6})\s+(.*)$/);
    if (heading) {
      const level = heading[1].length;
      const size = level <= 2 ? "text-[15px]" : "text-[14px]";
      out.push(
        <p key={`h-${li}`} className={`${size} font-semibold`}>
          {renderInline(heading[2], `h${li}`)}
        </p>,
      );
      continue;
    }
    // 空行 → 段距
    if (line.trim() === "") {
      out.push(<div key={`sp-${li}`} className="h-1.5" />);
      continue;
    }
    // 普通段落
    out.push(<p key={`p-${li}`}>{renderInline(line, `p${li}`)}</p>);
  }
  flushList();
  return out;
}
