/**
 * M8+ 清单层级：拖拽跨层级改父
 *
 * 覆盖点（横向位移即意图，阈值 20px）：
 * - 右拖 ≥ 阈值 → **内嵌**为落点行的最后一个子项（depth +1、parent_uuid 落库）
 * - 左拖 ≥ 阈值 → **提升一级**（depth −1；挂到祖父下、紧跟原父之后）
 * - 位移不足阈值 → **同级重排**，层级字段一律不动（防误改父）
 *
 * 前置：seed 在页面加载后写入内存库（mock db 为模块级，刷新即重置，故不可先 seed
 * 再 reload）；拖拽用真实指针事件驱动 dnd-kit（PointerSensor 无激活约束，按下即
 * 进入拖拽），落点按**拖拽前**测量的元素中心计算——dnd-kit 的 droppable 矩形在
 * 拖拽开始时一次性测量，拖拽中的重排动画不改变判定基准。
 *
 * 注：父清单聚合子清单任务的 e2e 依赖面板客户端过滤层（`task-filters.ts::projectIds`），
 * 该文件与并发会话的排序方向档改动同一 hunk，暂未随本批提交，故其断言另置
 * `project-aggregation.spec.ts`（与源文件同批落库）。
 */
import { expect, test, type Page } from "@playwright/test";

const ROW = '[data-testid="project-row"]';

/**
 * 造三层清单：甲(顶层) → 乙 → 丙；丁(顶层)。
 * 渲染序（全量 DFS）：测试项目(0) / 甲(0) / 乙(1) / 丙(2) / 丁(0)
 */
async function openSidebar(page: Page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.evaluate(() => {
    const mock = (window as any).__orbitMock;
    mock.seed();
    const now = Date.now();
    const base = {
      description: null,
      hex_color: "#3B82F6",
      is_archived: 0,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      deleted_at: null,
      version: 1,
    };
    mock.db.projects.push(
      { id: mock.db.seq++, uuid: "e2e-a", title: "甲", sort_order: 1, parent_uuid: null, ...base },
      { id: mock.db.seq++, uuid: "e2e-b", title: "乙", sort_order: 2, parent_uuid: "e2e-a", ...base },
      { id: mock.db.seq++, uuid: "e2e-c", title: "丙", sort_order: 3, parent_uuid: "e2e-b", ...base },
      { id: mock.db.seq++, uuid: "e2e-d", title: "丁", sort_order: 4, parent_uuid: null, ...base },
    );
    mock.emitDbChange();
  });
  // 5 个项目行（含 seed 的「测试项目」）
  await expect(page.locator(ROW)).toHaveCount(5);
}

/** 读数：某 uuid 项目在内存库里的 parent_uuid / sort_order */
async function projectRow(page: Page, uuid: string) {
  const rows = await page.evaluate(
    (u) =>
      (window as any).__orbitMock.db.projects
        .filter((p: any) => p.uuid === u)
        .map((p: any) => ({ parent_uuid: p.parent_uuid, sort_order: p.sort_order })),
    uuid,
  );
  expect(rows).toHaveLength(1);
  return rows[0];
}

/**
 * 真实指针拖拽：从 `active` 行把手拖到 `over` 行中心，附加横向位移 dx。
 *
 * 起点取把手中心（把手在行内左端、纵向居中），故：
 * - 纵向目标取落点行中心 → 拖拽后被拖行中心正落在落点行中心，closestCenter
 *   判定为落点行；
 * - **横向终点必须是「起点 x + dx」**（不是落点行中心 + dx）——起点是把手不是
 *   整行，用行中心当基准会白送一个 ≈ 半行宽的右移，dx=0 也会越过改父阈值。
 */
async function dragProject(page: Page, active: string, over: string, dx: number) {
  const handle = page.locator(ROW, { hasText: active }).locator(`[aria-label="拖动项目 ${active}"]`);
  const from = await handle.boundingBox();
  const to = await page.locator(ROW, { hasText: over }).boundingBox();
  if (!from || !to) throw new Error("拖拽元素不可见");

  const startX = from.x + from.width / 2;
  const startY = from.y + from.height / 2;
  const endY = to.y + to.height / 2;
  await page.mouse.move(startX, startY);
  await page.mouse.down();
  // 先来一小段位移跨过 dnd-kit 的启动判定，再走完剩余路程
  await page.mouse.move(startX + dx * 0.2, startY + (endY - startY) * 0.2);
  await page.mouse.move(startX + dx, endY, { steps: 10 });
  await page.mouse.up();
}

