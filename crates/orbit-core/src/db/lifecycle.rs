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

use crate::crypto::is_legacy_v1_format;
use crate::crypto::master_auth::MasterAuthMeta;
use crate::error::{CoreError, CoreResult};

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
/// 文件存在但**损坏**：先复制留证（`*.corrupt-{ts}`），再返回明确错误（F69）——
/// 与 `load_sync_crypto_meta` 同口径：绝不返回 `Ok(None)`，否则上层会把「损坏」
/// 误判成「未设置密码」。
///
/// 留证方式与 `fs_util::quarantine_corrupt_file` 不同：这里用**复制**而非改名，
/// 因为 `master_auth.json` 是否存在本身就是状态机输入（`has_master_auth()` 决定
/// 前端是否显示解锁页、以及 `master_auth_init` 是否拒绝重复初始化）。改名会让
/// 损坏态被读成「未设置主密码」，从而放过重新 init——那会生成全新 DB Key，
/// 旧加密库再也打不开，属不可逆后果。复制既保住现场，又不改变存在性语义。
///
/// 副作用：检测到 v1 旧格式时记录告警日志（无法在无密码情况下"强制迁移"，
/// 升级仅在 `unlock_master_auth` 成功路径发生）。调用方可在 UI 提示用户尽快解锁。
pub fn load_master_auth(app_data_dir: &Path) -> CoreResult<Option<MasterAuthMeta>> {
    let path = master_auth_path(app_data_dir);
    if !path.exists() {
        return Ok(None);
    }

    // 读字节再自行判定 UTF-8：非原子写被打断的文件可能切在多字节字符中间，
    // 此时 `read_to_string` 会以 IO 错误退出，走不到下面的「解析失败」分支——
    // 而这两种成因都属「文件损坏」，应走同一处置。
    let raw = std::fs::read(&path)?;
    let parsed: Result<MasterAuthMeta, String> = std::str::from_utf8(&raw)
        .map_err(|e| format!("文件不是合法 UTF-8：{e}"))
        .and_then(|s| serde_json::from_str::<MasterAuthMeta>(s).map_err(|e| e.to_string()));

    let meta = match parsed {
        Ok(meta) => meta,
        Err(why) => {
            let evidence = preserve_corrupt_master_auth(&path)
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "<留证失败>".to_string());
            log::error!(
                "[master_auth] {} 解析失败（已留证 {}）：{}。\
                 请勿重新初始化主密码——旧加密库将无法再打开，\
                 如需恢复请用备份的 master_auth.json 覆盖后重试。",
                path.display(),
                evidence,
                why
            );
            return Err(CoreError::Other(format!(
                "主密码认证元数据损坏（已留证 {}）：{}",
                evidence, why
            )));
        }
    };

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

/// 复制损坏的 `master_auth.json` 留证，返回留证路径
///
/// 已存在同名留证副本时直接复用（否则每次启动 + 每次解锁尝试都会堆积一份）。
/// 整体失败返回 `None`——留证是尽力而为，不能因此掩盖真正要报的解析错误。
fn preserve_corrupt_master_auth(path: &Path) -> Option<PathBuf> {
    let file_name = path.file_name()?.to_string_lossy().to_string();
    let prefix = format!("{file_name}.corrupt-");

    if let Some(parent) = path.parent()
        && let Ok(entries) = std::fs::read_dir(parent)
    {
        for entry in entries.flatten() {
            if entry.file_name().to_string_lossy().starts_with(&prefix) {
                return Some(entry.path());
            }
        }
    }

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let dest = PathBuf::from(format!("{}.corrupt-{}", path.display(), ts));
    std::fs::copy(path, &dest).ok().map(|_| dest)
}

