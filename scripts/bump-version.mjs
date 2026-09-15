#!/usr/bin/env node
/**
 * 版本单一来源同步脚本 —— 升版与版本校验的唯一入口（流程见 docs/08_发布与更新流程.md）
 *
 * 用法：
 *   node scripts/bump-version.mjs 0.2.0    # 升版：以 apps/desktop/package.json 为源，同步全部清单
 *   node scripts/bump-version.mjs --check  # 只校验一致性（CI / vitest 护栏复用同一实现），零写入
 *
 * 数据源：apps/desktop/package.json#version —— 其余清单一律由本脚本写入，不要手改。
 * 前端不写死版本号：apps/desktop/vite.config.ts 构建期注入 __APP_VERSION__。
 *
 * 为什么连 Cargo.lock 一起改：两个 lock（根 workspace 与桌面壳嵌套 workspace）都记录本地包
 * 的版本行，版本号变了但 lock 没跟上时 `cargo --locked` 会直接报错——手工漏改的经典踩点。
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const ROOT = path.resolve(import.meta.dirname, "..");

/** 版本清单（相对仓库根路径）——顺序即输出顺序 */
const FILES = {
  source: "apps/desktop/package.json",
  tauriConf: "apps/desktop/src-tauri/tauri.conf.json",
  desktopCargo: "apps/desktop/src-tauri/Cargo.toml",
  rootCargo: "Cargo.toml",
  pubspec: "apps/mobile/pubspec.yaml",
};

/** lock 文件 + 各文件内需要同步版本的本地包名 */
const LOCKS = [
  { file: "Cargo.lock", packages: ["orbit-core", "orbit-flutter"] },
  { file: "apps/desktop/src-tauri/Cargo.lock", packages: ["orbit-desktop"] },
];

const SEMVER = /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/;

const read = (rel) => readFileSync(path.join(ROOT, rel), "utf8");
const write = (rel, text) => writeFileSync(path.join(ROOT, rel), text);

/** 读取指定 Cargo.toml 段落内的 version 字段（段落外的 dependencies 版本不受影响） */
function readCargoVersion(text, section) {
  let inSection = false;
  for (const line of text.split(/\r?\n/)) {
    if (line.startsWith("[")) inSection = line.trim() === section;
    else if (inSection) {
      const m = /^version\s*=\s*"([^"]+)"/.exec(line);
      if (m) return m[1];
    }
  }
  return null;
}

/** 替换指定 Cargo.toml 段落内的 version 字段，保持其余内容逐字节不变 */
function writeCargoVersion(text, section, version) {
  const eol = text.includes("\r\n") ? "\r\n" : "\n";
  const lines = text.split(/\r?\n/);
  let inSection = false;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith("[")) inSection = lines[i].trim() === section;
    else if (inSection && /^version\s*=/.test(lines[i])) {
      lines[i] = `version = "${version}"`;
      return lines.join(eol);
    }
  }
  throw new Error(`未在 ${section} 段落内找到 version 字段`);
}

/** Cargo.lock 内本地包的版本行（lock 由 cargo 生成，此处只改已存在的行，不新增条目） */
function readLockVersion(text, pkg) {
  const m = new RegExp(`\\[\\[package\\]\\]\\r?\\nname = "${pkg}"\\r?\\nversion = "([^"]+)"`).exec(text);
  return m ? m[1] : null;
}

function writeLockVersion(text, pkg, version) {
  return text.replace(
    new RegExp(`(\\[\\[package\\]\\]\\r?\\nname = "${pkg}"\\r?\\nversion = ")[^"]+(")`),
    `$1${version}$2`,
  );
}

/** pubspec.yaml 的 `version: x.y.z+build`（Flutter 的 build 号每次发版必须递增） */
function readPubspecVersion(text) {
  const m = /^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/m.exec(text);
  return m ? { version: m[1], build: Number(m[2]) } : null;
}

function writePubspecVersion(text, version, build) {
  return text.replace(/^version:\s*\d+\.\d+\.\d+\+\d+\s*$/m, `version: ${version}+${build}`);
}

/** 汇总五处清单 + 两个 lock 的实际版本，供 --check 与升版后复核共用 */
function collectVersions() {
  const tauriConf = JSON.parse(read(FILES.tauriConf));
  const desktopCargo = read(FILES.desktopCargo);
  const rootCargo = read(FILES.rootCargo);
  const pubspec = readPubspecVersion(read(FILES.pubspec));

  const rows = [
    { label: "apps/desktop/package.json（源）", version: JSON.parse(read(FILES.source)).version },
    { label: "src-tauri/tauri.conf.json", version: tauriConf.version },
    {
      label: "src-tauri/Cargo.toml [package]",
      version: readCargoVersion(desktopCargo, "[package]"),
    },
    { label: "Cargo.toml [workspace.package]", version: readCargoVersion(rootCargo, "[workspace.package]") },
    { label: "apps/mobile/pubspec.yaml", version: pubspec?.version ?? null, build: pubspec?.build ?? null },
  ];

  const locks = LOCKS.map((lock) => {
    const text = read(lock.file);
    return {
      label: lock.file,
      versions: lock.packages.map((pkg) => ({ pkg, version: readLockVersion(text, pkg) })),
    };
  });

  return { rows, locks };
}

