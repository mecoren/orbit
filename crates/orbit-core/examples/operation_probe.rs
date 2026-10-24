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
//! 场景：`backup-export` / `backup-import` / `csv-import` / `attachment-write` /
//! `attachment-read` / `attachment-sync-push` / `attachment-sync-pull` /
//! `backup-export-large` / `initial-sync` / `global-search`。
//!
//! `global-search`（docs/13 §七 P3 测量前置）：对 10k 任务库跑三口径搜索——
//! 中文 FTS 短语（主路径）/ 中文两字 LIKE（兜底全表扫）/ 拼音首字母（含
//! 首次 reconcile 全量回填），各采样多次报 p50/p95 毫秒；量的是「搜索延迟
//! 尺子」，不是内存场景（内存四指标照常输出但阈值不设）。
//!
//! 数据规模由参数控制（默认 10k 任务 / 20k CSV 行 / 50MB 附件；大库场景由
//! `--rows` + `--description-kb` 放大）：基线文件记录规模，跨版本对比时必须
//! 同规模，否则数字不可比。
//!
//! `initial-sync` 用丢弃型适配器（上传字节丢弃、云端为空）量「首同步」的
//! 装载 + 加密 + 上传峰值，不引入网络与磁盘写入噪声；云端对象总量由
//! `uploadedMB` 单独报出。

use std::alloc::{GlobalAlloc, Layout, System};
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use orbit_core::api::{asset_api, csv_import_api, full_sync_backup_v2_api};
use orbit_core::cloud_sync::asset_container;
use orbit_core::cloud_sync::attachments::{
    AttachmentSyncResult, sync_attachments_pull, sync_attachments_push,
};
use orbit_core::cloud_sync::progress::{NoopProgressSender, SyncOrigin};
use orbit_core::cloud_sync::push::push_all;
use orbit_core::cloud_sync::state::SyncStateStore;
use orbit_core::db::pool::init_pool_unencrypted;
use orbit_core::db::repository::attachment_repo;
use orbit_core::models::business::Attachment;
use orbit_core::sync::error::SyncError;
use orbit_core::sync_adapters::traits::{RemoteFile, SyncAdapter};
use orbit_core::sync_crypto::SyncCryptoService;
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
    description_kb: usize,
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
        description_kb: get("description-kb", "0")
            .parse()
            .map_err(|_| "--description-kb 需为整数".to_string())?,
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
async fn seed_tasks(pool: &SqlitePool, n: usize, description_kb: usize) -> Result<(), String> {
    let now = chrono::Utc::now().timestamp_millis();
    // 大库场景用重复正文放大 JSON 体积：内容无意义，只保证确定性
    let big_desc = (description_kb > 0)
        .then(|| Some("x".repeat(description_kb * 1024)))
        .flatten();
    let mut tx = pool.begin().await.map_err(|e| e.to_string())?;
    for i in 0..n {
        let description = if let Some(ref big) = big_desc {
            Some(big.clone())
        } else if i % 4 == 0 {
            Some(format!(
                "描述正文 {i}：用于让备份/导出通道产生真实 JSON 体积"
            ))
        } else {
            None
        };
        sqlx::query(
            "INSERT INTO todo_tasks
               (uuid, title, description, priority, status, position, created_at, updated_at, version)
             VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, 1)",
        )
        .bind(format!("probe-{i:08}"))
        .bind(format!("操作探针任务 {i:06}"))
        .bind(description)
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
    seed_tasks(&pool, args.rows, args.description_kb).await?;
    let db_bytes = std::fs::metadata(&db)
        .map_err(|e| format!("读取探针库大小失败：{e}"))?
        .len();
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
    obj.insert("dbBytes".into(), json!(db_bytes));
    obj.insert("dbMB".into(), json!(mb(db_bytes as usize)));
    obj.insert("rows".into(), json!(args.rows));
    obj.insert("descriptionKb".into(), json!(args.description_kb));
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

/// 建库 + 一个任务，返回 (pool, task_id)
async fn attachment_db(args: &Args, name: &str) -> Result<(SqlitePool, i64), String> {
    let db = args.workdir.join(name);
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
    Ok((pool, task_id))
}

/// 流式计算文件 sha256（与 asset_api 生产口径一致；探针内不做整文件读）
fn file_sha256(path: &std::path::Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;

    let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = file.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect())
}

