/**
 * 错误边界（D14，两层）。
 *
 * 例外说明：React 19 没有错误边界 hook，边界**必须**是 class 组件——
 * 后来者不要按「函数组件 + hooks」惯例重构掉它。
 *
 * - 内层（AppShell 包 <Outlet/>）：页面崩溃时 TitleBar / Toaster /
 *   壳层 Tauri 监听存活。「白屏但进程常驻」正是 ADR 0006 里 WebView
 *   驻留税的最坏形态（隐藏窗口 + 崩溃页 = 不干活还占常驻内存的壳），
 *   故内层给「重试 + 回到今天」的软恢复，不直接白屏。
 * - 外层（App 包 ReadyShell）：只给重载级恢复 + 托盘退出提示。
 * - 不接外部上报（PRIVACY 无遥测是硬边界）：只 console.error 留本地痕。
 */
import { Component, type ReactNode } from "react";

/** 崩溃后回退路径：去掉 query/hash（测试探针 `?crash=` 不得带进重试路径） */
export function recoverFromCrash(raw: string): string {
  const path = raw.split("?")[0].split("#")[0];
  return path.startsWith("/") && path.length > 1 ? path : "/";
}

interface ErrorBoundaryProps {
  children: ReactNode;
  /** 崩溃页渲染；retry 重置边界状态（同路径重试） */
  fallback: (error: Error, retry: () => void) => ReactNode;
}

interface ErrorBoundaryState {
  error: Error | null;
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { error: null };

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { error };
  }

  componentDidCatch(error: Error): void {
    // 本地诊断痕（不外发）：崩溃堆栈进控制台，生产包同理
    console.error("[error-boundary] 页面崩溃已隔离:", error);
  }

  private retry = (): void => {
    this.setState({ error: null });
  };

  render(): ReactNode {
    if (this.state.error != null) {
      return this.props.fallback(this.state.error, this.retry);
    }
    return this.props.children;
  }
}