/** 校验：全部清单与源版本一致、pubspec build 号存在于 lock/清单、返回不一致项列表 */
function check() {
  const { rows, locks } = collectVersions();
  const source = rows[0].version;
  const problems = [];

  for (const row of rows.slice(1)) {
    if (row.version !== source) {
      problems.push(`${row.label}: ${row.version ?? "未找到"} ≠ ${source}`);
    }
  }

  for (const lock of locks) {
    for (const entry of lock.versions) {
      if (entry.version !== source) {
        problems.push(`${lock.label} [${entry.pkg}]: ${entry.version ?? "未找到"} ≠ ${source}`);
      }
    }
  }

  for (const row of rows) {
    console.log(`  ${row.version === source ? "ok  " : "DIFF"} ${row.label}: ${row.version ?? "未找到"}`);
  }
  for (const lock of locks) {
    for (const entry of lock.versions) {
      const ok = entry.version === source;
      console.log(`  ${ok ? "ok  " : "DIFF"} ${lock.label} [${entry.pkg}]: ${entry.version ?? "未找到"}`);
    }
  }

  return { source, problems };
}

/** 升版：写源与全部清单（pubspec build 号自增） */
function bump(next) {
  const pubspecText = read(FILES.pubspec);
  const pubspec = readPubspecVersion(pubspecText);
  const nextBuild = (pubspec?.build ?? 0) + 1;

  const pkg = JSON.parse(read(FILES.source));
  pkg.version = next;
  write(FILES.source, `${JSON.stringify(pkg, null, 2)}\n`);

  const conf = JSON.parse(read(FILES.tauriConf));
  conf.version = next;
  write(FILES.tauriConf, `${JSON.stringify(conf, null, 2)}\n`);

  write(FILES.desktopCargo, writeCargoVersion(read(FILES.desktopCargo), "[package]", next));
  write(FILES.rootCargo, writeCargoVersion(read(FILES.rootCargo), "[workspace.package]", next));
  write(FILES.pubspec, writePubspecVersion(pubspecText, next, nextBuild));

  for (const lock of LOCKS) {
    let text = read(lock.file);
    for (const pkgName of lock.packages) {
      if (readLockVersion(text, pkgName) !== null) {
        text = writeLockVersion(text, pkgName, next);
      }
    }
    write(lock.file, text);
  }

  console.log(`\nbump ${next}（pubspec build → ${nextBuild}）后复核：`);
  const { problems } = check();
  return problems;
}

function printChecklist(version) {
  console.log(`
下一步（发版清单，详见 docs/08_发布与更新流程.md）：
  1. 从上一 tag 起提炼变更：git log v<prev>..HEAD --oneline（忽略 docs/chore/style 噪声）
  2. 两份更新日志同一次提交写完：
     - CHANGELOG.md：把 [Unreleased] 段改为 ## [${version}] - YYYY-MM-DD
     - apps/desktop/src/lib/changelog.ts：CHANGELOG_VERSIONS 头部插 ${version}（应用内「关于」数据源）
  3. 本地跑通 CI 等价检查：pnpm typecheck / pnpm test / pnpm e2e
     + pnpm lint:rust（cargo fmt --check + clippy）
  4. 提交：git commit -m "chore(release): 版本 ${version}"；打 tag 并推送：git tag v${version} && git push origin main --tags
  5. tag 推送即触发 Release 流水线（先跑 workflow_dispatch dry_run 可只构建不发布）
  6. Release 完成后校验：latest.json 可访问、各资产 200、应用内「关于与更新 → 检查更新」端到端验证
`);
}

function main() {
  const arg = process.argv[2];

  if (!arg || arg === "-h" || arg === "--help") {
    console.log(`用法：
  node scripts/bump-version.mjs <x.y.z>   升版并同步全部清单
  node scripts/bump-version.mjs --check   只校验一致性（零写入）`);
    process.exit(arg ? 0 : 1);
  }

  if (arg === "--check") {
    console.log("版本一致性校验：");
    const { source, problems } = check();
    if (problems.length > 0) {
      console.error(`\nVERSION_MISMATCH（源 ${source}）：\n  - ${problems.join("\n  - ")}`);
      console.error("\n修复：node scripts/bump-version.mjs <源版本> 或手工补齐差异项。");
      process.exit(1);
    }
    console.log(`\nVERSION_SYNC_OK: ${source}`);
    return;
  }

  if (!SEMVER.test(arg)) {
    console.error(`ERROR: 非法版本号 ${arg}（期望 MAJOR.MINOR.PATCH，如 0.2.0 或 1.0.0-rc.1）`);
    process.exit(1);
  }

  const problems = bump(arg);
  if (problems.length > 0) {
    console.error(`VERSION_MISMATCH（写入后复核失败）：\n  - ${problems.join("\n  - ")}`);
    process.exit(1);
  }
  printChecklist(arg);
}

main();
