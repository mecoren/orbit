/**
 * 更新日志：列表 → 原地详情 → 返回（版式与开源组件区同源）。
 *
 * 运行环境同 smoke.spec.ts：纯浏览器 + mock IPC，不启 Tauri 壳。
 * mock 只给一条版本（版本号 = 清单版本），供发布护栏与交互回归共用。
 */
import { expect, test } from "@playwright/test";

test("更新日志：版本列表 → 详情 → 返回", async ({ page }) => {
  await page.goto("/about");
  await expect(page.getByRole("heading", { name: "关于" })).toBeVisible({
    timeout: 15_000,
  });

  await page.getByRole("button", { name: "更新日志", exact: true }).click();
  await expect(page.getByText(/共 \d+ 个版本/)).toBeVisible();

  // 列表行：版本号 + 日期 + 条目数，点开进详情
  await page.getByRole("button", { name: /^v\d/ }).first().click();
  await expect(
    page.getByRole("button", { name: "返回版本列表" }),
  ).toBeVisible();
  await expect(page.getByText("发布日期")).toBeVisible();
  await expect(page.getByText("变更条目")).toBeVisible();
  await expect(page.getByText("同上").first()).toBeVisible();

  // 返回列表：标题与版本记录仍在
  await page.getByRole("button", { name: "返回版本列表" }).click();
  await expect(page.getByText(/共 \d+ 个版本/)).toBeVisible();
});
