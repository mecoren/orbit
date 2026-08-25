import { Button } from "@/components/ui/button";

/**
 * 路由级错误兜底（P0 代码分割配套）：动态 import 的 chunk 加载失败
 * （部分更新后产物缺失、WebView 缓存损坏等）或页面渲染异常时，
 * 展示可恢复面板而非白屏。桌面嵌在壳内（h-full），移动端整屏。
 */
export function RouteError({ fullScreen = false }: { fullScreen?: boolean }) {
  return (
    <div
      className={
        fullScreen
          ? "grid h-dvh place-items-center bg-[var(--m-bg)] p-6 text-center"
          : "grid h-full place-items-center p-6 text-center"
      }
    >
      <div className="space-y-3">
        <p className="text-sm text-muted-foreground">页面加载失败，可能是版本更新后的缓存残留。</p>
        <Button size="sm" variant="outline" onClick={() => location.reload()}>
          重新加载
        </Button>
      </div>
    </div>
  );
}
