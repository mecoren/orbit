/**
 * 「损坏数据不得被空值覆盖」静态护栏。
 *
 * 背景（2026-11-14 第六轮只读复核）：第一批修了移动端
 * `saved_filters_screen.dart` 的 jsonDecode 静默回落，但桌面端同型的三条
 * 路径没动——编辑态解析失败回落空表单/空草稿/空列表，随后一次「保存」就把
 * 空值整体写回，覆盖原筛选器、模板与全部自定义主题且不可逆。行为测试
 * （saved-filter-builder.test.ts）锁住解析返回 null，这里锁住**消费方必须
 * 区分 null 并拒绝写入**，防止后来者「顺手改回防御性回落」。
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const SRC = path.join(import.meta.dirname, "..");
const ROOT = path.join(SRC, "../../..");
const read = (rel: string) => readFileSync(path.join(SRC, rel), "utf8");
const readRepo = (rel: string) => readFileSync(path.join(ROOT, rel), "utf8");

describe("损坏的 JSON 数据不得被空值覆盖", () => {
  it("筛选条件解析失败返回 null，编辑态禁止提交", () => {
    const builder = read("features/todo/shared/saved-filter-builder.ts");
    expect(builder).toContain(
      "parseConditions(raw: string): FilterFormState | null",
    );
    expect(builder).toContain("return null");

    const dialog = read("features/todo/desktop/saved-filter-dialog.tsx");
    expect(dialog).toContain("setConditionsBroken(parsed === null)");
    expect(dialog).toContain("if (conditionsBroken)");
    expect(dialog).toContain("saving || conditionsBroken");
  });

  it("模板 payload 解析失败拒绝打开编辑弹窗", () => {
    const section = read("components/settings/templates-section.tsx");
    expect(section).toContain(
      "function draftOf(t: TodoTemplate): TemplateDraft | null",
    );
    expect(section).toContain("if (draft === null)");
    expect(section).not.toContain("损坏 payload 按空编辑");
  });

  it("同步冲突载荷解析失败返回 null 并禁用展开与恢复（双端）", () => {
    const desktop = read("components/settings/sync-conflict-section.tsx");
    expect(desktop).toContain(
      "parsePayload(raw: string): Record<string, unknown> | null",
    );
    expect(desktop).toContain(
      "const payloadBroken = loser === null || winner === null;",
    );
    expect(desktop).toContain("restoreMutation.isPending || payloadBroken");

    const dart = readRepo(
      "apps/mobile/lib/modules/settings/sync_conflicts_page.dart",
    );
    expect(dart).toContain("static Map<String, Object?>? _parse(String raw)");
    expect(dart).toContain("(_busy || payloadBroken)");
    expect(dart).toContain("载荷损坏");
  });

  it("自定义主题损坏时写操作抛错并备份原始值", () => {
    const theme = read("lib/color-theme.ts");
    expect(theme).toContain("CUSTOM_THEMES_CORRUPT_BACKUP_KEY");
    expect(theme).toContain("hasCorruptedCustomThemes");
    expect(theme).toContain("已阻止写入");
    expect(theme).not.toContain("忽略损坏数据");

    const section = read("components/settings/theme-section.tsx");
    expect(section).toContain("hasCorruptedCustomThemes()");
  });

  it("筛选条件损坏时列表给出可见徽标，不静默显示全量", () => {
    // applySavedFilter 的降级（损坏 = 不过滤）本身是合理防御，问题在于
    // 「列表看着正常、其实没过滤」。徽标是这条降级的可见性契约。
    const panel = read("features/todo/desktop/task-panel.tsx");
    expect(panel).toContain("savedFilterCorrupted");
    expect(panel).toContain('data-testid="saved-filter-corrupted"');
    expect(panel).toContain("当前列表未按条件过滤");

    const filter = read("features/todo/shared/saved-filter.ts");
    expect(filter).toContain("条件损坏不过滤");
  });

  it("排程偏好损坏时先备份原始值再回落默认", () => {
    // set_day_plan_prefs 会整键覆盖，UI 回显默认值后再保存 = 损坏内容永久消失。
    const rust = readRepo("crates/orbit-core/src/api/day_planner_api.rs");
    expect(rust).toContain('const KV_PREFS_CORRUPT: &str = "day_plan_prefs.corrupt"');
    expect(rust).not.toContain("serde_json::from_str(&raw).unwrap_or_default()");
  });
});
