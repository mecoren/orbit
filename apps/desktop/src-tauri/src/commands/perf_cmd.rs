//! perf_cmd — 冷启动首屏标记命令（性能度量专用，docs/09 §六）
//!
//! 口径：`perf-metrics/cold-start.mjs` 以环境变量 `ORBIT_PERF_MARKER=<路径>`
//! 启动 release exe；前端首屏就绪（boot 门控落到解锁页/主界面并完成首帧
//! 绘制）时调用本命令，把当前 epoch 毫秒写入该文件——脚本按「spawn 前 t0 →
//! 文件内时刻」计算真首屏耗时，取代旧口径「首窗句柄轮询 + 400ms 拍定常数」。
//!
//! 边界：未设置环境变量时纯 no-op（生产零副作用）；每进程只写第一笔
//! （解锁页→主界面的二次上报不改写首次时刻）；`create_new` 只创建不覆盖，
//! 不会动任何既有文件（脚本每轮先删标记文件）。

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};

/// 进程级一次性闸：首屏只记第一笔
static MARKED: AtomicBool = AtomicBool::new(false);

/// 记录「首屏就绪」时刻到 `ORBIT_PERF_MARKER` 指定文件（未设置则跳过）
#[tauri::command]
pub fn perf_first_screen_mark() -> Result<(), String> {
    let Ok(path) = std::env::var("ORBIT_PERF_MARKER") else {
        return Ok(());
    };
    if MARKED.swap(true, Ordering::SeqCst) {
        return Ok(());
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis();
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(mut f) => f
            .write_all(now_ms.to_string().as_bytes())
            .map_err(|e| e.to_string()),
        // 文件已存在 / 目录不可写：静默（脚本以超时+提示诊断）
        Err(_) => Ok(()),
    }
}
