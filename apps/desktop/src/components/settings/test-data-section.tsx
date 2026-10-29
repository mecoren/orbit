/**
 * 测试数据分区（仅开发构建可见）
 *
 * 为什么要有它：`pnpm tauri dev` 起来后手工点几十条任务只够看首屏，翻页续拉、
 * 看板列总数、日历范围、统计聚合、回收站都测不到边界。这里一键写入一份覆盖
 * 各读通道的样本库（项目树 / 标签 / 任务 / 子任务 / 提醒 / 评论 / 关联）。
 *
 * 环境门禁（两道）：
 * - 入口：`settingsCategories` 只在 `import.meta.env.DEV` 下列出本分区；本组件
 *   内再自检一次，兜住「被别处直接渲染」的情况；
 * - 执行：Rust 命令在 release 构建下直接返回不可用（见 `commands/dev_cmd.rs`）。
 *
 * 幂等与边界：生成前由 core 按 uuid 前缀（`dev-seed-`）清掉上一批，标题统一带
 * `【示例】` 前缀；手工数据不受影响，重复点击不会叠数据。
 */
import { useState } from "react";
import { Database, FlaskConical, Trash2 } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { DangerousConfirmDialog } from "@/components/ui/dangerous-confirm-dialog";
import { Spinner } from "@/components/ui/spinner";
import {
  devSeedClear,
  devSeedDemoData,
  type DevSeedClearResult,
  type DevSeedCounts,
  type DevSeedResult,
} from "@/lib/tauri";
import { formatCount } from "./diagnostics-format";
import {
  testDataConfirmCopy,
  type TestDataAction,
  type TestDataConfirmStep,
} from "./test-data-confirm";

/** 三档规模：首屏联调 / 常规翻页与看板 / 统计与滚动压力 */
const SCALES = [
  { tasks: 300, label: "300" },
  { tasks: 1_200, label: "1,200" },
  { tasks: 5_000, label: "5,000" },
] as const;

/** 结果明细行（顺序与阅读习惯一致：主表在前） */
const COUNT_ROWS: { key: keyof DevSeedCounts; label: string }[] = [
  { key: "projects", label: "项目" },
  { key: "labels", label: "标签" },
  { key: "tasks", label: "任务（含回收站）" },
  { key: "subtasks", label: "子任务" },
  { key: "reminders", label: "提醒" },
  { key: "comments", label: "评论" },
  { key: "task_labels", label: "标签关联" },
  { key: "task_relations", label: "任务关联" },
];

function totalOf(counts: DevSeedCounts): number {
  return COUNT_ROWS.reduce((sum, row) => sum + counts[row.key], 0);
}

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** 结果明细（生成与清理共用；只显示非零项） */
function CountBreakdown({ counts }: { counts: DevSeedCounts }) {
  const rows = COUNT_ROWS.filter((row) => counts[row.key] > 0);
  if (rows.length === 0) {
    return <p className="text-xs text-muted-foreground">没有需要处理的数据。</p>;
  }
  return (
    <div className="flex flex-wrap gap-x-4 gap-y-1">
      {rows.map((row) => (
        <span key={row.key} className="text-xs text-muted-foreground">
          {row.label}
          <span className="ml-1 font-mono tabular-nums text-foreground">
            {formatCount(counts[row.key])}
          </span>
        </span>
      ))}
    </div>
  );
}

