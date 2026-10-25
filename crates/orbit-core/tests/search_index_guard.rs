//! 拼音索引直写守卫（docs/07 #104 的残留风险 → 可执行 tripwire）
//!
//! ## 为什么需要
//! 自 2026-10-25 起，`search_pinyin` 的新鲜度不再靠「每次查询全量对账」兜底
//! （50k 行对账 ≈316ms，见 docs/13 §七 P3），而依赖两条纪律：
//!
//! 1. 业务写路径（`generic_repo` 五点、`trash_api` restore）写完即 `sync_row` / `remove_row`；
//! 2. **绕过 `generic_repo` 的裸写**（同步合并 / 备份恢复 / 批量导入 / 冲突恢复 /
//!    子任务转出 / 重复任务下次实例 / 复制任务）提交后 `mark_dirty` 或 `sync_row`。
//!
//! 第 2 条编译器管不了：漏一处不会报错，只会让「这条任务用拼音搜不到」长期静默存在。
//! 本测试把**生产代码里对三张被索引表的每一处写入**登记成台账——新增一处裸写，
//! 计数变化即失败，强制作者当场二选一：
//!
//! - 会写 `title` / `content`（含 `is_deleted` 变化）→ 提交后 `search_pinyin::mark_dirty`，
//!   或对该行 `sync_row` / `remove_row`；
//! - 不碰检索列（只写 `done` / `position` / `my_day_date` 等）→ 把台账数字改掉并写清理由。
//!
//! ## 扫描口径
//! - 只扫 `src/**/*.rs`（`examples/`、`tests/` 不算生产面）；
//! - `#[cfg(test)]` 块整体剔除（按括号配对；字符串/注释/raw string 先屏蔽，
//!   避免 SQL 里的 `{` 或测试里的 JSON 大括号干扰配对）；
//! - 注释不参与扫描（故文档里出现的「UPDATE todo_tasks」不误报），字符串照常扫描
//!   （SQL 就写在字符串里）；
//! - 按 (文件, 动词, 表) 分组计数，不绑行号——重排/缩进/挪行不该让守卫翻红。
//!
//! ## 本机跑不出结果时
//! 测试二进制位于 `target/` 时，本仓所在沙箱禁止其读取工作区源码（`OS Error 5`）。
//! 把测试二进制复制到 `%TEMP%` 再执行即可（本仓已知环境限制，见 docs/13 §七 P3）。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// 进拼音索引面的三张源表（与 `orbit_core::db::search_pinyin::INDEXED_TABLES` 同口径）
const TABLES: [&str; 3] = ["TODO_TASKS", "TODO_PROJECTS", "TODO_COMMENTS"];

/// 会改动行的动词（长的在前，避免前缀重复计数）
const VERBS: [&str; 4] = [
    "INSERT OR REPLACE INTO",
    "INSERT INTO",
    "UPDATE",
    "DELETE FROM",
];

/// 人工审过的台账：(文件, 动词, 表, 处数, 为什么可以不经置脏)
///
/// 处数是**该文件内该 (动词, 表) 的语句条数**。新增/删除语句都会让计数对不上——
/// 这正是本守卫的目的；改数字前请确认那一处是否真的不碰检索列。
const LEDGER: &[(&str, &str, &str, usize, &str)] = &[
    (
        "api/day_planner_api.rs",
        "UPDATE",
        "TODO_TASKS",
        1,
        "只写 my_day_date / start_date，不碰 title",
    ),
    (
        "api/todo_api.rs",
        "INSERT INTO",
        "TODO_TASKS",
        3,
        "子任务转出 / 重复任务下次实例 / 复制任务——三处均已提交后 sync_row",
    ),
    (
        "api/todo_api.rs",
        "UPDATE",
        "TODO_TASKS",
        3,
        "percent_done / position / done，不碰 title",
    ),
    (
        "api/todo_api.rs",
        "UPDATE",
        "TODO_PROJECTS",
        1,
        "只写 sort_order，不碰 title",
    ),
    (
        "api/trash_api.rs",
        "UPDATE",
        "TODO_TASKS",
        1,
        "回收站 restore 复活行——已 sync_row 重建索引",
    ),
    (
        "api/trash_api.rs",
        "DELETE FROM",
        "TODO_TASKS",
        3,
        "回收站物理清理（purge）；软删时索引行已 remove_row",
    ),
    (
        "api/trash_api.rs",
        "DELETE FROM",
        "TODO_COMMENTS",
        3,
        "同上：评论软删时索引行已移除",
    ),
    (
        "api/widget_api.rs",
        "UPDATE",
        "TODO_TASKS",
        1,
        "只写 done / done_at / status，不碰 title",
    ),
    (
        "db/repository/generic_repo.rs",
        "INSERT INTO",
        "TODO_TASKS",
        1,
        "创建钩子内 sync_row（失败不阻断，置脏兜底）",
    ),
    (
        "db/repository/generic_repo.rs",
        "INSERT INTO",
        "TODO_PROJECTS",
        1,
        "创建钩子内 sync_row",
    ),
    (
        "db/repository/generic_repo.rs",
        "INSERT INTO",
        "TODO_COMMENTS",
        1,
        "创建钩子内 sync_row",
    ),
    (
        "db/repository/generic_repo.rs",
        "UPDATE",
        "TODO_TASKS",
        1,
        "更新钩子内按 title 变更重建索引",
    ),
    (
        "db/repository/generic_repo.rs",
        "UPDATE",
        "TODO_PROJECTS",
        1,
        "更新钩子内按 title 变更重建索引",
    ),
];

