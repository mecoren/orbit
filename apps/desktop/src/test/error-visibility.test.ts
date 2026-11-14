/**
 * 上线就绪评估第二批整改的静态护栏
 *
 * 守两件事：
 * 1. 同步历史 / 本地备份 / 云端备份的**读取失败**不得再被伪装成「空列表」。
 *    用户据此判断「有没有备份可以恢复」，静默失败会直接导致错误的恢复决策；
 *    保留空列表只为不卡加载态，错误必须同时通过 toast 可见。
 * 2. Tauri fs 权限不得加宽泛静态 scope。前端所有 read/write/stat 路径都来自
 *    dialog 的 open()/save()，Tauri 2 官方口径是「选中路径自动加入 fs scope」
 *    （会话级、重启清空）；静态放通 $HOME 等反而扩大攻击面。若将来新增不经
 *    dialog 的 fs 路径，应先改 capabilities 并同步调整本用例。
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const DESKTOP = path.resolve(import.meta.dirname, "../..");
const SYNC_SECTION = path.join(
  DESKTOP,
  "src/components/settings/sync-section.tsx",
);
const CAPABILITIES = path.join(
  DESKTOP,
  "src-tauri/capabilities/default.json",
);

const syncSection = readFileSync(SYNC_SECTION, "utf8");
const capabilities = JSON.parse(readFileSync(CAPABILITIES, "utf8")) as {
  permissions: Array<
    | string
    | { identifier: string; allow?: unknown[]; deny?: unknown[] }
  >;
};

describe("同步设置的错误可见性", () => {
  it("列表读取失败不得静默回落成空列表", () => {
    expect(syncSection).not.toMatch(/\.catch\(\(\) => setHistory\(\[\]\)\)/);
    expect(syncSection).not.toMatch(/\.catch\(\(\) => setCloudList\(\[\]\)\)/);
    expect(syncSection).not.toMatch(/\.catch\(\(\) => setEntries\(\[\]\)\)/);
    expect(syncSection).toContain("读取本地备份历史失败");
    expect(syncSection).toContain("读取云端备份列表失败");
    expect(syncSection).toContain("读取同步历史失败");
  });

  it("锁定同步密码失败不得静默吞掉", () => {
    expect(syncSection).not.toContain("syncCryptoLock().catch(() => {})");
    expect(syncSection).toContain("锁定同步密码失败");
  });
});

describe("Tauri capabilities", () => {
  it("fs 权限不配宽泛静态 allow scope", () => {
    const fsEntries = capabilities.permissions.filter((p) =>
      typeof p === "string"
        ? p.startsWith("fs:")
        : p.identifier.startsWith("fs:"),
    );
    expect(fsEntries.length).toBeGreaterThan(0);
    for (const entry of fsEntries) {
      if (typeof entry !== "string") {
        expect(entry.allow ?? []).toEqual([]);
      }
    }
  });
});
