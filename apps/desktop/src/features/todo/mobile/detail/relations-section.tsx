/**
 * RelationsSection —— 详情关联任务区（05 §4.3 后半；M4 Task 14）
 *
 * 只读胶囊：padding h8/v2（px-2/py-0.5）、bg accent@10%（color-mix）、radius 8、
 * 字 12 accent，文案规格原文"任务 #id"（id 取对方任务 other_task_id）；行距 bottom4。
 * relations 为空不渲染整个区块。
 */
import type { TodoTaskRelation } from "@/lib/tauri";
import { TODO_ACCENT } from "../../shared/constants";
import { SectionCard } from "../section-card";

export function RelationsSection({ relations }: { relations: TodoTaskRelation[] }) {
  if (relations.length === 0) return null;

  return (
    <SectionCard title="关联任务">
      <div className="space-y-1">
        {relations.map((r) => (
          <div key={r.id}>
            <span
              className="inline-block rounded-lg px-2 py-0.5 text-xs"
              style={{
                background: `color-mix(in srgb, ${TODO_ACCENT} 10%, transparent)`,
                color: TODO_ACCENT,
              }}
            >
              任务 #{r.other_task_id}
            </span>
          </div>
        ))}
      </div>
    </SectionCard>
  );
}
