#!/usr/bin/env node
/**
 * generate-android-keystore.mjs — 生成 Android 发布 keystore 与 key.properties
 *
 * 为什么需要固定 keystore：Android 只允许同签名的 APK 覆盖安装。若每次构建
 * 都用随机 debug keystore，跨版本升级会报 INSTALL_FAILED_UPDATE_INCOMPATIBLE；
 * 本项目 release 构建在缺 key.properties 时直接失败（build.gradle.kts）。
 *
 * 用法：
 *   pnpm keystore:android
 *   pnpm keystore:android --alias orbit --force
 *   pnpm keystore:android --help
 *
 * 生成后把 keystore 与密码离线备份；丢失 keystore 等价于所有存量用户必须卸载
 * 重装（应用数据随之丢失）。
 */
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ANDROID_DIR = path.join(ROOT, "apps", "mobile", "android");
// 签名物料集中放在用户目录，避免误提交；keystore 丢失 = 存量用户卸载重装
const DEFAULT_KEYSTORE = path.join(homedir(), ".orbit", "orbit-release.keystore");
const KEY_PROPERTIES = path.join(ANDROID_DIR, "key.properties");
const DEFAULT_DNAME = "CN=Orbit, OU=Orbit, O=Orbit, L=Local, ST=Local, C=CN";

function usage() {
  console.log(`用法：pnpm keystore:android [选项]

选项：
  --output <path>           keystore 输出路径，相对仓库根或绝对路径（默认 ~/.orbit/orbit-release.keystore）
  --alias <name>            key alias（默认 orbit）
  --store-password <pass>   keystore 密码（默认随机生成并打印）
  --key-password <pass>     key 密码；PKCS12 要求与 store 密码一致
  --dname <name>            X.500 名称（默认 ${DEFAULT_DNAME}）
  --validity <days>         有效期天数（默认 10000，约 27 年）
  --force                   覆盖已存在的 keystore
  -h, --help                显示本帮助

生成后需要配置四个 GitHub Secrets：
  ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD`);
}

function parse(argv) {
  const out = { alias: "orbit", validity: "10000", force: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const value = argv[++i];
      if (value == null || value.startsWith("--")) {
        throw new Error(`${arg} 需要一个值`);
      }
      return value;
    };
    switch (arg) {
      case "-h":
      case "--help":
        out.help = true;
        break;
      case "--":
        // pnpm/npm 的 `--` 分隔符可能被原样透传，忽略
        break;
      case "--output":
        out.output = next();
        break;
      case "--alias":
        out.alias = next();
        break;
      case "--store-password":
        out.storePassword = next();
        break;
      case "--key-password":
        out.keyPassword = next();
        break;
      case "--dname":
        out.dname = next();
        break;
      case "--validity":
        out.validity = next();
        break;
      case "--force":
        out.force = true;
        break;
      default:
        throw new Error(`未知参数：${arg}（--help 查看用法）`);
    }
  }
  return out;
}

/** 优先使用 JAVA_HOME 下的 keytool，避免 Windows 上 PATH 未配置 JDK。 */
function resolveKeytool() {
  if (process.env.KEYTOOL) return process.env.KEYTOOL;
  if (process.env.JAVA_HOME) {
    const name = process.platform === "win32" ? "keytool.exe" : "keytool";
    const candidate = path.join(process.env.JAVA_HOME, "bin", name);
    if (existsSync(candidate)) return candidate;
  }
  return "keytool";
}

function main() {
  let opts;
  try {
    opts = parse(process.argv.slice(2));
  } catch (e) {
    console.error(`[keystore] ${e.message}`);
    process.exit(2);
  }
  if (opts.help) {
    usage();
    return;
  }

  const output = path.resolve(ROOT, opts.output ?? DEFAULT_KEYSTORE);
  if (existsSync(output) && !opts.force) {
    console.error(`[keystore] 已存在：${output}`);
    console.error("[keystore] 覆盖会改变签名，导致存量用户无法覆盖安装；确认要重建请加 --force。");
    process.exit(1);
  }

  const storePassword = opts.storePassword ?? randomBytes(18).toString("base64url");
  const keyPassword = opts.keyPassword ?? storePassword;
  if (keyPassword !== storePassword) {
    // Java 9+ 默认 PKCS12：key 密码必须与 store 密码一致，否则 key.properties 里的
    // keyPassword 会与实际签名密码不符，Gradle 签包直接失败。
    console.error("[keystore] PKCS12 keystore 要求 key 密码与 store 密码一致。");
    process.exit(2);
  }
  const keytool = resolveKeytool();

  mkdirSync(path.dirname(output), { recursive: true });
  try {
    execFileSync(
      keytool,
      [
        "-genkeypair",
        "-v",
        "-keystore",
        output,
        "-alias",
        opts.alias,
        "-keyalg",
        "RSA",
        "-keysize",
        "2048",
        "-validity",
        opts.validity,
        "-storepass",
        storePassword,
        "-keypass",
        keyPassword,
        "-dname",
        opts.dname ?? DEFAULT_DNAME,
      ],
      { stdio: "inherit" },
    );
  } catch (e) {
    console.error("\n[keystore] keytool 执行失败。");
    console.error("[keystore] 确认已安装 JDK 17+，或设置 JAVA_HOME / KEYTOOL 指向 keytool。");
    process.exit(1);
  }

  // storeFile 相对 apps/mobile/android/（build.gradle.kts 的 rootProject.file 基准）；
  // 输出在 android/ 之外（如用户目录 .orbit）时写绝对路径，避免一长串 ../
  const relative = path.relative(ANDROID_DIR, output);
  const storeFile = (relative.startsWith("..") ? output : relative).split(path.sep).join("/");
  writeFileSync(
    KEY_PROPERTIES,
    [
      "# 由 pnpm keystore:android 生成；本文件与 keystore 均不得入库。",
      `storeFile=${storeFile}`,
      `storePassword=${storePassword}`,
      `keyAlias=${opts.alias}`,
      `keyPassword=${keyPassword}`,
      "",
    ].join("\n"),
    { mode: 0o600 },
  );

  console.log("\n[keystore] 已生成：");
  console.log(`  keystore:       ${output}`);
  console.log(`  key.properties: ${KEY_PROPERTIES}`);
  console.log(`  alias:          ${opts.alias}`);
  console.log(`  storePassword:  ${storePassword}`);
  console.log(`  keyPassword:    ${keyPassword}`);
  console.log("\n[keystore] 立刻离线备份 keystore 与两个密码——丢失后存量用户只能卸载重装。");
  console.log("[keystore] 配置 GitHub Secrets（四个）：");
  console.log("  ANDROID_KEYSTORE_BASE64     keystore 的 base64");
  console.log(`  ANDROID_KEYSTORE_PASSWORD   ${storePassword}`);
  console.log(`  ANDROID_KEY_ALIAS           ${opts.alias}`);
  console.log(`  ANDROID_KEY_PASSWORD        ${keyPassword}`);
  console.log("\n[keystore] 生成 base64（任选其一）：");
  console.log(
    `  PowerShell: [Convert]::ToBase64String([IO.File]::ReadAllBytes('${output}')) | Set-Clipboard`,
  );
  console.log(`  bash:       base64 -w0 '${output}'`);
}

main();
