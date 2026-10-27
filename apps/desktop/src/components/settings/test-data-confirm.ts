/**
 * 测试数据两步确认的文案（纯函数，可单测）
 *
 * 生成与清除都是批量写库：第一步说明影响范围，第二步复述后果并要求再点一次，
 * 避免「选完规模顺手点一下」直接落到开发库里。第二步标题固定带「再次确认」，
 * 与第一步在视觉上无法混淆。
 */
import { formatCount } from "./diagnostics-format";

/** 可执行的操作：生成 / 清除 */
export type TestDataAction = "seed" | "clear";

/** 确认步骤：1 = 说明范围，2 = 再次确认 */
export type TestDataConfirmStep = 1 | 2;

export interface TestDataConfirmCopy {
  title: string;
  description: string;
  confirmLabel: string;
}

export function testDataConfirmCopy(
  action: TestDataAction,
  step: TestDataConfirmStep,
  tasks: number,
): TestDataConfirmCopy {
  const isSeed = action === "seed";
  if (step === 1) {
    return {
      title: isSeed
        ? "生成示例数据（第 1 步 / 共 2 步）"
        : "清除示例数据（第 1 步 / 共 2 步）",
      description: isSeed
        ? `将写入约 ${formatCount(tasks)} 条示例任务，以及按固定比例派生的子任务、提醒、评论、标签关联与任务关联；生成前会先清掉上一批示例数据，手工数据不受影响。`
        : "将删除库中 uuid 以 dev-seed- 开头的全部示例行（项目、标签、任务、子任务、提醒、评论、关联），手工数据不受影响。",
      confirmLabel: "继续",
    };
  }
  return {
    title: isSeed
      ? "再次确认生成（第 2 步 / 共 2 步）"
      : "再次确认清除（第 2 步 / 共 2 步）",
    description: isSeed
      ? `再确认一次：本次会先删掉上一批示例数据，再写入 ${formatCount(tasks)} 条任务；写入后可在本页用「清除示例数据」撤销。`
      : "再确认一次：删除是物理删除、不可撤销，确认后需重新生成才能恢复示例数据。",
    confirmLabel: isSeed ? "确认生成" : "确认清除",
  };
}
