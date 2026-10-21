//! v2_api — 备份 v2 流式导出/导入的编排层
//!
//! 与 v1（`encoder`/`decoder` 全内存整包）并列存在：
//! - **导出**：逐表按 rowid 分页读取 → 逐条写帧 → 直接落临时文件 → 原子重命名。
//!   任何时刻内存只有「一页记录 + 一帧密文」。
//! - **peek**：只读 header + 首帧（manifest），不碰正文。
//! - **导入**：逐帧解密 → 逐条写库，同一事务内先 DELETE 再 INSERT。
//!
//! v1 读兼容由调用方按 magic 分流（`is_v2_backup`）。

use std::collections::{BTreeMap, HashMap};
use std::io::BufWriter;
use std::path::Path;

use chrono::Utc;
use sqlx::SqlitePool;

use crate::api::business_api;
use crate::api::full_sync_backup_api::insert_record_raw_in_tx;
use crate::db::repository::import_type_validator::{ColumnMeta, load_table_columns_in_tx};
use crate::full_sync_backup::container::ITERATIONS;
use crate::full_sync_backup::error::{FullSyncBackupError, FullSyncBackupResult};
use crate::full_sync_backup::manifest::BackupManifest;
use crate::full_sync_backup::v2::{
    FRAME_PLAIN_MAX, FrameReader, FrameWriter, MAGIC_V2, V2Meta, write_records,
};

/// 导出时每页读取的记录数（分页粒度；与帧大小独立）
///
/// 取 500 与同步链路 `load_table_items_of` 同量级：一页 JSON 通常几十 KB，
/// 远小于 4MiB 帧，故内存由页决定、磁盘 IO 由帧决定。
pub const EXPORT_PAGE_ROWS: i64 = 500;

/// 判断备份字节流是否为 v2（读侧分流用）
pub fn is_v2_backup(bytes: &[u8]) -> bool {
    bytes.len() >= 4 && bytes[0..4] == MAGIC_V2
}

