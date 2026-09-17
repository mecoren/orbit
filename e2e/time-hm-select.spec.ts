/**
 * TimeHMSelect 回归（时:分手输 + 下拉二合一）
 *
 * 背景：日期弹层/快捷新增提醒/抽屉弹层的时间行与自动备份时刻统一换成
 * 共享 TimeHMSelect。下拉列表刻意不用 Radix portal（PopoverContent 内
 * 嵌 portal 是仓库已知坑），本文件在真实浏览器里验证：
 * 下拉点选不关父弹层、手输提交/钳制/空回退。
 */

import { expect, test, type Page } from "@playwright/test";

async function gotoApp(page: Page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
}

test("快捷新增提醒：下拉点选 + 手输提交/钳制/空回退", async ({ page }) => {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text().slice(0, 500));
  });
  page.on("pageerror", (err) => errors.push(String(err).slice(0, 500)));

  await gotoApp(page);
  // 快捷区（提醒时钟）有输入后才浮现：先填标题（纯文本，不触发 NLP 解析）
  await page.getByPlaceholder("添加任务").fill("时间选择验证");
  const clockBtn = page.getByRole("button", { name: "提醒时间" });
  await clockBtn.click();
  await page.getByRole("button", { name: "选择日期和时间" }).click();

  const hour = page.getByLabel("小时", { exact: true });
  const minute = page.getByLabel("分钟", { exact: true });
  await expect(hour).toHaveValue("09");
  await expect(minute).toHaveValue("00");

  // 下拉点选小时：父弹层保持打开（列表是内联渲染，无 portal 嵌套）
  await page.getByRole("button", { name: "小时下拉选择" }).click();
  await expect(page.getByRole("listbox", { name: "小时" })).toBeVisible();
  await page.getByRole("option", { name: "18", exact: true }).click();
  await expect(hour).toHaveValue("18");
  // 父弹层未被关闭：时间行仍在，且草稿已提交（时钟钮高亮）
  await expect(minute).toBeVisible();
  await expect(clockBtn).toHaveClass(/bg-primary/);

  // 分钟下拉滚轮（window 捕获手动滚动，对抗 Dialog/Sheet 的 RemoveScroll）
  await page.getByRole("button", { name: "分钟下拉选择" }).click();
  const minList = page.getByRole("listbox", { name: "分钟" });
  await expect(minList).toBeVisible();
  expect(await minList.evaluate((el) => el.scrollTop)).toBe(0);
  const mbox = await minList.boundingBox();
  await page.mouse.move((mbox?.x ?? 0) + 30, (mbox?.y ?? 0) + 40);
  await page.mouse.wheel(0, 400);
  await expect
    .poll(() => minList.evaluate((el) => el.scrollTop), { timeout: 3000 })
    .toBeGreaterThan(0);
  // 下拉行样式与项目统一：text-sm 行 + p-1 容器（原 text-xs 无内边距）
  const itemFont = await minList.evaluate(
    (el) => getComputedStyle(el.querySelector('[role="option"]')!).fontSize,
  );
  expect(itemFont).toBe("14px");
  await page.getByRole("option", { name: "30", exact: true }).click();
  await expect(minute).toHaveValue("30");

  // 手输分钟 + 回车提交：补零
  await minute.fill("7");
  await minute.press("Enter");
  await expect(minute).toHaveValue("07");

  // 越界钳制：小时 99 → 23
  await hour.fill("99");
  await hour.press("Tab");
  await expect(hour).toHaveValue("23");

  // 空草稿回退原值（不跳 00）
  await hour.fill("");
  await hour.press("Tab");
  await expect(hour).toHaveValue("23");

  // 几何：时间行不撑破弹层（右端下拉钮不横向溢出）
  const fits = await page
    .getByRole("button", { name: "分钟下拉选择" })
    .evaluate((el) => {
      const pop = el.closest("[data-radix-popper-content-wrapper]");
      if (!pop) return false;
      const a = el.getBoundingClientRect();
      const b = pop.getBoundingClientRect();
      return a.left >= b.left - 1 && a.right <= b.right + 1;
    });
  expect(fits).toBe(true);

  expect(errors).toEqual([]);
});

