/**
 * 规划今天（F3 阶段一只读预览）冒烟：候选归集 → 时段建议与理由徽标 →
 * 超载警示 → 空态。算法真值在 core（Rust 单测覆盖）；这里验证 mock 镜像
 * 与桌面弹窗接链（只读：不写库）。
 */
import { expect, test, type Page } from "@playwright/test";

/** 追加任务（字段形状对齐 seedDefault 的 MockTask；durationMinutes 支持造排程候选） */
async function addTask(
  page: Page,
  title: string,
  opts: { projectId?: number | null; dueOffsetMin?: number; myDay?: boolean; duration?: number } = {},
) {
  await page.evaluate(
    ({ title, opts }) => {
      const m = (window as any).__orbitMock;
      const now = Date.now();
      const n = new Date(now);
      const dayStart = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime();
      m.db.tasks.push({
        id: m.db.seq++,
        uuid: `plan-${title}`,
        title,
        description: null,
        project_id: opts.projectId ?? null,
        priority: 0,
        status: "pending",
        done: 0,
        done_at: null,
        due_date: opts.dueOffsetMin == null ? null : dayStart + opts.dueOffsetMin * 60_000,
        start_date: null,
        repeat_after: 0,
        repeat_mode: 0,
        repeat_month_mode: 0,
        repeat_nth_week: 0,
        percent_done: 0,
        position: 1000,
        is_favorite: 0,
        my_day_date: opts.myDay ? dayStart : null,
        duration_minutes: opts.duration ?? null,
        is_deleted: 0,
        created_at: now,
        updated_at: now,
        deleted_at: null,
        version: 1,
      });
      m.emitDbChange();
    },
    { title, opts },
  );
  await expect(page.getByText(title)).toBeVisible({ timeout: 10_000 });
}

function slotsOf(dialog: ReturnType<Page["getByRole"]>) {
  return dialog.getByTestId("plan-slots");
}

async function openPlanDay(page: Page) {
  await page.getByRole("button", { name: "更多" }).click();
  await page.getByRole("menuitem", { name: "规划今天" }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
}

test.beforeEach(async ({ page }) => {
  // 排程从「现在」起排且工作窗 09:00-18:00——挂 fake clock 固定到今天 10:00，
  // 用例不再随跑测墙钟漂移（晚间跑会整窗已过、全部未排入）
  await page.clock.install({ time: new Date(new Date().setHours(10, 0, 0, 0)) });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.evaluate(() => {
    (window as any).__orbitMock.seed();
  });
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
});

test("候选归集与理由徽标：逾期最先、截止时刻、我的一天", async ({ page }) => {
  await addTask(page, "排期-逾期", { dueOffsetMin: -60, duration: 30 });
  await addTask(page, "排期-截止", { dueOffsetMin: 16 * 60, duration: 30 });
  await addTask(page, "排期-我的一天", { myDay: true, duration: 30 });

  await openPlanDay(page);
  const slots = page.getByTestId("plan-slots");
  await expect(slots.getByText("排期-逾期")).toBeVisible();
  // 逾期行理由带「已逾期」；截止行带「截止」；我的一天行带档名
  await expect(slots.getByText(/已逾期/)).toBeVisible();
  await expect(slots.getByText(/截止 1[56]:/)).toBeVisible();
  await expect(slots.getByText("我的一天", { exact: true })).toBeVisible();
  // 时段文本为 HH:mm – HH:mm（fake clock 10:00 → 首槽 10:00 起）
  await expect(slots.getByText(/10:00 – /).first()).toBeVisible();
  // 只读：任务时间未被写入
  const untouched = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const t = m.db.tasks.find((x: any) => x.title === "排期-我的一天");
    return t.start_date == null;
  });
  expect(untouched).toBe(true);
});

