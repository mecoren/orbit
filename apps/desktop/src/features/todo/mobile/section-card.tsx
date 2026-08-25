/**
 * SectionCard —— 详情屏区块容器（05 §4.3）
 *
 * elevation 0（平面卡无阴影）、radius 12、边框 outlineVariant@30%
 * （light rgba(0,0,0,.08) / dark rgba(255,255,255,.08)，以黑白 alpha 等价直写）、
 * 内边距 16；头部 Row[标题 12/w600 accent #3B82F6 + 可选副标题 bodySmall/sub
 * + Spacer + trailing]。区块间距 12 由父级 space-y-3 承担，本组件不管。
 */
import type { ReactNode } from "react";
import { TODO_ACCENT } from "../shared/constants";

interface SectionCardProps {
  /** 头部标题；缺省不渲染头行（详情标题区为无头卡片） */
  title?: string;
  /** 副标题（bodySmall/sub），如 Task 14 子任务区的 doneCount/total */
  subtitle?: string;
  trailing?: ReactNode;
  children: ReactNode;
}

export function SectionCard({ title, subtitle, trailing, children }: SectionCardProps) {
  return (
    <section className="rounded-xl border border-black/[.08] p-4 dark:border-white/[.08]">
      {(title || subtitle || trailing) && (
        <div className="mb-2 flex items-center">
          {title && (
            <span className="text-xs font-semibold" style={{ color: TODO_ACCENT }}>
              {title}
            </span>
          )}
          {subtitle && (
            <span className={`${title ? "ml-2" : ""} text-xs text-[var(--m-sub)]`}>{subtitle}</span>
          )}
          {/* Spacer */}
          <div className="flex-1" />
          {trailing}
        </div>
      )}
      {children}
    </section>
  );
}
