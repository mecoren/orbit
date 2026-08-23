//! migrate — 数据库加密态迁移
//!
//! 提供加密数据库 → 明文数据库的迁移能力（用于清除主密码场景）。
//! 使用 SQLCipher 的 sqlcipher_export() SQL 函数原子性导出。

use std::path::Path;

use sqlx::SqlitePool;

use crate::error::{CoreError, CoreResult};

/// 将加密数据库导出为明文数据库
///
/// 流程：
/// 1. PRAGMA wal_checkpoint(FULL) 确保 WAL 数据刷入主数据库
/// 2. ATTACH 明文临时数据库
/// 3. sqlcipher_export('plain') 导出全部表结构 + 数据
/// 4. DETACH 明文数据库
/// 5. 关闭当前 pool（调用方负责后续操作）
///
/// 调用方在调用本函数后应：
/// - 关闭当前 pool
/// - 用明文临时文件替换原数据库文件（finalize_migration）
/// - 以明文模式重新打开数据库
pub async fn migrate_to_plaintext(pool: &SqlitePool, db_path: &Path) -> CoreResult<()> {
    // 临时明文文件路径
    let tmp_path = db_path.with_extension("db.plain_tmp");

    // 若临时文件已存在则先删除（避免 ATTACH 冲突）
    if tmp_path.exists() {
        std::fs::remove_file(&tmp_path)?;
    }

    // 1. WAL checkpoint 确保数据完整
    sqlx::query("PRAGMA wal_checkpoint(FULL)")
        .execute(pool)
        .await?;

    // 2-4. ATTACH + sqlcipher_export + DETACH
    let tmp_path_str = tmp_path
        .to_str()
        .ok_or_else(|| CoreError::Other("临时文件路径包含非 UTF-8 字符".to_string()))?;

    let attach_sql = format!("ATTACH DATABASE '{}' AS plain KEY ''", tmp_path_str);
    sqlx::query(&attach_sql).execute(pool).await?;

    // sqlcipher_export 是 SQLCipher 内置函数，导出全部表结构 + 数据到指定数据库
    let result = sqlx::query("SELECT sqlcipher_export('plain')")
        .execute(pool)
        .await;

    // 无论成功失败都尝试 DETACH
    let _ = sqlx::query("DETACH DATABASE plain").execute(pool).await;

    result?;

    Ok(())
}

/// 完成迁移后的文件替换
///
/// 在 migrate_to_plaintext / migrate_to_encrypted 成功且 pool.close() 完成后调用：
/// 1. 用临时文件替换原数据库文件
/// 2. 删除旧的 -wal/-shm 文件
/// 3. 删除临时文件（已 rename 则无需删除）
pub fn finalize_migration(db_path: &Path) -> CoreResult<()> {
    let tmp_path = db_path.with_extension("db.plain_tmp");

    if !tmp_path.exists() {
        return Err(CoreError::Other(format!(
            "明文临时文件不存在: {:?}",
            tmp_path
        )));
    }

    replace_db_file(&tmp_path, db_path)
}

/// 将明文数据库导出为加密数据库（设置主密码场景）
///
/// 与 migrate_to_plaintext 对称：
/// 1. PRAGMA wal_checkpoint(FULL) 确保 WAL 数据刷入主数据库
/// 2. ATTACH 加密临时数据库（KEY = x'<hex>'，SQLCipher hex key 格式）
/// 3. sqlcipher_export('enc') 导出全部表结构 + 数据（自动加密写入）
/// 4. DETACH 加密数据库
///
/// 调用方在调用本函数后应：
/// - 关闭当前 pool
/// - 用临时文件替换原数据库文件（finalize_encrypted_migration）
/// - 以加密模式重新打开数据库（PRAGMA key = x'<hex>'）
pub async fn migrate_to_encrypted(
    pool: &SqlitePool,
    db_path: &Path,
    db_key_hex: &str,
) -> CoreResult<()> {
    let tmp_path = db_path.with_extension("db.enc_tmp");

    if tmp_path.exists() {
        std::fs::remove_file(&tmp_path)?;
    }

    // 1. WAL checkpoint 确保数据完整
    sqlx::query("PRAGMA wal_checkpoint(FULL)")
        .execute(pool)
        .await?;

    let tmp_path_str = tmp_path
        .to_str()
        .ok_or_else(|| CoreError::Other("临时文件路径包含非 UTF-8 字符".to_string()))?;

    // hex 格式 key → SQLCipher 的 x'...' 格式
    let attach_sql = format!(
        "ATTACH DATABASE '{}' AS enc KEY \"x'{}'\"",
        tmp_path_str, db_key_hex
    );
    sqlx::query(&attach_sql).execute(pool).await?;

    let result = sqlx::query("SELECT sqlcipher_export('enc')")
        .execute(pool)
        .await;

    let _ = sqlx::query("DETACH DATABASE enc").execute(pool).await;

    result?;

    Ok(())
}

/// 完成加密迁移后的文件替换（配合 migrate_to_encrypted 使用）
pub fn finalize_encrypted_migration(db_path: &Path) -> CoreResult<()> {
    let tmp_path = db_path.with_extension("db.enc_tmp");

    if !tmp_path.exists() {
        return Err(CoreError::Other(format!(
            "加密临时文件不存在: {:?}",
            tmp_path
        )));
    }

    replace_db_file(&tmp_path, db_path)
}

/// 公共替换逻辑：移除旧 WAL/SHM 后用临时文件原子替换主库文件
fn replace_db_file(tmp_path: &Path, db_path: &Path) -> CoreResult<()> {
    // 删除旧的 -wal/-shm 文件（与旧主库配套的 WAL 不适用于新文件）
    let wal_path = db_path.with_extension("db-wal");
    let shm_path = db_path.with_extension("db-shm");
    if wal_path.exists() {
        std::fs::remove_file(&wal_path)?;
    }
    if shm_path.exists() {
        std::fs::remove_file(&shm_path)?;
    }

    std::fs::rename(tmp_path, db_path)?;

    Ok(())
}