/// 持久化主密码认证元数据到文件
///
/// 以 JSON 格式原子写入 `master_auth.json`（同目录临时文件 + rename，F69），
/// 文件权限由 OS 默认管理。
///
/// 此处必须原子：非原子 `fs::write` 在中途崩溃会留下半截 JSON，
/// 下次启动即解析失败——用户会被挡在解锁页外，且损坏内容若被后续写入覆盖，
/// 现场就没了（该文件是唯一能从密码解出 DB Key 的元数据，不在任何同步白名单里，
/// 也没有第二份副本可恢复）。
pub fn save_master_auth(app_data_dir: &Path, meta: &MasterAuthMeta) -> CoreResult<()> {
    let path = master_auth_path(app_data_dir);
    let content = serde_json::to_string_pretty(meta)?;
    crate::fs_util::write_atomic(&path, content.as_bytes())?;
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

    // ─────────── F69：损坏留证 + 原子写 ───────────

    /// 损坏文件：报错 + 复制留证，且**原文件仍在**（`has_master_auth()` 语义不变）
    ///
    /// 这条断言是 F69 的核心：改名式隔离会让 `has_master_auth()` 变 false，
    /// 前端据此认为「未设置主密码」，`master_auth_init` 的重复初始化保护随之失效。
    #[test]
    fn load_master_auth_corrupt_reports_error_and_keeps_file() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path();
        std::fs::write(master_auth_path(dir), "{ half written").unwrap();

        let err = load_master_auth(dir).expect_err("损坏文件必须报错而非 Ok(None)");
        let msg = err.to_string();
        assert!(msg.contains("损坏"), "错误信息应点明损坏: {msg}");
        assert!(msg.contains("留证"), "错误信息应带上留证路径: {msg}");

        assert!(
            has_master_auth(dir),
            "原文件必须保留，否则 has_master_auth() 会误判为「未设置主密码」"
        );
        let evidence: Vec<_> = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains("corrupt-"))
            .collect();
        assert_eq!(evidence.len(), 1, "应恰好留证一份副本");
        assert_eq!(
            std::fs::read(evidence[0].path()).unwrap(),
            b"{ half written",
            "留证副本内容应与损坏现场一致"
        );
    }

    /// 非 UTF-8 内容同样归入「损坏」（半截写入可能切在多字节字符中间）
    ///
    /// 断言「损坏」而非仅「UTF-8」：旧实现直接 `read_to_string`，其 IO 错误文案
    /// 里也含 "UTF-8"，只断言编码字样会在这条用例上永远为绿。
    #[test]
    fn load_master_auth_invalid_utf8_is_treated_as_corrupt() {
        let tmp = TempDir::new().unwrap();
        std::fs::write(master_auth_path(tmp.path()), [0xff, 0xfe, 0xfd]).unwrap();

        let err = load_master_auth(tmp.path()).expect_err("非法 UTF-8 必须报错");
        let msg = err.to_string();
        assert!(msg.contains("损坏"), "应走损坏处置分支: {msg}");
        assert!(msg.contains("UTF-8"), "错误信息应点明编码问题: {msg}");
    }

    /// 重复加载不堆积留证副本（损坏态下每次启动/每次解锁都会走到这条路径）
    #[test]
    fn load_master_auth_corrupt_does_not_accumulate_evidence() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path();
        std::fs::write(master_auth_path(dir), "not json").unwrap();

        for _ in 0..3 {
            assert!(load_master_auth(dir).is_err());
        }
        let count = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains("corrupt-"))
            .count();
        assert_eq!(count, 1, "重复加载应复用已有留证副本，实际 {count} 份");
    }

    /// 原子写不留 `.tmp` 残留（F69：save 改走 fs_util::write_atomic）
    #[test]
    fn save_master_auth_is_atomic_and_leaves_no_tmp() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path();
        let (meta, _) = crate::crypto::master_auth::init_master_auth("pw123").unwrap();

        save_master_auth(dir, &meta).unwrap();
        save_master_auth(dir, &meta).unwrap(); // 覆盖写走 remove + rename 分支

        let leftovers: Vec<_> = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "不应有 tmp 残留: {leftovers:?}");
    }
}
