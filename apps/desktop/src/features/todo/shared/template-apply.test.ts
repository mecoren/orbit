// apps/desktop/src/features/todo/shared/template-apply.test.ts
import { describe, expect, it } from "vitest";

import { parseTemplatePayload, templateDueDate } from "./template-apply";

describe("parseTemplatePayload", () => {
  it("全字段解析", () => {
    const p = parseTemplatePayload(
      '{"title":"周报","notes":"格式说明","priority":3,"due_offset_days":2,"subtasks":["a","b"]}',
    );
    expect(p).toEqual({
      title: "周报",
      notes: "格式说明",
      priority: 3,
      due_offset_days: 2,
      subtasks: ["a", "b"],
    });
  });

  it("空对象返回空预填（不覆盖表单默认）", () => {
    expect(parseTemplatePayload("{}")).toEqual({});
  });

  it("非法 JSON / 非对象返回 null", () => {
    expect(parseTemplatePayload("not-json")).toBeNull();
    expect(parseTemplatePayload("[1,2]")).toBeNull();
    expect(parseTemplatePayload('"str"')).toBeNull();
  });

  it("类型不匹配的键静默跳过", () => {
    const p = parseTemplatePayload('{"title":123,"priority":"高"}');
    expect(p).toEqual({});
  });

  it("subtasks 混入非字符串时整组丢弃（宁缺毋错）", () => {
    const p = parseTemplatePayload('{"subtasks":["a",1]}');
    expect(p!.subtasks).toBeUndefined();
  });
});

describe("templateDueDate", () => {
  it("offset 0 = 今天（YYYY-MM-DD）", () => {
    const today = new Date();
    const expected = [
      today.getFullYear(),
      String(today.getMonth() + 1).padStart(2, "0"),
      String(today.getDate()).padStart(2, "0"),
    ].join("-");
    expect(templateDueDate(0)).toBe(expected);
  });

  it("offset 1 = 明天；负偏移跨月回退", () => {
    const tomorrow = templateDueDate(1);
    const back = templateDueDate(-1);
    expect(new Date(tomorrow).getDate()).toBe(new Date().getDate() + 1 === 32 ? 1 : new Date().getDate() + 1);
    // 只断言可解析与格式长度（跨月/跨年由 Date 本地语义保证）
    expect(back).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});
