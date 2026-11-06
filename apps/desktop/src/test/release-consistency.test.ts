/**
 * 发版一致性护栏（流程见 docs/08_发布与更新流程.md）
 *
 * 守四件事：
 * 1. 版本号清单必须全部等于唯一数据源 `apps/desktop/package.json#version`
 *    —— 含两个 Cargo.lock 的本地包版本行（漏改会让 `cargo --locked` 直接失败）；
 * 2. 应用内更新日志头部条目 = 当前版本
 *    —— 数据源在 `crates/orbit-core/src/models/changelog/data.rs`（双端共用），
 *    只写 CHANGELOG.md 漏写它会让关于页永久缺失该版本（qraft 0.2.7 教训）；
 * 3. 仓库 `CHANGELOG.md` 存在当前版本的归档段（发版时两份日志同一次提交写完）；
 * 4. 更新日志头部日期为 YYYY-MM-DD，防手滑写成其它格式。
 *
 * 此处刻意不复用 scripts/bump-version.mjs 的实现：独立重读文件才能真正交叉验证脚本，
 * 复用同一份解析代码等于自证。Rust 数据文件用最小正则读取，不引 Rust 工具链。
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const DESKTOP = path.resolve(import.meta.dirname, "../..");
const ROOT = path.resolve(DESKTOP, "../..");
const RUST_CHANGELOG = path.join(ROOT, "crates/orbit-core/src/models/changelog/data.rs");

const read = (abs: string) => readFileSync(abs, "utf8");

/** 取 Cargo.toml 指定段落内的 version（段落外是依赖版本，不能顺手匹配到） */
function cargoSectionVersion(text: string, section: string): string | null {
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

/** 取 Cargo.lock 内本地包的版本行 */
function lockVersion(text: string, pkg: string): string | null {
  const m = new RegExp(`\\[\\[package\\]\\]\\r?\\nname = "${pkg}"\\r?\\nversion = "([^"]+)"`).exec(text);
  return m ? m[1] : null;
}

/** 取 Rust 更新日志数据文件的首条 `vec![v("x.y.z","YYYY-MM-DD", …)` */
function rustChangelogHead(text: string): { version: string; date: string } | null {
  const m = /vec!\[v\(\s*"([^"]+)",\s*"([^"]+)"/.exec(text);
  return m ? { version: m[1], date: m[2] } : null;
}

describe("发版一致性", () => {
  const sourceVersion = JSON.parse(read(path.join(DESKTOP, "package.json"))).version as string;

  it("数据源本身是合法 semver", () => {
    expect(sourceVersion).toMatch(/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/);
  });

  it("tauri.conf.json 与源一致（打包与 latest.json 取此值）", () => {
    const conf = JSON.parse(read(path.join(DESKTOP, "src-tauri/tauri.conf.json")));
    expect(conf.version).toBe(sourceVersion);
  });

  it("desktop 壳 Cargo.toml 与源一致（CARGO_PKG_VERSION → 应用内版本/更新检查）", () => {
    const version = cargoSectionVersion(read(path.join(DESKTOP, "src-tauri/Cargo.toml")), "[package]");
    expect(version).toBe(sourceVersion);
  });

  it("根 Cargo.toml workspace.package 与源一致（orbit-core / orbit-flutter）", () => {
    const version = cargoSectionVersion(read(path.join(ROOT, "Cargo.toml")), "[workspace.package]");
    expect(version).toBe(sourceVersion);
  });

  it("移动端 pubspec.yaml 与源一致（+build 号每次发版自增）", () => {
    const m = /^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/m.exec(
      read(path.join(ROOT, "apps/mobile/pubspec.yaml")),
    );
    expect(m, "pubspec.yaml 应形如 version: x.y.z+build").not.toBeNull();
    expect(m?.[1]).toBe(sourceVersion);
    expect(Number(m?.[2])).toBeGreaterThan(0);
  });

  it("两个 Cargo.lock 的本地包版本行与源一致", () => {
    expect(lockVersion(read(path.join(ROOT, "Cargo.lock")), "orbit-core")).toBe(sourceVersion);
    expect(lockVersion(read(path.join(ROOT, "Cargo.lock")), "orbit-flutter")).toBe(sourceVersion);
    expect(lockVersion(read(path.join(DESKTOP, "src-tauri/Cargo.lock")), "orbit")).toBe(
      sourceVersion,
    );
  });

  it("应用内更新日志头部条目 = 当前版本（Rust 数据源，发版时两处日志同一次提交写完）", () => {
    const head = rustChangelogHead(read(RUST_CHANGELOG));
    expect(head, "应能在 data.rs 中解析出首条 vec![v(...)]").not.toBeNull();
    expect(head?.version).toBe(sourceVersion);
    expect(head?.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it("仓库 CHANGELOG.md 存在当前版本的归档段（about 日志与仓库记录不漂移）", () => {
    expect(read(path.join(ROOT, "CHANGELOG.md"))).toContain(`## [${sourceVersion}]`);
  });
});
