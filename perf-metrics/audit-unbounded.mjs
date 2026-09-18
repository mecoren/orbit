/**
 * audit-unbounded.mjs — 常驻无界结构静态审计（零依赖，CI 可跑）
 *
 * 口径（AGENTS.md「内存口径」节 + 方案 §1.2）：进程生命周期内可达的累加容器
 * 必须满足三之一，并在声明行 ±3 行内写标记注释：
 *   // bounded: <上界> <淘汰策略>
 *   // bounded-by-lifecycle: <何时整体清空>
 *   // bounded-by-data: <数据来源天然有界>
 * 标记是唯一的豁免机制——没有第二份 allowlist，豁免理由与代码同处，改动时不会被漏掉。
 *
 * 只做正则不做 AST：本仓库不需要精确的借用分析，需要的是「新增一处常驻集合时
 * 有人在 CI 上被问一句」。已知误报面见各规则注释，误报用标记澄清即可。
 *
 * 棘轮（ratchet）：baselines.json#knownUnbounded 登记「已知待修」的违例
 * （按 file + rule 聚合计数），计数不增即通过；修掉后记得同步下调登记，
 * 登记归零是本文件的历史目标。
 *
 * 用法：
 *   node perf-metrics/audit-unbounded.mjs            # 打印违例，恒 exit 0
 *   node perf-metrics/audit-unbounded.mjs --gate     # 出现未登记/超量违例 exit 1
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BASELINES = path.join(ROOT, 'perf-metrics', 'baselines.json');
const GATE = process.argv.slice(2).includes('--gate');
const MARKER_WINDOW = 3;

/** 扫描范围：Rust 核心与双端壳的源码目录（生成物与迁移 DDL 不在内） */
const SCOPE = [
  { dir: 'crates/orbit-core/src', lang: 'rust' },
  { dir: 'crates/orbit-flutter/src', lang: 'rust', skip: ['frb_generated.rs'] },
  { dir: 'apps/desktop/src', lang: 'ts', skip: [] },
  { dir: 'apps/desktop/src-tauri/src', lang: 'rust', skip: [] },
];

const COLLECTION_TY = String.raw`(?:Vec|VecDeque|HashMap|HashSet|BTreeMap|BTreeSet|LinkedList)`;

/**
 * 规则表：每条一个 name + 命中正则 + 该规则的「已限流证据」（同窗口内出现即视为已约束）
 * fetch_all 的 LIMIT 常在几十行外的 SQL 串里拼好，故窗口放大到 30。
 * blocking:false = 只报不拦（存量尚未逐个复核，见 sql-fetch-all 的说明）。
 */
const RULES = [
  {
    name: 'rust-static-collection',
    lang: 'rust',
    re: new RegExp(String.raw`^\s*(?:pub\s+)?static\s+\w+.*${COLLECTION_TY}\s*<`, 'i'),
    evidence: null,
    window: MARKER_WINDOW,
    blocking: true,
  },
  {
    // 覆盖被 Arc/Rc 共享的长生命周期结构体字段（如 WebDAV 适配器的 dir_cache）
    name: 'rust-shared-collection',
    lang: 'rust',
    re: new RegExp(String.raw`\b(?:Mutex|RwLock)\s*<\s*${COLLECTION_TY}\s*<`, 'i'),
    evidence: null,
    window: MARKER_WINDOW,
    blocking: true,
  },
  {
    // 模块作用域（第 0 列）的 Map/Set：跨组件卸载存活，等价于 Rust 侧的 static
    name: 'ts-module-collection',
    lang: 'ts',
    re: /^(?:const|let)\s+\w+\s*=\s*new\s+(?:Map|Set)\b/,
    evidence: null,
    window: MARKER_WINDOW,
    blocking: true,
  },
  {
    // 存量 19 个文件尚未逐个复核（多数是按日期区间/小基数表读的天然有界集），
    // 故先只报不拦；A6 回收站分页落地后连同复核结论一起翻正为 blocking。
    name: 'sql-fetch-all',
    lang: 'rust',
    re: /\.fetch_all\s*\(/i,
    evidence: /\bLIMIT\b|\.bind\(\s*(?:\w+\.)?(?:page_size|limit|max)/i,
    window: 30,
    blocking: false,
  },
];

const MARKER_RE = /bounded(?:-by-lifecycle|-by-data)?:/i;
const EXT = { rust: ['.rs'], ts: ['.ts', '.tsx'] };

function* walk(dir, skip) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'target' || entry.name === 'node_modules' || entry.name === 'dist') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full, skip);
    else if (!skip.includes(entry.name)) yield full;
  }
}

