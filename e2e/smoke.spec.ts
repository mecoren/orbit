/**
 * 冒烟主链路（07 报告 §五-P2#19：新建→完成→删除）
 *
 * 前置：src/test/ipc-mock.ts 已在页面加载时伪造 IPC（main.tsx 接线），
 * 内存库经 window.__orbitMock 暴露给测试做 seed 与终态断言。
 * 数据流与真实 Tauri 链路同构：写命令 → mock 广播 db-change →
 * events 层 invalidateQueries → UI 刷新。
 */
import { expect, test, type Page } from "@playwright/test";

/** 每用例独立内存库：刷新页面即重置（mock db 在模块加载时创建） */
async function freshApp(page: Page) {
  await page.goto("/");
  // 启动门控：checking（EqualizerLoader）→ 明文免密 → ready
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 15_000,
  });
  // seed 直写内存库后 mock 广播 db-change → invalidateQueries → 列表刷新
  await page.evaluate(() => {
    (window as any).__orbitMock.seed();
  });
  // 既有 seed 任务可见 = 数据流就绪
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
}

/** 底部快速输入栏提交一条任务（04 §3.5 主入口） */
async function quickAdd(page: Page, title: string) {
  const bar = page.getByPlaceholder("添加任务"); // QuickAddBar 占位文案以实际为准
  await bar.fill(title);
  await bar.press("Enter");
}

test.beforeEach(async ({ page }) => {
  await freshApp(page);
});

test("主链路：快速新建 → 列表出现 → 完成 → 撤销删除恢复", async ({ page }) => {
  // ---- 新建（QuickAddBar Enter 提交）----
  await quickAdd(page, "冒烟任务-买牛奶");
  await expect(page.getByText("冒烟任务-买牛奶")).toBeVisible();

  // ---- 完成（行 checkbox）----
  const row = page.getByRole("button", { name: "未完成任务：冒烟任务-买牛奶" });
  await row.getByRole("button", { name: "标记完成" }).click();
  await expect(
    page.getByRole("button", { name: "已完成任务：冒烟任务-买牛奶" }),
  ).toBeVisible();

  // ---- 删除（右键菜单）→ 行消失 → 撤销恢复 ----
  await page.getByText("冒烟任务-买牛奶").click({
    button: "right",
  });
  await page.getByRole("menuitem", { name: "删除" }).click();
  // 确认弹窗（AlertDialog 删除保护）
  const confirm = page.getByRole("button", { name: "删除", exact: true });
  if (await confirm.isVisible().catch(() => false)) {
    await confirm.click();
  }
  // 行消失断言用任务行角色（aria-label）：删除 toast 的文案
  // 「已删除任务「冒烟任务-买牛奶」」含任务名，裸 getByText 会被 toast
  // 文本污染（toHaveCount 永不归零，超时假红）
  await expect(
    page.getByRole("button", { name: "已完成任务：冒烟任务-买牛奶" }),
  ).toHaveCount(0, { timeout: 10_000 });

  // ---- 撤销（sonner toast 的「撤销」按钮，5s 窗口内）----
  await page.getByRole("button", { name: "撤销" }).first().click();
  await expect(
    page.getByRole("button", { name: "已完成任务：冒烟任务-买牛奶" }),
  ).toBeVisible({ timeout: 10_000 });
});

test("回收站：删除入站 → 恢复回列表", async ({ page }) => {
  // ---- 新建 + 删除（等过 5s 撤销窗口，让墓碑真正落库）----
  await quickAdd(page, "冒烟任务-回收站验证");
  await expect(page.getByText("冒烟任务-回收站验证")).toBeVisible();
  await page.getByText("冒烟任务-回收站验证").click({ button: "right" });
  await page.getByRole("menuitem", { name: "删除" }).click();
  const confirm = page.getByRole("button", { name: "删除", exact: true });
  if (await confirm.isVisible().catch(() => false)) {
    await confirm.click();
  }
  // 撤销窗口 5s：不点撤销，等 toast 自然超时提交（软删落库）
  await page.waitForTimeout(6000);
  await expect(
    page.getByRole("button", { name: "未完成任务：冒烟任务-回收站验证" }),
  ).toHaveCount(0);

  // ---- 侧栏进回收站：墓碑行可见（含倒计时副标题）----
  await page.getByRole("button", { name: "回收站" }).first().click();
  await expect(page.getByRole("heading", { name: "回收站" })).toBeVisible();
  await expect(page.getByText("冒烟任务-回收站验证")).toBeVisible();
  await expect(page.getByText(/天后自动清除/)).toBeVisible();

  // ---- 恢复：回列表 + 回收站清空 ----
  await page.getByRole("button", { name: "恢复" }).first().click();
  await expect(page.getByText("已恢复")).toBeVisible(); // toast
  await expect(page.getByText("冒烟任务-回收站验证")).toHaveCount(0); // 回收站空

  // 回列表确认任务回来了
  await page.getByRole("button", { name: "待办", exact: true }).first().click();
  await expect(
    page.getByRole("button", { name: "未完成任务：冒烟任务-回收站验证" }),
  ).toBeVisible();
});

test("我的一天：行内加入 → 视图筛选 → 次日退出语义（my_day_date 按日判断）", async ({ page }) => {
  // 侧栏切到「我的一天」视图（QUICK_VIEWS 置顶第一项）
  await page.getByRole("button", { name: "我的一天" }).first().click();
  // 空态：无任务
  await expect(page.getByRole("heading", { name: "我的一天" })).toBeVisible();
  await expect(
    page.getByRole("button", { name: "未完成任务：既有任务-今天截止" }),
  ).toHaveCount(0);

  // 切回全部任务，行内「加入我的一天」按钮 hover 显现
  await page.getByRole("button", { name: "全部任务", exact: true }).first().click();
  const row = page.getByRole("button", { name: "未完成任务：既有任务-今天截止" });
  await row.getByRole("button", { name: "加入我的一天" }).click();

  // 回到「我的一天」：任务出现（my_day_date == 今天零点 命中）
  await page.getByRole("button", { name: "我的一天" }).first().click();
  await expect(
    page.getByRole("button", { name: "未完成任务：既有任务-今天截止" }),
  ).toBeVisible();

  // db 侧验证语义：my_day_date 应为今天零点（非任意真值）——
  // 昨天的时间戳不会命中视图（次日自动退出），这是微软 To Do 同款语义
  const myDay = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const t = m.db.tasks.find((x: any) => x.title === "既有任务-今天截止");
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return { raw: t?.my_day_date, isTodayZero: t?.my_day_date === today.getTime() };
  });
  expect(myDay.isTodayZero).toBe(true);

  // 行内「移出我的一天」→ 视图清空
  await page
    .getByRole("button", { name: "未完成任务：既有任务-今天截止" })
    .getByRole("button", { name: "移出我的一天" })
    .click();
  await expect(
    page.getByRole("button", { name: "未完成任务：既有任务-今天截止" }),
  ).toHaveCount(0);
});
