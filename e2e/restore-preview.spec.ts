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

test("时停自预览解密落定起算（解密中不走字）", async ({ page }) => {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text().slice(0, 500));
  });
  page.on("pageerror", (err) => errors.push(String(err).slice(0, 500)));

  await gotoSyncSettings(page);
  // 预览请求挂起在门闩上（模拟解密耗时），用例放行前不 resolve
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__;
    const origInvoke = internals.invoke.bind(internals);
    (window as any).__previewGate = new Promise<void>((resolve) => {
      (window as any).__releasePreview = resolve;
    });
    internals.invoke = (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "full_backup_peek_local" || cmd === "full_backup_peek_cloud") {
        return (window as any).__previewGate.then(() =>
          origInvoke(cmd, args),
        );
      }
      return origInvoke(cmd, args);
    };
  });
  await page.getByRole("button", { name: /历史备份/ }).click();
  await expect(
    page.getByText("backup2026-09-17-test.orfullsync"),
  ).toBeVisible();
  await page.getByRole("button", { name: "恢复", exact: true }).click();

  await expect(page.getByRole("alertdialog")).toBeVisible({ timeout: 5000 });
  // 解密中：确认钮显示等待文案且禁用，倒计时尚未起算
  const pendingBtn = page.getByRole("button", {
    name: "正在解密预览…",
    exact: true,
  });
  await expect(pendingBtn).toBeVisible({ timeout: 5000 });
  await expect(pendingBtn).toBeDisabled();
  // 等满 3 秒（超过一半冷静期）：仍无倒计时（旧并行口径此时已走到 2s）
  await page.waitForTimeout(3000);
  await expect(pendingBtn).toBeDisabled();
  await expect(
    page.getByRole("button", { name: /请阅读后果/ }),
  ).toHaveCount(0);

  // 放行解密 → 预览 ready，时停才从满格起算
  await page.evaluate(() => (window as any).__releasePreview());
  await expect(page.getByText("示例任务一")).toBeVisible({ timeout: 5000 });
  const holdBtn = page.getByRole("button", { name: /请阅读后果（[45]s）/ });
  await expect(holdBtn).toBeVisible({ timeout: 5000 });
  await expect(holdBtn).toBeDisabled();

  expect(errors).toEqual([]);
});

test("两段式确认：第一次只递交、第二次走完 5 秒才真正恢复", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text().slice(0, 500));
  });
  page.on("pageerror", (err) => errors.push(String(err).slice(0, 500)));

  await gotoSyncSettings(page);
  // 拦截真实恢复执行并计数（mock 未实现该命令，用例内伪造成功回执）
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__;
    const origInvoke = internals.invoke.bind(internals);
    (window as any).__importCalls = 0;
    internals.invoke = (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "full_backup_import") {
        (window as any).__importCalls += 1;
        return Promise.resolve({ success_count: 2, error_count: 0 });
      }
      return origInvoke(cmd, args);
    };
  });
  await page.getByRole("button", { name: /历史备份/ }).click();
  await expect(
    page.getByText("backup2026-09-17-test.orfullsync"),
  ).toBeVisible();
  await page.getByRole("button", { name: "恢复", exact: true }).click();

  // 第一段：预览 ready → 等 5 秒时停走完 → 点确认恢复
  await expect(page.getByText("示例任务一")).toBeVisible({ timeout: 5000 });
  const firstConfirm = page.getByRole("button", {
    name: "确认恢复",
    exact: true,
  });
  await expect(firstConfirm).toBeEnabled({ timeout: 15_000 });
  await firstConfirm.click();

  // 第一次点击只递交不执行：无导入调用，弹出第二段最终确认（独立 5 秒）
  await expect(page.getByText("最后确认：立即覆盖恢复")).toBeVisible({
    timeout: 5000,
  });
  await expect(
    page.getByRole("button", { name: /请阅读后果/ }),
  ).toBeDisabled();
  expect(await page.evaluate(() => (window as any).__importCalls)).toBe(0);

  // 第二段 5 秒走完 → 第二次点击才真正执行恢复
  const finalConfirm = page.getByRole("button", {
    name: "确认并恢复",
    exact: true,
  });
  await expect(finalConfirm).toBeEnabled({ timeout: 15_000 });
  await finalConfirm.click();
  await expect(page.getByText(/导入完成：成功/)).toBeVisible({
    timeout: 5000,
  });
  expect(await page.evaluate(() => (window as any).__importCalls)).toBe(1);

  expect(errors).toEqual([]);
});
