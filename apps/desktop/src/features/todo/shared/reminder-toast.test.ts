// 到期提醒卡「到点自动收」口径（2026-11-27 反馈：卡一直挂右上角不收）：
// ① 停留时长有限，沿用 04 §六 提醒兜底 10s（普通 toast 4s；本卡带四个动作钮）；
// ② 自动收也必须清 id 登记——sonner 到点只回调 onAutoClose、不回调 onDismiss，
//    漏挂会在 reminderToastIds 里留一条指向已消失 toast 的僵尸映射。
import { describe, expect, it, vi } from "vitest";

import { REMINDER_TOAST_DWELL_MS, reminderToastOptions } from "./reminder-toast";

describe("reminderToastOptions", () => {
  it("停留时长有限且为 04 §六 的 10 秒口径，不再常驻", () => {
    expect(REMINDER_TOAST_DWELL_MS).toBe(10_000);
  });

  it("到点自动收走 onAutoClose 清 id 登记", () => {
    const onGone = vi.fn();
    reminderToastOptions(onGone).onAutoClose();
    expect(onGone).toHaveBeenCalledTimes(1);
  });

  it("手动关闭/划走时 onDismiss 同样清登记", () => {
    const onGone = vi.fn();
    reminderToastOptions(onGone).onDismiss();
    expect(onGone).toHaveBeenCalledTimes(1);
  });
});
