# 设计文档：全量备份融合 + 复用同步密码 + 云端恢复

## 一、目标与范围

把「自动备份」与「手动全量备份」收敛为单一全量备份功能；导出/导入直接复用已解锁的同步密码；恢复可选本地或云端副本。`.orfullsync` 二进制格式零改动。

## 二、数据流设计

### 2.1 导出（单入口，origin 区分触发）

```text
前端设置卡片(合并后)
  ├─ 立即导出一份 ────────────► origin=Manual（不受开关约束，可带 upload_cloud）
  └─ 定时自动导(make) ────────► origin=Auto（受 backup_prefs.local/cloud 开关约束，
                                                由 scheduler 到点触发）
        │
        ▼
export_full_sync_backup(pool, app_data_dir, origin, cloud_config)
        │  前置: SyncCryptoService::is_unlocked()？ else 返回「请先解锁同步密码」
        │  key = svc.get_data_key()          # 复用已解锁派生密钥，不再手动 unlock/lock
        ▼
export_full_sync_backup_inner(同现状, EncodeParams 内密码换 key)
        │  云端阶段(cloud_enabled) → {base}/backups/{filename}.orfullsync
        │  本地阶段(local_enabled) → {backup_dir}/{filename}.orfullsync (+ keep_latest)
        ▼
ExportResult(同现状)
```

## 2.2 恢复（来源枚举，字节管线不变）

```text
恢复 UI
  ├─ 来源=本地 : 文件选择器 → path ──────────────► bytes = fs::read(path)
  └─ 来源=云端 : list_cloud_backups(adapter, base)
                  │ 展示副本列表（倒序）
                  └─ 选中 → download_cloud_backup(adapter, cloud_path) → bytes
                                                  │
                                                  ▼
import_full_sync_backup(pool, key, bytes, ignore_schema_mismatch)
  前置: is_unlocked() 校验；decode_backup 用已解锁 key
```

## 三、接口设计

### 3.1 core：`crates/orbit-core/src/api/full_sync_backup_api.rs`

```rust
/// 备份触发来源（融合后唯一入口按此分支开关约束）
pub enum BackupOrigin { Manual, Auto }

// 合并：回收 export_full_sync_backup / _with_cloud / _manual 三入口为：
pub async fn export_full_sync_backup(
    pool: &SqlitePool,
    app_data_dir: &Path,
    origin: BackupOrigin,
    cloud_config: Option<EngineSyncConfig>,   // Manual 带 upload_cloud 语义
    upload_cloud: bool,                        // Manual 下的云端开关；Auto 忽略
) -> FullSyncBackupResult<ExportResult>;
// origin=Auto 时内部控制 local/cloud 开关取自 backup_prefs（保留 ensure_any_switch_enabled）
// origin=Manual 时不落 prefs 开关约束（同现状 _manual 语义）

// 密码来源改为已解锁态：
// - 前置 is_unlocked() 校验，不满足返回统一错误
// - EncodeParams / decode_backup 使用 svc.get_data_key()（不再接收 sync_password）
```

- `import_full_sync_backup(pool, bytes, ignore_schema_mismatch)`：去掉 `sync_password` 参数，改内部读 `get_data_key()`（保持字节流输入不变）。
- 私有 `ensure_unlocked(svc)` helper：统一前置校验与错误文案。
- `list_cloud_backups` / `download_cloud_backup` / `upload_backup_bytes` **不改**（已可复用）。

### 3.2 桌面命令：`apps/desktop/src-tauri/src/commands/full_sync_cmd.rs`

```rust
#[tauri::command]
async fn full_backup_export(
    origin: BackupOriginDto,       // "manual" | "auto"
    upload_cloud: bool,
) -> Result<ExportResult, String>;   // 内部读取当前激活云配置 get_active_cloud_config_from_db

#[tauri::command]
enum BackupSourceDto { Local { path: String }, Cloud { cloud_path: String } }

#[tauri::command]
async fn full_backup_import(
    source: BackupSourceDto,       // Local|Cloud
    ignore_schema_mismatch: bool,
) -> Result<ImportResult, String>;  // Cloud 内部：列活跃云配置→download→字节

// 新增（可选独立以利于前端两段式加载）
#[tauri::command]
async fn full_backup_list_cloud() -> Result<Vec<RemoteFile>, String>;
```

- 均在 `lib.rs` 的 `invoke_handler` 集中注册。
- 复用 `get_active_cloud_config_from_db` 获取云配置。

### 3.3 前端：`apps/desktop/src/components/settings/sync-section.tsx` + `src/lib/tauri.ts`

- 合并两张卡片为「全量备份」一张：导出区（立即导出 + 定时自动导开关/频率/保留份数，均来自 backup_prefs）+ 恢复区（来源切换 本地/云端 + 副本列表）。
- 移除导出/恢复的密码输入；依赖既有「同步密码」解锁状态（设置页顶部 `syncCryptoUnlock`）。
- `tauri.ts` 更新 `fullBackupExport`/`fullBackupImport` 签名 + 新增 `fullBackupListCloud`。

## 四、测试策略

- **core 单测**（`full_sync_backup_api.rs` 同模块 `#[cfg(test)]`）：
  - origin=Auto 且开关全关 → 报错（保留 ensure_any_switch_enabled 行为）。
  - origin=Manual、开关全关 → 仍可本地导出。
  - 未解锁（svc 未 unlock）→ 导出/导入返回「请先解锁同步密码」，不进入加密/删除阶段。
  - 已解锁 → 导出/导入正常；.orfullsync roundtrip（含遗留扩展名）回归保持。
- **桌面命令**：Cloud 来源恢复用 mock adapter 断言先 list 后 download 再 import；Local 来源直读文件。
- **前端**：vitest 纯函数/状态逻辑；`window.__orbitMock` 校验密码输入项已不再渲染。
- **CI**：`pnpm typecheck` / `pnpm test` / `cargo test --workspace`（含 m4 WebDAV 已知环境依赖项）。

## 五、影响面与风险清单

| 风险 | 处置 |
|---|---|
| 未解锁即导出/导入 | `ensure_unlocked` 前置校验，返回统一可读错误 |
| Auto 开关约束丢失 | origin 分支保留 backup_prefs 门控 |
| `.orfullsync` 字节结构被误改 | 明确只动密钥来源/触发/选源，encoder/decoder/container 零改 |
| 移动端 FRB 桥破坏 | 若移动端有相同导出入口则同步签名，否则不动；CI codegen 门禁把关 |
| 历史备份兼容 | 已解锁密码仍可 decode 旧 `.orfullsync`/`.waitfullsync`/`.orsync` |
| 云端未配置时恢复选云 | 禁用云端项并提示「未配置云空间」 |

## 六、文件改动清单

- `crates/orbit-core/src/api/full_sync_backup_api.rs`（核心：origin 合并 + 解锁态复用）
- `crates/orbit-core/src/full_sync_backup/error.rs`（若补「未解锁」错误变体）
- `apps/desktop/src-tauri/src/commands/full_sync_cmd.rs`（命令签名 + Cloud 来源恢复）
- `apps/desktop/src-tauri/src/lib.rs`（invoke_handler 注册新命令）
- `apps/desktop/src/lib/tauri.ts`（IPC 封装签名）
- `apps/desktop/src/components/settings/sync-section.tsx`（卡片合并 + 选源 UI）
- `crates/orbit-core/tests/`（若补集成用例）
- 相关测试文件随改动同步