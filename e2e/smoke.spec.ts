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
