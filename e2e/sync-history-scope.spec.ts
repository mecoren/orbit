/**
 * 同步历史卡的类型筛选（对齐移动端 `_SyncHistoryCard._scopes` 四档）
 *
 * 背景：桌面此前固定 `cloudSyncHistory("all", 50)`——排障时想「只看失败的那几次
 * 即时推送」只能自己在上百行里翻。移动端早有四档筛选，本 spec 锁住桌面补齐后的
 * 行为：切档会重新按 scope 拉取、且列表只留该类型的行。
 *
 * 数据源：`ipc-mock` 的 `cloud_sync_history` 已种三条同构记录（push_only 成功 /
 * incremental 失败 / incremental 成功），并按 `scope` 过滤——与真桥同口径。
 */
import { expect, test, type Page } from "@playwright/test";

/** 进设置页 → 同步与备份分区（历史卡在该分区内） */
async function openSyncSection(page: Page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.getByRole("button", { name: "设置" }).click();
  await expect(page.getByRole("heading", { name: "设置" })).toBeVisible();
  await page.getByRole("button", { name: "同步与备份" }).click();
}

/** 展开同步历史卡（默认折叠，展开才拉取 IPC） */
async function expandHistory(page: Page) {
  const toggle = page.getByRole("button", { name: /同步历史/ });
  await toggle.click();
  await expect(page.getByRole("button", { name: "全部" })).toBeVisible();
}

test("同步历史：四档筛选条渲染，缺省全部", async ({ page }) => {
  await openSyncSection(page);
  await expandHistory(page);

  // 四档都在（「全部」在 expandHistory 里已断言）
  for (const label of ["完整同步", "即时推送", "启动同步"]) {
    await expect(page.getByRole("button", { name: label, exact: true })).toBeVisible();
  }
  // 缺省「全部」选中：aria-pressed 是筛选项的可访问态真值
  await expect(page.getByRole("button", { name: "全部" })).toHaveAttribute(
    "aria-pressed",
    "true",
  );
  // 全部档下行内类型标签也在（「即时推送」既是筛选钮也是行内标签，故按
  // 行容器定位——裸 getByText 会命中筛选钮，永远为真，等于没断言）
  await expect(page.getByText("最近 3 次增量同步")).toBeVisible();
});

test("同步历史：切到「即时推送」只剩该类型行，切回全部恢复", async ({ page }) => {
  await openSyncSection(page);
  await expandHistory(page);

  // 切档前：完整同步的行（mock 里 incremental 失败那条带错误文案）可见
  await expect(page.getByText(/todos 模块上传失败/)).toBeVisible();

  await page.getByRole("button", { name: "即时推送", exact: true }).click();

  // 切档后：只剩 push_only 一行——incremental 的失败行消失
  await expect(page.getByText(/todos 模块上传失败/)).toBeHidden();
  await expect(page.getByRole("button", { name: "即时推送", exact: true })).toHaveAttribute(
    "aria-pressed",
    "true",
  );
  // 副标题随档位改口（不再是「最近 N 次增量同步」）
  await expect(page.getByText(/最近 1 次即时推送/)).toBeVisible();

  // 切回全部：两条 incremental 行回来
  await page.getByRole("button", { name: "全部" }).click();
  await expect(page.getByText(/todos 模块上传失败/)).toBeVisible();
});

test("同步历史：某档无记录时给该档专属空态", async ({ page }) => {
  await openSyncSection(page);
  await expandHistory(page);

  // mock 没有 pull_only 记录 → 空态文案点名当前档位，而不是笼统「暂无同步记录」
  await page.getByRole("button", { name: "启动同步", exact: true }).click();
  await expect(page.getByText("暂无启动同步记录")).toBeVisible();
});
