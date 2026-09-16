# 需求文档：全量备份与自动备份融合 + 复用同步密码 + 云端恢复

## 一、需求理解

云端备份目前分为「自动备份」(schedule + backup_prefs 开关) 与「手动全量备份 (.orfullsync)」两套独立入口，导出/导入都要用户**手动重复输入同步密码**，恢复也只能**本地文件**。目标：把两者融合为单一「全量备份」功能——调度降为可选子项、导出/导入**直接复用已解锁的同步密码**、恢复支持**选择本地或云端副本**。

## 二、现状基线（改动依据）

- 导出 API 三入口：`export_full_sync_backup`（本地开关 gated）、`export_full_sync_backup_with_cloud`（云端开关 gated，供定时守护）、`export_full_sync_backup_manual`（手动不受开关约束）。三者加密逻辑完全一致，全部走 `export_full_sync_backup_inner`，均显式接收 `sync_password`。
  - 代码：`crates/orbit-core/src/api/full_sync_backup_api.rs#L86-L150`。
- 当前密码修为：`SyncCryptoService::new(app_data_dir).unlock(sync_password)?` 校验后立即 `lock()`，**不持久化解锁态**（同文件 `export_full_sync_backup_inner` L190-L192）。
- 恢复：`import_full_sync_backup(pool, sync_password, bytes, ignore_schema_mismatch)`，接收的是**字节流**（L522），`full_backup_import` 命令从本地 `path` 读取后传入（`apps/desktop/src-tauri/src/commands/full_sync_cmd.rs#L65-L99`）。
- 云端列副本/下载能力**已存在但未接入导入 UI**：`list_cloud_backups(adapter, base_path)`（`full_sync_backup_api.rs#L417`，已按 `.orfullsync`/`.waitfullsync`/`.orsync` 过滤+按修改时间倒序）、`download_cloud_backup(adapter, cloud_path)`（L445）。
- 密钥复用落点：`SyncCryptoService` 提供 `is_unlocked()` 与 `get_data_key()`（`crates/orbit-core/src/sync_crypto/service.rs#L102/L163`），可据此读当前已解锁派生密钥。

## 三、关键技术决策

1. **融合入口**：导出收敛为单一声明性入口，调度仅作 origin 标记。新增 `BackupOrigin::{Auto, Manual}`；所有导出路径统一，`auto` 仍受 backup_prefs 开关约束，`manual` 不受——通过单一 `export_full_sync_backup(pool, app_data_dir, origin, cloud_config)` 表达，删除两个 `_with_cloud`/`_manual` 专用入口（行为合并进 origin 分支）。
2. **复用已解锁同步密码**：导出/导入前要求 `SyncCryptoService::is_unlocked()` 为真，否则返回「请先解锁同步密码」错误；已解锁则直接用 `get_data_key()` 派生加密密钥（v2 密钥派生对齐，密码正确性由解锁态保证）。废弃「unlock 校验后即时 lock」的临时模式，改为「读取已解锁态密钥」。前端移除密码输入，改由既有 `syncCryptoUnlock` 流程保证解锁。
3. **恢复选源**：`import_full_sync_backup` 保持接收字节流不变，由调用方（桌面命令）决定来源；新增命令层来源枚举 `BackupSource::Local{path} | Cloud{cloud_path}`。Cloud 侧前端先调用既有 `list_cloud_backups` 展示副本列表 → 选中 → `download_cloud_backup` 拉字节 → 调 `import_full_sync_backup`。core 层不新增来源逻辑，只保证字节输入接口可用。
4. **加密/恢复字节管线不变**：encoder/decoder/container `.orfullsync` 格式零改动，降低回归面；仅改「谁的密码」与「字节从哪来」。

## 四、实现步骤

1. core：`full_sync_backup_api.rs` 新增 `BackupOrigin` + 合并导出为单入口；导出/导入改读 `SyncCryptoService::is_unlocked()/get_data_key()`，去掉手动密码参数路径（保留内部 v1 兼容用于测试）。
2. 桌面命令：`full_sync_cmd.rs` 更新 `full_backup_export`（去密码，带 origin + 可选 cloud_config）、`full_backup_import`（来源枚举 Local|Cloud，云端列副本/下载子命令）。
3. FRB/移动桥：若移动端也有导出入口，同步改签名（否则跳过，按现状移动端由伪装实现覆盖）。
4. 前端 `sync-section.tsx`：合并「自动备份」与「全量备份(.orfullsync)」两张卡片为一张；去掉导出/恢复的密码输入；恢复页提供「本地文件 / 云端副本」来源切换。
5. 测试：更新 core 密码校验用例（改成解锁态前置校验）、补 origin 分支用例、补 Cloud 来源恢复命令用例；跑 typecheck/test/cargo test。

## 五、边界条件与风险

- **未解锁即导出/导入**：必须前置校验并返回清晰错误，禁止静默用空 key。
- **调度（auto）受 backup_prefs 开关约束、manual 不受**：合并后不可破坏该语义（origin 分支保留）。
- **`.orfullsync` 格式冻结**：本需求只改密钥来源与触发/选源，禁止触碰 encoder/decoder/container 字节结构，避免破坏存量备份可读性。
- **云端副本恢复**：仅限「当前已激活云配置」的 `{base_path}/backups/` 目录；未配置云时云端选项禁用并提示。
- **移动端**：若不涉及移动端导出入口，则跳过桥改；不得因桌面改动破坏 FRB 桥一致性（CI codegen 门禁）。
- **兼容性**：历史 `.orfullsync` 备份用已解锁密码仍须可恢复；错误密码场景由解锁态提前阻断而非 decode 阶段报错。