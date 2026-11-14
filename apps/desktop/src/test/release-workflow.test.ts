/**
 * 发布流水线护栏（流程见 docs/08_发布与更新流程.md）
 *
 * 守两件事，都是 `latest.json` 合成作业的真实故障面：
 * 1. Release 资产枚举必须走 `GET /repos/{owner}/{repo}/releases/{release_id}/assets`。
 *    曾误写成 `releases/assets/{release_id}/assets`（不存在的端点），首发时
 *    「上一轮 latest.json 回落签名」必然为空，枚举拿不到任何资产 → 空清单被拒。
 * 2. 枚举失败必须可见。`gh api` 放在进程替换 `< <(...)` 内时，其退出码不会
 *    触发 `set -e`，脚本只会读到空列表再报「签名密钥不匹配」，掩盖真实原因。
 *
 * dry_run 预演不执行 manifest 作业（该 job 只在 tag + 非 dry_run 下运行），
 * 故这两条只能靠静态护栏守住；不复用 release.yml 内的任何解析代码。
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const DESKTOP = path.resolve(import.meta.dirname, "../..");
const ROOT = path.resolve(DESKTOP, "../..");
const WORKFLOW = path.join(ROOT, ".github/workflows/release.yml");

const workflow = readFileSync(WORKFLOW, "utf8");

describe("发布流水线 latest.json 合成", () => {
  it("资产枚举走 /releases/{release_id}/assets 列表端点", () => {
    expect(workflow).toContain('gh api "${API}/releases/${RELEASE_ID}/assets"');
    expect(workflow).not.toMatch(/releases\/assets\/\$\{RELEASE_ID\}\/assets/);
  });

  it("资产枚举先落变量并显式检查退出码，不藏在进程替换里", () => {
    expect(workflow).toMatch(/ASSET_LIST=\$\(gh api/);
    expect(workflow).toMatch(/\|\|\s*\{[\s\S]*?exit 1/);
    expect(workflow).not.toMatch(/done < <\(\s*gh api/);
  });

  it("依赖审计是硬拦截：既不得 || true，也不得 continue-on-error 放水", () => {
    const start = workflow.indexOf("- name: cargo audit");
    expect(start).toBeGreaterThan(-1);
    // 覆盖 cargo audit 与 pnpm audit 两段。第一批删了内层 `|| true`，
    // 第三批删了外层 continue-on-error —— 任一回归都会让 audit 假绿。
    const auditBlock = workflow.slice(start, start + 900);
    expect(auditBlock).not.toContain("|| true");
    expect(auditBlock).not.toContain("continue-on-error");
    expect(auditBlock).toContain("cargo audit --file");
    expect(auditBlock).toContain("pnpm audit");
  });

  it("发布链硬依赖 CI：reusable workflow + 构建作业 needs 含 ci", () => {
    const ciWorkflow = readFileSync(
      path.join(ROOT, ".github/workflows/ci.yml"),
      "utf8",
    );
    expect(ciWorkflow).toContain("workflow_call:");
    expect(workflow).toMatch(/uses: \.\/\.github\/workflows\/ci\.yml/);
    expect(workflow).toContain("secrets: inherit");
    // desktop 与 android 两个构建作业都必须等 CI 与 audit 全绿
    const needs = [...workflow.matchAll(/^    needs: \[audit, ci\]$/gm)];
    expect(needs).toHaveLength(2);
  });
});
