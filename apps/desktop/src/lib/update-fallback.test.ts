import { describe, expect, it } from "vitest";
import { RELEASES_URL, resolveReleaseFallbackUrl } from "./update-fallback";

describe("resolveReleaseFallbackUrl", () => {
  it("有版本号 → 定位到该 tag（补 v 前缀）", () => {
    expect(resolveReleaseFallbackUrl("0.2.0")).toBe(
      `${RELEASES_URL}/tag/v0.2.0`,
    );
  });

  it("版本号已带 v 前缀 → 不叠加", () => {
    expect(resolveReleaseFallbackUrl("v0.2.0")).toBe(
      `${RELEASES_URL}/tag/v0.2.0`,
    );
    expect(resolveReleaseFallbackUrl("vv0.2.0")).toBe(
      `${RELEASES_URL}/tag/v0.2.0`,
    );
  });

  it("首尾空白容错", () => {
    expect(resolveReleaseFallbackUrl(" 1.0.0 ")).toBe(
      `${RELEASES_URL}/tag/v1.0.0`,
    );
  });

  it("无版本号 / 空串 / null → 落 latest", () => {
    for (const v of [null, undefined, "", "   ", "v"]) {
      expect(resolveReleaseFallbackUrl(v)).toBe(`${RELEASES_URL}/latest`);
    }
  });
});
