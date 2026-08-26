// apps/desktop/src/features/todo/shared/position.ts
/** position 取中值公式（03 文档 §一）：prev 缺省视为 0，next 缺省视为 100000。
 *  看板拖拽（kanban-view.tsx）与列表拖拽（task-list-view.tsx）共用。 */
export function midpoint(prev?: number, next?: number): number {
  return ((prev ?? 0) + (next ?? 100000)) / 2;
}