test("勾选应用：写 my_day/start 不改 due，Ctrl+Z 撤销写回 prev", async ({ page }) => {
  await addTask(page, "要排的活", { myDay: true, duration: 30 });
  await openPlanDay(page);
  const dialog = page.getByRole("dialog");
  const slots = dialog.getByTestId("plan-slots");
  await expect(slots.getByText("要排的活")).toBeVisible();

  // 默认全选 → 应用（预览重拉后该任务已有今日 start_date，不再入候选；
  // seed 的「既有任务-今天截止」是另一候选，预览非空）
  await dialog.getByRole("button", { name: /应用到 \d+ 条任务/ }).click();
  await expect(slots.getByText("要排的活")).toHaveCount(0, { timeout: 10_000 });

  const n = new Date();
  const dayStart = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime();
  const after = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const t = m.db.tasks.find((x: any) => x.title === "要排的活");
    return {
      my_day: t.my_day_date as number | null,
      start: t.start_date as number | null,
      due: t.due_date as number | null,
    };
  });
  expect(after.my_day).toBe(dayStart);
  expect(after.start).not.toBeNull();
  expect(after.start! >= dayStart + 10 * 3_600_000).toBe(true, "fake clock 10:00 → 首槽 10:00 起");

  // Ctrl+Z 撤销：prev 写回（造数时 myDay:true → prev_my_day = 今天零点；
  // 原无 start_date → prev_start = null）
  await page.keyboard.press("Control+z");
  const reverted = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const t = m.db.tasks.find((x: any) => x.title === "要排的活");
    return { my_day: t.my_day_date, start: t.start_date };
  });
  expect(reverted.my_day).toBe(dayStart);
  expect(reverted.start).toBeNull();
});

test("作息编辑：改工作开始时段后预览随之变化并持久化", async ({ page }) => {
  await addTask(page, "作息活", { myDay: true, duration: 30 });
  await openPlanDay(page);
  const dialog = page.getByRole("dialog");

  // 展开作息 → 工作开始改 12:00（fake clock 10:00 → 首槽从 12:00 起）
  await dialog.getByRole("button", { name: "作息" }).click();
  const prefs = dialog.getByTestId("plan-prefs");
  await expect(prefs).toBeVisible();
  await prefs.getByLabel("工作开始").click();
  await page.getByRole("option", { name: "12:00", exact: true }).click();
  await prefs.getByRole("button", { name: "保存作息" }).click();

  // 预览重拉：首槽从 12:00 起（原 10:00 起的行已换时段）
  await expect(slotsOf(dialog).getByText(/12:00 – /).first()).toBeVisible({
    timeout: 10_000,
  });

  // 持久化：重开弹窗（编辑区组件态保留直接展开）回显 12:00
  await dialog.getByRole("button", { name: "关闭" }).first().click();
  await openPlanDay(page);
  const prefs2 = page.getByRole("dialog").getByTestId("plan-prefs");
  await expect(prefs2).toBeVisible();
  await expect(prefs2.getByLabel("工作开始")).toHaveText(/12:00/);
});

test("超载警示与未排入：容量满时给提示条与原因", async ({ page }) => {
  // 正午后（nowMinute 已过大半工作窗），600 分钟大活必然超容量
  await addTask(page, "超大活", { duration: 600 });
  await openPlanDay(page);
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText(/超出今日剩余容量/)).toBeVisible();
});

test("无可规划任务：空态正反馈（seed 既有任务拨到明天后无候选）", async ({ page }) => {
  // seed 自带「既有任务-今天截止」是合法候选——先把它拨到明天再验空态
  await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const now = Date.now();
    const n = new Date(now);
    const dayStart = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime();
    const t = m.db.tasks.find((x: any) => x.title === "既有任务-今天截止");
    t.due_date = dayStart + 86_400_000 + 10 * 3_600_000;
    m.emitDbChange();
  });
  await openPlanDay(page);
  await expect(page.getByRole("dialog").getByText("没有可规划的任务")).toBeVisible();
});
