/**
 * 冲突败方副本冒烟（03 文档 §八 遗留项兑现）
 *
 * 覆盖设置页「冲突记录」主路径：造态两条冲突 → 查看字段级差异 → 恢复为败方版本
 * → 已处置行离开待处理列表（切「全部」可见「已恢复」）。
 *
 * 前置：ipc-mock 在模块加载时造两条冲突（本地被覆盖 / 远端被丢弃各一），
 * 与 Rust 侧 sync_conflict_api 的口径同构；写命令仍走 mock 广播 db-change。
 */
import { expect, test, type Page } from "@playwright/test";

/** 进设置页并切到「冲突记录」分区 */
async function gotoConflictSection(page: Page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.goto("/settings");
  // 分区标题与左导航同名，点击用 button 角色、断言用 heading 角色区分
  await page.getByRole("button", { name: "冲突记录" }).click();
  await expect(page.getByRole("heading", { name: "冲突记录" })).toBeVisible();
}

test("冲突记录：查看差异 → 恢复败方版本 → 离开待处理列表", async ({ page }) => {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text().slice(0, 500));
  });
  page.on("pageerror", (err) => errors.push(String(err).slice(0, 500)));

  await gotoConflictSection(page);

  // 造态两条：任务「写周报」（本地被覆盖）+ 项目「季度目标」（远端被丢弃）
  await expect(page.getByText("写周报", { exact: true }).first()).toBeVisible();
  await expect(page.getByText("季度目标", { exact: true }).first()).toBeVisible();
  await expect(page.getByText("待处理 2 条")).toBeVisible();
  // 侧别与裁决类型文案（口径与 Rust decision/loser_side 字段一一对应）
  await expect(page.getByText(/本端版本被他端覆盖/).first()).toBeVisible();
  await expect(page.getByText(/他端版本被本端保留丢弃/).first()).toBeVisible();

  // ---- 查看差异：展开后显示「字段 / 当前（胜方）/ 被覆盖（败方）」三列 ----
  await page.getByRole("button", { name: /查看差异/ }).first().click();
  await expect(page.getByText("当前（胜方 · 他端）")).toBeVisible();
  await expect(page.getByText("被覆盖（败方 · 本端）")).toBeVisible();
  // 差异字段：优先级（1 → 3）与胜方标题
  await expect(page.getByText("优先级", { exact: true })).toBeVisible();
  await expect(page.getByText("写周报（本周）").first()).toBeVisible();

  // ---- 恢复：二次确认 → 败方内容回放为新的本端版本 ----
  await page.getByRole("button", { name: "恢复", exact: true }).first().click();
  await expect(page.getByText("恢复为败方版本")).toBeVisible();
  await page.getByRole("button", { name: "确认恢复" }).click();

  // 已处置的行不再属于「待处理」：切「全部」后可见「已恢复」标记
  // （行内状态挂在同一条副标题文案尾部，用子串正则匹配避开 toast 文案）
  await page.getByRole("button", { name: "全部", exact: true }).click();
  await expect(page.getByText("共 2 条")).toBeVisible();
  await expect(page.getByText(/· 已恢复/).first()).toBeVisible();

  expect(errors, `页面报错：${errors.join(" | ")}`).toEqual([]);
});

test("冲突记录：清空记录需二次确认", async ({ page }) => {
  await gotoConflictSection(page);

  await page.getByRole("button", { name: "清空记录" }).click();
  await expect(page.getByText(/将删除全部 2 条本地冲突记录/)).toBeVisible();
  await page.getByRole("button", { name: "确认清空" }).click();

  await expect(
    page.getByText("暂无冲突；多端并发修改同一记录后会在这里留档。"),
  ).toBeVisible();
});
