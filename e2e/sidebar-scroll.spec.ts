/**
 * 小窗口侧栏滚动回归（2026-10-10 修复：小屏幕侧栏内容被裁切且看不到滚动条）
 *
 * 覆盖点：
 * - 小视口高度下侧栏整栏统一滚动（快捷入口 + 筛选器 + 项目列表同一条滚动列），
 *   最后一个项目行可滚动到达、不被窗口底边裁掉
 * - 侧栏滚动容器走全局滚动条标准（原生滚动条常显，不隐藏成 hover 悬浮条）
 * - 折叠窄条（w-12）同样可滚动到达底部项目
 *
 * 前置：项目数据经 window.__orbitMock.db 直改后手动 emitDbChange（与 project-folder 同款）；
 * 小宽度（<1024）侧栏自动折叠，展开态用例先点「展开侧栏」模拟用户手动展开。
 */
import { expect, test, type Page } from "@playwright/test";

const ROW = '[data-testid="project-row"]';

/** seed 后追加 count 个顶层项目（模拟项目多到超出侧栏高度） */
async function seedProjects(page: Page, count: number) {
  await page.evaluate((n) => {
    const mock = (window as any).__orbitMock;
    mock.seed();
    const now = Date.now();
    for (let i = 1; i <= n; i++) {
      mock.db.projects.push({
        id: mock.db.seq++,
        uuid: `e2e-scroll-${i}`,
        title: `滚动项目${String(i).padStart(2, "0")}`,
        description: null,
        hex_color: "#3B82F6",
        sort_order: i,
        parent_uuid: null,
        is_archived: 0,
        is_deleted: 0,
        created_at: now,
        updated_at: now,
        deleted_at: null,
        version: 1,
      });
    }
    mock.emitDbChange();
  }, count);
  // 就绪信号只断「挂树」：展开态行渲染标题文本，折叠窄条只渲染 aria-label 图标钮
  // （标题在 Tooltip 内容里 hover 才挂载），用并集选择器兼容两种形态；
  // 在不在视口内是被测行为，不能拿可见性当就绪信号
  const last = `滚动项目${String(count).padStart(2, "0")}`;
  await expect(
    page.locator(
      `[data-testid="project-row"]:has-text("${last}"), button[aria-label="${last}"]`,
    ),
  ).toBeAttached();
}

/**
 * 从目标行向上找最近的可滚动祖先，滚到底后返回：
 * - withinWindow：目标行是否完整落在窗口内（用户可点得到）
 * - 滚动条口径：scrollbarWidth / ::-webkit-scrollbar display（全局标准 = 常显原生条）
 *
 * 为什么按祖先找而不是写死容器：修复前后滚动容器不同（Radix viewport → 整栏列），
 * 测试只锚定「用户能不能滚到」这一行为，不绑实现细节。
 */
async function scrollRowIntoReach(page: Page, selector: string) {
  return page.evaluate((sel) => {
    const rows = document.querySelectorAll(sel);
    const last = rows[rows.length - 1] as HTMLElement | undefined;
    if (last == null) return { found: false, reason: "no-row" };
    let el = last.parentElement as HTMLElement | null;
    let scroller: HTMLElement | null = null;
    while (el != null) {
      const cs = getComputedStyle(el);
      if (
        (cs.overflowY === "auto" || cs.overflowY === "scroll") &&
        el.scrollHeight > el.clientHeight
      ) {
        scroller = el;
        break;
      }
      el = el.parentElement;
    }
    if (scroller == null) return { found: false, reason: "no-scroller" };
    scroller.scrollTop = scroller.scrollHeight;
    const rect = last.getBoundingClientRect();
    return {
      found: true,
      withinWindow: rect.top >= -0.5 && rect.bottom <= window.innerHeight + 0.5,
      scrollbarWidth: getComputedStyle(scroller).scrollbarWidth,
      webkitScrollbarDisplay: getComputedStyle(scroller, "::-webkit-scrollbar").display,
    };
  }, selector);
}

test("小窗口展开态：项目列表末行可滚动到达，不被窗口裁掉", async ({ page }) => {
  await page.setViewportSize({ width: 1008, height: 420 });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await seedProjects(page, 30);
  // <1024 自动折叠，先手动展开（对应用户小屏幕 + 展开侧栏的使用姿势）
  await page.getByRole("button", { name: "展开侧栏" }).click();
  await expect(page.locator(ROW).first()).toBeVisible();

  const res = await scrollRowIntoReach(page, ROW);
  expect(res.found, `侧栏内应存在可滚动容器（实际：${res.reason ?? ""}）`).toBe(true);
  expect(
    (res as { withinWindow: boolean }).withinWindow,
    "滚动到底后最后一个项目行应完整落在窗口内",
  ).toBe(true);
});

test("侧栏滚动容器走全局滚动条标准：原生滚动条不被隐藏", async ({ page }) => {
  await page.setViewportSize({ width: 1008, height: 420 });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await seedProjects(page, 30);
  await page.getByRole("button", { name: "展开侧栏" }).click();
  await expect(page.locator(ROW).first()).toBeVisible();

  const res = (await scrollRowIntoReach(page, ROW)) as {
    found: boolean;
    scrollbarWidth?: string;
    webkitScrollbarDisplay?: string;
  };
  expect(res.found).toBe(true);
  // scrollbar-width 非 auto 会禁用 webkit 自定义退化为系统条（AGENTS 滚动条标准）
  expect(res.scrollbarWidth, "scrollbar-width 应为 auto").toBe("auto");
  // Radix viewport 的 display:none 会让滚动条常年不可见 = 用户感知「没有滑动条」
  expect(res.webkitScrollbarDisplay, "::-webkit-scrollbar 不应 display:none").not.toBe("none");
});

test("小窗口折叠窄条：底部项目可滚动到达", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 460 });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await seedProjects(page, 30);
  // 窄窗自动折叠，末尾项目按钮只存在于窄条
  const lastRail = page.locator('button[aria-label="滚动项目30"]');
  await expect(lastRail).toBeAttached();

  const res = await scrollRowIntoReach(page, 'button[aria-label="滚动项目30"]');
  expect(res.found, `窄条内应存在可滚动容器（实际：${res.reason ?? ""}）`).toBe(true);
  expect(
    (res as { withinWindow: boolean }).withinWindow,
    "滚动到底后窄条末尾项目应完整落在窗口内",
  ).toBe(true);
});
