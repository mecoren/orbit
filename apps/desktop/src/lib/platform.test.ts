import { describe, expect, it } from "vitest";
import { isMobileUA } from "./platform";

describe("isMobileUA", () => {
  it("android webview ua -> true", () => {
    const ua = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36";
    expect(isMobileUA(ua)).toBe(true);
  });
  it("ios wkwebview ua -> true", () => {
    const ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
    expect(isMobileUA(ua)).toBe(true);
  });
  it("desktop chrome ua -> false", () => {
    const ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
    expect(isMobileUA(ua)).toBe(false);
  });
});
