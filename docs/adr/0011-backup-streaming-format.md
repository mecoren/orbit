# ADR 0011：全量备份 v2 流式容器格式

- **状态**：已采纳（2026-10-21）
- **相关**：`docs/13 §6.2 M1`、`docs/07 #89`、ADR 0005（回收站边界）

## 背景

v1 的 `.orfullsync`（magic `OFS1`）把每张表全量序列化成 `String`，汇总进
`BTreeMap<String, String>`，再整包 ZIP + AES-256-GCM 加密。峰值内存约为
「库 JSON + ZIP + 密文」三份叠加，与数据总量线性相关。对一个几十万行的库，
导出/导入可能把进程内存打爆——而备份正是用户最不希望失败的路径。

## 决策

新增 **v2 容器**（magic `OFS2`），以**定长帧**承载加密数据，任何时刻内存中
只有一帧明文 + 一帧密文。

### 文件布局

```text
[magic "OFS2" 4B]
[header 长度 BE u32 4B][header 36B]
重复：
  [帧序号 BE u64 8B][密文长度 BE u32 4B][密文]
```

header 36B = salt(16) + nonce_base(12) + iterations(4) + frame_plain_max(4)。
header 不加密：它只含派生密钥所需的公开参数，不含业务数据。

### 帧加密

- master_key：PBKDF2-HMAC-SHA256（同步密码 + salt，迭代数写进 header），
  与 v1 同强度；读侧先经 `ensure_kdf_strength` 校验下限，防存储端把迭代数
  降到 1 实现密钥降级。
- nonce：`nonce_base` 的低 8 字节与帧序号异或。帧序号唯一 ⇒ nonce 唯一，
  满足 AES-GCM 的 nonce 不可复用要求。
- **帧序号进 AAD**：删帧、换序、拼接都会让 GCM tag 校验失败。读侧另外强制
  序号严格递增（`seq != expected` 即拒），双重防护。

### 帧边界语义

- 控制帧：`{"kind":"meta"|"table"|"table_end"|"end", ...}`，单个 JSON 对象；
- 记录帧：一条记录一个 JSON 对象（`write_records` 每条即落帧），记录不跨帧。

首帧固定是 `meta`（manifest + schema_version），因此 **peek 只需读 header +
首帧**，不必解密正文——这是 v1 做不到的（v1 的 manifest 在加密 ZIP 内部）。

### 容量与上限

- `FRAME_PLAIN_MAX` = 4 MiB；
- 读侧按 header 声明的 `frame_plain_max` 校验密文长度上限**再分配缓冲**，
  防伪造超大长度把内存打爆；
- 单条记录超过帧上限时由 `FrameWriter` 自动切帧（记录可跨多帧，导入侧按
  `read_records` 的行拼接语义还原）。

## 兼容策略

| 方向 | 策略 |
|---|---|
| 新写 | 一律 v2 |
| 读 v1 | 保留 `decode_backup` 整包路径，按 magic 分流（`is_v2_backup`） |
| 读 v2 | 新增 `import_v2_bytes` / `peek_v2_meta` / `peek_v2_tables` |
| 旧版本读 v2 | **不支持**，属预期；发布说明需标注「备份格式升级，旧版无法恢复新备份」 |

分流只看 magic，不看扩展名——用户可能把 v2 备份改名成 `.orsync`。

## 后果

**正面**

- 本地导出峰值由「页大小 500 行 + 一帧 4MiB」决定，与库大小无关；
- 本地导入逐帧解密逐条写库，峰值同理；
- peek 不再解密正文，恢复确认框打开更快；
- v1 备份仍可恢复（有独立回归用例）。

**代价 / 未做**

- 云端上传仍把文件读回内存（适配器接口是 `&[u8]`）：**本 ADR 只解耦本地
  路径**；云端流式化需要改三协议（WebDAV/S3/OSS）适配器签名，是后续独立批次。
- 备份格式升级不可逆：v1 应用读不了 v2 备份，必须靠发布说明与版本节奏控制。
- 导出时先 COUNT 一遍、再分页读，等于解析两次；换来启动前即知总量与
  超限同步拒绝。

## 参考实现

- 容器层：`crates/orbit-core/src/full_sync_backup/v2.rs`
- 编排层：`crates/orbit-core/src/api/full_sync_backup_v2_api.rs`
- 回归用例：`crates/orbit-core/tests/backup_v2_streaming.rs`（11 例，含 v1 兼容）
