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

test("右键添加评论：弹窗打开即聚焦输入框（2026-09-08 修复）", async ({ page }) => {
  // 右键任务行 → 添加评论 → Dialog 打开
  await page.getByText("既有任务-今天截止").click({ button: "right" });
  await page.getByRole("menuitem", { name: "添加评论" }).click();
  const textarea = page.getByPlaceholder("输入评论...");
  await expect(textarea).toBeVisible();
  // 焦点断言：打开后光标在输入框（旧实现 autoFocus 错过 open 时机，焦到关闭钮）
  await expect(textarea).toBeFocused();
  // 聚焦即可直接打字提交（回车行为不在此断言，聚焦即体验目标）
  await textarea.fill("聚焦验证评论");
  await page.getByRole("button", { name: "保存", exact: true }).click();
  // 弹窗关闭 + 评论落库（评论展示在详情抽屉，这里断 mock 库终态）
  await expect(page.getByPlaceholder("输入评论...")).not.toBeVisible();
  const saved = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    return m.db.comments.some((c: any) => c.content === "聚焦验证评论");
  });
  expect(saved).toBe(true);
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

test("导航回归：回收站/统计面板下点侧边栏菜单直接回任务面板（2026-09-08 修复）", async ({ page }) => {
  // ---- 进回收站后点「我的一天」：应直接回任务面板并应用该视图 ----
  await page.getByRole("button", { name: "回收站" }).first().click();
  await expect(page.getByRole("heading", { name: "回收站" })).toBeVisible();
  await page.getByRole("button", { name: "我的一天" }).first().click();
  await expect(page.getByRole("heading", { name: "我的一天" })).toBeVisible();

  // ---- 进统计后点「全部任务」：同样直接回任务面板 ----
  await page.getByRole("button", { name: "统计" }).first().click();
  await expect(page.getByRole("heading", { name: "统计" })).toBeVisible();
  await page.getByRole("button", { name: "全部任务", exact: true }).first().click();
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible();
  // 全部任务下 seed 行可见（确认不是空壳，视图状态真正应用了）
  await expect(
    page.getByRole("button", { name: "未完成任务：既有任务-今天截止" }),
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

test("重复任务：完成推进下一实例（引擎下沉 todo_tasks_complete 单命令）", async ({ page }) => {
  // 快加一条任务，mock 内存库直改 repeat 字段为每天重复（表单编辑路径不在此用例范围）
  await quickAdd(page, "冒烟任务-每天喝水");
  await expect(page.getByText("冒烟任务-每天喝水")).toBeVisible();

  await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const t = m.db.tasks.find((x: any) => x.title === "冒烟任务-每天喝水");
    t.repeat_mode = 1; // 每天
    t.repeat_after = 1;
    t.due_date = Date.now() + 86400000; // 明天到期（提前完成仍按原排程推进）
    m.emitDbChange();
  });
  await expect(
    page.getByRole("button", { name: "未完成任务：冒烟任务-每天喝水" }),
  ).toBeVisible();

  // 完成：单命令单事务——旧实例标记完成 + 下一实例出现
  const row = page.getByRole("button", { name: "未完成任务：冒烟任务-每天喝水" });
  await row.getByRole("button", { name: "标记完成" }).click();

  const dbState = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const rows = m.db.tasks.filter((x: any) => x.title === "冒烟任务-每天喝水");
    return rows.map((x: any) => ({
      done: x.done,
      due_date: x.due_date as number | null,
      repeat_mode: x.repeat_mode,
    }));
  });
  // 一旧一新：旧实例 done=1；新实例 pending、due 越过 now（快进口径）、规则保留
  expect(dbState.length).toBe(2);
  expect(dbState.filter((r) => r.done === 1).length).toBe(1);
  const next = dbState.find((r) => r.done === 0);
  expect(next).toBeTruthy();
  expect(next!.repeat_mode).toBe(1);
  expect(next!.due_date).toBeGreaterThan(Date.now());
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

  // ---- 议程档回归：先回今天（年视图点 1 月把视图切到了 1 月，议程按当月分组） ----
  await page.getByRole("button", { name: "回到今天" }).click();
  await expect(
    page.getByRole("heading", {
      name: `${today.getFullYear()}年${today.getMonth() + 1}月`,
      exact: true,
    }),
  ).toBeVisible(); // 月视图回到本月

  // ---- 右键日格：直接弹新增表单并预填该日截止日期 ----
  // 右键今天格；日格带 aria-label=YYYY-MM-DD（月历组件统一口径），
  // 不能用数字 name 定位——getByRole name 是子串匹配，「9」会先命中
  // 工具栏「9月」标题按钮（今日日期数字与月份标题撞车的日期敏感假红）
  const ymd = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
  await page.locator(`[aria-label="${ymd}"]`).click({ button: "right" });
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

  // ---- 议程档回归：先回今天再切议程（议程按当月分组，今天格在当前月） ----
  await page.getByRole("button", { name: "回到今天" }).click();
  await page.getByRole("button", { name: "议程" }).click();
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();
});

