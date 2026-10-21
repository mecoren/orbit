#!/usr/bin/env node
/**
 * mobile-bridge-audit.mjs — 移动端桥「整包过桥」静态门禁（docs/13 §6.2 M5 第 4 点）
 *
 * 存在理由：M1/M2 已把备份与导入改成流式，但**新代码随时可能再把整份文件
 * 读成 `List<int>` 过桥**——这类回归不会让任何测试变红，只会让内存悄悄翻倍。
 * 故用静态清单把它变成可拦截的规则。
 *
 * 规则：
 * - 桥接口（`apps/mobile/lib/data/api/orbit_bridge.dart`）中，形如
 *   `Future<X> name(List<int> ...)` 的方法视为「整包过桥」；
 * - 已有白名单（`ALLOWED`）只允许**已经过评估**的少数几条（附件上传/读取——
 *   附件有 50MB 单文件上限且是内容寻址的必然整块）；
 * - 白名单外新增即拦停，要求改用路径/流式入口。
 *
 * 退出码：0 = 无新增整包过桥；1 = 发现白名单外的整包过桥；2 = 找不到文件（配置错误）。
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BRIDGE = path.join(ROOT, "apps", "mobile", "lib", "data", "api", "orbit_bridge.dart");

/**
 * 已评估并允许的整包过桥方法。
 *
 * 每条都要写清「为什么整块是合理的」——没有理由的白名单就是技术债的温床。
 */
const ALLOWED = new Map([
  [
    "taskAttachmentAdd",
    "附件上传：单文件 50MB 上限 + 内容寻址需先算 hash，整块是协议决定的；超限在 core 侧拒绝",
  ],
  [
    "fullBackupImport",
    "备份导入的**字节版兼容入口**：v1 容器是整包 ZIP，格式决定必须整份解压；" +
      "移动端恢复页已改走 fullBackupImportPath（v2 全程流式、v1 也在 core 内读），" +
      "本方法保留给「已持有字节」的调用方",
  ],
  [
    "fullBackupPeekLocal",
    "备份预览的**字节版兼容入口**：与 fullBackupImport 同源。恢复页已改走 " +
      "fullBackupPeekPath；本方法保留兼容",
  ],
]);

function main() {
  let src;
  try {
    src = readFileSync(BRIDGE, "utf8");
  } catch (e) {
    console.error(`[bridge-audit] 读不到桥接口文件：${BRIDGE}\n${e.message}`);
    return 2;
  }

  // 匹配方法签名：`Future<...> name(参数...);`
  //
  // 实现选择：**不做语法解析**，而是用「方法名 + 其后第一个配平的参数块」
  // 的正向扫描。原因是 Dart 返回类型可嵌套泛型、参数里可出现函数类型
  // （`void Function(int)`）与箭头，任何单一正则都会在某个形态上失配——
  // 而本门禁的失败模式必须是「宁可误报，绝不漏报」。
  const offenders = [];
  // 只认「行首（缩进后）出现的标识符 + (」，即方法声明位置；
  // 这排除了参数里嵌套的函数类型与调用表达式。
  const declRe = /^[ \t]{2}(?:Future<[\s\S]*?>|void|[\w<>,\s]+)\s+(\w+)\s*\(/gm;
  let m;
  while ((m = declRe.exec(src)) !== null) {
    const name = m[1];
    // m[0] 以 '(' 结尾；用它定位参数起点，避免 +1/-1 偏移错位
    const openParen = m.index + m[0].length - 1;
    if (src[openParen] !== "(") continue;
    let i = openParen;
    let depth = 0;
    let end = -1;
    for (; i < src.length; i++) {
      if (src[i] === "(") depth++;
      else if (src[i] === ")") {
        depth--;
        if (depth === 0) {
          end = i;
          break;
        }
      }
    }
    if (end < 0) continue;
    const params = src.slice(openParen + 1, end);
    // 注意：不能写 `\bList<int>\b`——`>` 与后续字符之间没有词边界，
    // 末尾的 \b 会让所有 `List<int>` 参数漏检（实测踩过）。
    if (!/List<int>/.test(params)) continue;
    offenders.push({ name, index: m.index });
  }

  const unexpected = offenders.filter((o) => !ALLOWED.has(o.name));
  const stale = [...ALLOWED.keys()].filter(
    (k) => !offenders.some((o) => o.name === k),
  );

  console.log(`[bridge-audit] 桥接口中带 List<int> 参数的方法 ${offenders.length} 个：`);
  for (const o of offenders) {
    const why = ALLOWED.get(o.name);
    console.log(
      `  - ${o.name.padEnd(24)} ${why ? "允许：" + why : "⚠ 未在白名单"}`,
    );
  }

  if (stale.length) {
    console.log(
      `[bridge-audit] 提示：白名单里 ${stale.join(", ")} 已不再带 List<int>（可清理白名单）`,
    );
  }

  if (unexpected.length) {
    console.error("[bridge-audit] 发现白名单外的整包过桥：");
    for (const o of unexpected) {
      console.error(
        `  - ${o.name}：请改用路径/流式入口（参考 fullBackupImportPath / csvImportJobStart）`,
      );
    }
    return 1;
  }

  console.log("[bridge-audit] 通过：无白名单外的整包过桥");
  return 0;
}

process.exit(main());
