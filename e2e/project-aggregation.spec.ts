/**
 * M8+ 父清单聚合子清单任务（UI 层）
 *
 * 覆盖点：选中父清单 → 任务列表含其**全部后代清单**的直接任务；非后代清单的任务、
 * 未分组任务、其他项目（seed 的「测试项目」）的任务均不入；选中叶子清单只聚到自己。
 *
 * ⚠️ 与 `project-drag-reparent.spec.ts` 分开的原因：本用例断言的是**面板客户端过滤层**
 * （`apps/desktop/src/features/todo/shared/task-filters.ts::projectIds` +
 * `task-panel.tsx` 传参）。该文件与并发会话的「工具栏排序方向档」改动同处一个 hunk，
 * 本批未提交（留在工作树），因此本文件随其同批落库——单独提交会让 CI 的
 * `pnpm e2e` 在 HEAD 版面板代码上红（查询谓词聚合已生效、面板会再把后代任务过滤掉）。
 * 服务端谓词侧与纯函数侧的证据在已提交部分：`cargo test --lib`（`project_ids` 谓词
 * 9 例 + todo_api 集成 2 例）、`project-tree.test.ts`（`projectIdsWithDescendants`）、
 * 移动端 `task_logic_test.dart`（`projectIds` 集合过滤 4 例）。
 *
 * 前置：seed 在页面加载后写入内存库（mock db 为模块级，刷新即重置，故不可先 seed 再 reload）。
 */
import { expect, test, type Page } from "@playwright/test";

const ROW = '[data-testid="project-row"]';

/** 造三层清单 + 每个清单一条直接任务：甲 → 乙 → 丙；丁 顶层；另有无归属任务 */
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
    const 甲 = { id: mock.db.seq++, uuid: "e2e-a", title: "甲", sort_order: 1, parent_uuid: null, ...base };
    const 乙 = { id: mock.db.seq++, uuid: "e2e-b", title: "乙", sort_order: 2, parent_uuid: "e2e-a", ...base };
    const 丙 = { id: mock.db.seq++, uuid: "e2e-c", title: "丙", sort_order: 3, parent_uuid: "e2e-b", ...base };
    const 丁 = { id: mock.db.seq++, uuid: "e2e-d", title: "丁", sort_order: 4, parent_uuid: null, ...base };
    mock.db.projects.push(甲, 乙, 丙, 丁);

    const taskBase = {
      description: null,
      priority: 0,
      status: "pending",
      done: 0,
      done_at: null,
      due_date: null,
      start_date: null,
      repeat_after: 0,
      repeat_mode: 0,
      percent_done: 0,
      position: 1000,
      is_favorite: 0,
      my_day_date: null,
      is_deleted: 0,
      created_at: now,
      updated_at: now,
      deleted_at: null,
      version: 1,
    };
    mock.db.tasks.push(
      { id: mock.db.seq++, uuid: "e2e-t-a", title: "甲任务", project_id: 甲.id, ...taskBase },
      { id: mock.db.seq++, uuid: "e2e-t-b", title: "乙任务", project_id: 乙.id, ...taskBase },
      { id: mock.db.seq++, uuid: "e2e-t-c", title: "丙任务", project_id: 丙.id, ...taskBase },
      { id: mock.db.seq++, uuid: "e2e-t-d", title: "丁任务", project_id: 丁.id, ...taskBase },
      { id: mock.db.seq++, uuid: "e2e-t-x", title: "无归属任务", project_id: null, ...taskBase },
    );
    mock.emitDbChange();
  });
  await expect(page.locator(ROW)).toHaveCount(5);
}

test("M8+：选中父清单聚合全部后代清单的任务", async ({ page }) => {
  await openSidebar(page);

  // 选中父清单「甲」
  await page.locator(ROW, { hasText: "甲" }).click();
  await expect(page.getByRole("heading", { name: "甲" })).toBeVisible();

  // 自身 + 后代（乙、丙）的直接任务全在
  await expect(page.getByText("甲任务")).toBeVisible();
  await expect(page.getByText("乙任务")).toBeVisible();
  await expect(page.getByText("丙任务")).toBeVisible();

  // 非后代清单 / 未分组 / 其他项目（seed 的测试项目）的任务均不入
  await expect(page.getByText("丁任务")).toHaveCount(0);
  await expect(page.getByText("无归属任务")).toHaveCount(0);
  await expect(page.getByText("既有任务-今天截止")).toHaveCount(0);

  // 选中叶子清单「丙」→ 只聚到自己一条（兄弟与祖先的任务不入）
  await page.locator(ROW, { hasText: "丙" }).click();
  await expect(page.getByText("丙任务")).toBeVisible();
  await expect(page.getByText("甲任务")).toHaveCount(0);
  await expect(page.getByText("乙任务")).toHaveCount(0);
});
