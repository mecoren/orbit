/** M4 临时占位三屏（侧栏首屏/任务子列表/详情全屏），后续任务逐屏替换 */
export function PlaceholderScreen({ name }: { name: string }) {
  return (
    <div className="flex min-h-screen items-center justify-center bg-[var(--m-bg)] text-[var(--m-text)]">
      <p className="text-base">{name}（M4 施工中）</p>
    </div>
  );
}