function hasMarker(lines, idx, window, evidence) {
  const from = Math.max(0, idx - window);
  const to = Math.min(lines.length - 1, idx + window);
  const slice = lines.slice(from, to + 1);
  if (slice.some((l) => MARKER_RE.test(l))) return true;
  return !!evidence && slice.some((l) => evidence.test(l));
}

/**
 * 测试模块内的记录型 Mock 集合不算常驻（进程随测试结束，且这些是 Fake/Mock 适配器）：
 * 见到 `#[cfg(test)]` + 紧随其后的 `mod xxx {` 即跳到文件尾。
 * 只认属性与 mod 同行或邻行两种写法——`#[cfg(test)] fn helper()` 不算测试模块，不能整段跳过。
 */
const TEST_ATTR_RE = /^\s*#\[cfg\(test\)\]/;
const MOD_RE = /^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+/;

function testModuleStart(lines) {
  for (let i = 0; i < lines.length; i++) {
    if (!TEST_ATTR_RE.test(lines[i])) continue;
    for (let j = i + 1; j < lines.length; j++) {
      const l = lines[j].trim();
      if (!l || l.startsWith('#')) continue; // 属性/derive/doc 注释接着往下找
      // 属性后面紧跟 mod = 测试模块起始；紧跟 fn 等则不是，继续找下一个 #[cfg(test)]
      if (MOD_RE.test(l)) return i;
      break;
    }
  }
  return -1;
}

const violations = [];
for (const { dir, lang, skip = [] } of SCOPE) {
  const abs = path.join(ROOT, dir);
  if (!fs.existsSync(abs)) continue;
  for (const file of walk(abs, skip)) {
    if (!EXT[lang].some((e) => file.endsWith(e))) continue;
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
    const stopAt = lang === 'rust' ? testModuleStart(lines) : -1;
    const seenLines = new Set();
    for (let i = 0; i < lines.length; i++) {
      if (stopAt >= 0 && i >= stopAt) break;
      for (const rule of RULES) {
        // 文档/行注释里出现的类型名不是声明（如「使用 `Mutex<HashSet<String>>` 而非…」）
        if (/^\s*(?:\/\/|\/\*|\*)/.test(lines[i])) continue;
        if (rule.lang !== lang || !rule.re.test(lines[i])) continue;
        // 同一行只按最先命中的规则报一次（static 与 Mutex 双层命中是同一个结构）
        if (seenLines.has(i)) continue;
        seenLines.add(i);
        if (hasMarker(lines, i, rule.window, rule.evidence)) continue;
        violations.push({
          file: path.relative(ROOT, file).replaceAll('\\', '/'),
          line: i + 1,
          rule: rule.name,
          blocking: rule.blocking,
          code: lines[i].trim().slice(0, 80),
        });
      }
    }
  }
}

const cfg = JSON.parse(fs.readFileSync(BASELINES, 'utf8'));
const known = cfg.knownUnbounded ?? [];
const knownKey = (v) => `${v.file}|${v.rule}`;
const allowance = new Map(known.map((k) => [`${k.file}|${k.rule}`, k]));

// 按 (file, rule) 聚合后与登记的计数比：只许降不许升
const grouped = new Map();
for (const v of violations) {
  const key = knownKey(v);
  const g = grouped.get(key);
  if (g) g.items.push(v);
  else grouped.set(key, { key, file: v.file, rule: v.rule, blocking: v.blocking, items: [v] });
}

const unregistered = [];
const registered = [];
for (const g of grouped.values()) {
  const allowed = allowance.get(g.key);
  if (allowed && g.items.length <= allowed.count) registered.push({ ...g, note: allowed.note });
  else unregistered.push(g);
}

for (const g of unregistered) {
  console.log(`${g.blocking ? 'UNBOUNDED' : '提示     '} ${g.rule} ${g.file}`);
  for (const it of g.items) console.log(`  ${it.file}:${it.line}  ${it.code}`);
  console.log(
    g.blocking
      ? `  → 加 \`// bounded: <上界> <淘汰策略>\` 等标记，或按方案 §1.2 收敛该结构`
      : `  → 只报不拦（该规则 blocking:false）；确认有界后补 bounded 标记即从此消失`,
  );
}
for (const g of registered) {
  console.log(`已登记 ${g.rule} ${g.file} ×${g.items.length}（登记上限 ${allowance.get(g.key).count}）—— ${g.note}`);
}
const blockingGroups = unregistered.filter((g) => g.blocking);
console.log(
  `audit-unbounded: 命中 ${violations.length} 处 / ${grouped.size} 组（拦停违例 ${blockingGroups.length} 组，已登记 ${registered.filter((g) => g.blocking).length} 组，提示级 ${unregistered.length - blockingGroups.length} 组）`,
);

if (GATE && blockingGroups.length) {
  console.error('AUDIT_GATE_FAIL: 存在未登记的常驻无界结构');
  process.exit(1);
}
