/**
 * 快捷键分区（discoverability（全仓审计高价值缺口）：设置页常驻入口）
 *
 * 数据源同 ? 帮助面板——features/todo/shared/shortcut-help.ts 常量表
 * （单一口径源，改键位只改一处）。静态只读分区，无状态无 IO。
 */
import { SHORTCUT_GROUPS } from "@/features/todo/shared/shortcut-help";

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

export function ShortcutsSection() {
  return (
    <div className="flex flex-col gap-6">
      <SectionHeader
        title="键盘快捷键"
        desc="全局命令与列表导航键位一览；任意页面按 ? 可随时呼出速查面板。"
      />
      {SHORTCUT_GROUPS.map((group) => (
        <section key={group.title}>
          <h3 className="mb-2 text-xs font-medium text-muted-foreground">
            {group.title}
          </h3>
          <div className="rounded-lg border border-border/60">
            {group.entries.map((entry, i) => (
              <div
                key={entry.keys}
                className={
                  "flex items-center justify-between gap-4 px-4 py-2.5" +
                  (i > 0 ? " border-t border-border/40" : "")
                }
              >
                <span className="text-sm text-foreground/80">{entry.action}</span>
                <kbd className="inline-flex h-6 min-w-6 items-center justify-center rounded-md border border-border/60 bg-muted px-1.5 font-mono text-xs font-medium text-muted-foreground">
                  {entry.keys}
                </kbd>
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
