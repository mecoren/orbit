//! fs_util — 文件原子写入工具（Fix-04）
//!
//! 历史问题：`sync_crypto_meta.json` / `sync_state.json` 等关键元数据文件
//! 直接 `fs::write` 覆盖写入，进程在写入中途崩溃会留下半截文件：
//! - `sync_crypto_meta.json` 损坏 → `has_sync_password()` 误判为"未设置密码"，
//!   用户重新 init 会生成全新 Data Key，云端旧数据全部 KeyMismatch 且不可逆；
//! - `sync_state.json` 损坏 → 同步状态清零，触发全量重传（较轻但浪费流量）。
//!
//! 原子写协议（与 config_enc::storage 一致，此处抽为公共实现）：
//! 1. 写入同目录临时文件 `{filename}.{uuid}.tmp`
//! 2. 目标已存在则先删除（Windows rename 不允许覆盖）
//! 3. rename 到目标路径（同目录内 rename 是原子的）
//!
//! 附带损坏留证：`rename_corrupt_file` 将无法解析的元数据文件改名保留，
//! 避免后续写入静默覆盖用户最后的可诊断证据。

use std::path::{Path, PathBuf};

/// 原子写入文件内容（同目录临时文件 + rename 替换）
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use base64::Engine;
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "路径无父目录"))?;
    std::fs::create_dir_all(parent)?;

    // 临时文件名带随机后缀，避免同目录并发写入同名 tmp 冲突
    let rand_suffix = crate::crypto::random_bytes(8);
    let tmp_name = format!(
        "{}.{}.tmp",
        path.file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default(),
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&rand_suffix),
    );
    let tmp_path = parent.join(tmp_name);

    std::fs::write(&tmp_path, bytes)?;

    // Windows 上 rename 不允许覆盖已存在目标，先删除旧文件。
    // 极小概率窗口（删除后、rename 前崩溃）会丢失旧文件——但相比
    // "任意时刻崩溃都可能留下半截文件"，此窗口已收窄到不可接受更优。
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    match std::fs::rename(&tmp_path, path) {
        Ok(()) => Ok(()),
        Err(e) => {
            // rename 失败时清理 tmp，避免垃圾残留
            let _ = std::fs::remove_file(&tmp_path);
            Err(e)
        }
    }
}

/// 将损坏的元数据文件改名留证（`{path}.corrupt-{unix_ms}`），并返回新路径。
///
/// 用于加载阶段解析失败的场景：调用方应向用户明确报错，而不是把损坏文件
/// 当作"不存在"处理（那会诱发重新初始化密钥等不可逆操作）。
pub fn quarantine_corrupt_file(path: &Path) -> std::io::Result<PathBuf> {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let new_path = PathBuf::from(format!("{}.corrupt-{}", path.display(), ts));
    std::fs::rename(path, &new_path)?;
    Ok(new_path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_atomic_roundtrip_and_overwrite() {
        let dir = tempfile::TempDir::new().unwrap();
        let file = dir.path().join("meta.json");

        write_atomic(&file, b"v1").unwrap();
        assert_eq!(std::fs::read(&file).unwrap(), b"v1");

        // 覆盖写（走 remove + rename 分支）
        write_atomic(&file, b"version-2-longer").unwrap();
        assert_eq!(std::fs::read(&file).unwrap(), b"version-2-longer");

        // 无 tmp 残留
        let leftovers: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "不应有 tmp 残留");
    }

    #[test]
    fn write_atomic_creates_parent_dirs() {
        let dir = tempfile::TempDir::new().unwrap();
        let file = dir.path().join("a/b/c/meta.json");
        write_atomic(&file, b"x").unwrap();
        assert!(file.exists());
    }

    #[test]
    fn quarantine_renames_corrupt_file() {
        let dir = tempfile::TempDir::new().unwrap();
        let file = dir.path().join("broken.json");
        std::fs::write(&file, "{ half written").unwrap();

        let quarantined = quarantine_corrupt_file(&file).unwrap();
        assert!(!file.exists(), "原路径应已腾空");
        assert!(quarantined.exists());
        assert!(
            quarantined
                .file_name()
                .unwrap()
                .to_string_lossy()
                .contains("corrupt-")
        );
    }

    #[test]
    fn quarantine_missing_file_errors() {
        let dir = tempfile::TempDir::new().unwrap();
        let missing = dir.path().join("nope.json");
        assert!(quarantine_corrupt_file(&missing).is_err());
    }
}
