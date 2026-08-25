//! lifecycle — 数据库生命周期与文件持久化
//!
//! 管理数据库文件和主密码认证元数据的文件路径。
//! 桌面端使用 Tauri 的 `app_data_dir`，移动端使用 `path_provider`（Phase 6D）。
//!
//! 文件布局：
//! ```text
//! {app_data_dir}/
//! ├── orbit.db          ← SQLite 数据库（SQLCipher 加密或明文）
//! └── master_auth.json      ← 主密码认证元数据（salt/hash/encrypted_db_key）
//! ```

use std::path::{Path, PathBuf};

use crate::crypto::master_auth::MasterAuthMeta;
use crate::crypto::is_legacy_v1_format;
use crate::error::CoreResult;

/// 数据库文件名
const DB_FILE_NAME: &str = "orbit.db";

/// 主密码认证元数据文件名
const META_FILE_NAME: &str = "master_auth.json";

/// 返回数据库文件路径
///
/// `app_data_dir` 由上层传入（桌面端 = Tauri app_data_dir，移动端 = path_provider）。
pub fn db_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(DB_FILE_NAME)
}

/// 返回主密码认证元数据文件路径
pub fn master_auth_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(META_FILE_NAME)
}

/// 判断主密码是否已设置（master_auth.json 是否存在）
pub fn has_master_auth(app_data_dir: &Path) -> bool {
    master_auth_path(app_data_dir).exists()
}

/// 从文件加载主密码认证元数据
///
/// 文件不存在时返回 `None`（表示未设置主密码，使用明文数据库）。
///
/// 副作用：检测到 v1 旧格式时记录告警日志（无法在无密码情况下"强制迁移"，
/// 升级仅在 `unlock_master_auth` 成功路径发生）。调用方可在 UI 提示用户尽快解锁。
pub fn load_master_auth(app_data_dir: &Path) -> CoreResult<Option<MasterAuthMeta>> {
    let path = master_auth_path(app_data_dir);
    if !path.exists() {
        return Ok(None);
    }
    let content = std::fs::read_to_string(&path)?;
    let meta: MasterAuthMeta = serde_json::from_str(&content)?;
    // v1 旧格式告警：verify_hash 缺失表示文件仍以明文 derived_key 落盘，
    // 文件泄露即可解出 DB Key。无法在无密码下迁移，仅记录告警。
    if is_legacy_v1_format(&meta) {
        log::warn!(
            "[master_auth] 检测到 v1 旧格式文件（{}）：derived_key 明文落盘存在泄露风险。\
             用户首次解锁后将自动升级为 v2 格式。建议尽快解锁主密码以触发升级。",
            path.display()
        );
    }
    Ok(Some(meta))
}

/// 持久化主密码认证元数据到文件
///
/// 以 JSON 格式写入 `master_auth.json`，文件权限由 OS 默认管理。
pub fn save_master_auth(app_data_dir: &Path, meta: &MasterAuthMeta) -> CoreResult<()> {
    let path = master_auth_path(app_data_dir);
    let content = serde_json::to_string_pretty(meta)?;
    std::fs::write(&path, content)?;
    Ok(())
}

/// 清除主密码认证元数据（用于取消开屏密码）
///
/// 删除 `master_auth.json` 文件。若文件不存在则无操作。
pub fn clear_master_auth(app_data_dir: &Path) -> CoreResult<()> {
    let path = master_auth_path(app_data_dir);
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn db_path_and_meta_path_are_in_app_data_dir() {
        let dir = Path::new("/tmp/test_app");
        assert_eq!(db_path(dir), Path::new("/tmp/test_app/orbit.db"));
        assert_eq!(
            master_auth_path(dir),
            Path::new("/tmp/test_app/master_auth.json")
        );
    }

    #[test]
    fn has_master_auth_returns_false_when_no_file() {
        let tmp = TempDir::new().unwrap();
        assert!(!has_master_auth(tmp.path()));
    }

    #[test]
    fn save_load_clear_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path();

        // 初始无元数据
        assert!(!has_master_auth(dir));
        assert!(load_master_auth(dir).unwrap().is_none());

        // 初始化并保存
        let (meta, _) = crate::crypto::master_auth::init_master_auth("pw123").unwrap();
        save_master_auth(dir, &meta).unwrap();
        assert!(has_master_auth(dir));

        // 加载并验证
        let loaded = load_master_auth(dir).unwrap().unwrap();
        assert_eq!(loaded.salt, meta.salt);
        assert_eq!(loaded.hash, meta.hash);
        assert_eq!(loaded.iterations, meta.iterations);

        // 清除
        clear_master_auth(dir).unwrap();
        assert!(!has_master_auth(dir));
        assert!(load_master_auth(dir).unwrap().is_none());
    }

    #[test]
    fn clear_master_auth_is_idempotent() {
        let tmp = TempDir::new().unwrap();
        // 文件不存在时清除不应报错
        clear_master_auth(tmp.path()).unwrap();
    }
}
