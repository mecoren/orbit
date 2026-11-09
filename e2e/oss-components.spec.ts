/**
 * 开源组件：关于页入口 → 列表（来源 Tab / 排序）→ 详情 → 返回。
 *
 * 运行环境同 release-ui.spec.ts：纯浏览器 + mock IPC，不启 Tauri 壳。
 * 数据来自 src/test/ipc-mock.ts 的 oss_components（6 条，覆盖三类来源）；
 * 桌面壳只展示自己的直接依赖，Flutter 条目整体隐藏（前端 2 + Rust 2）。
 */
import { expect, test } from "@playwright/test";

test("开源组件：来源 Tab、排序、详情与返回", async ({ page }) => {
  await page.goto("/about");
  await expect(page.getByRole("heading", { name: "关于" })).toBeVisible({
    timeout: 15_000,
  });

  await page.getByRole("button", { name: "开源组件", exact: true }).click();
  await expect(page.getByRole("heading", { name: "开源组件" })).toBeVisible();
  await expect(
    page.getByText("共 4 个直接依赖（前端 2 · Rust 2）"),
  ).toBeVisible();

  // 桌面端隐藏移动壳来源：Flutter 条目在任一 Tab 都不出现
  await expect(page.getByText("react", { exact: true })).toBeVisible();
  await expect(page.getByText("flutter_miuix", { exact: true })).toHaveCount(0);
  await expect(page.getByText("go_router", { exact: true })).toHaveCount(0);

  // 来源 Tab：切 Rust 后只剩两条 Rust 依赖
  await page.getByRole("tab", { name: "Rust" }).click();
  await expect(page.getByText("tauri", { exact: true })).toBeVisible();
  await expect(page.getByText("sqlx", { exact: true })).toBeVisible();
  await expect(page.getByText("react", { exact: true })).toHaveCount(0);
  await expect(page.getByText("flutter_miuix", { exact: true })).toHaveCount(0);

  // 排序：名称 A→Z 后 sqlx 排在 tauri 前
  await page.getByRole("button", { name: "默认排序" }).click();
  await page.getByRole("menuitemradio", { name: "名称 A→Z" }).click();
  const sqlxY = (await page.getByText("sqlx", { exact: true }).boundingBox())?.y;
  const tauriY = (await page.getByText("tauri", { exact: true }).boundingBox())?.y;
  expect(sqlxY).toBeDefined();
  expect(tauriY).toBeDefined();
  expect(sqlxY!).toBeLessThan(tauriY!);

  // 详情：名称、基础信息、仓库外链
  await page.getByRole("button", { name: /tauri/ }).click();
  await expect(page.getByRole("heading", { name: "tauri" })).toBeVisible();
  await expect(page.getByText("来源", { exact: true })).toBeVisible();
  await expect(page.getByText("许可证", { exact: true })).toBeVisible();
  await expect(page.getByText("Apache-2.0 / MIT").first()).toBeVisible();
  await expect(
    page.getByRole("link", { name: /github\.com\/tauri-apps\/tauri/ }),
  ).toBeVisible();

  // 返回列表：Tab 与排序状态保留
  await page.getByRole("button", { name: "返回组件列表" }).click();
  await expect(page.getByRole("heading", { name: "开源组件" })).toBeVisible();
  await expect(page.getByText("tauri", { exact: true })).toBeVisible();
  await expect(page.getByText("react", { exact: true })).toHaveCount(0);
});
