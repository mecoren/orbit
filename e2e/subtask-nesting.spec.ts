/**
 * 子任务多层嵌套回归（M10，2026-10-12）
 *
 * 覆盖点（桌面详情抽屉「子任务」区块，mock IPC 环境）：
 * - 三级树渲染：DFS 父在前 + depth 缩进（14px/层，getBoundingClientRect 逐层对齐）
 * - 行内「添加子级」：回车落库后新行挂在父下（缩进深一层）
 * - 「提到顶层」：嵌套行缩进回顶层
 * - 删除父行带走整棵子树（core 软删语义，mock 同口径）
 *
 * 前置：详情抽屉打开的种子任务 + window.__orbitMock.db 直灌三级树后手动
 * emitDbChange（写命令由 mock 自动 emit，直改库需手动）。
 */
import { expect, test, type Page } from "@playwright/test";

const DRAWER = '[role="dialog"]';

/** 行标题 span 的左缘（缩进挂在行容器 paddingLeft，标题随行平移） */
async function titleLeft(page: Page, title: string): Promise<number | null> {
  return page.evaluate(
    ({ title, drawerSel }) => {
      const drawer = document.querySelector(drawerSel);
      const spans = [...(drawer?.querySelectorAll("span") ?? [])];
      const el = spans.find((s) => s.textContent === title);
      return el ? el.getBoundingClientRect().left : null;
    },
    { title, drawerSel: DRAWER },
  );
}

test("子任务多层嵌套：三级树缩进渲染 + 行内加子级 + 提到顶层 + 删除整棵子树", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  // seed 直写内存库（smoke freshApp 同款）：既有任务可见 = 数据流就绪
  await page.evaluate(() => {
    (window as any).__orbitMock.seed();
  });
  await expect(page.getByText("既有任务-今天截止")).toBeVisible();

  // 任务行点击打开详情抽屉
  await page.getByRole("button", { name: "未完成任务：既有任务-今天截止" }).click();
  await expect(page.locator(DRAWER)).toBeVisible();

  // 直灌三级树 a → b → c（与 sidebar-scroll 同款直改 + 手动 emit）
  await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const t = m.db.tasks.find((x: any) => x.title === "既有任务-今天截止");
    const now = Date.now();
    const mk = (uuid: string, title: string, position: number, parent: string | null) => ({
      id: m.db.seq++,
      uuid,
      task_id: t.id,
      title,
      done: 0,
      done_at: null,
      position,
      parent_uuid: parent,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      deleted_at: null,
      version: 1,
    });
    m.db.subtasks.push(mk("sub-a", "甲", 0, null));
    m.db.subtasks.push(mk("sub-b", "乙", 1, "sub-a"));
    m.db.subtasks.push(mk("sub-c", "丙", 2, "sub-b"));
    m.emitDbChange();
  });
  await expect(page.getByText("甲", { exact: true })).toBeVisible();

  // ① 三级缩进：乙比甲深一层、丙比乙再深一层（14px/层，±1px 容断言）
  const leftJia = await titleLeft(page, "甲");
  const leftYi = await titleLeft(page, "乙");
  const leftBing = await titleLeft(page, "丙");
  expect(leftJia, "甲应渲染").not.toBeNull();
  expect(leftYi! - leftJia!, "乙应比甲缩进一层（14px）").toBeCloseTo(14, 0);
  expect(leftBing! - leftYi!, "丙应比乙再缩进一层（14px）").toBeCloseTo(14, 0);

  // ② 行内「加子级」：乙下加「丁」→ 深一层（42px = 三层）
  await page.getByRole("button", { name: "添加子级 乙" }).click();
  const childInput = page.locator('input[placeholder="添加子任务"]:focus');
  await expect(childInput).toBeFocused();
  await page.keyboard.type("丁");
  await page.keyboard.press("Enter");
  await expect(page.getByText("丁", { exact: true })).toBeVisible();
  const leftDing = await titleLeft(page, "丁");
  expect(leftDing! - leftYi!, "丁应挂在乙下（再深一层）").toBeCloseTo(14, 0);

  // ③ 「提到顶层」：丙的缩进回顶层（与甲同左缘）
  await page.getByRole("button", { name: "提到顶层 丙" }).click();
  await expect
    .poll(async () => (await titleLeft(page, "丙")) ?? -1)
    .toBeCloseTo(leftJia!, 0);

  // ④ 删除甲：确认弹层说明带子树规模 → 确认 → 整棵子树（乙/丁）软删，
  //    已提顶层的丙不受牵连
  const rowJia = page.locator(`${DRAWER} div.group`).filter({ hasText: "甲" }).first();
  await rowJia.hover();
  await rowJia.getByRole("button", { name: "删除子任务" }).click();
  const popover = page.locator(".w-56").filter({ hasText: "删除子任务" });
  await expect(popover).toBeVisible();
  await popover.getByRole("button", { name: "删除", exact: true }).click();

  const flags = await page.evaluate(() => {
    const m = (window as any).__orbitMock;
    const flag = (uuid: string) =>
      m.db.subtasks.find((s: any) => s.uuid === uuid)?.is_deleted;
    return {
      a: flag("sub-a"),
      b: flag("sub-b"),
      c: flag("sub-c"),
      d: m.db.subtasks.find((s: any) => s.title === "丁")?.is_deleted,
      cAlive: flag("sub-c"),
    };
  });
  expect(flags, "甲/乙/丁应软删，丙（已提顶层）存活").toEqual({
    a: 1,
    b: 1,
    c: 0,
    d: 1,
    cAlive: 0,
  });
  await expect(page.getByText("甲", { exact: true })).not.toBeVisible();
  await expect(page.getByText("丙", { exact: true })).toBeVisible();
});
