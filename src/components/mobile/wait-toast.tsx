import { toast } from "sonner";

/**
 * 移动端 WaitToast 皮肤（规格：05 §五 WaitToast；variant default/destructive）。
 * sonner 包装：调用方经 className 注入皮肤类（index.css `.wait-toast-*`），
 * 不动 Toaster 全局 toastOptions；destructive 用 error 色调 + 逾期红文字。
 */
export const waitToast = {
  /** 普通提示（default） */
  message: (msg: string) => toast(msg, { className: "wait-toast" }),
  /** 危险提示（destructive）：title 红字，可选 description 副文案 */
  destructive: (title: string, description?: string) =>
    toast.error(title, { description, className: "wait-toast-destructive" }),
};
