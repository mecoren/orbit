/**
 * Toaster — sonner 包装（shadcn 配方，去 next-themes 依赖）
 *
 * 经 --normal-* 变量把 toast 接到应用设计令牌（popover/border），
 * 深浅色随 html.dark 类自动切换（变量定义在 :root/.dark 上，可级联进 portal）；
 * 类型区分靠 sonner 自带彩色图标（success 绿 ✓ / warning 橙 ⚠ / error 红 / info 蓝），
 * 不开 richColors 的整块染色底。
 */
import { Toaster as Sonner, type ToasterProps } from "sonner";

const Toaster = ({ ...props }: ToasterProps) => {
  return (
    <Sonner
      className="toaster group"
      style={
        {
          "--normal-bg": "var(--popover)",
          "--normal-text": "var(--popover-foreground)",
          "--normal-border": "var(--border)",
        } as React.CSSProperties
      }
      toastOptions={{
        classNames: {
          description: "group-[.toast]:text-muted-foreground",
          actionButton:
            "group-[.toast]:bg-primary group-[.toast]:text-primary-foreground",
          cancelButton:
            "group-[.toast]:bg-muted group-[.toast]:text-muted-foreground",
        },
      }}
      {...props}
    />
  );
};

export { Toaster };
