import { describe, expect, it } from "vitest";
import { pickGlassStrategy } from "./glass-strategy";

describe("pickGlassStrategy", () => {
  it("mask supported -> mask", () => {
    expect(pickGlassStrategy(true)).toBe("mask");
  });
  it("mask unsupported -> segmented (WKWebView 降级)", () => {
    expect(pickGlassStrategy(false)).toBe("segmented");
  });
});
