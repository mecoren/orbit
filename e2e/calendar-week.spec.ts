/**
 * 日历周视图回归（G1 周档）
 *
 * 覆盖点：
 * - 工具栏「周」档可切入，周条为 7 列网格（周一→周日）
 * - 标题与工具栏均为周区间（"M月d日 – M月d日"），工具栏带滚轮切周入口
 * - 右栏切为「本周任务」（区间日分组，今天截止的 seed 任务可见）
 * - 翻周（前后按钮）以 7 天为步长；「回到今天」留在周档不跳回月档
 * - 切回「月」档后恢复月度口径
 *
 * 前置：视图档位经 localStorage 注入（addInitScript 在页面脚本前执行）——
 * 不走「···」菜单切视图，避免依赖工具栏菜单结构。
 * seed 在页面加载后写入内存库（mock db 为模块级，刷新即重置，故不可先 seed 再 reload）。
 */
import { expect, test, type Page } from "@playwright/test";

const WEEK_TITLE = 'h2 span[title="滚轮切换周"]';

/** 直接以日历视图启动（档位预置 + 载入后 seed 今天截止任务） */
async function openCalendar(page: Page) {
  await page.addInitScript(() => {
    localStorage.setItem("todo_view_mode", "calendar");
  });
  await page.goto("/");
  // 启动门控：checking（EqualizerLoader）→ 明文免密 → ready
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.evaluate(() => {
    (window as any).__orbitMock.seed();
  });
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
}

/** 工具栏分段控件切档（月/周/年/议程） */
async function switchSubMode(page: Page, label: string) {
  await page.getByRole("button", { name: label, exact: true }).click();
}

test("周档：7 列网格 + 周区间标题 + 右栏本周分组", async ({ page }) => {
  await openCalendar(page);
  await switchSubMode(page, "周");

  // 周区间标题（工具栏滚轮入口 + 标题文案）
  const weekTitle = page.locator(WEEK_TITLE);
  await expect(weekTitle).toBeVisible();
  await expect(weekTitle).toHaveText(/\d+月\d+日 – \d+月\d+日/);

  // 周条为单行 7 格（月档为 42 格）
  await expect(page.locator('[data-testid="month-calendar-grid"] button')).toHaveCount(7);

  // 右栏切为本周口径；今天截止的 seed 任务落在本周
  await expect(page.getByText("本周任务")).toBeVisible();
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
  await expect(page.getByText("本月没有带截止日期的任务")).toHaveCount(0);
});

test("周档：翻周 ±7 天、回到今天留在周档、切回月档", async ({ page }) => {
  await openCalendar(page);
  await switchSubMode(page, "周");
  const weekTitle = page.locator(WEEK_TITLE);
  const before = await weekTitle.textContent();

  // 下一周：标题区间左移 7 天（seed 任务截止今天 → 本周之外，右栏空态）
  await page.getByRole("button", { name: "下一周" }).click();
  await expect(weekTitle).not.toHaveText(before ?? "");
  await expect(page.getByText("本周没有带截止日期的任务")).toBeVisible();

  // 上一周回位：周区间与 seed 任务同时回来
  await page.getByRole("button", { name: "上一周" }).click();
  await expect(weekTitle).toHaveText(before ?? "");
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();

  // 「回到今天」应留在周档（不切回月档）
  await page.getByRole("button", { name: "回到今天" }).click();
  await expect(weekTitle).toBeVisible();

  // 切回月档：标题失去周区间口径，右栏回到「M月的任务」
  await switchSubMode(page, "月");
  await expect(page.locator(WEEK_TITLE)).toHaveCount(0);
  await expect(page.getByText("月的任务")).toBeVisible();
  await expect(page.locator('[data-testid="month-calendar-grid"] button')).toHaveCount(42);
});
