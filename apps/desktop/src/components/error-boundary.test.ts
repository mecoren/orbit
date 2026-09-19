/**
 * recoverFromCrash 纯函数单测（D14）。
 *
 * vitest.config 是 environment node、纯函数测试为主——边界组件本身的
 * 抛错/恢复走 e2e 真实验证（崩溃后 TitleBar 仍在、可点）。
 */
import { describe, expect, it } from "vitest";

import { recoverFromCrash } from "./error-boundary";

describe("recoverFromCrash", () => {
  it("去掉 query/hash，保留路径作重试路径", () => {
    expect(recoverFromCrash("/todo?crash=inner")).toBe("/todo");
    expect(recoverFromCrash("/settings#anchor")).toBe("/settings");
  });

  it("根路径与空串回退到今天（/todo 由 index 导航承担）", () => {
    expect(recoverFromCrash("/")).toBe("/");
    expect(recoverFromCrash("")).toBe("/");
  });

  it("非路径输入不透出（防 location 污染）", () => {
    expect(recoverFromCrash("javascript:alert(1)")).toBe("/");
  });
});
