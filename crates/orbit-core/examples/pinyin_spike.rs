//! pinyin_spike — 拼音/首字母搜索技术验证探针（F5 spike，docs/13 §五 F5）
//!
//! **只读技术验证，非产品代码**：对 docs/13 的三条硬门限实测——
//! ① 10k 条中文标题回填（全拼 + 首字母）< 2s；
//! ② 索引磁盘 < 5MB（全拼串 + 首字母串的字节量近似）；
//! ③ 首字母查询 p95 < 100ms（线性扫描口径，正式方案走 FTS 合并只会更快）。
//! ④ crate 侧门限（MIT/342KB/零依赖/活跃维护）已在立项前人工核实。
//!
//! 运行：`cargo run -p orbit-core --example pinyin_spike --release`
//! 结论：见 docs/13 §五 F5 的落地记录（达标 → 正式立项才把 pinyin 转
//! [dependencies]；不达标 → 移除本探针与 dev-dependency）。

use std::time::Instant;

use pinyin::ToPinyin;

/// 常用汉字样本（待办高频 160 字，覆盖多音字：了/行/重/发/长/会/得/着…）
const COMMON: &str = "的了在是我有和人个时上去一来去说大到地你出要会着看行里后自小点心好先重再次前几天所发成本动方干事想生得分下把还过面老从年正将用手又如同经向问但很外没与当便起家它果开明只场实学习情义都道现使间让由位通名其中长问气业务被部定两各交打美关真每给东比物命表水白儿常公办案青非原车马走听科强言天书文南和平月色计等需因变条反台们明力如二性平者西区体合者即直业向会议安排总结报告待办任务清单项目";

/// 确定性伪随机（LCG；spike 不引入 rand 依赖）
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0 >> 33
    }
}

fn rand_title(rng: &mut Lcg, chars: &[char]) -> String {
    let len = 2 + (rng.next() as usize) % 5; // 2–6 字
    (0..len)
        .map(|_| chars[(rng.next() as usize) % chars.len()])
        .collect()
}

fn main() {
    let chars: Vec<char> = COMMON
        .chars()
        .filter(|c| !c.is_whitespace() && c.is_alphabetic() || (*c as u32) >= 0x4E00)
        .collect();
    // 种子取固定日期，保证样本可复现（按 3 位分组以免 clippy 判不一致）
    let mut rng = Lcg(20_261_024);

    // 10k 中文标题
    let titles: Vec<String> = (0..10_000).map(|_| rand_title(&mut rng, &chars)).collect();

    // ① 回填：全拼（无声调）+ 首字母
    let t0 = Instant::now();
    let mut index: Vec<(usize, String, String)> = Vec::with_capacity(titles.len());
    for (i, title) in titles.iter().enumerate() {
        let mut full = String::with_capacity(title.len() * 6);
        let mut initials = String::with_capacity(title.len());
        // to_pinyin 逐字符产出（与 chars 等长对齐）：None = 非汉字原样保留
        //（0.11 的 ToPinyin 只为 &str 实现，String 需 as_str 转发）
        for (orig, p) in title.chars().zip(title.as_str().to_pinyin()) {
            match p {
                Some(p) => {
                    full.push_str(p.plain());
                    // 首字母 = 全拼串首字符（0.11 的 Pinyin::first_letter 需要
                    // with_tone_num_end 之外的 feature 组合，plain[0..1] 等价）
                    initials.push(p.plain().chars().next().unwrap_or(' '));
                }
                None => {
                    full.push(orig);
                    initials.push(orig);
                }
            }
        }
        index.push((i, full.to_lowercase(), initials.to_lowercase()));
    }
    let backfill = t0.elapsed();

    // ② 索引大小（全拼串 + 首字母串字节数近似磁盘占用）
    let bytes: usize = index.iter().map(|(_, f, ini)| f.len() + ini.len()).sum();

    // ③ 查询 p95：随机 100 个首字母查询（1–3 字母），线性扫描计数命中
    let mut queries: Vec<String> = Vec::with_capacity(100);
    for _ in 0..100 {
        let len = 1 + (rng.next() as usize) % 3;
        let q: String = (0..len)
            .map(|_| (b'a' + (rng.next() as u8) % 26) as char)
            .collect();
        queries.push(q);
    }
    let mut hits_total = 0usize;
    let mut latencies: Vec<u128> = Vec::with_capacity(queries.len());
    for q in &queries {
        let t = Instant::now();
        let mut hits = 0usize;
        for (_, full, initials) in &index {
            if initials.starts_with(q.as_str()) || full.contains(q.as_str()) {
                hits += 1;
            }
        }
        latencies.push(t.elapsed().as_micros());
        hits_total += hits;
    }
    latencies.sort();
    let p95 = latencies[latencies.len() * 95 / 100];
    let p50 = latencies[latencies.len() / 2];

    println!("=== F5 拼音 spike（10k 中文标题，确定性样本） ===");
    println!("① 回填耗时           : {:?}", backfill);
    println!(
        "② 索引字节量（近似） : {} bytes（{} MB）",
        bytes,
        bytes / 1024 / 1024
    );
    println!(
        "③ 首字母查询 p50/p95 : {} / {} μs（线性扫描，命中 {} 条）",
        p50, p95, hits_total
    );
    println!("样例（前 3 条）       :");
    for (i, title) in titles.iter().take(3).enumerate() {
        println!(
            "  {:?} → full={:?} initials={:?}",
            title, index[i].1, index[i].2
        );
    }

    // 门限判定（docs/13 §五 F5）
    let ok_backfill = backfill.as_millis() < 2_000;
    let ok_disk = bytes < 5 * 1024 * 1024;
    let ok_query = p95 < 100_000; // 100ms = 100_000 μs
    println!(
        "门限：回填<2s {} ｜ 索引<5MB {} ｜ p95<100ms {}",
        if ok_backfill { "✓" } else { "✗" },
        if ok_disk { "✓" } else { "✗" },
        if ok_query { "✓" } else { "✗" }
    );
    if ok_backfill && ok_disk && ok_query {
        println!("结论：三门限全过 → 可正式立项（search_pinyin 表 + 写路径维护）");
    } else {
        println!("结论：存在未达标项 → 维持 FTS 现状，不做");
    }
}
