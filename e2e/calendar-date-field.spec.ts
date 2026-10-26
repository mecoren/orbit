/**
 * 日历日期口径切换回归：截止日期（历史默认）/ 开始日期
 *
 * 覆盖点：
 * - 工具栏「日期口径」分段存在，默认「截止」按下（存量用户行为不变）
 * - 切到「开始」后按 start_date 分桶：无开始日期的任务不显示，空态文案随口径
 * - 补上 start_date 后任务回到右栏；切回「截止」恢复历史默认
 *
 * 前置同 calendar-week：视图档位经 localStorage 注入，seed 在页面加载后写入
 * 内存库（mock db 每次 goto 重建，不能先 seed 再 reload）。
 */
import { expect, test, type Page } from "@playwright/test";

async function openCalendar(page: Page) {
  await page.addInitScript(() => {
    localStorage.setItem("todo_view_mode", "calendar");
  });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.evaluate(() => {
    (window as any).__orbitMock.seed();
  });
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
}

test("日期口径：默认按截止日期，切「开始」后按 start_date 分桶", async ({ page }) => {
  await openCalendar(page);
  const group = page.getByRole("group", { name: "日历日期口径" });
  await expect(group.getByRole("button", { name: "截止" })).toHaveAttribute(
    "aria-pressed",
    "true",
  );

  // seed 任务只有截止日期 → 切到开始口径后不显示，空态文案随口径变化
  await group.getByRole("button", { name: "开始" }).click();
  await expect(page.getByText("本月没有带开始日期的任务")).toBeVisible();
  await expect(page.getByText("既有任务-今天截止")).toHaveCount(0);

  // 补上今天零点的开始日期 → 任务回到右栏
  await page.evaluate(() => {
    const mock = (window as any).__orbitMock;
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    mock.db.tasks[0].start_date = today.getTime();
    mock.emitDbChange();
  });
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();

  // 切回截止口径：恢复历史默认，任务仍在
  await group.getByRole("button", { name: "截止" }).click();
  await expect(group.getByRole("button", { name: "截止" })).toHaveAttribute(
    "aria-pressed",
    "true",
  );
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
});
