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

test("日历视图：左右分栏 + 选中定位 + 年视图 + 右键新增预填日期", async ({ page }) => {
  const today = new Date();

  // ---- 切到日历视图（工具栏三联钮） ----
  await page.getByRole("button", { name: "日历视图" }).click();

  // 左半区月历：默认选中今天 → 右栏显示当月任务分组（seed 的今天截止任务）
  await expect(page.getByText("月的任务", { exact: false })).toBeVisible();
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
  // 右栏选中日分组行有「今天」徽标（seed 任务截止今天）
  await expect(page.getByText("今天", { exact: true }).first()).toBeVisible();

  // ---- 农历副标签可见（今天格下方有农历日名/节气/节日之一） ----
  // 月历星期表头存在（周一起始）
  await expect(page.getByText("一", { exact: true }).first()).toBeVisible();

  // ---- 点击月历另一天：右栏滚动定位（选中日切换不报错即可） ----
  // 工具栏标题（h2）显示本月；右栏标题（h3）带「月的任务」后缀
  await expect(
    page.getByRole("heading", { name: `${today.getFullYear()}年${today.getMonth() + 1}月`, exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: `${today.getFullYear()}年${today.getMonth() + 1}月的任务` }),
  ).toBeVisible();

  // ---- 年视图：点「年」档 → 12 个迷你月历 + 干支生肖 ----
  await page.getByRole("button", { name: "年" }).click();
  await expect(page.getByText(/(鼠|牛|虎|兔|龙|蛇|马|羊|猴|鸡|狗|猪)年/)).toBeVisible();
  await expect(page.getByText("年的任务", { exact: false })).toBeVisible();
  // 迷你月历标题 1-12 月齐全
  for (const m of ["1月", "2月", "3月", "10月", "11月", "12月"]) {
    await expect(page.getByRole("button", { name: m, exact: true })).toBeVisible();
  }

  // 年视图点击某天 → 回月视图并定位（点 1 月标题）
  await page.getByRole("button", { name: "1月", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "月", exact: true }),
  ).toBeVisible(); // 工具栏回到月档

  // ---- 右键日格：直接弹新增表单并预填该日截止日期 ----
  // 右键今天格（右栏「今天」徽标所在的日期分组对应今天）
  const ymd = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
  // 月历日格是按钮：右键数字「今天日期」
  await page
    .getByRole("button", { name: String(today.getDate()) })
    .first()
    .click({ button: "right" });
  // 新增表单打开且截止日期已预填为该日
  await expect(page.getByRole("dialog")).toBeVisible();
  const dueInput = page.locator("button", { hasText: ymd }).first();
  await expect(dueInput).toBeVisible();

  // 填标题提交 → 任务出现在右栏列表
  const dlg = page.getByRole("dialog");
  const titleInput = dlg.locator("input").first();
  await titleInput.fill("日历右键任务");
  await dlg.getByRole("button", { name: "创建" }).click();
  await expect(page.getByText("日历右键任务")).toBeVisible({ timeout: 10_000 });

  // ---- 议程档回归：先回今天（年视图点 1 月把视图切到了 1 月，议程按当月分组） ----
  await page.getByRole("button", { name: "回到今天" }).click();
  await page.getByRole("button", { name: "议程" }).click();
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
});
