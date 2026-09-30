/**
 * 项目文件夹分组回归（M8 清单层级）
 *
 * 覆盖点：
 * - 项目按 parent_uuid 渲染为层级树：DFS 序（父紧跟其子树）+ data-depth 标注
 * - 缩进随层级递增（8 / 22 / 36px）
 * - 父 uuid 指向不存在的项目（孤儿）回落顶层，行不丢
 * - 有子项的节点带折叠箭头，折叠收起整棵子树，展开恢复
 * - 编辑弹窗「上级文件夹」候选排除自身，选中后层级实际落库（depth 变化）
 *
 * 前置：seed 在页面加载后写入内存库（mock db 为模块级，刷新即重置，故不可先 seed 再 reload）；
 * 层级数据经 window.__orbitMock.db 直改后手动 emitDbChange（走 seed 同款广播路径）。
 */
import { expect, test, type Page } from "@playwright/test";

const ROW = '[data-testid="project-row"]';

/** 造层级：测试项目(顶层) / 文件夹父(顶层) → 子项目甲 → 孙项目乙 / 孤儿项目(父不存在) */
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
      { id: mock.db.seq++, uuid: "e2e-folder", title: "文件夹父", sort_order: 1, parent_uuid: null, ...base },
      { id: mock.db.seq++, uuid: "e2e-child", title: "子项目甲", sort_order: 2, parent_uuid: "e2e-folder", ...base },
      { id: mock.db.seq++, uuid: "e2e-grand", title: "孙项目乙", sort_order: 3, parent_uuid: "e2e-child", ...base },
      { id: mock.db.seq++, uuid: "e2e-orphan", title: "孤儿项目", sort_order: 4, parent_uuid: "not-exist-uuid", ...base },
    );
    mock.emitDbChange();
  });
  await expect(page.locator(ROW)).toHaveCount(5);
}

test("M8：层级渲染——DFS 序 + 深度标注 + 缩进递增 + 孤儿回落顶层", async ({ page }) => {
  await openSidebar(page);
  const rows = page.locator(ROW);

  // 期望序：测试项目(0) / 文件夹父(0) / 子项目甲(1) / 孙项目乙(2) / 孤儿项目(0)
  const expected: Array<[string, string]> = [
    ["测试项目", "0"],
    ["文件夹父", "0"],
    ["子项目甲", "1"],
    ["孙项目乙", "2"],
    ["孤儿项目", "0"],
  ];
  for (let i = 0; i < expected.length; i++) {
    const [title, depth] = expected[i];
    await expect(rows.nth(i)).toContainText(title);
    await expect(rows.nth(i)).toHaveAttribute("data-depth", depth);
  }

  // 缩进：顶层 8px，每层 +14px
  const padOf = (i: number) =>
    rows.nth(i).evaluate((el) => getComputedStyle(el).paddingLeft);
  expect(await padOf(1)).toBe("8px");
  expect(await padOf(2)).toBe("22px");
  expect(await padOf(3)).toBe("36px");
  // 孤儿回落顶层 → 与顶层同缩进
  expect(await padOf(4)).toBe("8px");
});

test("M8：折叠箭头收起/展开整棵子树", async ({ page }) => {
  await openSidebar(page);
  const rows = page.locator(ROW);

  // 两层父节点都有折叠入口
  await expect(page.getByRole("button", { name: "折叠子项目 文件夹父" })).toBeVisible();
  await expect(page.getByRole("button", { name: "折叠子项目 子项目甲" })).toBeVisible();

  // 折叠顶层父 → 子孙全部隐藏，顶层孤儿不受影响
  await page.getByRole("button", { name: "折叠子项目 文件夹父" }).click();
  await expect(rows).toHaveCount(3);
  await expect(rows.nth(0)).toContainText("测试项目");
  await expect(rows.nth(1)).toContainText("文件夹父");
  await expect(rows.nth(2)).toContainText("孤儿项目");
  await expect(page.getByRole("button", { name: "展开子项目 文件夹父" })).toBeVisible();

  // 展开恢复
  await page.getByRole("button", { name: "展开子项目 文件夹父" }).click();
  await expect(rows).toHaveCount(5);

  // 折叠中间层 → 只隐藏其子树，父与顶层仍在
  await page.getByRole("button", { name: "折叠子项目 子项目甲" }).click();
  await expect(rows).toHaveCount(4);
  await expect(rows.nth(2)).toContainText("子项目甲");
  await expect(rows.nth(3)).toContainText("孤儿项目");
});

test("M8：编辑弹窗「上级文件夹」候选排除自身，改层级后落库", async ({ page }) => {
  await openSidebar(page);
  const rows = page.locator(ROW);

  // 初始：孤儿项目在顶层
  await expect(rows.nth(4)).toContainText("孤儿项目");
  await expect(rows.nth(4)).toHaveAttribute("data-depth", "0");

  // 右键 → 编辑项目
  await page.locator(ROW, { hasText: "孤儿项目" }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "编辑项目" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();

  // 候选排除自身（否则 Rust 侧自引用必拒）；
  // 候选文案带祖先路径（"文件夹父 / 子项目甲"），故用 exact 精确锁定顶层项
  await page.getByRole("combobox").click();
  await expect(page.getByRole("option", { name: "孤儿项目", exact: true })).toHaveCount(0);
  await expect(page.getByRole("option", { name: "文件夹父", exact: true })).toBeVisible();
  await page.getByRole("option", { name: "文件夹父", exact: true }).click();

  await page.getByRole("button", { name: "保存" }).click();
  await expect(dialog).toHaveCount(0);

  // 落库生效：仍在序末（sort_order 未变，只换了父），但缩进 +14px、深度 1；
  // 文本断言是必须的——它正是暴露「mock 未模拟 JSON 边界导致标题被 undefined 覆盖」
  // 这一缺陷的断言（见 src/test/ipc-mock.ts 的 wireArgs 注释）
  await expect(rows).toHaveCount(5);
  await expect(rows.nth(4)).toContainText("孤儿项目");
  await expect(rows.nth(4)).toHaveAttribute("data-uuid", "e2e-orphan");
  await expect(rows.nth(4)).toHaveAttribute("data-depth", "1");
});
