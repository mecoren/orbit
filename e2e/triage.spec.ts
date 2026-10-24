/**
 * 收件箱分诊（F2）冒烟：键盘流主链路（归入项目 / 排今天 / 撤销拉回 /
 * 删除延迟提交 / 汇总）+ 两个入口（··· 菜单 / 侧栏未分组行 hover 钮）。
 *
 * 前置与 smoke.spec 同构：ipc-mock 内存库 + __orbitMock 直改。队列归集与
 * 快照口径的纯函数在 vitest（shared/triage.test.ts）覆盖；这里验证键盘
 * 接链与写库终态。
 */
import { expect, test, type Page } from "@playwright/test";

/** 追加一条未分组任务（字段形状对齐 seedDefault 的 MockTask），并等
 *  db-change 失效链（合并窗口 + 重拉）把它送进主列表——不等就开弹窗会
 *  拿到旧缓存快照，队列偶发为空 */
async function addUngrouped(page: Page, title: string, position: number) {
  await page.evaluate(
    ({ title, position }) => {
      const m = (window as any).__orbitMock;
      const now = Date.now();
      m.db.tasks.push({
        id: m.db.seq++,
        uuid: `triage-${title}`,
        title,
        description: null,
        project_id: null,
        priority: 0,
        status: "pending",
        done: 0,
        done_at: null,
        due_date: null,
        start_date: null,
        repeat_after: 0,
        repeat_mode: 0,
        repeat_month_mode: 0,
        repeat_nth_week: 0,
        percent_done: 0,
        position,
        is_favorite: 0,
        my_day_date: null,
        duration_minutes: null,
        is_deleted: 0,
        created_at: now,
        updated_at: now,
        deleted_at: null,
        version: 1,
      });
      m.emitDbChange();
    },
    { title, position },
  );
  await expect(page.getByText(title)).toBeVisible({ timeout: 10_000 });
}

/** 「···」菜单 → 分诊未分组 */
async function openTriageViaMenu(page: Page) {
  await page.getByRole("button", { name: "更多" }).click();
  await page.getByRole("menuitem", { name: "分诊未分组" }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
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

test("键盘流：数字键归入项目 → 落库出队；Backspace 撤销拉回", async ({ page }) => {
  await addUngrouped(page, "分诊甲", 500);
  await addUngrouped(page, "分诊乙", 600);
  await openTriageViaMenu(page);

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("分诊甲")).toBeVisible();
  await expect(dialog.getByText("0 / 2")).toBeVisible();

  // 数字键 1 = seed 项目「测试项目」；写库出队到下一张
  await page.keyboard.press("1");
  await expect(dialog.getByText("分诊乙")).toBeVisible();
  const moved = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    return m.db.tasks.find((t: any) => t.title === "分诊甲").project_id;
  });
  expect(moved).toBeTruthy();

  // Backspace 撤销：卡片拉回 + 库侧回未分组
  await page.keyboard.press("Backspace");
  await expect(dialog.getByText("分诊甲")).toBeVisible();
  const reverted = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    return m.db.tasks.find((t: any) => t.title === "分诊甲").project_id;
  });
  expect(reverted).toBeNull();
});

test("键盘流：T 排今天（18 点口径）→ 汇总与清空正反馈", async ({ page }) => {
  await addUngrouped(page, "排期甲", 500);
  await openTriageViaMenu(page);

  await page.keyboard.press("t");
  await expect(page.getByRole("dialog").getByText("收件箱已清空")).toBeVisible();
  await expect(page.getByRole("dialog").getByText("已分诊 1 · 跳过 0")).toBeVisible();

  const due = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    return m.db.tasks.find((t: any) => t.title === "排期甲").due_date as number;
  });
  const d = new Date(due);
  expect(d.getHours()).toBe(18);
  expect(d.getMinutes()).toBe(0);
});

test("删除走延迟提交：toast 撤销在 5 秒窗内恢复", async ({ page }) => {
  await addUngrouped(page, "待删甲", 500);
  await openTriageViaMenu(page);

  await page.keyboard.press("d");
  await expect(page.getByRole("dialog").getByText("收件箱已清空")).toBeVisible();
  // 延迟提交窗内：行仍在 mock 库（5s 后才真正软删）
  const before = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    return m.db.tasks.some((t: any) => t.title === "待删甲");
  });
  expect(before).toBe(true);

  // sonner 入场动画期间按钮「不稳定」，force 直点（动画不影响命中语义）
  await page.getByRole("button", { name: "撤销" }).first().click({ force: true });
  const after = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const t = m.db.tasks.find((x: any) => x.title === "待删甲");
    return t != null && t.is_deleted === 0;
  });
  expect(after).toBe(true);
});

test("空收件箱：直接给清空正反馈（无卡可分诊）", async ({ page }) => {
  await openTriageViaMenu(page);
  await expect(page.getByRole("dialog").getByText("收件箱已清空")).toBeVisible();
});

test("入口：侧栏未分组行 hover 出分诊钮直达弹窗", async ({ page }) => {
  await addUngrouped(page, "入口甲", 500);
  // 展开态未分组行是文本按钮（exact 防撞「分诊未分组」入口钮的子串匹配）
  await page.getByRole("button", { name: "未分组", exact: true }).hover();
  await page.locator('button[aria-label="分诊未分组"]').click();
  await expect(page.getByRole("dialog").getByText("入口甲")).toBeVisible();
});