#[test]
fn raw_writes_to_indexed_tables_match_ledger() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let sources = load_sources(&root);

    let mut found: BTreeMap<(String, String, String), Vec<String>> = BTreeMap::new();
    for (rel, src) in &sources {
        let prod = strip_test_blocks(src);
        for line in prod.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let upper = trimmed.to_uppercase();
            for verb in VERBS {
                for table in TABLES {
                    if upper.contains(&format!("{verb} {table}"))
                        || upper.contains(&format!("{verb} \"{table}"))
                    {
                        found
                            .entry((rel.clone(), verb.to_string(), table.to_string()))
                            .or_default()
                            .push(trimmed.chars().take(120).collect());
                    }
                }
            }
        }
    }

    let mut problems: Vec<String> = Vec::new();
    for (key, lines) in &found {
        match LEDGER
            .iter()
            .find(|(f, v, t, _, _)| *f == key.0 && *v == key.1 && *t == key.2)
        {
            Some((_, _, _, count, _)) if *count == lines.len() => {}
            Some((_, _, _, count, _)) => problems.push(format!(
                "{} | {} {} | 台账 {} 处，实际 {} 处\n      实际语句：{:#?}",
                key.0,
                key.1,
                key.2,
                count,
                lines.len(),
                lines
            )),
            None => problems.push(format!(
                "{} | {} {} | 台账未登记（新增裸写路径）\n      语句：{:#?}",
                key.0, key.1, key.2, lines
            )),
        }
    }
    for (file, verb, table, count, _) in LEDGER {
        if !found.contains_key(&(file.to_string(), verb.to_string(), table.to_string())) {
            problems.push(format!(
                "{file} | {verb} {table} | 台账登记 {count} 处，实际一处都没有（语句被删/改写？）"
            ));
        }
    }

    assert!(
        problems.is_empty(),
        "\n拼音索引写路径台账与源码不一致（docs/07 #104 的纪律守卫）：\n\n{}\n\n\
         处理方式：\n  \
         · 该语句会写 title/content（含 is_deleted 变化）→ 提交后调 search_pinyin::mark_dirty，\n    \
         或对该行 sync_row / remove_row；\n  \
         · 不碰检索列 → 更新本文件 LEDGER 的处数并写明理由。\n",
        problems.join("\n\n")
    );
}

/// 读取 `src/**/*.rs`（相对路径 → 内容）。
///
/// 读不了就**明确失败**而不是静默跳过：静默跳过等于守卫不存在。
fn load_sources(root: &Path) -> Vec<(String, String)> {
    let mut files: Vec<PathBuf> = Vec::new();
    collect_rs_files(root, &mut files);
    files.sort();
    assert!(files.len() > 40, "源码扫描数量异常：{}", files.len());

    let mut out = Vec::with_capacity(files.len());
    for path in &files {
        let rel = path
            .strip_prefix(root)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/");
        match std::fs::read_to_string(path) {
            Ok(src) => out.push((rel, src)),
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => panic!(
                "读取源码被拒（{e}）：{}\n\
                 本仓所在沙箱禁止 `target/` 下的测试二进制读工作区源码（OS Error 5）。\n\
                 把该测试二进制复制到 %TEMP% 后再跑即可执行本守卫：\n  \
                 cp target/debug/deps/search_index_guard-*.exe \"$TEMP/g.exe\" \
                 && (cd crates/orbit-core && \"$TEMP/g.exe\")",
                path.display()
            ),
            Err(e) => panic!("读取源文件失败 {}: {e}", path.display()),
        }
    }
    out
}

