// 守卫:src 下所有静态 <MaterialIcon name="xxx"> 字面量必须已登记进
// scripts/icon-names.json(动态名如三元/映射值靠人工评审,此测试兜底静态项)。
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const SRC_DIR = fileURLToPath(new URL("../..", import.meta.url)); // src/

function* walk(dir: string): Generator<string> {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else if (p.endsWith(".tsx")) yield p;
  }
}

const allowlist: string[] = JSON.parse(
  readFileSync(join(SRC_DIR, "..", "scripts", "icon-names.json"), "utf8"),
);

describe("material icon 子集清单守卫", () => {
  it("清单无空项、无重复", () => {
    expect(allowlist.every((n) => /^[a-z0-9_]+$/.test(n))).toBe(true);
    expect(new Set(allowlist).size).toBe(allowlist.length);
  });

  it("所有静态 name 字面量都已登记", () => {
    const missing: string[] = [];
    const re = /<MaterialIcon\s+name="([a-z0-9_]+)"/g;
    for (const file of walk(SRC_DIR)) {
      const content = readFileSync(file, "utf8");
      for (const m of content.matchAll(re)) {
        if (!allowlist.includes(m[1])) missing.push(`${m[1]} (${file})`);
      }
    }
    expect(missing).toEqual([]);
  });
});
