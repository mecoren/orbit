//! startup_cmd — 启动形态探针（开机自启拉起时是否静默驻留）
//!
//! 口径：`--hidden` 由 tauri-plugin-autostart 注册项注入（lib.rs 插件
//! `args(["--hidden"])`，落点为三平台注册项的命令行 / plist
//! `ProgramArguments` / .desktop `Exec`）。自启拉起的语义是**静默驻留**：
//! 不显示主窗（前端 main.tsx 经本模块命令判定后跳过 show），并在壳层接上
//! 隐藏回收链（webview_low_power 降档 + window_recycler 超时销毁，常驻
//! 内存从 ~330MB 落到宿主档 ~40MB），托盘/热键随时唤起重建。
//!
//! setup 阶段解析一次落进程级原子量，命令与壳内分支共用同一结论——
//! 各处各自扫 argv 迟早口径漂移（漂移的可见症状就是启动闪窗）。

use std::sync::atomic::{AtomicBool, Ordering};

/// 自启注册项注入的隐藏启动标记（与 lib.rs 插件 args 单一同源）
pub const HIDDEN_FLAG: &str = "--hidden";

/// 本次进程是否由自启拉起（setup 阶段 `resolve_launch_mode` 落定）
static LAUNCHED_HIDDEN: AtomicBool = AtomicBool::new(false);

/// 纯函数：命令行参数是否含隐藏启动标记
///
/// 精确匹配——`--hidden-extra` / `--hidden=1` 都算「不是」。
pub fn launched_hidden(args: &[String]) -> bool {
    args.iter().any(|a| a == HIDDEN_FLAG)
}

/// setup 阶段解析本次命令行并落定启动形态，返回是否隐藏启动
pub fn resolve_launch_mode() -> bool {
    let hidden = launched_hidden(&std::env::args().collect::<Vec<_>>());
    LAUNCHED_HIDDEN.store(hidden, Ordering::SeqCst);
    hidden
}

/// 本次进程是否为自启拉起的隐藏形态
pub fn is_launched_hidden() -> bool {
    LAUNCHED_HIDDEN.load(Ordering::SeqCst)
}

/// 启动形态探针：前端据此决定是否跳过主窗 show（纯浏览器 mock 恒 false）
#[tauri::command]
pub fn startup_launched_hidden() -> bool {
    is_launched_hidden()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(raw: &[&str]) -> Vec<String> {
        raw.iter().map(|s| s.to_string()).collect()
    }

    /// 精确匹配：命中 `--hidden`，前缀/等号/无标记变体均不误判
    #[test]
    fn hidden_flag_exact_match() {
        assert!(launched_hidden(&args(&["orbit.exe", "--hidden"])));
        assert!(launched_hidden(&args(&["--hidden", "--other"])));
        assert!(!launched_hidden(&args(&["orbit.exe"])));
        assert!(!launched_hidden(&args(&["orbit.exe", "--hidden=1"])));
        assert!(!launched_hidden(&args(&["orbit.exe", "--hiddenish"])));
        assert!(!launched_hidden(&args(&[])));
    }

    /// 标记常量与插件注册项契约绑定：改字面量必须同时改 lib.rs 的 args
    #[test]
    fn hidden_flag_contract() {
        assert_eq!(HIDDEN_FLAG, "--hidden");
    }
}
