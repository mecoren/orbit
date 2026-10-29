// Spinner 原语几何口径：与移动端 orbit_spinner.dart / 参考实现同源的比例锁定。
// vitest 为 node 环境（vitest.config.ts），组件渲染由 e2e 覆盖，这里只校验纯数据。
import { describe, expect, it } from "vitest";

import { SPINNER_GEOMETRY } from "./spinner";

describe("SPINNER_GEOMETRY", () => {
  const { viewBox, strokeWidth, trackAlpha, dotRadius, dotCenterY } =
    SPINNER_GEOMETRY;
  const radius = (viewBox - strokeWidth) / 2;

  it("描边宽度按边长 8% 推导", () => {
    expect(strokeWidth).toBeCloseTo(viewBox * 0.08, 6);
  });

  it("轨道透明度 0.28（点实色，两者拉开层次）", () => {
    expect(trackAlpha).toBeCloseTo(0.28, 6);
  });

  it("点半径 / 环半径 = 0.34", () => {
    expect(dotRadius / radius).toBeCloseTo(0.34, 6);
  });

  it("点心落在 12 点方向、轨道半径 42% 处", () => {
    expect(dotCenterY).toBeLessThan(viewBox / 2);
    expect((viewBox / 2 - dotCenterY) / radius).toBeCloseTo(0.42, 6);
  });

  it("点与外环不重叠（点不压环描边）", () => {
    const orbit = viewBox / 2 - dotCenterY;
    expect(orbit + dotRadius).toBeLessThan(radius - strokeWidth / 2);
  });
});
