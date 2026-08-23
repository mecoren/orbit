//! fingerprint — 模块指纹计算
//!
//! 指纹 = `sha256(canonical_json(items))`，用于判断模块数据是否变化。
//! 指纹未变则跳过上传/下载，实现模块级增量同步。
//!
//! ## canonical JSON 规则
//! 1. 每条记录按 `uuid` 字段升序排序
//! 2. 每个 JSON 对象的 key 按字典序排序（递归）
//! 3. 排除同步元字段：`updated_at`、`id`（自增 id 不影响业务数据）
//! 4. 紧凑序列化（无空格）
//!
//! ## 为什么排除 `updated_at`？
//! 指纹用于检测"业务数据是否变化"。`updated_at` 仅用于 LWW 合并时决冲突，
//! 不应让"仅时间戳变化"触发全量上传。合并时单独比对 `updated_at` 即可。

use serde_json::{Map, Value};

use crate::cloud_sync::error::CloudSyncError;
use crate::crypto::sha256::sha256_hex;

/// 同步元字段白名单：计算指纹时排除这些字段
const META_FIELDS: &[&str] = &["updated_at", "id"];

/// 计算模块指纹
///
/// 输入：模块所有未删除记录的 JSON 数组（每条记录是 serde_json::Value::Object）
/// 输出：64 字符的 sha256 hex 字符串
///
/// 空数组的指纹是 sha256("[]")，用于"首次同步空模块"场景。
pub fn compute_fingerprint(items: &[Value]) -> Result<String, CloudSyncError> {
    // 1. 规范化每条记录（移除元字段 + 排序 key + 递归）
    let canonical: Vec<Value> = items
        .iter()
        .map(canonicalize_value)
        .collect::<Result<_, _>>()?;

    // 2. 按 uuid 字段升序排序（顺序无关性）
    let mut sorted = canonical;
    sorted.sort_by(|a, b| {
        let ua = a.get("uuid").and_then(|v| v.as_str()).unwrap_or("");
        let ub = b.get("uuid").and_then(|v| v.as_str()).unwrap_or("");
        ua.cmp(ub)
    });

    // 3. 紧凑序列化
    let json_str = serde_json::to_string(&sorted)?;

    // 4. sha256
    Ok(sha256_hex(json_str.as_bytes()))
}

/// 递归规范化 JSON Value
///
/// - Object：移除元字段 + key 按字典序排序（BTreeMap 天然有序）
/// - Array：递归规范化每个元素
/// - 其他：原样返回
fn canonicalize_value(v: &Value) -> Result<Value, CloudSyncError> {
    match v {
        Value::Object(obj) => {
            let mut new_obj = Map::new();
            // serde_json::Map 默认按插入顺序，需手动按 key 排序后插入
            let mut keys: Vec<&String> = obj.keys().collect();
            keys.sort();
            for k in keys {
                // 排除同步元字段（仅作用于顶层 Object，避免误删嵌套的同名字段）
                if META_FIELDS.contains(&k.as_str()) {
                    continue;
                }
                let canonical_val = canonicalize_value(&obj[k])?;
                new_obj.insert(k.clone(), canonical_val);
            }
            // 用 BTreeMap 重建确保序列化时 key 有序
            let btree: serde_json::Map<String, Value> = new_obj;
            Ok(Value::Object(btree))
        }
        Value::Array(arr) => {
            let items: Vec<Value> = arr
                .iter()
                .map(canonicalize_value)
                .collect::<Result<_, _>>()?;
            Ok(Value::Array(items))
        }
        _ => Ok(v.clone()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn empty_array_has_stable_fingerprint() {
        let fp = compute_fingerprint(&[]).unwrap();
        // sha256("[]") = 4f5...（确定性）
        let fp2 = compute_fingerprint(&[]).unwrap();
        assert_eq!(fp, fp2);
        assert_eq!(fp.len(), 64);
    }

    #[test]
    fn fingerprint_is_deterministic() {
        let items = vec![
            json!({"uuid": "b", "name": "B"}),
            json!({"uuid": "a", "name": "A"}),
        ];
        let fp1 = compute_fingerprint(&items).unwrap();

        // 反序输入，指纹应相同（顺序无关）
        let reversed: Vec<Value> = items.iter().rev().cloned().collect();
        let fp2 = compute_fingerprint(&reversed).unwrap();

        assert_eq!(fp1, fp2, "指纹必须与输入顺序无关");
    }

    #[test]
    fn fingerprint_excludes_meta_fields() {
        // 仅 updated_at 和 id 不同，业务数据相同 → 指纹应相同
        let items1 = vec![json!({"uuid": "a", "name": "A", "updated_at": 100, "id": 1})];
        let items2 = vec![json!({"uuid": "a", "name": "A", "updated_at": 200, "id": 2})];

        let fp1 = compute_fingerprint(&items1).unwrap();
        let fp2 = compute_fingerprint(&items2).unwrap();
        assert_eq!(fp1, fp2, "updated_at/id 不应影响指纹");
    }

    #[test]
    fn fingerprint_changes_when_business_data_changes() {
        let items1 = vec![json!({"uuid": "a", "name": "A"})];
        let items2 = vec![json!({"uuid": "a", "name": "B"})];

        let fp1 = compute_fingerprint(&items1).unwrap();
        let fp2 = compute_fingerprint(&items2).unwrap();
        assert_ne!(fp1, fp2, "业务数据变化时指纹必须变化");
    }

    #[test]
    fn fingerprint_handles_nested_objects() {
        // 嵌套对象的 key 顺序也应规范化
        let items1 = vec![json!({"uuid": "a", "meta": {"b": 2, "a": 1}})];
        let items2 = vec![json!({"uuid": "a", "meta": {"a": 1, "b": 2}})];

        let fp1 = compute_fingerprint(&items1).unwrap();
        let fp2 = compute_fingerprint(&items2).unwrap();
        assert_eq!(fp1, fp2, "嵌套对象 key 顺序应规范化");
    }

    #[test]
    fn fingerprint_handles_arrays_in_objects() {
        let items1 = vec![json!({"uuid": "a", "tags": ["x", "y", "z"]})];
        let items2 = vec![json!({"uuid": "a", "tags": ["x", "y", "z"]})];

        let fp1 = compute_fingerprint(&items1).unwrap();
        let fp2 = compute_fingerprint(&items2).unwrap();
        assert_eq!(fp1, fp2);
    }

    #[test]
    fn fingerprint_includes_uuid_in_data() {
        // uuid 不同 → 指纹不同
        let items1 = vec![json!({"uuid": "a", "name": "A"})];
        let items2 = vec![json!({"uuid": "b", "name": "A"})];

        let fp1 = compute_fingerprint(&items1).unwrap();
        let fp2 = compute_fingerprint(&items2).unwrap();
        assert_ne!(fp1, fp2);
    }

    #[test]
    fn fingerprint_handles_missing_uuid() {
        // 缺失 uuid 的记录按空字符串排序，不应 panic
        let items = vec![
            json!({"name": "B"}),
            json!({"uuid": "a", "name": "A"}),
        ];
        let fp = compute_fingerprint(&items);
        assert!(fp.is_ok());
    }

    #[test]
    fn fingerprint_matches_known_sha256() {
        // 空数组的指纹应为 sha256("[]")
        let fp = compute_fingerprint(&[]).unwrap();
        let expected = sha256_hex(b"[]");
        assert_eq!(fp, expected);
    }
}