async fn scenario_attachment_write(args: &Args) -> Result<serde_json::Value, String> {
    let file = args.workdir.join("probe-attachment.bin");
    let size = std::fs::metadata(&file)
        .map_err(|e| format!("读取附件样本失败：{e}"))?
        .len();
    let (pool, task_id) = attachment_db(args, "attachment.db").await?;
    let attachments_dir = args.workdir.join("attachments");
    std::fs::create_dir_all(&attachments_dir).map_err(|e| e.to_string())?;
    let dir_str = attachments_dir.to_string_lossy().to_string();
    let (result, metrics) = measure(async {
        // M3/T1.1：路径入参——core 按 256KiB 块读盘 + 算 hash，峰值与文件大小无关
        asset_api::add_task_attachment_from_path(
            &pool,
            &dir_str,
            task_id,
            "probe-attachment.bin",
            "application/octet-stream",
            &file,
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

async fn scenario_attachment_read(args: &Args) -> Result<serde_json::Value, String> {
    let file = args.workdir.join("probe-attachment.bin");
    let size = std::fs::metadata(&file)
        .map_err(|e| format!("读取附件样本失败：{e}"))?
        .len();
    let (pool, task_id) = attachment_db(args, "attachment-read.db").await?;
    let attachments_dir = args.workdir.join("attachments");
    std::fs::create_dir_all(&attachments_dir).map_err(|e| e.to_string())?;
    let dir_str = attachments_dir.to_string_lossy().to_string();
    // 写入不计入本场景（由 attachment-write 覆盖）
    let view = asset_api::add_task_attachment_from_path(
        &pool,
        &dir_str,
        task_id,
        "probe-attachment.bin",
        "application/octet-stream",
        &file,
    )
    .await
    .map_err(|e| e.to_string())?;

    let target = args.workdir.join("exported.bin");
    let (result, metrics) = measure(async {
        asset_api::export_task_attachment(&pool, &dir_str, &view.hash, &target)
            .await
            .map_err(|e| e.to_string())
    })
    .await;
    let written = result?;
    let mut out = metrics_json(&metrics);
    let obj = out.as_object_mut().expect("json object");
    obj.insert("artifactBytes".into(), json!(size));
    obj.insert("artifactMB".into(), json!(mb(size as usize)));
    obj.insert("exportedBytes".into(), json!(written));
    Ok(out)
}

/// 探针用「网络」适配器：上传按 64KiB 块读临时容器并丢弃；下载把预置容器
/// 按 OS 级 copy 写到目标——两者峰值都与对象大小无关，用来量 core 侧
/// 「加密 → 上传」「下载 → 解密」链路的峰值，而不是适配器自身的缓冲策略。
struct ProbeCloud {
    /// pull 场景的云端对象（容器文件）
    object: Option<PathBuf>,
    /// push 场景的云端已有 hash（非空列表，跳过首传防御探测）
    cloud_hash: Option<String>,
    uploaded_bytes: Mutex<u64>,
}

#[async_trait::async_trait]
impl SyncAdapter for ProbeCloud {
    async fn list_all_files(&self, _: &str) -> Result<Vec<RemoteFile>, SyncError> {
        Ok(Vec::new())
    }
    async fn download(&self, _: &str) -> Result<bytes::Bytes, SyncError> {
        Err(SyncError::NotFound {
            message: "探针不提供普通对象下载".to_string(),
        })
    }
    async fn upload(&self, _: &str, _: &[u8]) -> Result<(), SyncError> {
        Ok(())
    }
    async fn delete(&self, _: &str) -> Result<(), SyncError> {
        Ok(())
    }
    async fn upload_asset(&self, _: &str, _: Vec<u8>) -> Result<(), SyncError> {
        panic!("M3 后 push 不得走整包 upload_asset");
    }
    async fn upload_asset_file(
        &self,
        _hash: &str,
        local_path: &std::path::Path,
        total_len: u64,
    ) -> Result<(), SyncError> {
        use tokio::io::AsyncReadExt;
        let mut file = tokio::fs::File::open(local_path)
            .await
            .map_err(|e| SyncError::Network {
                message: format!("探针读取容器失败: {e}"),
                retryable: false,
            })?;
        let mut buf = vec![0u8; 64 * 1024];
        let mut got = 0u64;
        loop {
            let n = file.read(&mut buf).await.map_err(|e| SyncError::Network {
                message: format!("探针读取容器失败: {e}"),
                retryable: false,
            })?;
            if n == 0 {
                break;
            }
            got += n as u64;
        }
        assert_eq!(got, total_len, "上传声明长度必须与实际容器一致");
        *self.uploaded_bytes.lock().unwrap() += got;
        Ok(())
    }
    async fn download_asset(&self, _: &str) -> Result<bytes::Bytes, SyncError> {
        Err(SyncError::NotFound {
            message: "探针走 download_asset_to_file".to_string(),
        })
    }
    async fn download_asset_to_file(
        &self,
        _hash: &str,
        target: &std::path::Path,
    ) -> Result<u64, SyncError> {
        let src = self.object.as_ref().ok_or_else(|| SyncError::Network {
            message: "探针未预置云端对象".to_string(),
            retryable: false,
        })?;
        tokio::fs::copy(src, target)
            .await
            .map_err(|e| SyncError::Network {
                message: format!("探针写下载目标失败: {e}"),
                retryable: false,
            })
    }
    async fn asset_exists(&self, _: &str) -> Result<bool, SyncError> {
        Ok(false)
    }
    async fn list_assets(&self, _: &str) -> Result<Vec<String>, SyncError> {
        Ok(vec![
            self.cloud_hash
                .clone()
                .unwrap_or_else(|| "probe-cloud-sentinel".to_string()),
        ])
    }
}

fn sync_crypto(
    workdir: &std::path::Path,
    name: &str,
) -> Result<(SyncCryptoService, [u8; 32]), String> {
    let crypto = SyncCryptoService::new(workdir);
    let key = [0x5Au8; 32];
    crypto
        .init_with_data_key("probe-pass", &key)
        .map_err(|e| format!("初始化探针 Data Key 失败（{name}）: {e}"))?;
    Ok((crypto, key))
}

async fn run_attachment_sync(args: &Args, push: bool) -> Result<serde_json::Value, String> {
    let file = args.workdir.join("probe-attachment.bin");
    let size = std::fs::metadata(&file)
        .map_err(|e| format!("读取附件样本失败：{e}"))?
        .len();
    let hash = file_sha256(&file)?;
    let (pool, task_id) =
        attachment_db(args, if push { "sync-push.db" } else { "sync-pull.db" }).await?;
    let attachments_dir = args.workdir.join("attachments");
    std::fs::create_dir_all(&attachments_dir).map_err(|e| e.to_string())?;
    let dir_str = attachments_dir.to_string_lossy().to_string();
    let (crypto, key) = sync_crypto(&args.workdir, if push { "push" } else { "pull" })?;

    let (adapter, artifact) = if push {
        // 本地账本：已缓存、待上传
        attachment_repo::upsert(
            &pool,
            &Attachment {
                hash: hash.clone(),
                original_name: "probe-attachment.bin".to_string(),
                mime_type: "application/octet-stream".to_string(),
                size_bytes: size as i64,
                local_path: Some(file.to_string_lossy().to_string()),
                is_uploaded: 0,
                is_local_cached: 1,
                created_at: 1,
                last_accessed_at: 1,
            },
        )
        .await
        .map_err(|e| e.to_string())?;
        // 把样本放到「本地缓存文件」位置（内容寻址路径）
        std::fs::copy(&file, attachments_dir.join(&hash)).map_err(|e| e.to_string())?;
        (
            ProbeCloud {
                object: None,
                cloud_hash: Some("probe-cloud-existing".to_string()),
                uploaded_bytes: Mutex::new(0),
            },
            size,
        )
    } else {
        // 云端对象 = 预生成的 OSAC 容器（setup 不计入测量）
        let container = args.workdir.join("probe-container.bin");
        let info = asset_container::encrypt_file_to_container(&file, &container, &key, &hash)
            .map_err(|e| format!("生成探针容器失败: {e}"))?;
        // 任务引用（pull 只拉有存活引用的附件）
        sqlx::query(
            "INSERT INTO todo_task_attachments
               (uuid, task_id, hash, is_deleted, created_at, updated_at, version)
             VALUES ('probe-link', ?, ?, 0, 1, 1, 1)",
        )
        .bind(task_id)
        .bind(&hash)
        .execute(&pool)
        .await
        .map_err(|e| e.to_string())?;
        (
            ProbeCloud {
                object: Some(container),
                cloud_hash: Some(hash.clone()),
                uploaded_bytes: Mutex::new(0),
            },
            info.container_bytes,
        )
    };

    let (result, metrics) = measure(async {
        if push {
            sync_attachments_push(
                &pool,
                &crypto,
                &adapter,
                &NoopProgressSender,
                SyncOrigin::Manual,
                &dir_str,
            )
            .await
            .map_err(|e| e.to_string())
        } else {
            sync_attachments_pull(
                &pool,
                &crypto,
                &adapter,
                &NoopProgressSender,
                SyncOrigin::Manual,
                &dir_str,
            )
            .await
            .map_err(|e| e.to_string())
        }
    })
    .await;
    let sync: AttachmentSyncResult = result?;
    if !sync.errors.is_empty() {
        return Err(format!("附件同步出现错误: {:?}", sync.errors));
    }
    if push && sync.uploaded != 1 {
        return Err(format!("push 期望上传 1 件，实际 {}", sync.uploaded));
    }
    if !push && sync.downloaded != 1 {
        return Err(format!("pull 期望下载 1 件，实际 {}", sync.downloaded));
    }
    if !push {
        let restored = std::fs::read(attachments_dir.join(&hash)).map_err(|e| e.to_string())?;
        if restored.len() as u64 != size {
            return Err(format!(
                "pull 落盘大小不符：期望 {} 实际 {}",
                size,
                restored.len()
            ));
        }
    }

    let mut out = metrics_json(&metrics);
    let obj = out.as_object_mut().expect("json object");
    obj.insert("artifactBytes".into(), json!(size));
    obj.insert("artifactMB".into(), json!(mb(size as usize)));
    obj.insert("containerBytes".into(), json!(artifact));
    obj.insert(
        "uploadedContainerBytes".into(),
        json!(*adapter.uploaded_bytes.lock().unwrap()),
    );
    Ok(out)
}

/// 首同步探针适配器：云端为空、上传丢弃、只累计字节数
///
/// 不引入真实网络与磁盘写入，量的是 push 链路的「逐桶装载 + 加密 + 上传」
/// 峰值；上传总量由 `uploadedMB` 单独报出，用于确认数据确实流过了链路。
struct DiscardCloud {
    uploaded: Mutex<u64>,
}

#[async_trait::async_trait]
impl SyncAdapter for DiscardCloud {
    async fn list_all_files(&self, _: &str) -> Result<Vec<RemoteFile>, SyncError> {
        Ok(Vec::new())
    }
    async fn download(&self, path: &str) -> Result<bytes::Bytes, SyncError> {
        Err(SyncError::NotFound {
            message: format!("首同步探针云端为空: {path}"),
        })
    }
    async fn upload(&self, _: &str, data: &[u8]) -> Result<(), SyncError> {
        *self.uploaded.lock().unwrap() += data.len() as u64;
        Ok(())
    }
    async fn delete(&self, _: &str) -> Result<(), SyncError> {
        Ok(())
    }
    async fn upload_asset(&self, _: &str, data: Vec<u8>) -> Result<(), SyncError> {
        *self.uploaded.lock().unwrap() += data.len() as u64;
        Ok(())
    }
    async fn list_assets(&self, _: &str) -> Result<Vec<String>, SyncError> {
        Ok(Vec::new())
    }
    async fn asset_exists(&self, _: &str) -> Result<bool, SyncError> {
        Ok(false)
    }
}

/// 首同步峰值（M4 验收欠账，docs/07 #91）：本地 50k 行 + 云端为空
/// 全局搜索延迟场景（docs/13 §七 P3）：三口径各采样 N 次报 p50/p95 毫秒。
/// 候选标题模式 = seed_tasks 的「操作探针任务 NNNNNN」；中文精确查询取唯一
/// 编号（FTS 短语命中 1 行），中文宽词「操作探针」命中全表（截断 limit），
/// 两字词「任务」走 LIKE 兜底，拼音首字母走 reconcile 回填 + initials 前缀。
async fn scenario_global_search(args: &Args) -> Result<serde_json::Value, String> {
    use orbit_core::api::business_api::search_all;

    let db = args.workdir.join("global-search.db");
    let pool = init_pool_unencrypted(&db)
        .await
        .map_err(|e| e.to_string())?;
    seed_tasks(&pool, args.rows, 0).await?;

    let limit = 20;
    let samples_per_query = 30;
    // (口径名, 查询词)
    let queries: Vec<(&str, String)> = vec![
        ("fts-unique", "操作探针任务 000123".into()),
        ("fts-broad", "操作探针".into()),
        ("like-short", "任务".into()),
        ("pinyin-initials", "cztc".into()),
    ];

    let mut per_query: Vec<serde_json::Value> = Vec::new();
    let mut all_ms: Vec<u128> = Vec::new();
    for (name, kw) in &queries {
        // 预热一次（含拼音通道的首次 reconcile 全量回填——单独计时报出）
        let t0 = Instant::now();
        let _ = search_all(&pool, kw, limit).await.map_err(|e| e.to_string())?;
        let first_ms = t0.elapsed().as_millis();

        let mut lat: Vec<u128> = Vec::new();
        for _ in 0..samples_per_query {
            let t = Instant::now();
            let _ = search_all(&pool, kw, limit).await.map_err(|e| e.to_string())?;
            lat.push(t.elapsed().as_millis());
        }
        lat.sort();
        let p50 = lat[lat.len() / 2];
        let p95 = lat[(lat.len() as f64 * 0.95) as usize % lat.len()];
        all_ms.extend(&lat);
        per_query.push(json!({
            "query": name,
            "firstMs": first_ms,
            "p50Ms": p50,
            "p95Ms": p95,
        }));
    }
    all_ms.sort();
    let overall_p50 = all_ms[all_ms.len() / 2];
    let overall_p95 = all_ms[(all_ms.len() as f64 * 0.95) as usize % all_ms.len()];

    let (_, metrics) = measure(async {
        // 收尾再跑一次混合查询进内存/延迟四指标（口径对齐其他场景）
        search_all(&pool, "操作探针", limit)
            .await
            .map_err(|e| e.to_string())
    })
    .await;

    let mut out = metrics_json(&metrics);
    let obj = out.as_object_mut().expect("json object");
    obj.insert("rows".into(), json!(args.rows));
    obj.insert("samplesPerQuery".into(), json!(samples_per_query));
    obj.insert("overallP50Ms".into(), json!(overall_p50));
    obj.insert("overallP95Ms".into(), json!(overall_p95));
    obj.insert("perQuery".into(), json!(per_query));
    Ok(out)
}

async fn scenario_initial_sync(args: &Args) -> Result<serde_json::Value, String> {
    let db = args.workdir.join("initial-sync.db");
    let pool = init_pool_unencrypted(&db)
        .await
        .map_err(|e| e.to_string())?;
    seed_tasks(&pool, args.rows, args.description_kb).await?;
    let db_bytes = std::fs::metadata(&db)
        .map_err(|e| format!("读取探针库大小失败：{e}"))?
        .len();

    let crypto = SyncCryptoService::new(&args.workdir);
    crypto
        .init_with_data_key(SYNC_PASSWORD, &[0x27u8; 32])
        .map_err(|e| format!("初始化探针 Data Key 失败: {e}"))?;
    let state_store = SyncStateStore::new(&args.workdir);
    let adapter = DiscardCloud {
        uploaded: Mutex::new(0),
    };
    let skip: [String; 0] = [];

    let (result, metrics) = measure(async {
        push_all(
            &pool,
            &crypto,
            &state_store,
            &adapter,
            &NoopProgressSender,
            SyncOrigin::Manual,
            "probe-device",
            &skip[..],
        )
        .await
        .map_err(|e| e.to_string())
    })
    .await;
    let push = result?;
    if push.failed_modules != 0 {
        return Err(format!("首同步存在失败模块: {:?}", push.errors));
    }
    if push.pushed_chunks == 0 {
        return Err("首同步没有上传任何桶——云端为空时应至少推送一桶".to_string());
    }

    let uploaded = *adapter.uploaded.lock().unwrap();
    let mut out = metrics_json(&metrics);
    let obj = out.as_object_mut().expect("json object");
    obj.insert("artifactBytes".into(), json!(db_bytes));
    obj.insert("artifactMB".into(), json!(mb(db_bytes as usize)));
    obj.insert("uploadedBytes".into(), json!(uploaded));
    obj.insert("uploadedMB".into(), json!(mb(uploaded as usize)));
    obj.insert("rows".into(), json!(args.rows));
    obj.insert("pushedChunks".into(), json!(push.pushed_chunks));
    obj.insert("pushedModules".into(), json!(push.pushed_modules));
    obj.insert("skippedModules".into(), json!(push.skipped_modules));
    obj.insert("failedModules".into(), json!(push.failed_modules));
    Ok(out)
}

async fn run(args: &Args) -> Result<serde_json::Value, String> {
    std::fs::create_dir_all(&args.workdir).map_err(|e| e.to_string())?;
    match args.scenario.as_str() {
        "backup-export" => scenario_backup_export(args).await,
        "backup-import" => scenario_backup_import(args).await,
        "csv-import" => scenario_csv_import(args).await,
        "attachment-write" => scenario_attachment_write(args).await,
        "attachment-read" => scenario_attachment_read(args).await,
        "attachment-sync-push" => run_attachment_sync(args, true).await,
        "attachment-sync-pull" => run_attachment_sync(args, false).await,
        "backup-export-large" => scenario_backup_export(args).await,
        "initial-sync" => scenario_initial_sync(args).await,
        "global-search" => scenario_global_search(args).await,
        other => Err(format!(
            "未知场景 '{other}'，可选 backup-export / backup-import / csv-import / \
             attachment-write / attachment-read / attachment-sync-push / attachment-sync-pull / \
             backup-export-large / initial-sync"
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
