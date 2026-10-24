/**
 * 项目回顾节奏（F1）冒烟：到期归集 → 侧栏徽标 → 回顾中心处置闭环。
 *
 * 前置与 smoke.spec 同构：ipc-mock 内存库 + __orbitMock 直改 + emitDbChange
 * 刷新。到期判定真值在 core（Rust 单测覆盖）；这里验证的是 mock 镜像与
 * 桌面 UI 的接链：到期行渲染/排序文案、徽标出现与消失、向导完成标记已回顾。
 */
import { expect, test, type Page } from "@playwright/test";

/** 给 seed 项目开回顾周期并把上次回顾拨到 N 天前（正午基点，DST 安全） */
async function backdateReview(page: Page, intervalDays: number, reviewedDaysAgo: number) {
  await page.evaluate(
    ({ intervalDays, reviewedDaysAgo }) => {
      const m = (window as any).__orbitMock;
      const p = m.db.projects[0];
      p.review_interval_days = intervalDays;
      const d = new Date();
      const noon = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 12).getTime();
      p.review_last_at = noon - reviewedDaysAgo * 86_400_000;
      m.emitDbChange();
    },
    { intervalDays, reviewedDaysAgo },
  );
}

/** 侧栏「回顾」入口（到期时无障碍名带计数后缀「回顾 N」，用正则兼容两种态；
 *  不裸匹配「回顾」防撞「周回顾」菜单项） */
function reviewEntry(page: Page) {
  return page.getByRole("button", { name: /^回顾( \d+)?$/ });
}

/** 等回顾中心面板就绪 */
async function openReviewCenter(page: Page) {
  await reviewEntry(page).click();
  await expect(page.getByRole("heading", { name: "回顾" })).toBeVisible();
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.evaluate(() => {
    (window as any).__orbitMock.seed();
  });
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
});

test("到期项目进回顾中心：逾期文案/未完成计数/侧栏徽标/已回顾收口", async ({ page }) => {
  // 周期 7 天、上次回顾 10 天前 → 到期 3 天前（已逾期 3 天）；seed 任务未完成 → 计数 1
  await backdateReview(page, 7, 10);

  // 侧栏项目行出现「待回顾」徽标（琥珀点），侧栏「回顾」入口带计数
  await expect(page.locator('[data-testid="project-row"] button[aria-label="测试项目待回顾"]')).toBeVisible();
  // 计数徽标：textContent 直连无空格（「回顾1」），无障碍名有空格（「回顾 1」）
  await expect(reviewEntry(page)).toHaveText(/回顾1/);

  await openReviewCenter(page);
  const row = page.getByTestId("review-row");
  await expect(row).toHaveCount(1);
  await expect(row.getByText("测试项目")).toBeVisible();
  await expect(row.getByText("每周")).toBeVisible();
  await expect(row.getByText("已逾期 3 天")).toBeVisible();
  await expect(row.getByText("1 件未完成", { exact: false })).toBeVisible();

  // 点徽标直达的入口也在（同一行「开始回顾」按钮存在，本用例只走快捷收口）
  await row.getByRole("button", { name: "已回顾" }).click();
  await expect(row).toHaveCount(0);
  // 侧栏徽标随 db-change 失效链消失
  await expect(
    page.locator('[data-testid="project-row"] button[aria-label="测试项目待回顾"]'),
  ).toHaveCount(0);
});

test("开始回顾走完向导 → 自动标记已回顾（三步空清单直通）", async ({ page }) => {
  await backdateReview(page, 14, 20);

  await openReviewCenter(page);
  const row = page.getByTestId("review-row");
  await expect(row).toHaveCount(1);
  await row.getByRole("button", { name: "开始回顾" }).click();

  // 向导标题带项目名（复用周回顾组件的 heading 注入）
  await expect(page.getByText("项目回顾 · 测试项目")).toBeVisible();
  // 三步直通（seed 任务不落逾期/无日期/停滞任何一桶，各步空清单）
  for (const _ of [1, 2, 3]) {
    await page.getByRole("button", { name: /下一步|完成回顾/ }).click();
  }
  await expect(page.getByText("项目回顾 · 测试项目")).not.toBeVisible();
  // 完成回调标记已回顾：行消失 + 库侧 review_last_at 已推进到当前
  await expect(row).toHaveCount(0);
  const lastAt = await page.evaluate(() => (window as any).__orbitMock.db.projects[0].review_last_at as number);
  expect(lastAt).toBeGreaterThan(Date.now() - 60_000);
});

test("暂缓一周：行退场且 7 天内不再到期", async ({ page }) => {
  await backdateReview(page, 7, 10);
  await openReviewCenter(page);
  const row = page.getByTestId("review-row");
  await row.getByRole("button", { name: "稍后一周" }).click();
  await expect(row).toHaveCount(0);
  // 库侧暂缓截止 = 今天零点 + 7 天
  const snooze = await page.evaluate(() => (window as any).__orbitMock.db.projects[0].review_snooze_until as number);
  const d = new Date();
  const dayStart = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  expect(snooze).toBe(dayStart + 7 * 86_400_000);
});

test("未到期/关闭周期的项目不出现在回顾中心（空态）", async ({ page }) => {
  await openReviewCenter(page);
  await expect(page.getByText("没有待回顾的项目")).toBeVisible();
});
