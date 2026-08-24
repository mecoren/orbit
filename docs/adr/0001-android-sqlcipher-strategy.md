# ADR 0001 — Android SQLCipher 启用策略（风险 R1 技术验证）

- **状态**：已采纳（Accepted）
- **日期**：2026-08-24
- **关联**：M4 Task 3 / 06 文档 §三 风险 R1；实验依据 docs/superpowers/plans/2026-08-24-m4-mobile.md「Task 3」

## 一、背景

### 1.1 风险原文（06 文档 §三 风险表 R1）

> **Android 无 SQLCipher**：wait-home 中 libsqlite3-sys 的 sqlcipher feature 明确排除 Android 目标（移动端走 FRB 时另有处理）。新项目 Android 端加密策略未验证。影响：**高：M4 数据层阻塞**。缓解：4.1 spike 先行。候选：sqlcipher-android 系统库接入 / net.zetetic:sqlcipher-android AAR / Android Keystore + 明文库降级（需在隐私承诺上让步，最后手段）。

### 1.2 现状明文事实（实验前基线）

`orbit_core/Cargo.toml:62-63` 以 `cfg(not(target_os = "android"))` 仅给非 Android 目标注入 `libsqlite3-sys` 的 `bundled-sqlcipher-vendored-openssl` 特性；Android 目标只从 workspace 依赖获得 `bundled`（明文 SQLite）。因此：

- `orbit_core/src/db/pool.rs` 中 `init_pool` 的 `PRAGMA key` 在 Android 上**无加密语义**（底层不是 SQLCipher，PRAGMA key 被忽略），`db_init_encrypted` 实际打开的是明文库；
- 移动端 `KeyringCekProvider::get_or_create()` 恒返 `CekUnavailable`（src-tauri/src/commands/sync_runtime.rs:160-165），`config_enc` 注册表走"加密优先、明文降级"路径 → `sync_config.json` 与 `full_sync_backup_prefs.json` 均落**明文 JSON**；
- `master_auth.json` 不受影响：v2 格式下 DB Key 经主密码 PBKDF2(600k) 派生密钥包裹，密钥材料本身不落明文。

## 二、实验 A 记录 —— Android 启用 vendored SQLCipher 交叉构建

**环境**：Windows 11 + PowerShell 5.1；rustc/cargo 1.96.0；NDK 29.0.13846066（目标 `aarch64-linux-android24`）；openssl-src 300.6.1+3.6.3（由 libsqlite3-sys 0.30 传递引入）；JDK 21；perl Strawberry 5.42.2 (MSWin32-x64-multi-thread)。

**改动**（临时）：在 `orbit_core/Cargo.toml` 增加 Android 目标段，features 与桌面端完全一致：

```toml
[target.'cfg(target_os = "android")'.dependencies]
libsqlite3-sys = { version = "0.30", features = ["bundled-sqlcipher-vendored-openssl"] }
```

**命令**：

```powershell
pnpm tauri android build --target aarch64 --debug
```

### 第 1 次（默认 Strawberry perl）——失败于 OpenSSL Configure

```
running "perl" "./Configure" ... "no-shared" ... "linux-aarch64" "--target=aarch64-linux-android24" ...
Configuring OpenSSL version 3.6.3 for target linux-aarch64
cargo:warning=configuring OpenSSL build: 'perl' reported failure with exit code: 255
--- stderr
Failure!  Makefile wasn't produced.
This perl implementation doesn't produce Unix like paths (with forward slash
directory separators).  Please use an implementation that matches your
building platform.
This Perl version: 5.42.2 for MSWin32-x64-multi-thread
```

根因：OpenSSL 对 unix 类目标（`linux-aarch64`）要求产生 Unix 路径的 perl；Strawberry perl 为 MSWin32 原生实现，被 Configure 直接拒绝。

### 第 2 次（`OPENSSL_SRC_PERL` 指向 Git 自带 msys perl）——仍失败于 Configure

设置 `OPENSSL_SRC_PERL="C:\Program Files\Git\usr\bin\perl.exe"` 并前置 PATH 后重跑：

```
Can't locate Locale/Maketext/Simple.pm in @INC ...
BEGIN failed--compilation aborted at ./Configure line 23.
cargo:warning=configuring OpenSSL build: '...\perl.exe' reported failure with exit code: 2
```

根因：Git for Windows 自带 perl 是精简发行版，缺 OpenSSL Configure 必需的核心模块。

### 结构性阻塞（源码级证据）

即使 perl 可修复，openssl-src 300.6.1 的 `cmd_make()` 在 Windows 宿主下无条件调用 GNU `make`（非 BSD 宿主不走 nmake 分支），而本机全盘检索无任何 `make.exe`（Git usr/bin 含 sh/bash 但不含 make；WSL 仅有 docker-desktop 发行版）。即：**Windows 宿主 × openssl-src vendored × 非 Windows 目标**的组合需要完整的 Unix 构建环境（Unix-path perl + GNU make + sh 工具链），本机不具备，时间盒内补齐超出 spike 范围。

### 结果

**实验 A 失败**。构建在 ~2 分钟内于 Configure 阶段失败两次（未进入 OpenSSL 编译阶段，未触发 25 分钟时间盒上限）。已执行 `git checkout -- orbit_core/Cargo.toml` 完整恢复原状；恢复后 `cargo check --workspace` 通过（桌面行为不变）。

## 三、实验 B 记录 —— 替代方案评估（文档级分析）