/// v2 导出：流式写临时文件后原子重命名
///
/// 返回 `(文件大小, 各表行数)`。临时文件与目标同目录，保证 rename 是同分区
/// 原子操作；任何失败路径都删临时文件（不留下半份备份）。
pub async fn export_v2_to_file(
    pool: &SqlitePool,
    target: &Path,
    sync_password: &str,
    device_id: &str,
    device_name: Option<String>,
) -> FullSyncBackupResult<(u64, BTreeMap<String, usize>)> {
    // 确保目标父目录存在：调用方可能只给了文件名（测试/手动路径），
    // 而备份目录的创建在 v1 里由外层负责，v2 导出自己兜一层更稳。
    if let Some(parent) = target.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }

    let schema_version = crate::api::full_sync_backup_api::query_schema_version(pool).await?;
    let now_ts = Utc::now().timestamp();
    let app_version = env!("CARGO_PKG_VERSION").to_string();

    // 先数各表行数（manifest 需要；这一步只读 COUNT，不搬数据）
    let mut table_counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut present_tables: Vec<&str> = Vec::new();
    for table in business_api::FULL_BACKUP_TABLES {
        match count_table_rows(pool, table).await {
            Ok(n) => {
                table_counts.insert(table.to_string(), n);
                present_tables.push(table);
            }
            Err(e) => {
                // 与 v1 同口径：表不存在可跳过，表在但读不出来必须中止
                if !table_present(pool, table).await {
                    log::warn!("[export_v2] 表 {table} 不存在（迁移前旧库），跳过: {e}");
                } else {
                    return Err(FullSyncBackupError::Other(format!(
                        "导出中止：表 {table} 读取失败，未生成备份文件：{e}"
                    )));
                }
            }
        }
    }

    let manifest = BackupManifest::new(
        device_id.to_string(),
        device_name,
        schema_version,
        table_counts.clone(),
        now_ts,
        app_version,
    );
    let schema_version_json = serde_json::to_string(&serde_json::json!({
        "version": schema_version
    }))?;

    // 临时文件：与目标同目录，保证 rename 原子
    let tmp = tmp_path_for(target);
    let result = write_v2_file(pool, &tmp, sync_password, &manifest, &schema_version_json, &present_tables).await;

    match result {
        Ok(size) => {
            // 原子落位：先删旧目标再 rename（Windows rename 不覆盖已存在文件）
            if target.exists() {
                std::fs::remove_file(target)?;
            }
            std::fs::rename(&tmp, target)?;
            Ok((size, table_counts))
        }
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

/// 写 v2 文件本体（失败时由调用方删临时文件）
async fn write_v2_file(
    pool: &SqlitePool,
    path: &Path,
    sync_password: &str,
    manifest: &BackupManifest,
    schema_version_json: &str,
    tables: &[&str],
) -> FullSyncBackupResult<u64> {
    let file = std::fs::File::create(path)?;
    let sink = BufWriter::with_capacity(64 * 1024, file);
    let mut writer = FrameWriter::new(sink, sync_password, ITERATIONS, FRAME_PLAIN_MAX)?;

    // 首帧：元数据信封（manifest + schema_version）——peek 只读这一帧
    let meta = serde_json::to_vec(&serde_json::json!({
        "kind": "meta",
        "manifest": manifest,
        "schema_version": serde_json::from_str::<serde_json::Value>(schema_version_json)?,
    }))?;
    writer.write(&meta)?;
    writer.flush_frame()?;

    // 后续帧：逐表逐条记录
    for table in tables {
        // 表边界帧：`{"kind":"table","name":...}`，导入侧据此切表
        let marker = serde_json::to_vec(&serde_json::json!({
            "kind": "table",
            "name": table,
        }))?;
        writer.write(&marker)?;
        writer.flush_frame()?;

        let mut offset = 0i64;
        loop {
            let page = read_page_json(pool, table, offset, EXPORT_PAGE_ROWS).await?;
            if page.is_empty() {
                break;
            }
            let n = page.len();
            write_records(&mut writer, page.into_iter())?;
            offset += n as i64;
            if n < EXPORT_PAGE_ROWS as usize {
                break;
            }
        }
        // 表结束标记
        let end = serde_json::to_vec(&serde_json::json!({
            "kind": "table_end",
            "name": table,
        }))?;
        writer.write(&end)?;
        writer.flush_frame()?;
    }

    // 尾帧：结束标记（导入侧据此确认完整）
    writer.write(br#"{"kind":"end"}"#)?;
    writer.flush_frame()?;

    let sink = writer.finish()?;
    let file = sink
        .into_inner()
        .map_err(|e| FullSyncBackupError::Other(format!("刷新备份文件失败: {e}")))?;
    file.sync_all()?;
    let size = file.metadata()?.len();
    Ok(size)
}

/// v2 peek：只读 header + 首帧元数据，不碰正文
pub fn peek_v2_meta(bytes: &[u8], sync_password: &str) -> FullSyncBackupResult<V2Meta> {
    let cursor = std::io::Cursor::new(bytes);
    let mut reader = FrameReader::new(cursor, sync_password)?;
    let first = reader
        .next_frame()?
        .ok_or_else(|| FullSyncBackupError::InvalidFormat("v2 备份缺少元数据帧".into()))?;
    let v: serde_json::Value = serde_json::from_slice(&first)?;
    if v["kind"] != "meta" {
        return Err(FullSyncBackupError::InvalidFormat(
            "v2 首帧不是元数据信封".into(),
        ));
    }
    let manifest: BackupManifest = serde_json::from_value(v["manifest"].clone())?;
    let schema_version_json = serde_json::to_string(&v["schema_version"])?;
    Ok(V2Meta {
        manifest,
        schema_version_json,
    })
}

/// v2 导入：逐帧解密 → 逐条写库（同一事务内先 DELETE 再 INSERT）
///
/// 内存只保留当前帧明文与当前记录。单条失败记入 errors 不中断（与 v1 同口径）。
pub async fn import_v2_bytes(
    pool: &SqlitePool,
    bytes: &[u8],
    sync_password: &str,
    ignore_schema_mismatch: bool,
) -> FullSyncBackupResult<crate::api::full_sync_backup_api::ImportResult> {
    // 1. 先 peek 元数据做校验（不重复解密正文）
    let meta = peek_v2_meta(bytes, sync_password)?;
    meta.manifest.validate_format_version()?;

    let current_schema = crate::api::full_sync_backup_api::query_schema_version(pool).await?;
    if meta.manifest.schema_version != current_schema && !ignore_schema_mismatch {
        return Err(FullSyncBackupError::SchemaVersionMismatch {
            backup: meta.manifest.schema_version,
            current: current_schema,
        });
    }

    // 2. 开事务，先 DELETE 所有已知表
    let mut tx = pool.begin().await?;
    let mut total_errors: Vec<String> = Vec::new();

    for table_name in meta.manifest.table_counts.keys() {
        if !business_api::FULL_BACKUP_TABLES.contains(&table_name.as_str()) {
            total_errors.push(format!("{table_name}: 表名不在白名单"));
            continue;
        }
        let exists: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?")
                .bind(table_name)
                .fetch_one(&mut *tx)
                .await
                .map_err(FullSyncBackupError::Db)?;
        if exists.0 == 0 {
            total_errors.push(format!("{table_name}: 表不存在，跳过"));
            continue;
        }
        sqlx::query(&format!("DELETE FROM \"{table_name}\""))
            .execute(&mut *tx)
            .await
            .map_err(FullSyncBackupError::Db)?;
    }

    // 3. 逐帧解析并写库
    let cursor = std::io::Cursor::new(bytes);
    let mut reader = FrameReader::new(cursor, sync_password)?;
    // 跳过已读的首帧（meta 已在 peek 阶段解析）
    let _ = reader.next_frame()?;

    let mut current_table: Option<String> = None;
    let mut total_success: i64 = 0;
    let mut saw_end = false;
    // 列元数据按表缓存（同表多帧不必重复加载）
    let mut columns_cache: BTreeMap<String, HashMap<String, ColumnMeta>> = BTreeMap::new();

    loop {
        let Some(frame) = reader.next_frame()? else {
            break;
        };
        // 一帧只有两种可能：
        //  ① 控制帧：`{"kind":...}`（write_v2_file 显式 flush，单对象）
        //  ② 记录帧：write_records 每写一条即落帧，故帧内是「一条 JSON + 换行」
        // 判定依据只能是内容形状：控制帧带 `kind` 键。
        let frame_trimmed = trim_ascii(&frame);
        if frame_trimmed.is_empty() {
            continue;
        }
        let parsed: serde_json::Value = match serde_json::from_slice(frame_trimmed) {
            Ok(v) => v,
            Err(e) => {
                total_errors.push(format!("v2 帧解析失败: {e}"));
                continue;
            }
        };
        if let Some(kind) = parsed.get("kind").and_then(|k| k.as_str()) {
            match kind {
                "table" => {
                    let name = parsed["name"].as_str().unwrap_or_default().to_string();
                    current_table = Some(name);
                }
                "table_end" => current_table = None,
                "end" => {
                    saw_end = true;
                    break;
                }
                "meta" => {
                    return Err(FullSyncBackupError::InvalidFormat(
                        "v2 正文出现重复元数据帧".into(),
                    ));
                }
                other => total_errors.push(format!("未知控制帧 kind={other}")),
            }
            continue;
        }

        // 记录帧
        let Some(table) = current_table.clone() else {
            total_errors.push("记录帧出现在表边界之外".to_string());
            continue;
        };
        if !business_api::FULL_BACKUP_TABLES.contains(&table.as_str()) {
            continue;
        }
        if !columns_cache.contains_key(&table) {
            match load_table_columns_in_tx(&mut tx, &table).await {
                Ok(c) => {
                    columns_cache.insert(table.clone(), c);
                }
                Err(e) => {
                    total_errors.push(format!("{table}: 加载表结构失败: {e}"));
                    continue;
                }
            }
        }
        let columns = columns_cache.get(&table).expect("上面刚插入");

        let Some(obj) = parsed.as_object() else {
            total_errors.push(format!("{table}: 记录帧不是 JSON 对象"));
            continue;
        };
        match insert_record_raw_in_tx(&mut tx, &table, obj, columns).await {
            Ok(()) => total_success += 1,
            Err(e) => total_errors.push(format!("{table} 第 {} 条: {e}", total_success + 1)),
        }
    }

    if !saw_end {
        return Err(FullSyncBackupError::InvalidFormat(
            "v2 备份缺少结束标记（可能被截断）".into(),
        ));
    }

    tx.commit().await?;

    Ok(crate::api::full_sync_backup_api::ImportResult {
        success_count: total_success,
        error_count: total_errors.len() as i64,
        errors: total_errors,
        manifest: meta.manifest,
        needs_restart: false,
    })
}

/// 分页读取一页记录（JSON 数组）
///
/// **口径与 v1 严格一致**：只取 `is_deleted = 0` 的存活行（v1 的
/// `list_records_as_json` 同样带这个过滤）。备份语义是「备份活数据」，
/// 墓碑不进备份——否则恢复后会把早已删除的行重新带回来。
async fn read_page_json(
    pool: &SqlitePool,
    table: &str,
    offset: i64,
    limit: i64,
) -> FullSyncBackupResult<Vec<serde_json::Value>> {
    // 与 v1 的 list_records_as_json 同源，只是加了 OFFSET/LIMIT
    let sql = format!(
        "SELECT * FROM \"{table}\" WHERE is_deleted = 0 ORDER BY rowid LIMIT ? OFFSET ?"
    );
    let rows = sqlx::query(&sql)
        .bind(limit)
        .bind(offset)
        .fetch_all(pool)
        .await
        .map_err(FullSyncBackupError::Db)?;

    use sqlx::{Column, Row, TypeInfo};
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let mut obj = serde_json::Map::new();
        for (i, col) in row.columns().iter().enumerate() {
            let name = col.name().to_string();
            let value = match col.type_info().name() {
                "INTEGER" | "INT" | "BIGINT" => row
                    .try_get::<Option<i64>, _>(i)
                    .ok()
                    .flatten()
                    .map(serde_json::Value::from)
                    .unwrap_or(serde_json::Value::Null),
                "REAL" | "DOUBLE" => row
                    .try_get::<Option<f64>, _>(i)
                    .ok()
                    .flatten()
                    .and_then(|f| serde_json::Number::from_f64(f).map(serde_json::Value::Number))
                    .unwrap_or(serde_json::Value::Null),
                "BLOB" => row
                    .try_get::<Option<Vec<u8>>, _>(i)
                    .ok()
                    .flatten()
                    .map(|b| serde_json::Value::Array(b.into_iter().map(|x| x.into()).collect()))
                    .unwrap_or(serde_json::Value::Null),
                _ => row
                    .try_get::<Option<String>, _>(i)
                    .ok()
                    .flatten()
                    .map(serde_json::Value::from)
                    .unwrap_or(serde_json::Value::Null),
            };
            obj.insert(name, value);
        }
        out.push(serde_json::Value::Object(obj));
    }
    Ok(out)
}

/// 表行数（COUNT；只数存活行，与导出口径一致）
async fn count_table_rows(pool: &SqlitePool, table: &str) -> FullSyncBackupResult<usize> {
    let n: i64 = sqlx::query_scalar(&format!(
        "SELECT COUNT(*) FROM \"{table}\" WHERE is_deleted = 0"
    ))
    .fetch_one(pool)
    .await
    .map_err(FullSyncBackupError::Db)?;
    Ok(n as usize)
}

/// 表是否存在（区分「旧库缺表」与「表在但读不出来」）
async fn table_present(pool: &SqlitePool, table: &str) -> bool {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?")
        .bind(table)
        .fetch_one(pool)
        .await
        .map(|n| n > 0)
        .unwrap_or(false)
}

/// 去掉首尾 ASCII 空白（帧内行切分后每行可能带 `\r` 或空格）
fn trim_ascii(mut b: &[u8]) -> &[u8] {
    while let Some((first, rest)) = b.split_first() {
        if first.is_ascii_whitespace() {
            b = rest;
        } else {
            break;
        }
    }
    while let Some((last, rest)) = b.split_last() {
        if last.is_ascii_whitespace() {
            b = rest;
        } else {
            break;
        }
    }
    b
}

/// v2 预览：只解出预览需要的表（默认 tasks + projects），不做整包解压
///
/// 与 v1 的 `DecodedBackup.table_data` 对齐同一形状（表名 → JSON 数组字符串），
/// 让上层的 `extract_task_preview` 抽样逻辑可以原样复用、无需两套解析。
pub fn peek_v2_tables(
    bytes: &[u8],
    sync_password: &str,
    wanted: &[&str],
) -> FullSyncBackupResult<(V2Meta, BTreeMap<String, String>)> {
    let meta = peek_v2_meta(bytes, sync_password)?;

    let cursor = std::io::Cursor::new(bytes);
    let mut reader = FrameReader::new(cursor, sync_password)?;
    let _ = reader.next_frame()?; // meta 帧

    let mut out: BTreeMap<String, Vec<serde_json::Value>> = BTreeMap::new();
    let mut current: Option<String> = None;
    while let Some(frame) = reader.next_frame()? {
        let frame_trimmed = trim_ascii(&frame);
        if frame_trimmed.is_empty() {
            continue;
        }
        let parsed: serde_json::Value = match serde_json::from_slice(frame_trimmed) {
            Ok(v) => v,
            Err(_) => continue, // 预览容错：坏帧跳过，不阻断
        };
        if let Some(kind) = parsed.get("kind").and_then(|k| k.as_str()) {
            match kind {
                "table" => {
                    let name = parsed["name"].as_str().unwrap_or_default().to_string();
                    current = Some(name);
                }
                "table_end" => current = None,
                "end" => break,
                _ => {}
            }
            continue;
        }
        let Some(table) = current.clone() else {
            continue;
        };
        if !wanted.contains(&table.as_str()) {
            continue; // 不在预览范围内：跳过（但仍要读完帧以保持序号连续）
        }
        out.entry(table).or_default().push(parsed);
    }

    let table_data = out
        .into_iter()
        .map(|(k, v)| Ok((k, serde_json::to_string(&v)?)))
        .collect::<FullSyncBackupResult<BTreeMap<String, String>>>()?;
    Ok((meta, table_data))
}

/// 临时文件路径：与目标同目录、后缀 `.tmp`
fn tmp_path_for(target: &Path) -> std::path::PathBuf {
    let mut name = target
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "backup".to_string());
    name.push_str(".tmp");
    target.with_file_name(name)
}

/// 确保临时文件在异常路径也被清理（供调用方在 panic/提前 return 时用）
pub fn cleanup_tmp(target: &Path) {
    let tmp = tmp_path_for(target);
    if tmp.exists() {
        let _ = std::fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v2_magic_detected() {
        assert!(is_v2_backup(b"OFS2rest"));
        assert!(!is_v2_backup(b"OFS1rest"));
        assert!(!is_v2_backup(b"OF"));
        assert!(!is_v2_backup(b""));
    }

    #[test]
    fn tmp_path_is_sibling_with_suffix() {
        let p = Path::new("/data/backups/device-a.orfullsync");
        let tmp = tmp_path_for(p);
        assert_eq!(
            tmp.file_name().unwrap().to_string_lossy(),
            "device-a.orfullsync.tmp"
        );
        assert_eq!(tmp.parent(), p.parent());
    }
}
