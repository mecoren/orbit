import type { ReactNode } from "react";

interface WaitAlertDialogProps {
  open: boolean;
  title: string;
  message: string;
  onClose: () => void;
  /** 自定义按钮插槽；缺省按 destructiveLabel 有无渲染默认形态 */
  actions?: ReactNode;
  /** 双钮模式确认钮文案（红字）；有则渲染「取消 + 红字确认」 */
  destructiveLabel?: string;
  onConfirm?: () => void;
}

/**
 * 移动端 WaitAlertDialog（规格：05 §五 WaitAlertDialog；variant default/destructive）。
 * 复刻蓝本对话框：fixed 遮罩点击关闭，max-w-xs 圆角 20 surface 底卡片；
 * 三种按钮形态——default 单钮「我知道了」accent 蓝字 / destructive 双钮红字 #F44336
 * 确认（05 §四删除保护文案流使用）/ 自定义 actions 插槽优先。
 */
export function WaitAlertDialog({ open, title, message, onClose, actions, destructiveLabel, onConfirm }: WaitAlertDialogProps) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-[60] grid place-items-center bg-black/40 p-6" onClick={onClose}>
      <div
        className="w-full max-w-xs rounded-[20px] p-6"
        style={{ background: "var(--m-surface)" }}
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className="text-base font-semibold text-[var(--m-text)]">{title}</h3>
        <p className="mt-2 text-sm text-[var(--m-sub)]">{message}</p>
        <div className="mt-5 flex justify-end gap-2">
          {actions ?? (destructiveLabel ? (
            <>
              <button className="rounded-lg px-4 py-2 text-sm text-[var(--m-sub)]" onClick={onClose}>
                取消
              </button>
              <button
                className="rounded-lg px-4 py-2 text-sm font-medium text-[#F44336]"
                onClick={() => {
                  onConfirm?.();
                  onClose();
                }}
              >
                {destructiveLabel}
              </button>
            </>
          ) : (
            <button className="rounded-lg px-4 py-2 text-sm font-medium text-[#3B82F6]" onClick={onClose}>
              我知道了
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
