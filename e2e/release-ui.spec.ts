/**
 * 关于页版本一致性（发布流程护栏，docs/08_发布与更新流程.md）
 *
 * 守的是「版本漂移」这一类事故：关于页此前硬编码版本号，与清单实际版本
 * 脱节（0.1.0 vs 0.1.1）。现在版本经 vite define 注入，本用例在真实浏览器里
 * 断言徽标 = `apps/desktop/package.json#version`，并确认应用内更新日志
 * 头部条目同版本（与 CHANGELOG.md 同源双写）。
 *
 * 运行环境同 smoke.spec.ts：纯浏览器 + mock IPC，不启 Tauri 壳。
 */
import { readFileSync } from "node:fs";
import path from "node:path";

import { expect, test } from "@playwright/test";

const version: string = JSON.parse(
  readFileSync(path.resolve(__dirname, "../apps/desktop/package.json"), "utf8"),
).version;

test("关于页：版本徽标 = 清单版本，且更新日志头部条目同版本", async ({ page }) => {
  await page.goto("/about");
  await expect(page.getByRole("heading", { name: "关于" })).toBeVisible({ timeout: 15_000 });

  // 版本徽标（应用信息区）——注入值必须等于清单版本
  await expect(page.getByText(`v${version}`, { exact: true }).first()).toBeVisible();

  // 更新日志区：头部条目为当前版本（发版时两处日志须同一次提交写完）
  await page.getByRole("button", { name: "更新日志" }).click();
  await expect(page.getByText(/共 \d+ 个版本/)).toBeVisible();
  const escaped = version.replace(/\./g, "\\.");
  await expect(page.getByRole("button", { name: new RegExp(`v${escaped}\\b`) }).first()).toBeVisible();
});