/// 递归收集 `*.rs`
fn collect_rs_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = std::fs::read_dir(dir).expect("读取源码目录");
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_rs_files(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
            out.push(path);
        }
    }
}

/// 屏蔽字符串字面量（含 raw string）与注释：等长替换为空格、保留换行。
///
/// 返回 `(structure, scan)` 两份文本：
/// - `structure`：字符串与注释都清空——只用来数 `{` / `}`，避免 SQL 里的花括号
///   与 JSON 字面量干扰配对；
/// - `scan`：**保留字符串内容**、只清注释——SQL 就写在字符串里，清掉就什么也扫不到；
///   注释清空则让文档里出现的「UPDATE todo_tasks」不误报。
fn mask(src: &str) -> (String, String) {
    let b = src.as_bytes();
    let n = b.len();
    let mut structure = b.to_vec();
    let mut scan = b.to_vec();
    let mut i = 0usize;
    while i < n {
        // 行注释：两份都清
        if b[i] == b'/' && i + 1 < n && b[i + 1] == b'/' {
            let mut j = i;
            while j < n && b[j] != b'\n' {
                structure[j] = b' ';
                scan[j] = b' ';
                j += 1;
            }
            i = j;
        // 块注释：两份都清
        } else if b[i] == b'/' && i + 1 < n && b[i + 1] == b'*' {
            let mut j = i;
            while j + 1 < n && !(b[j] == b'*' && b[j + 1] == b'/') {
                if b[j] != b'\n' {
                    structure[j] = b' ';
                    scan[j] = b' ';
                }
                j += 1;
            }
            for k in j..(j + 2).min(n) {
                structure[k] = b' ';
                scan[k] = b' ';
            }
            i = j + 2;
        // raw string：r"..." / r#"..."# / r##"..."## —— 只清 structure
        } else if b[i] == b'r' && is_raw_string_start(b, i) {
            let hashes = b[i + 1..].iter().take_while(|c| **c == b'#').count();
            let quote = i + 1 + hashes;
            let mut j = quote + 1;
            while j + hashes < n {
                if b[j] == b'"' && b[j + 1..j + 1 + hashes].iter().all(|c| *c == b'#') {
                    j += 1 + hashes;
                    break;
                }
                j += 1;
            }
            for k in i..j.min(n) {
                if b[k] != b'\n' {
                    structure[k] = b' ';
                }
            }
            i = j;
        // 普通字符串：只清 structure
        } else if b[i] == b'"' {
            let mut j = i + 1;
            while j < n {
                if b[j] == b'\\' {
                    j += 2;
                    continue;
                }
                if b[j] == b'"' {
                    j += 1;
                    break;
                }
                j += 1;
            }
            for k in i..j.min(n) {
                if b[k] != b'\n' {
                    structure[k] = b' ';
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
    (
        String::from_utf8(structure).expect("structure 仍应为合法 UTF-8"),
        String::from_utf8(scan).expect("scan 仍应为合法 UTF-8"),
    )
}

/// `r` 位于 token 起始且后面紧跟 `"` 或 `#`（排除 `for x` 这类普通标识符）
fn is_raw_string_start(b: &[u8], i: usize) -> bool {
    let prev_ok = i == 0 || !is_ident_byte(b[i - 1]);
    if !prev_ok {
        return false;
    }
    matches!(b.get(i + 1), Some(b'"') | Some(b'#'))
}

fn is_ident_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

/// 把 `#[cfg(test)]` 修饰的模块整体替换为空格（保留换行），只留生产代码。
///
/// 返回可直接按行扫描的文本（注释已清、字符串保留）。
fn strip_test_blocks(src: &str) -> String {
    let (structure, scan) = mask(src);
    let m = structure.as_bytes();
    let n = m.len();
    let mut out = scan.as_bytes().to_vec();
    let mut search = 0usize;
    while let Some(off) = structure[search..].find("#[cfg(test)]") {
        let start = search + off;
        search = start + 12;
        let Some(brace_off) = structure[start..].find('{') else {
            continue;
        };
        let mut depth = 0i32;
        let mut j = start + brace_off;
        while j < n {
            match m[j] {
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                _ => {}
            }
            j += 1;
        }
        for k in start..j.min(n) {
            if out[k] != b'\n' {
                out[k] = b' ';
            }
        }
    }
    String::from_utf8(out).expect("剔除测试块后仍应为合法 UTF-8")
}