test("M8+：右拖内嵌为落点行的子项（depth +1 且 parent_uuid 落库）", async ({ page }) => {
  await openSidebar(page);
  const rows = page.locator(ROW);

  // 初始：丁 顶层、序末
  await expect(rows.nth(4)).toContainText("丁");
  await expect(rows.nth(4)).toHaveAttribute("data-depth", "0");
  expect((await projectRow(page, "e2e-d")).parent_uuid).toBeNull();

  // 把「丁」右拖到「甲」上 → 成为甲的子项（挂在其子项末位 = 丙 之后，故仍在序末）
  await dragProject(page, "丁", "甲", 40);

  await expect(rows.nth(4)).toContainText("丁");
  await expect(rows.nth(4)).toHaveAttribute("data-depth", "1");
  await expect(rows.nth(4)).toHaveAttribute("data-uuid", "e2e-d");
  expect((await projectRow(page, "e2e-d")).parent_uuid).toBe("e2e-a");

  // 甲 的子树顺序未被打乱：乙(1) / 丙(2) 原位
  await expect(rows.nth(2)).toContainText("乙");
  await expect(rows.nth(2)).toHaveAttribute("data-depth", "1");
  await expect(rows.nth(3)).toContainText("丙");
  await expect(rows.nth(3)).toHaveAttribute("data-depth", "2");
});

test("M8+：左拖提升一级（depth −1 且挂到祖父下）", async ({ page }) => {
  await openSidebar(page);
  const rows = page.locator(ROW);

  // 初始：丙 深度 2，父 = 乙
  await expect(rows.nth(3)).toContainText("丙");
  await expect(rows.nth(3)).toHaveAttribute("data-depth", "2");
  expect((await projectRow(page, "e2e-c")).parent_uuid).toBe("e2e-b");

  // 把「丙」左拖到「乙」上 → 提升一级：挂到祖父「甲」下、紧跟原父之后
  await dragProject(page, "丙", "乙", -40);

  await expect(rows.nth(3)).toContainText("丙");
  await expect(rows.nth(3)).toHaveAttribute("data-uuid", "e2e-c");
  await expect(rows.nth(3)).toHaveAttribute("data-depth", "1");
  expect((await projectRow(page, "e2e-c")).parent_uuid).toBe("e2e-a");
  // 原父「乙」降为叶子：折叠箭头消失
  await expect(page.getByRole("button", { name: "折叠子项目 乙" })).toHaveCount(0);
});

test("M8+：位移不足阈值只做同级重排，层级字段一律不动", async ({ page }) => {
  await openSidebar(page);
  const rows = page.locator(ROW);

  // 把顶层「甲」下拖到「丁」（横向位移 0）→ 顶层组内挪到丁之后
  await dragProject(page, "甲", "丁", 0);

  // 顶层新序：测试项目 / 丁 / 甲（子树跟随）
  await expect(rows.nth(1)).toContainText("丁");
  await expect(rows.nth(1)).toHaveAttribute("data-depth", "0");
  await expect(rows.nth(2)).toContainText("甲");
  await expect(rows.nth(2)).toHaveAttribute("data-depth", "0");
  await expect(rows.nth(3)).toContainText("乙");
  await expect(rows.nth(3)).toHaveAttribute("data-depth", "1");
  await expect(rows.nth(4)).toContainText("丙");
  await expect(rows.nth(4)).toHaveAttribute("data-depth", "2");

  // 关键：三方 parent_uuid 全部保持原状
  expect((await projectRow(page, "e2e-a")).parent_uuid).toBeNull();
  expect((await projectRow(page, "e2e-b")).parent_uuid).toBe("e2e-a");
  expect((await projectRow(page, "e2e-c")).parent_uuid).toBe("e2e-b");
});