export function TestDataSection() {
  const [tasks, setTasks] = useState<number>(SCALES[1].tasks);
  const [busy, setBusy] = useState<"seed" | "clear" | null>(null);
  const [seeded, setSeeded] = useState<DevSeedResult | null>(null);
  const [cleared, setCleared] = useState<DevSeedClearResult | null>(null);
  /** 两步确认：第一步说明范围，第二步再点一次才真正落库 */
  const [confirm, setConfirm] = useState<{
    action: TestDataAction;
    step: TestDataConfirmStep;
  } | null>(null);

  // 兜底门禁：即使被别处直接渲染，也拿不到操作按钮
  if (!import.meta.env.DEV) {
    return (
      <section className="space-y-4">
        <h2 className="text-base font-semibold text-foreground">测试数据</h2>
        <p className="text-sm text-muted-foreground">
          当前不是开发构建，测试数据功能不可用。
        </p>
      </section>
    );
  }

  const runSeed = async () => {
    if (busy) return;
    setBusy("seed");
    try {
      const result = await devSeedDemoData({ tasks });
      setSeeded(result);
      setCleared(null);
      toast.success(`已写入 ${formatCount(totalOf(result.created))} 行示例数据`, {
        description: `用时 ${result.elapsed_ms} ms；列表与统计已自动刷新`,
      });
    } catch (e) {
      toast.error("生成测试数据失败", { description: errorText(e) });
    } finally {
      setBusy(null);
    }
  };

  const runClear = async () => {
    if (busy) return;
    setBusy("clear");
    try {
      const result = await devSeedClear();
      setCleared(result);
      setSeeded(null);
      toast.success(`已清除 ${formatCount(totalOf(result.removed))} 行示例数据`, {
        description: `用时 ${result.elapsed_ms} ms；手工数据不受影响`,
      });
    } catch (e) {
      toast.error("清除测试数据失败", { description: errorText(e) });
    } finally {
      setBusy(null);
    }
  };

  /** 第一步 → 第二步 → 执行；两步各有一次强制冷静期 */
  const advanceConfirm = () => {
    if (!confirm) return;
    if (confirm.step === 1) {
      setConfirm({ action: confirm.action, step: 2 });
      return;
    }
    const action = confirm.action;
    setConfirm(null);
    void (action === "seed" ? runSeed() : runClear());
  };

  const confirmCopy = confirm
    ? testDataConfirmCopy(confirm.action, confirm.step, tasks)
    : null;

  return (
    <section className="space-y-4">
      <div>
        <h2 className="text-base font-semibold text-foreground">测试数据</h2>
        <p className="mt-1 text-[13px] text-muted-foreground">
          仅在开发构建（<code>pnpm tauri dev</code>）可见。一键写入覆盖各读通道的
          示例项目 / 标签 / 任务 / 子任务 / 提醒 / 评论 / 关联；生成前会先清掉上一批，
          重复点击不会叠数据，也不会碰手工数据。生成与清除都需要两步确认。
        </p>
      </div>

      <div className="space-y-4 rounded-lg border p-5">
        <div className="flex items-center gap-3">
          <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-muted">
            <FlaskConical className="size-4 text-muted-foreground" />
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-sm font-medium">生成规模</p>
            <p className="text-xs text-muted-foreground">
              子任务 / 提醒 / 评论 / 关联按固定比例派生；日期档覆盖已完成、逾期、
              今天到期、未来 30 天与无日期；约八成任务带开始日期，完成时间按
              「近密远疏」铺满近 3 年（热力图可切年份）
            </p>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2 pl-12">
          {SCALES.map((scale) => (
            <Button
              key={scale.tasks}
              size="sm"
              variant={tasks === scale.tasks ? "default" : "outline"}
              disabled={busy != null}
              onClick={() => setTasks(scale.tasks)}
            >
              {scale.label} 条任务
            </Button>
          ))}
        </div>

        <div className="flex flex-wrap items-center gap-2 pl-12">
          <Button
            onClick={() => setConfirm({ action: "seed", step: 1 })}
            disabled={busy != null}
          >
            {busy === "seed" ? (
              <Spinner className="size-4" />
            ) : (
              <Database className="size-4" />
            )}
            一键生成示例数据
          </Button>
          <Button
            variant="outline"
            className="text-destructive hover:text-destructive"
            onClick={() => setConfirm({ action: "clear", step: 1 })}
            disabled={busy != null}
          >
            {busy === "clear" ? (
              <Spinner className="size-4" />
            ) : (
              <Trash2 className="size-4" />
            )}
            清除示例数据
          </Button>
        </div>
      </div>

      {seeded && (
        <div className="space-y-2 rounded-lg border p-5">
          <p className="text-sm font-medium">
            已生成 {formatCount(totalOf(seeded.created))} 行
            <span className="ml-2 text-xs font-normal text-muted-foreground">
              用时 {seeded.elapsed_ms} ms
              {seeded.cleared.projects + seeded.cleared.tasks > 0
                ? `，先清掉上一批 ${formatCount(totalOf(seeded.cleared))} 行`
                : ""}
            </span>
          </p>
          <CountBreakdown counts={seeded.created} />
        </div>
      )}

      {cleared && (
        <div className="space-y-2 rounded-lg border p-5">
          <p className="text-sm font-medium">
            已清除 {formatCount(totalOf(cleared.removed))} 行
            <span className="ml-2 text-xs font-normal text-muted-foreground">
              用时 {cleared.elapsed_ms} ms
            </span>
          </p>
          <CountBreakdown counts={cleared.removed} />
        </div>
      )}

      <p className="text-xs text-muted-foreground">
        示例数据的标题带「【示例】」前缀、uuid 以 <code>dev-seed-</code> 开头，
        便于与手工数据区分；生产构建不显示本分区，命令在 release 下也会拒绝执行。
      </p>

      {/*
        两步确认共用同一个弹层组件：key 随步骤变化强制重挂，
        让第二步的冷静期从满格重新计时（否则会继承第一步已走完的倒计时）。
      */}
      {confirm && confirmCopy && (
        <DangerousConfirmDialog
          key={`${confirm.action}-${confirm.step}`}
          open
          onOpenChange={(open) => {
            if (!open) setConfirm(null);
          }}
          title={confirmCopy.title}
          description={confirmCopy.description}
          confirmLabel={confirmCopy.confirmLabel}
          holdSeconds={3}
          busy={busy != null}
          onConfirm={advanceConfirm}
          body={
            <div className="mt-3 space-y-1 rounded-md border bg-muted/40 px-3 py-2 text-xs text-muted-foreground">
              <p>
                {confirm.action === "seed"
                  ? `规模：${formatCount(tasks)} 条任务（子任务 / 提醒 / 评论 / 关联按比例派生）`
                  : "范围：uuid 以 dev-seed- 开头的全部示例行"}
              </p>
              <p>环境：开发构建（DEV）· 手工数据不在操作范围内</p>
            </div>
          }
        />
      )}
    </section>
  );
}
