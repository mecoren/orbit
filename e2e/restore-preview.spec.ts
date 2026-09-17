/**
 * 恢复预览确认框（备份卡「恢复」→ 五秒时停 + 前 10 条预览 + 统计）
 *
 * 回归口径：点恢复必须弹出确认框（不可静默无响应），预览 ready，
 * 确认钮时停中禁用；全程零控制台报错。
 *
 * mock 默认历史为空（无恢复按钮），本文件在用例内包一层 invoke
 * 拦截返回一条历史备份；预览命令走 ipc-mock 同构体。
 */
import { expect, test, type Page } from "@playwright/test";

async function gotoSyncSettings(page: Page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "全部任务" })).toBeVisible({
    timeout: 30_000,
  });
  await page.goto("/settings");
  // 注意：goto 后 JS 上下文重建，拦截器必须在此之后注入
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__;
    const origInvoke = internals.invoke.bind(internals);
    internals.invoke = (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "full_backup_list_local") {
        return Promise.resolve([
          {
            filename: "backup2026-09-17-test.orfullsync",
            file_path: "/mock/backups/backup.orfullsync",
            modified_at: 1758067200,
            size_bytes: 2450,
          },
        ]);
      }
      return origInvoke(cmd, args);
    };
  });
  await page.getByRole("button", { name: "同步与备份" }).click();
  await expect(page.getByText("全量备份（.orfullsync）")).toBeVisible();
}

test("恢复按钮弹出预览确认框", async ({ page }) => {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text().slice(0, 500));
  });
  page.on("pageerror", (err) => errors.push(String(err).slice(0, 500)));

  await gotoSyncSettings(page);
  await page.getByRole("button", { name: /历史备份/ }).click();
  await expect(
    page.getByText("backup2026-09-17-test.orfullsync"),
  ).toBeVisible();
  await page.getByRole("button", { name: "恢复", exact: true }).click();

  await expect(page.getByRole("alertdialog")).toBeVisible({ timeout: 5000 });
  await expect(page.getByText("从备份恢复全部数据")).toBeVisible();
  // 预览 ready（mock 回固定体）
  await expect(page.getByText("示例任务一")).toBeVisible({ timeout: 5000 });
  // 确认钮时停中禁用
  await expect(
    page.getByRole("button", { name: /请阅读后果/ }),
  ).toBeDisabled();

  expect(errors).toEqual([]);
});
