/**
 * 日历滚轮步进回归（桌面 mouse/trackpad 手势）：
 * - 日期弹层（PickerCalendar）整体滚轮切月；
 * - 年/月下拉展开时滚轮只滚列表，不翻月（portal 让位）；
 * - 日历视图：月历整体滚轮翻月，工具栏年/月分段各滚各，年视图滚轮切年。
 *
 * 合成 wheel 事件与字体无关，可稳定入库。
 */
import { expect, test, type Page } from "@playwright/test";

/** 打开快速新增的完整日期弹层（复用冒烟 seeding 口径） */
async function openPickerCalendar(page: Page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.evaluate(() => {
    (window as any).__orbitMock.seed();
  });
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
  await page.getByPlaceholder("添加任务").fill("滚轮验证任务");
  await page.evaluate(() => {
    const btns = Array.from(document.querySelectorAll("button"));
    const cal = btns.find((b) => b.querySelector("svg.lucide-calendar"));
    if (!cal) throw new Error("找不到截止日期按钮");
    (cal as HTMLElement).click();
  });
  await page.evaluate(() => {
    const el = Array.from(document.querySelectorAll("*")).find(
      (e) =>
        e.textContent === "选择日期" &&
        (e as HTMLElement).offsetParent !== null &&
        (e.children?.length ?? 0) === 0,
    );
    if (!el) throw new Error("找不到选择日期入口");
    (el as HTMLElement).click();
  });
  const monthTrigger = page.getByRole("combobox", { name: "选择月份" });
  await expect(monthTrigger).toBeVisible();
  return monthTrigger;
}

/** 切到日历视图（月模式） */
async function openCalendarView(page: Page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.evaluate(() => {
    localStorage.setItem("todo_view_mode", "calendar");
    (window as any).__orbitMock.seed();
  });
  await page.reload();
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  // 工具栏年月标题出现 = 日历视图就绪
  const title = page.locator("h2").first();
  await expect(title).toBeVisible();
  return title;
}

test("日期弹层滚轮下上翻月并回位", async ({ page }) => {
  const monthTrigger = await openPickerCalendar(page);
  const before = await monthTrigger.textContent();

  await monthTrigger.hover();
  await page.mouse.wheel(0, 120);
  await expect
    .poll(async () => monthTrigger.textContent(), { timeout: 5_000 })
    .not.toBe(before);

  await page.waitForTimeout(300); // 步进冷却
  await monthTrigger.hover();
  await page.mouse.wheel(0, -120);
  await expect
    .poll(async () => monthTrigger.textContent(), { timeout: 5_000 })
    .toBe(before);
});

test("日期弹层快速连滑 5 格恰好进 5 月（合并渲染但零丢步）", async ({ page }) => {
  const monthTrigger = await openPickerCalendar(page);
  const before = (await monthTrigger.textContent()) ?? "";
  const startMonth = parseInt(before, 10);

  await monthTrigger.hover();
  // 背靠背连滑：全部落入同一冷却窗的步数必须累积，后沿一次性补齐
  for (let i = 0; i < 5; i++) {
    await page.mouse.wheel(0, 120);
  }
  const expected = `${((startMonth - 1 + 5) % 12) + 1}月`;
  await expect
    .poll(async () => monthTrigger.textContent(), { timeout: 5_000 })
    .toBe(expected);
});

test("年份下拉展开时滚轮不翻月", async ({ page }) => {
  const monthTrigger = await openPickerCalendar(page);
  const before = await monthTrigger.textContent();

  const yearTrigger = page.getByRole("combobox", { name: "选择年份" });
  await yearTrigger.click();
  const listbox = page.getByRole("listbox");
  await expect(listbox).toBeVisible();
  const firstOption = listbox.getByRole("option").first();
  await firstOption.hover();
  await page.mouse.wheel(0, 300);
  await page.waitForTimeout(400);
  // 月份未动，列表仍展开（原生滚动接管，无翻月副作用）
  expect(await monthTrigger.textContent()).toBe(before);
  await expect(listbox).toBeVisible();
});

test("日历视图月历滚轮翻月、标题年段滚轮切年", async ({ page }) => {
  const title = await openCalendarView(page);
  const yearSpan = title.locator('span[title="滚轮切换年份"]');
  const monthSpan = title.locator('span[title="滚轮切换月份"]');
  await expect(yearSpan).toBeVisible();
  const beforeTitle = await title.textContent();

  // 月历网格滚轮下翻一月
  await page.locator('[data-testid="month-calendar-grid"]').first().hover();
  await page.mouse.wheel(0, 120);
  await expect
    .poll(async () => title.textContent(), { timeout: 5_000 })
    .not.toBe(beforeTitle);

  // 标题月段滚轮上翻回位
  await page.waitForTimeout(300);
  await monthSpan.hover();
  await page.mouse.wheel(0, -120);
  await expect
    .poll(async () => title.textContent(), { timeout: 5_000 })
    .toBe(beforeTitle);

  // 标题年段滚轮下切一年
  await page.waitForTimeout(300);
  const beforeYear = await yearSpan.textContent();
  await yearSpan.hover();
  await page.mouse.wheel(0, 120);
  await expect
    .poll(async () => yearSpan.textContent(), { timeout: 5_000 })
    .not.toBe(beforeYear);
});

test("年视图滚轮切年", async ({ page }) => {
  await openCalendarView(page);
  await page.getByRole("button", { name: "年", exact: true }).click();
  const yearLabel = page.locator("span.text-3xl").first();
  await expect(yearLabel).toBeVisible();
  const before = await yearLabel.textContent();

  await yearLabel.hover();
  await page.mouse.wheel(0, 120);
  await expect
    .poll(async () => yearLabel.textContent(), { timeout: 5_000 })
    .not.toBe(before);
});