test("自动备份时刻：下拉点选 + 手输提交", async ({ page }) => {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text().slice(0, 500));
  });
  page.on("pageerror", (err) => errors.push(String(err).slice(0, 500)));

  await gotoApp(page);
  // mock 的 backup_prefs_get 回 null（卡片永久加载中），用例内伪造 daily 偏好
  await page.goto("/settings");
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__;
    const origInvoke = internals.invoke.bind(internals);
    internals.invoke = (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "backup_prefs_get") {
        return Promise.resolve({
          local_path: null,
          keep_latest: true,
          cloud_backup_enabled: false,
          local_backup_enabled: true,
          schedule_type: "daily",
          schedule_time: "03:00",
          schedule_minute: 0,
          schedule_weekday: 0,
          schedule_day_of_month: 1,
          schedule_month: 1,
          last_backup_at: 0,
          next_backup_at: 0,
        });
      }
      return origInvoke(cmd, args);
    };
  });
  await page.getByRole("button", { name: "同步与备份" }).click();
  await expect(page.getByText("全量备份（.orfullsync）")).toBeVisible();

  const hour = page.getByLabel("小时", { exact: true });
  const minute = page.getByLabel("分钟", { exact: true });
  await expect(hour).toHaveValue("03");
  await expect(minute).toHaveValue("00");

  // 下拉点选分钟（60 项长列表，选中项自动滚到可视区）
  await page.getByRole("button", { name: "分钟下拉选择" }).click();
  await expect(page.getByRole("listbox", { name: "分钟" })).toBeVisible();
  await page.getByRole("option", { name: "45", exact: true }).click();
  await expect(minute).toHaveValue("45");

  // 手输小时 + 失焦提交
  await hour.fill("6");
  await hour.press("Enter");
  await expect(hour).toHaveValue("06");

  expect(errors).toEqual([]);
});

test("抽屉截止时间：下拉改分 + 手输改时 + 确定落库", async ({ page }) => {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text().slice(0, 500));
  });
  page.on("pageerror", (err) => errors.push(String(err).slice(0, 500)));

  await gotoApp(page);
  await page.evaluate(() => {
    (window as any).__orbitMock.seed();
  });
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();

  // 左键进抽屉；seed 任务今天 10:00 截止
  await page.getByText("既有任务-今天截止").click();
  const today = new Date();
  const dateStr = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
  const dueTrigger = page.getByRole("button", { name: new RegExp(`${dateStr} \\d{2}:\\d{2}`) });
  await expect(dueTrigger).toBeVisible({ timeout: 10_000 });
  await dueTrigger.click();
  await page.getByRole("button", { name: "选择日期和时间" }).click();

  const hour = page.getByLabel("小时", { exact: true });
  const minute = page.getByLabel("分钟", { exact: true });
  await expect(hour).toBeVisible();

  // 几何：日期网格左右对称（相对弹层内容盒，容差 2px，不过界）
  const geo = await page.evaluate(() => {
    const hourEl = document.querySelector('input[aria-label="小时"]');
    const content = hourEl
      ?.closest("[data-radix-popper-content-wrapper]")
      ?.querySelector(":scope > div");
    const grid = content?.querySelector('[data-testid="month-calendar-grid"]');
    if (!content || !grid) return null;
    const cs = getComputedStyle(content);
    const cb = content.getBoundingClientRect();
    const tb = grid.getBoundingClientRect();
    return {
      left: tb.left - cb.left - parseFloat(cs.paddingLeft),
      right: cb.right - parseFloat(cs.paddingRight) - tb.right,
    };
  });
  expect(geo).not.toBeNull();
  expect(Math.abs(geo!.left - geo!.right)).toBeLessThanOrEqual(2);
  expect(geo!.right).toBeGreaterThanOrEqual(-1);

  // 年份下拉滚轮（201 项虚拟列表，同走 window 捕获手动滚动；
  // 打开即居中到当前年，基线非零，必须断言相对位移）
  await page.getByRole("combobox", { name: "选择年份" }).click();
  const yearList = page.getByRole("listbox");
  await expect(yearList).toBeVisible();
  const yearBefore = await yearList.evaluate((el) => el.scrollTop);
  const ybox = await yearList.boundingBox();
  await page.mouse.move((ybox?.x ?? 0) + 40, (ybox?.y ?? 0) + 60);
  await page.mouse.wheel(0, 400);
  await expect
    .poll(() => yearList.evaluate((el) => el.scrollTop), { timeout: 3000 })
    .toBeGreaterThan(yearBefore + 100);
  // 再点一次触发器收起（不改年份，日历不翻页）
  await page.getByRole("combobox", { name: "选择年份" }).click();
  await expect(yearList).toHaveCount(0);

  await expect(hour).toHaveValue("10");
  await expect(minute).toHaveValue("00");

  // 下拉改分 + 手输改时
  await page.getByRole("button", { name: "分钟下拉选择" }).click();
  await page.getByRole("option", { name: "30", exact: true }).click();
  await expect(minute).toHaveValue("30");
  await hour.fill("9");
  await hour.press("Enter");
  await expect(hour).toHaveValue("09");

  // 确定落库：触发钮文案更新，父弹层关闭
  await page.getByRole("button", { name: "确定", exact: true }).click();
  await expect(
    page.getByRole("button", { name: `${dateStr} 09:30` }),
  ).toBeVisible({ timeout: 5000 });

  expect(errors).toEqual([]);
});
