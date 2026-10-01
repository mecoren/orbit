//! fingerprint — 模块指纹计算
//!
//! 指纹 = `sha256(canonical_json(items))`，用于判断模块数据是否变化。
//! 指纹未变则跳过上传/下载，实现模块级增量同步。
//!
//! ## canonical JSON 规则
//! 1. 每条记录按 `uuid` 字段升序排序
//! 2. 每个 JSON 对象的 key 按字典序排序（递归）
//! 3. 排除同步元字段：`updated_at`、`id`（自增 id 不影响业务数据）——**仅对顶层记录生效**，
//!    嵌套对象里的同名字段属业务数据，必须参与指纹（F70，2026-10-01 第六轮）
//! 4. 排除带 `_fk` 标记的整数外键列（F47）：其值是本端自增 id，跨设备不可比，
//!    真实语义由 `_fk` 里的父行 uuid 承载并参与指纹
//! 5. 紧凑序列化（无空格）
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
        .map(|v| canonicalize_value(v, true))
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
///
/// `top_level` 标识「这就是记录本身」而不是它内部的嵌套对象（F70）。元字段白名单与
/// `_fk` 外键排除**只在顶层成立**：它们描述的是「本端这一行」的同步元数据，
/// 而嵌套对象（某个 JSON 列里存的 `{"id":…,"updated_at":…}` 快照）里的同名 key
/// 属于业务数据。原实现把排除写在递归分支内（与本函数文档相矛盾），一旦载荷出现
/// 嵌套对象，嵌套的 `id`/`updated_at` 就被静默摘掉——嵌套内容怎么改桶指纹都不变，
/// 于是 `bucket_is_unchanged` 判「干净」，那部分编辑永远传不上云端。
fn canonicalize_value(v: &Value, top_level: bool) -> Result<Value, CloudSyncError> {
    match v {
        Value::Object(obj) => {
            let mut new_obj = Map::new();
            // serde_json::Map 默认按插入顺序，需手动按 key 排序后插入
            let mut keys: Vec<&String> = obj.keys().collect();
            keys.sort();
            // F47：整数外键列存的是本端自增 id（跨设备不可比），其真实语义已由
            // `_fk` 里的父行 uuid 承载并参与指纹。排除这些列，否则两端对同一份
            // 逻辑数据算出的桶指纹永远不等——每轮互相判为已变更而反复重传。
            // `_fk` 标记由 `load_table_items` 只注入顶层，故仅在顶层取用。
            let fk_mark = if top_level {
                obj.get(crate::cloud_sync::db_loader::FK_MARK)
                    .and_then(|m| m.as_object())
            } else {
                None
            };
            for k in keys {
                // 排除同步元字段（仅作用于顶层 Object，嵌套同名字段属业务数据）
                if top_level && META_FIELDS.contains(&k.as_str()) {
                    continue;
                }
                if fk_mark.is_some_and(|m| m.contains_key(k.as_str())) {
                    continue;
                }
                let canonical_val = canonicalize_value(&obj[k], false)?;
                new_obj.insert(k.clone(), canonical_val);
            }
            // 用 BTreeMap 重建确保序列化时 key 有序
            let btree: serde_json::Map<String, Value> = new_obj;
            Ok(Value::Object(btree))
        }
        Value::Array(arr) => {
            let items: Vec<Value> = arr
                .iter()
                .map(|item| canonicalize_value(item, false))
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

    /// F47：整数外键列由 `_fk` 的父 uuid 代表，本端 id 不得进指纹
    ///
    /// 否则两台设备对同一份逻辑数据算出的桶指纹永远不等，每轮互相重传。
    #[test]
    fn fk_int_columns_are_represented_by_uuid_mark() {
        let device_a = vec![json!({
            "uuid": "t1", "title": "T", "id": 7, "task_id": 7,
            "_fk": {"task_id": "parent-x"}, "updated_at": 1
        })];
        // 同一行逻辑数据，本端 id 与外键整数都不同、父 uuid 相同
        let device_b = vec![json!({
            "uuid": "t1", "title": "T", "id": 991, "task_id": 42,
            "_fk": {"task_id": "parent-x"}, "updated_at": 9
        })];
        assert_eq!(
            compute_fingerprint(&device_a).unwrap(),
            compute_fingerprint(&device_b).unwrap(),
            "跨设备同一份数据须指纹相等（否则每轮互相重传）"
        );

        // 换父级：_fk 变了即业务数据变了，必须落到指纹里
        let moved = vec![json!({
            "uuid": "t1", "title": "T", "id": 7, "task_id": 7,
            "_fk": {"task_id": "parent-y"}, "updated_at": 1
        })];
        assert_ne!(
            compute_fingerprint(&device_a).unwrap(),
            compute_fingerprint(&moved).unwrap(),
            "改父级须被指纹感知"
        );

        // 无 _fk 标记（叶子表）时，整数列照常参与指纹——排除逻辑只在有标记时生效
        let plain1 = vec![json!({"uuid": "l1", "name": "N", "sort_order": 1})];
        let plain2 = vec![json!({"uuid": "l1", "name": "N", "sort_order": 2})];
        assert_ne!(
            compute_fingerprint(&plain1).unwrap(),
            compute_fingerprint(&plain2).unwrap()
        );
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
        let items = vec![json!({"name": "B"}), json!({"uuid": "a", "name": "A"})];
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

    /// F70：元字段排除**只作用于顶层**，嵌套同名 key 必须参与指纹
    ///
    /// 旧实现把 `META_FIELDS.contains(...)` 写在递归分支里（与函数文档
    /// 「仅作用于顶层 Object」相矛盾）。后果不是「多算一次」而是少算：
    /// 嵌套对象里的 `id`/`updated_at` 被摘掉后，**嵌套内容怎么改桶指纹都不变**，
    /// `bucket_is_unchanged` 判「干净」→ 编辑永远传不上云端，且每轮都报成功。
    #[test]
    fn nested_meta_like_fields_are_part_of_fingerprint() {
        // 顶层 id/updated_at 仍然排除（既有口径不变）
        let top_only_1 = vec![json!({"uuid": "a", "nested": {"id": 1}, "id": 10, "updated_at": 1})];
        let top_only_2 = vec![json!({"uuid": "a", "nested": {"id": 1}, "id": 20, "updated_at": 2})];
        assert_eq!(
            compute_fingerprint(&top_only_1).unwrap(),
            compute_fingerprint(&top_only_2).unwrap(),
            "顶层元字段仍不应影响指纹"
        );

        // 嵌套的对象里出现同名字段 → 变化必须被感知
        let nested_1 = vec![json!({"uuid": "a", "payload": {"id": 1, "name": "x"}})];
        let nested_2 = vec![json!({"uuid": "a", "payload": {"id": 2, "name": "x"}})];
        assert_ne!(
            compute_fingerprint(&nested_1).unwrap(),
            compute_fingerprint(&nested_2).unwrap(),
            "嵌套对象里的 id 变化必须落到指纹上"
        );

        let ts_1 = vec![json!({"uuid": "a", "snapshot": {"updated_at": 100}})];
        let ts_2 = vec![json!({"uuid": "a", "snapshot": {"updated_at": 200}})];
        assert_ne!(
            compute_fingerprint(&ts_1).unwrap(),
            compute_fingerprint(&ts_2).unwrap(),
            "嵌套对象里的 updated_at 变化必须落到指纹上"
        );

        // 数组内的对象同样按业务数据算
        let arr_1 = vec![json!({"uuid": "a", "steps": [{"id": 1}, {"id": 2}]})];
        let arr_2 = vec![json!({"uuid": "a", "steps": [{"id": 1}, {"id": 3}]})];
        assert_ne!(
            compute_fingerprint(&arr_1).unwrap(),
            compute_fingerprint(&arr_2).unwrap(),
            "数组元素的字段变化必须落到指纹上"
        );

        // 嵌套里的 `_fk` 同名 key 也不再被误当成同步标记（只在顶层读 `_fk`）
        let fk_1 = vec![json!({"uuid": "a", "payload": {"_fk": "v1"}})];
        let fk_2 = vec![json!({"uuid": "a", "payload": {"_fk": "v2"}})];
        assert_ne!(
            compute_fingerprint(&fk_1).unwrap(),
            compute_fingerprint(&fk_2).unwrap(),
            "嵌套里的 _fk 同名 key 属业务数据"
        );
    }
}
