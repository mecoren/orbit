/**
 * 设置页「日历」分区的节假日记账冒烟（2026-09-30）
 *
 * 覆盖此前唯一零浏览器级覆盖的双端功能：`holiday_meta` 记账在设置页的呈现——
 * ①正常态只出「上次成功更新」一行；②失败态（`failure_count > 0`）补出「上次尝试」
 * 并用警示色亮出「连续失败 N 次（旧缓存保留可用）」。
 *
 * 前置：`ipc-mock` 的 `holiday_meta` 读 localStorage 造态开关
 * （`__orbitMock.setHolidayFailure`）——mock 是页面模块，内存态跨 `goto` 会丢，
 * 而用例需要「先设态 → 再进设置页」两步导航，故经 localStorage 传递。
 */
import { expect, test, type Page } from "@playwright/test";

/** 进设置页并切到「日历」分区（左导航 button + 分区 heading 同名，用角色区分） */
async function gotoCalendarSection(page: Page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.goto("/settings");
  // exact: 工具栏还有「日历视图」按钮，非精确匹配会命中两个触发 strict mode
  await page.getByRole("button", { name: "日历", exact: true }).click();
  await expect(page.getByRole("heading", { name: "日历" })).toBeVisible();
}

test("设置页日历分区：正常态只出「上次成功更新」，无失败诊断行", async ({ page }) => {
  await gotoCalendarSection(page);

  await expect(page.getByText("每月自动更新", { exact: true })).toBeVisible();
  await expect(page.getByText(/^上次成功更新：/)).toBeVisible();
  await expect(page.getByText(/^尚未成功更新过$/)).toHaveCount(0);
  await expect(page.getByText(/^上次尝试：/)).toHaveCount(0);
  // 只否定**诊断行**：区块底部说明文案里也有「连续失败即中止」字样，松正则会假红
  await expect(
    page.getByText(/^连续失败 \d+ 次（旧缓存保留可用）$/),
  ).toHaveCount(0);
  // 手动入口仍在（记账行不挤掉操作区）
  await expect(page.getByRole("button", { name: "立即更新" })).toBeVisible();
});

test("设置页日历分区：失败态补「上次尝试」+ 警示色「连续失败 N 次」", async ({
  page,
}) => {
  await page.goto("/");
  // 时刻由本地 Date 组件构造、界面按本地组件渲染，两端同机同 tz，故可断言字面量
  const attemptMs = new Date(2026, 8, 30, 15, 20).getTime();
  await page.evaluate((ms) => {
    (window as any).__orbitMock?.setHolidayFailure(3, ms);
  }, attemptMs);

  await gotoCalendarSection(page);

  await expect(page.getByText(/^上次尝试：9月30日 15:20/)).toBeVisible();
  const failureLine = page.getByText("连续失败 3 次（旧缓存保留可用）");
  await expect(failureLine).toBeVisible();

  // 警示色断言用 var(--warning) 探针取基准：oklch 计算值序列化格式不稳定，
  // 直接比字符串不可靠（同 smoke.spec.ts 完成态 checkbox 的取色手法）
  const [actual, warning] = await Promise.all([
    failureLine.evaluate((el) => getComputedStyle(el).color),
    page.evaluate(() => {
      const probe = document.createElement("div");
      probe.style.color = "var(--warning)";
      document.body.appendChild(probe);
      const color = getComputedStyle(probe).color;
      probe.remove();
      return color;
    }),
  ]);
  expect(actual).toBe(warning);
});
