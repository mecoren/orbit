/**
 * 冲突记录分区纯函数测试（03 文档 §八 遗留项）
 *
 * 面板的「查看差异」是用户判断该不该点「恢复」的唯一依据，因此载荷解析、
 * 差异计算与值渲染三个纯函数必须稳定：解析失败要回落空对象（不丢整条记录）、
 * 元字段不得混进业务差异、时间戳列要按本地时间可读化。
 */
import { describe, expect, it } from "vitest";

import { diffFields, fmtValue, parsePayload } from "./sync-conflict-section";

describe("parsePayload", () => {
  it("解析对象载荷", () => {
    expect(parsePayload('{"title":"写周报","priority":1}')).toEqual({
      title: "写周报",
      priority: 1,
    });
  });

  it("非法/非对象载荷回落空对象（不吞整条记录）", () => {
    expect(parsePayload("not-json")).toEqual({});
    expect(parsePayload("[1,2]")).toEqual({});
    expect(parsePayload('"str"')).toEqual({});
  });
});

describe("diffFields", () => {
  it("只保留两侧不一致的业务字段", () => {
    const loser = { title: "旧", priority: 1, status: "pending" };
    const winner = { title: "新", priority: 1, status: "pending" };
    expect(diffFields(loser, winner)).toEqual([
      { key: "title", before: "旧", after: "新" },
    ]);
  });

  it("同步元字段不进差异（uuid/updated_at/version/is_deleted 等）", () => {
    const loser = { uuid: "u1", updated_at: 100, version: 1, is_deleted: 0, title: "同名" };
    const winner = { uuid: "u1", updated_at: 200, version: 2, is_deleted: 0, title: "同名" };
    expect(diffFields(loser, winner)).toEqual([]);
  });

  it("缺键不当作差异（列裁剪差异不误导用户）", () => {
    // 旧版本同步包缺少新列时，胜方有键而败方无键 → JSON 序列化后不同，
    // 这里显式约束为「只比较两侧都存在的键」
    expect(diffFields({ title: "A" }, { title: "A", hex_color: "#111" })).toEqual([]);
  });
});

describe("fmtValue", () => {
  it("时间戳列按本地时间可读化", () => {
    const ts = new Date(2026, 8, 17, 9, 5).getTime();
    expect(fmtValue("due_date", ts)).toBe("2026-09-17 09:05");
  });

  it("非时间戳数值原样输出", () => {
    expect(fmtValue("priority", 3)).toBe("3");
  });

  it("空值、对象与超长文本有兜底", () => {
    expect(fmtValue("description", null)).toBe("（空）");
    expect(fmtValue("conditions", { a: 1 })).toBe('{"a":1}');
    expect(fmtValue("title", "x".repeat(200))).toHaveLength(121);
  });
});
