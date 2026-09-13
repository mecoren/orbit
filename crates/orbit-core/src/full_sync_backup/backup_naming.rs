//! backup_naming — 备份命名规范（v3 新增，参考 legado `Backup.kt::getNowZipFileName`）
//!
//! 命名格式：`backup{yyyy-MM-dd}-{设备码}.waitfullsync`
//! - 日期部分：取自系统当前日期，格式 `yyyy-MM-dd`
//! - 设备码部分：取自 `sync_config.device_id`，文件名安全化（替换 `[\\/:*?"<>|]` 为下划线）
//! - 设备码为空时退化为 `backup{yyyy-MM-dd}.waitfullsync`

use chrono::{DateTime, Utc};

/// 文件扩展名
pub const FILE_EXTENSION: &str = ".waitfullsync";

/// 文件名前缀
pub const FILE_PREFIX: &str = "backup";

/// 设备码文件名安全化：将 `[\\/:*?"<>|]` 替换为下划线
///
/// 参考 legado `normalizeFileName` 实现。
/// S3（2026-09-13 探查）：增补 `#`/`%`/空格/控制字符——文件名会拼进云端
/// URL：`#` 被解析为 fragment 起点（URL 截断）、`%` 形成非法转义、
/// 空格依赖隐式编码，三者在 S3/WebDAV 的请求路径与签名间制造错位。
pub fn sanitize_device_id(device_id: &str) -> String {
    device_id
        .chars()
        .map(|c| match c {
            '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '#' | '%' | ' ' => '_',
            c if c.is_control() => '_',
            other => other,
        })
        .collect()
}

/// 生成备份文件名：`backup{yyyy-MM-dd}-{设备码}.waitfullsync`
///
/// 设备码为空时退化为 `backup{yyyy-MM-dd}.waitfullsync`
pub fn generate_backup_filename(device_id: &str, now: DateTime<Utc>) -> String {
    let date = now.format("%Y-%m-%d").to_string();
    let sanitized = sanitize_device_id(device_id);

    if sanitized.is_empty() {
        format!("{}{}{}", FILE_PREFIX, date, FILE_EXTENSION)
    } else {
        format!("{}{}-{}{}", FILE_PREFIX, date, sanitized, FILE_EXTENSION)
    }
}

/// 生成备份文件名：优先使用 device_name，为空时回退 device_id
///
/// 格式：`backup{yyyy-MM-dd}-{name}.waitfullsync`
/// - device_name 非空（去除首尾空白后）时使用 device_name
/// - device_name 为空时回退到 device_id
/// - 两者均为空时退化为 `backup{yyyy-MM-dd}.waitfullsync`
///
/// 文件名安全化复用 [`sanitize_device_id`]，将 `[\\/:*?"<>|]` 替换为下划线。
pub fn generate_backup_filename_with_name(
    device_name: &str,
    device_id: &str,
    now: DateTime<Utc>,
) -> String {
    let name = if !device_name.trim().is_empty() {
        device_name
    } else {
        device_id
    };
    let date = now.format("%Y-%m-%d").to_string();
    let sanitized = sanitize_device_id(name);

    if sanitized.is_empty() {
        format!("{}{}{}", FILE_PREFIX, date, FILE_EXTENSION)
    } else {
        format!("{}{}-{}{}", FILE_PREFIX, date, sanitized, FILE_EXTENSION)
    }
}

