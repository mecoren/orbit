//! 操作级内存探针（docs/13 §6.2 M6 / 总计划 T0.1）
//!
//! **不是产品代码**：只在本地由 `perf-metrics/operation-probe.mjs` 拉起，用于给
//! 「备份导出/导入、CSV 导入、附件写入」四类大对象操作建立可复现的峰值基线。
//! 每个场景跑在独立进程里，避免上一个场景的驻留污染下一个场景。
//!
//! 两个口径同时采：
//! - **堆增量**：自定义 `GlobalAlloc` 计数器精确记录「本阶段净分配峰值」，不受
//!   SQLite page cache / mmap 干扰；这是判断 M1/M2/M3 流式化是否生效的主指标。
//! - **RSS 增量**：10ms 采样当前进程 WorkingSet（Windows）/ VmRSS（Linux），
//!   反映包含数据库缓存、加密缓冲在内的整体占用；与 `memory3.mjs` 的真机口径
//!   不同（这里没有 WebView），不要互相替换数字。
//!
//! 用法（一般经 Node 入口调用，见 `perf-metrics/operation-probe.mjs`）：
//! ```text
//! cargo run --release -p orbit-core --example operation_probe -- \
//!   --scenario backup-export --workdir <dir> --out <result.json>
//! ```
//! 场景：`backup-export` / `backup-import` / `csv-import` / `attachment-write`。
//!
//! 数据规模由参数控制（默认 10k 任务 / 20k CSV 行 / 50MB 附件）：基线文件记录
//! 规模，跨版本对比时必须同规模，否则数字不可比。

use std::alloc::{GlobalAlloc, Layout, System};
use std::future::Future;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use orbit_core::api::{asset_api, csv_import_api, full_sync_backup_v2_api};
use orbit_core::db::pool::init_pool_unencrypted;
use serde_json::json;
use sqlx::SqlitePool;

// ============================================================================
// 全局分配计数（阶段峰值）
// ============================================================================

static ALLOC_CURRENT: AtomicUsize = AtomicUsize::new(0);
static ALLOC_PEAK: AtomicUsize = AtomicUsize::new(0);

struct TrackingAlloc;

fn alloc_add(n: usize) {
    let cur = ALLOC_CURRENT.fetch_add(n, Ordering::Relaxed) + n;
    ALLOC_PEAK.fetch_max(cur, Ordering::Relaxed);
}

unsafe impl GlobalAlloc for TrackingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            alloc_add(layout.size());
        }
        ptr
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc_zeroed(layout) };
        if !ptr.is_null() {
            alloc_add(layout.size());
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) };
        ALLOC_CURRENT.fetch_sub(layout.size(), Ordering::Relaxed);
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let new_ptr = unsafe { System.realloc(ptr, layout, new_size) };
        if !new_ptr.is_null() {
            // 保守口径：先减旧块再加新块；全程只用于「峰值增量」判断
            ALLOC_CURRENT.fetch_sub(layout.size(), Ordering::Relaxed);
            alloc_add(new_size);
        }
        new_ptr
    }
}

#[global_allocator]
static GLOBAL: TrackingAlloc = TrackingAlloc;

fn alloc_current() -> usize {
    ALLOC_CURRENT.load(Ordering::Relaxed)
}

// ============================================================================
// 进程 RSS（10ms 采样）
// ============================================================================

#[cfg(windows)]
mod rss {
    #[repr(C)]
    #[allow(non_snake_case)]
    struct ProcessMemoryCounters {
        cb: u32,
        PageFaultCount: u32,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
    }

    // 只调用两个 Win32 基本 API，故不为探针单独引 windows-sys；cb 必须显式赋值
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCurrentProcess() -> isize;
        fn K32GetProcessMemoryInfo(
            process: isize,
            counters: *mut ProcessMemoryCounters,
            cb: u32,
        ) -> i32;
    }

    pub fn read() -> Option<u64> {
        let mut counters = ProcessMemoryCounters {
            cb: 0,
            PageFaultCount: 0,
            PeakWorkingSetSize: 0,
            WorkingSetSize: 0,
            QuotaPeakPagedPoolUsage: 0,
            QuotaPagedPoolUsage: 0,
            QuotaPeakNonPagedPoolUsage: 0,
            QuotaNonPagedPoolUsage: 0,
            PagefileUsage: 0,
            PeakPagefileUsage: 0,
        };
        counters.cb = std::mem::size_of::<ProcessMemoryCounters>() as u32;
        let ok =
            unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, counters.cb) };
        (ok != 0).then_some(counters.WorkingSetSize as u64)
    }
}