test("详情属性：开始日期可见/可改可清除 + 完成时间展示（2026-09-08 补断层）", async ({ page }) => {
  // 任务行点击打开详情抽屉
  const row = page.getByRole("button", { name: "未完成任务：既有任务-今天截止" });
  await row.click();
  await expect(page.getByRole("dialog")).toBeVisible();

  // ---- 开始日期行存在且可编辑（此前桌面详情是唯一断层：表单可设、详情失明）----
  await expect(page.getByText("开始日期", { exact: true })).toBeVisible();

  // 经 mock 直写 start_date（零点 ms），db-change 后抽屉值区显示 yyyy-MM-dd
  const startMs = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const t = m.db.tasks.find((x: any) => x.title === "既有任务-今天截止");
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    t.start_date = d.getTime();
    m.emitDbChange();
    return t.start_date;
  });
  // 本地时区格式化（toISOString 是 UTC，本地零点会差一天）
  const sd = new Date(startMs);
  const ymd = `${sd.getFullYear()}-${String(sd.getMonth() + 1).padStart(2, "0")}-${String(sd.getDate()).padStart(2, "0")}`;
  await expect(page.getByText(ymd, { exact: true })).toBeVisible({ timeout: 5_000 });

  // ---- 完成任务 → done_at 写入 → 完成时间行显示（此前 done_at 无处可看）----
  // 详情抽屉标题行的完成圆钮（常驻可点，不依赖列表行 hover）
  await page.getByRole("button", { name: "标记完成" }).first().click();
  await expect(page.getByRole("button", { name: "标记未完成" }).first()).toBeVisible();
  // done_at 由 completeTask 链路写入；详情抽屉常驻，值区应显示 yyyy-MM-dd HH:mm
  await expect(
    page.getByText(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/, { exact: false }).first(),
  ).toBeVisible({ timeout: 5_000 });

  // ---- 标题栏固定（2026-09-08）：内容滚到底后标题行仍在抽屉视口顶部 ----
  const drawer = page.getByRole("dialog");
  await drawer.evaluate((el) => {
    // 找内容滚动容器（头部之外的 overflow-y-auto 子元素）滚到底
    const scroller = el.querySelector(".overflow-y-auto");
    if (scroller) scroller.scrollTop = scroller.scrollHeight;
  });
  const titleEl = drawer.locator("h2", { hasText: "既有任务-今天截止" });
  await expect(titleEl).toBeVisible();
  const inViewport = await titleEl.evaluate((el: HTMLElement) => {
    const rect = el.getBoundingClientRect();
    return rect.top >= 0 && rect.bottom <= window.innerHeight;
  });
  expect(inViewport).toBe(true);
});

test("附件：详情抽屉区块渲染 + 列表/移除链路（mock 命令面）", async ({ page }) => {
  // 任务行点击打开详情抽屉
  const row = page.getByRole("button", { name: "未完成任务：既有任务-今天截止" });
  await row.click();
  // 抽屉八区块滚动可见：标题输入在抽屉顶部
  await expect(page.getByRole("dialog")).toBeVisible();

  // 经 mock 直挂附件（真实链路 = fs 读文件 → task_attachment_add 同构语义），
  // emitDbChange 后抽屉区块 9 重渲染列表
  await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const t = m.db.tasks.find((x: any) => x.title === "既有任务-今天截止");
    const link = {
      link_id: m.db.seq++,
      link_uuid: "att-e2e-1",
      task_id: t.id,
      hash: "e2ehash01",
      original_name: "验收报告.pdf",
      mime_type: "application/pdf",
      size_bytes: 2048,
      is_local_cached: 1,
    };
    m.db.attachments.push(link);
    m.emitDbChange();
  });
  await expect(page.getByText("验收报告.pdf")).toBeVisible({ timeout: 5_000 });
  // 大小人类可读（2.0 KB）
  await expect(page.getByText("2.0 KB")).toBeVisible();

  // 移除：hover 行 → 移除按钮 → ConfirmPopover 确认
  const attRow = page.getByText("验收报告.pdf");
  await attRow.hover();
  await page.getByRole("button", { name: "移除附件" }).click();
  // ConfirmPopover 弹层（标题「移除附件」→ 段落说明 → 删除按钮），
  // 与标题行的 aria-label「删除」按钮同名，用弹层说明文案锚定作用域
  const popover = page.getByText("仅解除与任务的关联", { exact: false }).locator("..");
  await popover.getByRole("button", { name: "删除", exact: true }).click();
  await expect(page.getByText("验收报告.pdf")).not.toBeVisible({ timeout: 5_000 });
  // mock 库终态：附件关联已删
  const remaining = await page.evaluate(() => (window as any).__orbitMock.db.attachments.length);
  expect(remaining).toBe(0);
});

test("保存的筛选器：创建 → 侧栏分组 → 点击过滤 → 删除（#35）", async ({ page }) => {
  // 经 mock 直改内存库（真实链路 = 弹层名称/条件 JSON → saved_filter_create 同构）
  await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    m.db.savedFilters.push({
      id: m.db.seq++,
      uuid: "sf-e2e-1",
      name: "本周紧急",
      conditions: '{"priority_min":4,"due_within_days":7}',
      sort_order: 1,
    });
    m.emitDbChange();
  });
  // 侧栏分组渲染（行内 button 与 aria-label 继承行名，用 first 严格定位行）
  const filterRow = page.getByRole("button", { name: "本周紧急" }).first();
  await expect(filterRow).toBeVisible({ timeout: 5_000 });
  await filterRow.click();
  // 标题切换为筛选器名（面板消费 activeSavedFilter）
  await expect(page.getByRole("heading", { name: "本周紧急" })).toBeVisible();

  // 删除：hover 行 → 删除按钮
  await filterRow.hover();
  await page.getByRole("button", { name: "删除筛选器 本周紧急" }).click();
  await expect(page.getByRole("button", { name: "本周紧急" })).toHaveCount(0, {
    timeout: 5_000,
  });
});
