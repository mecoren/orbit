/**
 * 手动滚轮滚动——让内联下拉列表在 Radix Dialog/Sheet 里也能滚轮滚动。
 *
 * 病根：modal 型 Dialog/Sheet 的 react-remove-scroll 在 document 级捕获
 * wheel 并 stopPropagation，导致挂在列表元素上的捕获监听收不到事件，
 * 而原生滚动又被 preventDefault——轮子表现为完全失灵（实测抽屉日期弹层
 * 里的年份/时间下拉 scrollTop 纹丝不动）。
 *
 * 对策：挂在 window 捕获阶段（先于 document 触发），事件目标落在列表内
 * 才接管：手动改 scrollTop（编程式滚动不受 preventDefault 影响）并吞掉
 * 事件，避免与 RemoveScroll 行为叠加。目标在列表外时直接放行，不干扰
 * 页面其他滚动。
 */

/** 把 el 变成手动滚轮滚动容器，返回解绑函数（调用方在下拉 open 时挂载）。 */
export function attachManualWheelScroll(el: HTMLElement): () => void {
  const onWheel = (e: WheelEvent) => {
    if (!el.contains(e.target as Node)) return;
    e.preventDefault();
    e.stopPropagation();
    // Firefox 行模式增量按 16px/行折算，其余按像素
    const dy = e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY;
    el.scrollTop += dy;
  };
  window.addEventListener("wheel", onWheel, { capture: true, passive: false });
  return () => window.removeEventListener("wheel", onWheel, { capture: true });
}