/// 判断文件名是否符合 `backup*.waitfullsync` 命名规范
pub fn is_backup_filename(filename: &str) -> bool {
    filename.starts_with(FILE_PREFIX)
        && filename.ends_with(FILE_EXTENSION)
        && filename.len() > FILE_PREFIX.len() + FILE_EXTENSION.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now_at(date_str: &str) -> DateTime<Utc> {
        // 解析 yyyy-MM-dd 为 UTC 00:00:00
        let date = chrono::NaiveDate::parse_from_str(date_str, "%Y-%m-%d").unwrap();
        let dt = date.and_hms_opt(0, 0, 0).unwrap();
        DateTime::<Utc>::from_naive_utc_and_offset(dt, Utc)
    }

    #[test]
    fn filename_with_device_id() {
        let now = now_at("2026-07-20");
        let name = generate_backup_filename("a1b2c3d4e5f6g7h8", now);
        assert_eq!(name, "backup2026-07-20-a1b2c3d4e5f6g7h8.waitfullsync");
    }

    #[test]
    fn filename_without_device_id() {
        let now = now_at("2026-07-20");
        let name = generate_backup_filename("", now);
        assert_eq!(name, "backup2026-07-20.waitfullsync");
    }

    #[test]
    fn filename_sanitizes_unsafe_chars() {
        let now = now_at("2026-07-20");
        // 设备码包含 Windows 文件名非法字符
        let name = generate_backup_filename("dev:1/2\\3", now);
        assert_eq!(name, "backup2026-07-20-dev_1_2_3.waitfullsync");
    }

    #[test]
    fn is_backup_filename_valid() {
        assert!(is_backup_filename("backup2026-07-20-abc.waitfullsync"));
        assert!(is_backup_filename("backup2026-07-20.waitfullsync"));
    }

    #[test]
    fn is_backup_filename_rejects_non_backup() {
        assert!(!is_backup_filename("data.zip"));
        assert!(!is_backup_filename("backup.waitfullsync")); // 仅前缀+扩展名，无日期
        assert!(!is_backup_filename("backup2026-07-20.zip")); // 错误扩展名
        assert!(!is_backup_filename("restore2026-07-20.waitfullsync")); // 错误前缀
    }

    #[test]
    fn sanitize_device_id_preserves_safe_chars() {
        assert_eq!(sanitize_device_id("abc123-_"), "abc123-_");
    }

    #[test]
    fn sanitize_device_id_replaces_all_unsafe() {
        let input = r#"a\b/c:d*e?f"g<h>i|j"#;
        let result = sanitize_device_id(input);
        assert_eq!(result, "a_b_c_d_e_f_g_h_i_j");
    }

    /// S3：URL 危险字符与控制字符消毒（# / % / 空格 / 控制字符）
    #[test]
    fn sanitize_device_id_replaces_url_unsafe_chars() {
        assert_eq!(sanitize_device_id("dev#1"), "dev_1");
        assert_eq!(sanitize_device_id("50%off"), "50_off");
        assert_eq!(sanitize_device_id("my pc"), "my_pc");
        assert_eq!(sanitize_device_id("a\u{0000}b"), "a_b");
    }

    // ===== generate_backup_filename_with_name 测试 =====

    #[test]
    fn filename_with_name_prefers_device_name() {
        let now = now_at("2026-07-20");
        let name = generate_backup_filename_with_name("zhangsan", "a1b2c3d4", now);
        assert_eq!(name, "backup2026-07-20-zhangsan.waitfullsync");
    }

    #[test]
    fn filename_with_empty_name_uses_device_id() {
        let now = now_at("2026-07-20");
        let name = generate_backup_filename_with_name("", "a1b2c3d4", now);
        assert_eq!(name, "backup2026-07-20-a1b2c3d4.waitfullsync");
    }

    #[test]
    fn filename_with_whitespace_name_uses_device_id() {
        let now = now_at("2026-07-20");
        // device_name 仅含空白时回退 device_id
        let name = generate_backup_filename_with_name("   ", "a1b2c3d4", now);
        assert_eq!(name, "backup2026-07-20-a1b2c3d4.waitfullsync");
    }

    #[test]
    fn filename_with_both_empty_degrades_to_date_only() {
        let now = now_at("2026-07-20");
        let name = generate_backup_filename_with_name("", "", now);
        assert_eq!(name, "backup2026-07-20.waitfullsync");
    }

    #[test]
    fn filename_sanitizes_device_name_unsafe_chars() {
        let now = now_at("2026-07-20");
        // device_name 含 Windows 文件名非法字符，应被替换为下划线
        let name = generate_backup_filename_with_name("dev:1/2\\3", "abc", now);
        assert_eq!(name, "backup2026-07-20-dev_1_2_3.waitfullsync");
    }
}