#[cfg(target_os = "linux")]
mod rss {
    /// `/proc/self/statm` 第二列是常驻页数；Linux 常规页 4KiB（探针只做基线对比）
    pub fn read() -> Option<u64> {
        let text = std::fs::read_to_string("/proc/self/statm").ok()?;
        let pages: u64 = text.split_whitespace().nth(1)?.parse().ok()?;
        Some(pages * 4096)
    }
}

#[cfg(all(not(windows), not(target_os = "linux")))]
mod rss {
    /// macOS 未做平台适配：RSS 指标返回 null，堆增量仍可用
    pub fn read() -> Option<u64> {
        None
    }
}

struct RssSampler {
    stop: Arc<AtomicBool>,
    peak: Arc<AtomicU64>,
    handle: Option<std::thread::JoinHandle<()>>,
    baseline: Option<u64>,
}

impl RssSampler {
    fn start() -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let peak = Arc::new(AtomicU64::new(0));
        let baseline = rss::read();
        if let Some(v) = baseline {
            peak.store(v, Ordering::Relaxed);
        }
        let stop2 = Arc::clone(&stop);
        let peak2 = Arc::clone(&peak);
        let handle = std::thread::spawn(move || {
            while !stop2.load(Ordering::Relaxed) {
                if let Some(v) = rss::read() {
                    peak2.fetch_max(v, Ordering::Relaxed);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        Self {
            stop,
            peak,
            handle: Some(handle),
            baseline,
        }
    }

    fn stop(mut self) -> (Option<u64>, Option<u64>) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
        let peak = self.peak.load(Ordering::Relaxed);
        let peak = (peak > 0).then_some(peak);
        (self.baseline, peak)
    }
}

// ============================================================================
// 阶段测量
// ============================================================================

struct StageMetrics {
    alloc_baseline: usize,
    alloc_peak: usize,
    alloc_end: usize,
    rss_baseline: Option<u64>,
    rss_peak: Option<u64>,
    rss_end: Option<u64>,
    duration_ms: u64,
}

async fn measure<T, F>(future: F) -> (T, StageMetrics)
where
    F: Future<Output = T>,
{
    let sampler = RssSampler::start();
    let alloc_baseline = alloc_current();
    ALLOC_PEAK.store(alloc_baseline, Ordering::Relaxed);
    let started = Instant::now();
    let out = future.await;
    let duration_ms = started.elapsed().as_millis() as u64;
    let alloc_peak = ALLOC_PEAK.load(Ordering::Relaxed).max(alloc_baseline);
    let alloc_end = alloc_current();
    let rss_end = rss::read();
    let (rss_baseline, rss_peak) = sampler.stop();
    (
        out,
        StageMetrics {
            alloc_baseline,
            alloc_peak,
            alloc_end,
            rss_baseline,
            rss_peak,
            rss_end,
            duration_ms,
        },
    )
}

// ============================================================================
// 参数与种子数据
// ============================================================================

struct Args {
    scenario: String,
    workdir: PathBuf,
    out: PathBuf,
    rows: usize,
    csv_rows: usize,
    attachment_mb: u64,
    backup: Option<PathBuf>,
}

fn parse_args() -> Result<Args, String> {
    let mut map = std::collections::HashMap::new();
    let mut iter = std::env::args().skip(1);
    while let Some(key) = iter.next() {
        if !key.starts_with("--") {
            return Err(format!("无法识别的参数：{key}"));
        }
        let value = iter.next().ok_or_else(|| format!("{key} 缺少取值"))?;
        map.insert(key.trim_start_matches("--").to_string(), value);
    }
    let get = |k: &str, default: &str| map.get(k).cloned().unwrap_or_else(|| default.into());
    Ok(Args {
        scenario: get("scenario", ""),
        workdir: PathBuf::from(get("workdir", ".")),
        out: PathBuf::from(get("out", "probe-result.json")),
        rows: get("rows", "10000")
            .parse()
            .map_err(|_| "--rows 需为整数".to_string())?,
        csv_rows: get("csv-rows", "20000")
            .parse()
            .map_err(|_| "--csv-rows 需为整数".to_string())?,
        attachment_mb: get("attachment-mb", "50")
            .parse()
            .map_err(|_| "--attachment-mb 需为整数".to_string())?,
        backup: map.get("backup").map(PathBuf::from),
    })
}

/// 直接 SQL 批量种子：与 0001 基线同构，绕开 API 的活动日志/事件开销，
/// 保证「操作阶段」的量主要来自被测量操作而不是造数。
async fn seed_tasks(pool: &SqlitePool, n: usize) -> Result<(), String> {
    let now = chrono::Utc::now().timestamp_millis();
    let mut tx = pool.begin().await.map_err(|e| e.to_string())?;
    for i in 0..n {
        sqlx::query(
            "INSERT INTO todo_tasks
               (uuid, title, description, priority, status, position, created_at, updated_at, version)
             VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, 1)",
        )
        .bind(format!("probe-{i:08}"))
        .bind(format!("操作探针任务 {i:06}"))
        .bind(if i % 4 == 0 {
            Some(format!("描述正文 {i}：用于让备份/导出通道产生真实 JSON 体积"))
        } else {
            None
        })
        .bind((i % 6) as i64)
        .bind(i as f64)
        .bind(now)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
    }
    tx.commit().await.map_err(|e| e.to_string())
}

fn mb(bytes: usize) -> f64 {
    round1(bytes as f64 / 1048576.0)
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

fn opt_mb(bytes: Option<u64>) -> Option<f64> {
    bytes.map(|b| mb(b as usize))
}

fn opt_delta_mb(end: Option<u64>, baseline: Option<u64>) -> Option<f64> {
    match (end, baseline) {
        (Some(e), Some(b)) => Some(mb(e.saturating_sub(b) as usize)),
        _ => None,
    }
}

fn metrics_json(m: &StageMetrics) -> serde_json::Value {
    json!({
        "allocBaselineMB": mb(m.alloc_baseline),
        "allocPeakMB": mb(m.alloc_peak),
        "allocEndMB": mb(m.alloc_end),
        "allocPeakDeltaMB": mb(m.alloc_peak.saturating_sub(m.alloc_baseline)),
        "allocEndDeltaMB": mb(m.alloc_end.saturating_sub(m.alloc_baseline)),
        "rssBaselineMB": opt_mb(m.rss_baseline),
        "rssPeakMB": opt_mb(m.rss_peak),
        "rssEndMB": opt_mb(m.rss_end),
        "rssPeakDeltaMB": opt_delta_mb(m.rss_peak, m.rss_baseline),
        "rssEndDeltaMB": opt_delta_mb(m.rss_end, m.rss_baseline),
        "durationMs": m.duration_ms,
    })
}

// ============================================================================
// 场景
// ============================================================================

const SYNC_PASSWORD: &str = "operation-probe-pass";

async fn scenario_backup_export(args: &Args) -> Result<serde_json::Value, String> {
    let db = args.workdir.join("export.db");
    let pool = init_pool_unencrypted(&db)
        .await
        .map_err(|e| e.to_string())?;
    seed_tasks(&pool, args.rows).await?;
    let target = args.workdir.join("probe.orfullsync");
    let (result, metrics) = measure(async {
        full_sync_backup_v2_api::export_v2_to_file(
            &pool,
            &target,
            SYNC_PASSWORD,
            "operation-probe-device",
            Some("operation-probe".into()),
        )
        .await
    })
    .await;
    let (bytes, counts) = result.map_err(|e| format!("备份导出失败：{e}"))?;
    let mut out = metrics_json(&metrics);
    let obj = out.as_object_mut().expect("json object");
    obj.insert("artifactBytes".into(), json!(bytes));
    obj.insert("artifactMB".into(), json!(mb(bytes as usize)));
    obj.insert("tableRows".into(), json!(counts.values().sum::<usize>()));
    obj.insert("tables".into(), json!(counts.len()));
    Ok(out)
}

async fn scenario_backup_import(args: &Args) -> Result<serde_json::Value, String> {
    let backup = args
        .backup
        .clone()
        .ok_or_else(|| "backup-import 需要 --backup <v2 备份路径>".to_string())?;
    let size = std::fs::metadata(&backup)
        .map_err(|e| format!("读取备份文件失败：{e}"))?
        .len();
    let db = args.workdir.join("import.db");
    let pool = init_pool_unencrypted(&db)
        .await
        .map_err(|e| e.to_string())?;
    let (result, metrics) = measure(async {
        full_sync_backup_v2_api::import_v2_from_path(&pool, &backup, SYNC_PASSWORD, false).await
    })
    .await;
    let imported = result.map_err(|e| format!("备份导入失败：{e}"))?;
    let mut out = metrics_json(&metrics);
    let obj = out.as_object_mut().expect("json object");
    obj.insert("artifactBytes".into(), json!(size));
    obj.insert("artifactMB".into(), json!(mb(size as usize)));
    obj.insert("tableRows".into(), json!(imported.success_count));
    Ok(out)
}

async fn scenario_csv_import(args: &Args) -> Result<serde_json::Value, String> {
    let csv_path = args.workdir.join("probe.csv");
    let size = std::fs::metadata(&csv_path)
        .map_err(|e| format!("读取 CSV 文件失败：{e}"))?
        .len();
    let db = args.workdir.join("csv.db");
    let pool = init_pool_unencrypted(&db)
        .await
        .map_err(|e| e.to_string())?;
    let (result, metrics) = measure(async {
        // 读文件是 UI 路径的一部分（选完文件→core 解析），计入操作峰值
        let content = std::fs::read_to_string(&csv_path).map_err(|e| e.to_string())?;
        csv_import_api::execute_csv_import(&pool, &content, "todoist")
            .await
            .map_err(|e| e.to_string())
    })
    .await;
    let stats = result?;
    let mut out = metrics_json(&metrics);
    let obj = out.as_object_mut().expect("json object");
    obj.insert("artifactBytes".into(), json!(size));
    obj.insert("artifactMB".into(), json!(mb(size as usize)));
    obj.insert("importedRows".into(), json!(stats.success));
    obj.insert("skippedRows".into(), json!(stats.skipped));
    obj.insert("failedRows".into(), json!(stats.failed));
    Ok(out)
}

async fn scenario_attachment_write(args: &Args) -> Result<serde_json::Value, String> {
    let file = args.workdir.join("probe-attachment.bin");
    let size = std::fs::metadata(&file)
        .map_err(|e| format!("读取附件样本失败：{e}"))?
        .len();
    let db = args.workdir.join("attachment.db");
    let pool = init_pool_unencrypted(&db)
        .await
        .map_err(|e| e.to_string())?;
    sqlx::query(
        "INSERT INTO todo_tasks (uuid, title, version) VALUES ('probe-attach', '附件探针任务', 1)",
    )
    .execute(&pool)
    .await
    .map_err(|e| e.to_string())?;
    let task_id: i64 = sqlx::query_scalar("SELECT id FROM todo_tasks WHERE uuid = 'probe-attach'")
        .fetch_one(&pool)
        .await
        .map_err(|e| e.to_string())?;
    let attachments_dir = args.workdir.join("attachments");
    std::fs::create_dir_all(&attachments_dir).map_err(|e| e.to_string())?;
    let dir_str = attachments_dir.to_string_lossy().to_string();
    let (result, metrics) = measure(async {
        // 当前实现入参是 &[u8]：读整文件的这 50MB 正是 M3 要去掉的那一份
        let data = std::fs::read(&file).map_err(|e| e.to_string())?;
        asset_api::add_task_attachment(
            &pool,
            &dir_str,
            task_id,
            "probe-attachment.bin",
            "application/octet-stream",
            &data,
        )
        .await
        .map_err(|e| e.to_string())
    })
    .await;
    let view = result?;
    let mut out = metrics_json(&metrics);
    let obj = out.as_object_mut().expect("json object");
    obj.insert("artifactBytes".into(), json!(size));
    obj.insert("artifactMB".into(), json!(mb(size as usize)));
    obj.insert("attachmentHash".into(), json!(view.hash));
    obj.insert("attachmentSize".into(), json!(view.size_bytes));
    Ok(out)
}

async fn run(args: &Args) -> Result<serde_json::Value, String> {
    std::fs::create_dir_all(&args.workdir).map_err(|e| e.to_string())?;
    match args.scenario.as_str() {
        "backup-export" => scenario_backup_export(args).await,
        "backup-import" => scenario_backup_import(args).await,
        "csv-import" => scenario_csv_import(args).await,
        "attachment-write" => scenario_attachment_write(args).await,
        other => Err(format!(
            "未知场景 '{other}'，可选 backup-export / backup-import / csv-import / attachment-write"
        )),
    }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("PROBE_ARGS_ERROR: {e}");
            std::process::exit(2);
        }
    };
    let started = Instant::now();
    let scenario = args.scenario.clone();
    let result = run(&args).await;
    let payload = match result {
        Ok(metrics) => json!({
            "scenario": scenario,
            "ok": true,
            "rows": args.rows,
            "csvRows": args.csv_rows,
            "attachmentMB": args.attachment_mb,
            "wallMs": started.elapsed().as_millis() as u64,
            "metrics": metrics,
        }),
        Err(error) => json!({
            "scenario": scenario,
            "ok": false,
            "error": error,
            "rows": args.rows,
            "csvRows": args.csv_rows,
            "attachmentMB": args.attachment_mb,
            "wallMs": started.elapsed().as_millis() as u64,
        }),
    };
    let text = serde_json::to_string_pretty(&payload).expect("序列化探针结果");
    if let Some(parent) = args.out.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(e) = std::fs::write(&args.out, text + "\n") {
        eprintln!("PROBE_OUT_ERROR: 写入 {} 失败：{e}", args.out.display());
        std::process::exit(2);
    }
    if payload["ok"] != true {
        eprintln!(
            "PROBE_FAIL: {}",
            payload["error"].as_str().unwrap_or("未知错误")
        );
        std::process::exit(1);
    }
}
