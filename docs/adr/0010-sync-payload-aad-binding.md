# ADR 0010：同步载荷 AAD 绑定（两拍发布，第一拍已落地）

- 状态：已决策 + **第一拍已实施**（2026-09-19，第五轮探查 F43–F46）。第二拍
  （启用写入）待发布，见文末「实施状态」。
- 日期：2026-09-19
- 编号说明：0008/0009 预留第五轮内存与性能治理专项占用，本件顺延 0010。
- 上下文：第六轮优化 D12。`crypto_io.rs` 的 AES-256-GCM 加密原本 AAD 为空，
  表桶载荷与附件共用同一 Data Key。有提案建议把“表名/桶名”绑进 AAD，
  使跨桶密文不可互换。本 ADR 只 pin 结论与前置项，实现按第一拍落地。

## 决定（六条）

1. **不新造版本位。** `crypto_io.rs` 的 `PAYLOAD_VERSION` 与 `meta.rs` 的
   `LAYOUT_VERSION` 已够用；真正缺的是门禁语义——原先三处都写 `!=` 而非
   大小判定，且 `DeviceCheckpoint` 缺 `app_version` 字段。动 AAD 前先补这些，
   否则新旧客户端互相拒读。（已实施：清单侧收敛为 `Manifest::check_layout_version()`
   一处，载荷侧收敛为 `decrypt_payload_at` 一处。）
2. **真正的成本是客户端版本编排，不是格式。** 需要两拍发布：先发具备
   AAD 协商能力的版本并让全网设备升级，再发启用绑定的版本。仓库此前
   无任何能力协商机制（无版本握手、无特性位），单版本直接启用 = 把旧
   设备当场踢下线。（协商位已落：`DeviceCheckpoint::app_version` +
   `Manifest::all_devices_support_aad()`，见「实施状态」。）
3. **版本不匹配不得复用 `KeyMismatch`。** 原先解密失败统一映射密钥错误，
   会把用户误导向密钥恢复页。启用绑定前须先有独立错误码
   （已落：`CloudSyncError::PayloadVersionMismatch`，tag `payload_version`）。
4. **AAD 只能随计划内 rekey / force 事件下发，不得与 A10/A13 同版。**
   A10/A13 依赖“指纹相等、零上传”的验证信号做归因；同版启用 AAD 会让
   全量重传污染它们的基线，事后分不清是绑定生效还是回归。
   本轮据此把**写入**门禁留在关闭态（当前版本低于 `AAD_MIN_APP_VERSION`），
   性能项 A10/A13 与绑定开关不同版生效。
5. **价值只是纵深防御；表桶先做，附件永不做。** 附件走
   `media/<sha256>` 内容寻址，sha 即自校验，绑 AAD ≈ 零收益。
   即使将来做，也只绑表桶载荷。（已按此实现：只有 `tables/` 与 `tombstones/`
   分桶走 `encrypt_bucket_payload`，清单与附件仍走 `encrypt_payload`。）
6. **附带口径澄清（N36 收口）：** 现存 nonce 是确定性派生
   `SHA256(data_key ‖ SHA256(compressed)hex ‖ len)[hex 前 12 字符]`，
   实为 48-bit 熵（12 个 hex ASCII 字符），**不是** 96-bit 标准随机 nonce。
   存量云端密文已按此落盘，任何改动都是格式演进，须走本 ADR 的版本门禁。
   详见 `crypto_io.rs` 注释与 `derived_nonce_length_is_12` 双断言。
   第一拍给派生函数加了 `aad` 入参（0x02 下不同路径不得复用同一 nonce），
   空 AAD 的产出与存量**逐字节一致**——这条由 `empty_aad_keeps_legacy_nonce`
   手工重算旧公式钉住，不是靠“看起来没变”。

## 明确延后（顺带记）

- **N33（同步取消）延后**：真要做走 `progress.rs` 既有桶边界的协作式取消，
  远便宜于探查报告估算的“四层改动”，但仍不在本轮。
- **N15（设备注销）延后，且它不是内存项**：删设备行会改变
  `tombstone_watermark()`（`meta.rs`，设备数 < 2 即不回收的保守分支），
  触第四轮报告 A11 的墓碑水位线红线（该结论未单独成 ADR，0008/0009 缺号）。
  将来做必须先复核水位线判据再动。

## 实施状态（第一拍，2026-09-19）

| 前置项 | 落点 | 守护测试 |
| --- | --- | --- |
| 门禁语义 `!=` → 大小判定 | `Manifest::check_layout_version`（pull/push 共用）、`decrypt_payload_at` | `layout_version_gate_distinguishes_future_from_ancient`、`zero_version_payload_is_reported_corrupt` |
| 独立错误码 | `CloudSyncError::PayloadVersionMismatch` → `category_tag() = "payload_version"` | `bound_payload_on_plain_entry_reports_version_mismatch` |
| 能力协商位 | `DeviceCheckpoint::app_version`（serde default，清单是加密 JSON → **无迁移**），`touch_device` 写 `env!("CARGO_PKG_VERSION")` | `legacy_manifest_without_app_version_parses`、`touch_device_records_local_app_version` |
| 绑定本身 | `encrypt_bucket_payload(.., bind_aad)` / `decrypt_bucket_payload(.., path)`，版本 0x02；`bind_aad` 取 `Manifest::all_devices_support_aad()` | `ciphertext_is_not_interchangeable_across_buckets`、`wrong_path_fails_to_decrypt`、`legacy_payload_still_decrypts_through_bucket_entry`、`gate_selects_payload_version` |

**第一拍的实际行为**：写侧门禁恒为关（本机版本 0.1.0 < `AAD_MIN_APP_VERSION` =
0.2.0），所以本版本产出的仍是存量 0x01；读侧已能吃 0x02。于是**第二拍无需再改
门禁代码**——发布 0.2.0 后，门禁在「清单内全部已登记设备都 ≥ 0.2.0」时自动打开，
任一设备未升级（含 `app_version` 为空的存量清单）即不打开。

## 后果

- 第一拍：无迁移、无桥签名变更、无跨端镜像链改动（新错误 tag 靠既有
  `[tag] message` 通道流通，两端无需新分支：`key_mismatch` 才跳恢复页）。
- 已知代价：AAD 不符与密钥不符同为 AEAD tag 失败 → 都报 `KeyMismatch`。
  这不是绑定引入的新歧义（0x01 下存储端改一个比特同样报 `KeyMismatch`），
  且门禁关闭期间不存在绑定密文，故本轮无用户可见影响。
- 第二拍启用前必须复核：决定 4（不得与 A10/A13 同版）与「全部设备已升级」
  判据；任一 AAD 相关 PR 须引用本 ADR。