### B1. libsqlite3-sys 特性变体（如仅 `bundled-sqlcipher`、去掉 vendored-openssl）

**结论：不可行（本机）/ 无收益。** `bundled-sqlcipher` 编译 SQLCipher 源码但仍链接系统 OpenSSL libcrypto——Android NDK 不提供 OpenSSL，`openssl-sys` 将退回 pkg-config/`OPENSSL_DIR` 查找并失败。要让它成立，必须先自行交叉编译出 aarch64-linux-android 的 libcrypto 静态库并用 `OPENSSL_DIR` 指认——工作量与维护成本不低于 vendored 方案，还引入自管产物的版本漂移风险。除非未来已有 CI 产物可复用，否则不值得单独尝试。

### B2. net.zetetic:sqlcipher-android AAR 经 JNI 接入

**结论：技术上可行但 MVP 否决。** 接入面评估：

- AAR 自带 `libsqlcipher.so` + Java/Kotlin 层（`SupportOpenHelperFactory` + passphrase API）。Rust 侧 sqlx 的整条链路——`SqliteConnectOptions`/连接池/运行时迁移（`sqlx::migrate!`）——全部建立在进程内 libsqlite3-sys C API 之上；换用 AAR 后该链路整体作废。
- 两条实现路线均重：① 放弃 sqlx，Rust 经 JNI 调 SQLiteDatabase——查询宏、类型映射、事务语义全部重写；② 绕过 Java 层直接 FFI 到 AAR 的 .so 符号做 PRAGMA key——官方未承诺 C ABI 兼容与符号可见性，属脆弱私有路径。
- 另需处理双 .so 冲突（AAR 的 sqlcipher 与 cargo 打入的明文 sqlite 并存）、Gradle 侧依赖注入、以及 M3 已验收的同步/备份流程回归。
- 工作量评级 L（>5 天）且高风险，与 M4 其余任务争夺关键路径带宽。**留作后续里程碑候选，不进 MVP。**

### B3. Android Keystore 包裹 DB Key + 明文库降级（最后手段）

**结论：采纳为 MVP 现状基线。** 即维持当前架构：

- DB 文件明文落盘（SQLCipher 缺失是既成事实）；`master_auth.json` v2 仍以主密码派生密钥包裹 DB Key，密钥材料不以明文出现（Keystore 包裹可作为后续生物识别解锁的增强项，见 biometric.rs 预留，不在本次范围）；
- 云同步域不受影响（见下节边界说明）。

## 四、决策与影响面

### 决策

**MVP 维持 Android 明文库降级（候选序第 3 位）**；`orbit_core/Cargo.toml` 保持现状（Android 排除 SQLCipher 特性），不合并实验 A 的临时改动。全端统一 SQLCipher 列为目标态，触发条件见回滚条件一节。

理由：在本机 Windows 宿主工具链上，实验 A 被 openssl-src 对 Unix 构建环境的硬性要求阻断（两轮实证 + 源码级确认），B1 无收益、B2 成本超 MVP 承受度；B3 是唯一零新增工作量且不伤云同步安全模型的选项。

### 影响面（隐私承诺让步清单——共三处明文落盘）

若决策为维持降级，隐私声明中"本地数据加密存储"的表述须明确覆盖以下三处（均位于应用数据目录）：

| # | 文件 | 内容 | 敏感度 |
|---|---|---|---|
| 1 | `orbit.db` | 全部待办业务数据 | 高 |
| 2 | `sync_config.json` | 同步引擎配置，**含 WebDAV/S3 凭据** | 高（敏感面最大） |
| 3 | `full_sync_backup_prefs.json` | 备份偏好与调度状态（路径/开关/时间戳） | 低 |

- **不在让步清单内**：`master_auth.json`（v2 包裹格式，DB Key 不落明文）、`sync_crypto_meta.json`（仅存包裹后的 Data Key）、`.orsync` 备份包（整体 AES-GCM 加密）。
- **云同步 E2E 承诺边界（不受影响，须说清）**：上行载荷先 zstd 压缩再经 Data Key AES-256-GCM 加密（OSZS 格式），WebDAV/S3 服务端只见密文；本地明文降级不改变云端零知识属性。桌面端三处文件维持原有加密行为，承诺不变。
- **威胁模型口径**：让步限于设备本地攻击面（设备丢失、root 提权后同应用目录读取）；不影响传输与云端机密性。

## 五、回滚条件（重试实验 A 的触发点）

满足任一条即在 Linux/macOS 宿主或 WSL2 完整发行版上重跑实验 A（命令与本 ADR 第二节相同）：

1. **构建宿主切换**：CI 采用 ubuntu-latest 出 Android 包，或本机建立 WSL2 完整开发发行版（含 make/perl/NDK）——openssl-src 在 Unix 宿主走原生 make 路径，两个 Configure 阻塞均不存在，成功概率最高；
2. **上游工具链演进**：openssl-src ≥ 当前版本发布对 Windows 宿主交叉编译的支持修复，或 libsqlite3-sys 升级改用其他加密后端；
3. **NDK 大版本变更**（如 29 → 30+）：API level / clang 行为变化时顺带重验；
4. **产品要求升级**：隐私承诺决定收紧为"五端一致本地加密"，届时按优先序重估 A → B2。

## 六、附：本次实验产物

- 实验日志：`%TEMP%\opencode\expA-android-build.log`、`expA-retry-build.log`（会话临时区，不入库）
- `git checkout -- orbit_core/Cargo.toml` 已恢复；恢复后 `cargo check --workspace` 通过
