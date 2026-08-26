// apps/desktop/src/features/todo/shared/parse-quick-input.test.ts
// parseQuickInput 规则表驱动测试（07 报告 §五-P1#7）
// 基准时刻 2026-08-26 为周三；日期 token 一律落到当日零点（本地时区），
// 与 lib/quick-dates.ts 快捷菜单「今天」口径一致。
import { describe, expect, it } from "vitest";

import { parseQuickInput } from "./parse-quick-input";

const NOW = new Date(2026, 7, 26, 15, 30); // 周三
const day = (month1based: number, d: number) => new Date(2026, month1based - 1, d).getTime();

const CTX = {
  projects: [
    { id: 1, title: "工作" },
    { id: 2, title: "工作汇报" },
    { id: 7, title: "生活" },
  ],
  labels: [
    { id: 10, title: "家人" },
    { id: 11, title: "紧急跟进" },
  ],
  now: NOW,
};

describe("parseQuickInput · 日期", () => {
  it("明天 → 次日零点，正文剥离", () => {
    const r = parseQuickInput("明天开会", CTX);
    expect(r.title).toBe("开会");
    expect(r.dueDate!.getTime()).toBe(day(8, 27));
  });

  it("大后天 → +3 天", () => {
    const r = parseQuickInput("交周报 大后天", CTX);
    expect(r.dueDate!.getTime()).toBe(day(8, 29));
    expect(r.title).toBe("交周报");
  });

  it("周X → 未来最近（含今天）：周五聚餐", () => {
    const r = parseQuickInput("周五聚餐", CTX); // 周三→周五 = +2
    expect(r.dueDate!.getTime()).toBe(day(8, 28));
  });

  it("今天恰逢周X → 取今天", () => {
    const r = parseQuickInput("周三站会", CTX);
    expect(r.dueDate!.getTime()).toBe(day(8, 26));
  });

  it("下周X → 下周一为首日的下周对应日", () => {
    const r = parseQuickInput("下周三复查", CTX); // 下周一=08-31，+2 → 09-02
    expect(r.dueDate!.getTime()).toBe(day(9, 2));
  });

  it("M月d日 今年未过 → 今年；已过 → 顺延一年", () => {
    expect(parseQuickInput("9月10日体检", CTX).dueDate!.getTime()).toBe(day(9, 10));
    expect(parseQuickInput("1月5日续费", CTX).dueDate!.getTime()).toBe(
      new Date(2027, 0, 5).getTime(),
    );
  });

  it("多个日期 token：靠后者覆盖；下周X 不被内层 周X 二次命中", () => {
    const r = parseQuickInput("下周三复查 改明天", CTX);
    expect(r.dueDate!.getTime()).toBe(day(8, 27));
    expect(r.title).toBe("复查 改");
  });
});

describe("parseQuickInput · 优先级/项目/标签", () => {
  it("!1-!5 提取优先级", () => {
    expect(parseQuickInput("买菜 !3", CTX).priority).toBe(3);
    expect(parseQuickInput("买菜", CTX).priority).toBe(0);
  });

  it("#项目 精确优先于前缀；前缀唯一命中可用", () => {
    expect(parseQuickInput("#工作 计划", CTX).projectId).toBe(1);
    expect(parseQuickInput("#工作汇 计划", CTX).projectId).toBe(2);
  });

  it("@标签 可多个且去重", () => {
    const r = parseQuickInput("买礼物 @家人 @家人 @紧急跟进", CTX);
    expect(r.labelIds).toEqual([10, 11]);
  });

  it("项目名以标点收尾也能截断（中文无空格场景）", () => {
    const r = parseQuickInput("#生活，明天交电费", CTX);
    expect(r.projectId).toBe(7);
    expect(r.title).toBe("，交电费");
    expect(r.dueDate!.getTime()).toBe(day(8, 27));
  });
});

describe("parseQuickInput · 兜底语义", () => {
  it("未匹配的 #token 原样保留在标题", () => {
    const r = parseQuickInput("事项 #不存在", CTX);
    expect(r.projectId).toBeNull();
    expect(r.title).toBe("事项 #不存在");
  });

  it("无 token 时原样返回", () => {
    const r = parseQuickInput("纯文本任务", CTX);
    expect(r.title).toBe("纯文本任务");
    expect(r.dueDate).toBeNull();
    expect(r.priority).toBe(0);
    expect(r.labelIds).toEqual([]);
  });

  it("剥离后收敛多余空白", () => {
    expect(parseQuickInput("买 牛奶  明天", CTX).title).toBe("买 牛奶");
  });

  it("!10 以上不识别且不损坏标题（评审修复：负向先行）", () => {
    const r = parseQuickInput("买菜 !12", CTX);
    expect(r.title).toBe("买菜 !12");
    expect(r.priority).toBe(0);
  });

  it("无效日期（平年 2月29日）不静默滚动，保留原文", () => {
    const r = parseQuickInput("2月29日聚会", CTX);
    expect(r.dueDate).toBeNull();
    expect(r.title).toBe("2月29日聚会");
  });

  it("词形变体：今天/后天/星期X/礼拜X/M月d号", () => {
    expect(parseQuickInput("今天交", CTX).dueDate!.getTime()).toBe(day(8, 26));
    expect(parseQuickInput("后天搬", CTX).dueDate!.getTime()).toBe(day(8, 28));
    expect(parseQuickInput("星期四复诊", CTX).dueDate!.getTime()).toBe(day(8, 27));
    expect(parseQuickInput("礼拜六加班", CTX).dueDate!.getTime()).toBe(day(8, 29));
    expect(parseQuickInput("9月10号体检", CTX).dueDate!.getTime()).toBe(day(9, 10));
  });
});
