# Changelog

本文件记录 Orbit 的所有显著变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> **0.1.0 条目口径**：0.1.0 是项目整体首个版本，本条目由 2026-08-23 初始提交至
> 2026-09-24 的**全部 git 记录**（543 次提交：222 feat / 130 fix / 32 perf / 84 docs，
> 余为 chore / refactor / style / test 及其他；计数口径为提交主题前缀，`git rev-list
> --count` 与 `findstr` 实测，PowerShell 原生管道会吞掉含中文主题的行故不用它计数）
> 按模块归并总结——合并同源提交、剔除过程性改动，不逐条罗列中间过程；逐条明细以
> git 历史与 `docs/07` backlog 为准。历史 `v0.1.0`
> （2026-09-15）tag 及其后的全部未发布工作（云同步存储结构重构、第五轮探查收口、
> 内存门禁入库、移动端快速添加面板与抽屉口径收口等）已一并并入本条目。

## [Unreleased]

### 云同步第六轮盘查：三条 P1 + 十条 P2/P3 收口（2026-09-30）

- **失败轮次不再推进增量水位线（P1）**：`push_all_impl` 引入 `round_clean =
  failed_modules == 0`，仅干净轮次才写 `last_pushed_clock_ms`（「无变化」早退分支同样只
  在干净轮次落盘）。此前单次限流/瞬断后，**行数不变的编辑**（改标题、勾选完成等）会
  因为水位线被推进而永久漏传云端，且后续轮次一路报「成功」——静默数据丢失且不可自愈。
- **rekey 不再产出密钥混合态（P1）**：`push_all_force_full` 新增
  `require_all_tables_ok`，任一分桶上传失败即**在写清单之前**中断。此前部分表失败仍会写入
  「已换成新 Key」的清单，导致云端出现「新 Key 清单指向旧 Key 分桶」，全体设备（含本机）
  一律 `KeyMismatch`。
- **清单 CAS 在弱 ETag 服务端可用（P1）**：`get_with_token` 改走与列举侧同源的
  `normalize_etag`——剥掉 `W/` 弱校验前缀、空 ETag 归 `None`。此前弱 ETag 的 WebDAV
  服务端上 `If-Match` 恒不匹配，合并重试耗尽后**清单永不落盘**。
- **S3 签名与请求 URL 统一按 AWS UriEncode 编码（P2/F51）**：`s3/url.rs` 新增
  `uri_encode`，`build_url` 成为唯一编码点。此前路径裸拼进 URL 由 `Url::parse` 按 WHATWG
  规则归一：`base_path` 含 `#`/`?` 时路径被**截断到另一个对象**，含 `+`/`=`/`[` 时
  canonical URI 与 AWS 重算结果不符 → 整包 403 `SignatureDoesNotMatch`。
- **墓碑回收水位线改用「已拉取位置」（P2/F52）**：`DeviceCheckpoint` 拆出
  `last_pulled_at`（水位线只取它），pull 成功路径回写；只推送不拉取的设备不再抬高水位线。
  同时修掉「本轮刚写入的墓碑分桶在同轮被回收」的窗口（`prune_expired_tombstones` 增
  `already_known` 过滤 + 按 `(table, bucket)` 精确回收）。
- **合法清空全部数据可以上云了（P2/F53）**：空数据覆盖守卫前置「本地留有软删墓碑 ⇒ 合法
  删除」判据。此前「逐条软删清空」被误判为删库重装而阻断 Push，删除永远传不到云端，下一轮
  pull 又把远端活行拉回来——用户看到的是「删了还会自己回来」。
- **全量备份导入后失效同步账本（P2/F54）**：导入提交后清 `sync_state.json` 并重置激活配置
  的 `last_synced_at`，与「断开同步」同口径。此前恢复出的行 `updated_at` 早于旧水位线、
  桶内行数又与远端一致时被判「干净」而漏推；陈旧守卫线还会让恢复出的软删行被提前物理清理。
- **部分失败不再谎报「同步完成」（P2/F55）**：表级错误隔离产生的 `Ok` 但 `errors` 非空的
  轮次，在 `Done` 帧之后补发一帧带摘要的 `Error`（最多列 3 条）。此前 UI 说「同步完成」、
  历史表说 `failed`，而后台调度路径不把返回值交给 UI，用户唯一可见信号就是进度帧。
- **两处 KDF 迭代下限补挂（P2/F62、F63）**：`rotate_key` 与 `unlock_master_auth` 补
  `ensure_kdf_strength`。本地 meta 文件属不可信来源，此前被篡改降迭代即可解锁 / 把整套云端
  密文重新包到降级强度的密钥下。
- **错误信息与提示方向修正（P2/F67、F68）**：MKCOL 深度超限 arm 改走脱敏（credentials 不再
  进错误串，F34 收口）；附件上传读文件改 `match`，区分「读取失败（带 IO 原因与路径）」与
  「内容为空」——IO 故障不再被吞成「文件为空」把用户引向错误排查方向。
- **明确可重试的状态码不再放弃（P3/F79）**：`from_http_status` 增 `408` / `425` 可重试 arm。
- **WebDAV 存在性判定改按状态码（P2/F57）**：新增 `remote_exists`（只看 HEAD 状态码），
  `exists` 两处判据改走它。此前复用 `remote_file_size`，服务端对 HEAD 不回 `Content-Length`
  （部分实现如此）时返回 `None` → 存在的对象被判「不存在」，后果不是报错而是**静默走错分支**：
  附件差集每轮空跑重传、首传三分叉探测误放行、pull 活跃引用判定失真。
- **分片目录清理不再「清一半就继续」（P2/F59）**：`delete_parts_dir` 改为**先删清单**再尽力删
  分片，清单删除失败即上抛；逐片「大小相等即跳过」的续传判定加 `reusable` 前置（只在清单已
  证明目录同源时启用）。此前 rekey 后（同一明文跨 Data Key 的密文长度必然相同）陈旧分片会被
  整片跳过，写出「清单声明本轮密文、目录里却是旧密文」的对象 → 读侧拼装 sha256 校验永久失败，
  每轮重试都被同一判据（`retryable: false`）拒掉。
- **普通 PUT 发送阶段首次有超时（P2/F60）**：按请求体大小给 per-request 总超时（每 5MiB 给
  120s，小体量下限 120s，8MiB 单 PUT 为 240s）。此前只配了 `read_timeout`（仅覆盖响应体读取），
  服务端接受连接后停止读取时 socket 写阻塞、PUT 永不返回——整轮同步挂死并一直持着同步互斥锁。
- **WebDAV 路径按 RFC 3986 编码（P2/F61）**：`build_url` 对路径做百分号编码，复用 S3 的
  `uri_encode`（同一实现，避免两协议在「哪些字符必须 `%XX`」上漂移）。此前路径裸拼进 URL，
  `#` / `?` 处截断成 fragment / query → 请求打到**另一个路径**上且状态码看着正常。
- **全量备份导出不再静默丢掉整张表（P3/F71）**：导出循环区分「表不存在（迁移前旧库）→ 跳过
  并记 warn」与「表在但读取失败 → `log::error!` + 中止导出」。此前一律 `eprintln!` 后
  `continue`，出口仍是一份「成功」的备份：文件名、大小、云端上传、`sync_history` 全部正常，
  唯独缺一整张表的数据——用户要等到用这份备份恢复时才发现，而 `keep_latest` 很可能已把上一份
  好备份删掉。同步域壳层残留 `eprintln!` 一并收口（桌面改 `log::*`；移动端一条**刻意保留**，
  因为 `orbit-flutter` 未安装任何 logger，改为 `log::*` 等于删掉该端唯一输出通道，另记 F81）。
- **备份导入不再信任文件自述长度（P2/F65）**：`decoder` 新增 `MAX_ENTRY_BYTES`(512 MiB) /
  `MAX_TOTAL_BYTES`(2 GiB) 与 `read_entry_bounded`，去掉 `String::with_capacity(file.size())`。
  ZIP 中央目录里的 `size` 是随文件进来的元数据：伪造成 8 GiB 时旧代码第一行就发起 8 GiB 分配
  （分配失败即进程中止），即便报得小也会无上限读到内存耗尽；总量上限另防「每条都不越界但条数
  极多」的 ZIP 炸弹。越界判定按「多读 1 字节」实现，等长条目不受误伤。
- **撤销主密码元数据不再可能写出半截文件（P2/F69）**：`save_master_auth` 改走
  `fs_util::write_atomic`（同目录 tmp + rename）；`load_master_auth` 解析失败（含非法 UTF-8）
  先留证 `.corrupt-*` 再上抛明确错误。留证用**复制**而非既有 `quarantine_corrupt_file` 的改名：
  `master_auth.json` 的存在性本身就是状态机输入（`has_master_auth()` 决定是否显示解锁页、
  `master_auth_init` 是否拒绝重复初始化），改名会把「损坏」读成「未设置主密码」，从而放过
  重新初始化——那会生成全新 DB Key，旧加密库再也打不开。
- **同步合并不再把类型漂移静默写成 NULL（P2/F58）**：`merge` 批量 INSERT 的
  `normalize_value` 失败由「折成 `Value::Null`」改为上抛（与同文件 UPDATE 路径同口径）。
  此前「对端把 `deleted_at` 序列化成本地化日期串」这类漂移会把可空列静默写成 NULL——不报错、
  不进 `sync_conflicts`，而 version 已随本轮合并推进，用户只看到「字段同步后凭空被清空」
  且查无线索。
- **桶指纹不再把嵌套同名业务字段当同步元数据（P3/F70）**：`canonicalize_value` 增 `top_level`
  形参，`updated_at`/`id` 白名单与 `_fk` 外键排除**只在顶层记录生效**（递归分支传 `false`）。
  嵌套对象（JSON 列里存的 `{"id":…,"updated_at":…}` 快照）里的同名字段此前被静默摘掉，后果是
  **少算而非多算**：嵌套内容怎么改桶指纹都不变，下一轮 `bucket_is_unchanged` 判「干净」直接跳过，
  那部分编辑永远传不上云端且每轮报成功。原实现把排除写在递归分支内，与本函数文档「仅作用于顶层
  Object」自相矛盾。
- **分片 ETag 不再被当成并发令牌归一化（P3/F72）**：`put_part_once` 改 `trim()`（只去首尾空白、
  保留引号），`complete_multipart_body` doc 明确入参必须是 UploadPart 响应头原文。协议要求
  CompleteMultipartUpload 清单里的 Part ETag 与 UploadPart 回传值**逐字节一致**，剥引号会被
  严格校验的服务端以 `InvalidPart` / `MalformedXML` 拒绝整份清单——而分片此时已全部传完，
  重试代价是整文件重传。归一化那套（剥 `W/` 与引号）服务的是**并发令牌比较**，与「回传服务端
  回执原文」是两件事。
- **S3 列举不再把半页当成完整列举（P3/F73）**：`parse_list_objects_xml` 解析 `<IsTruncated>` 并
  落到 `ListPage.truncated`；空 `<NextContinuationToken/>` 归 `None`（空游标不是游标）；
  `IsTruncated=true` 却拿不到游标时**直接报错**。此前 `IsTruncated` 从不解析，适配器在 `None`
  分支 `return Ok(entries)` 把半页当完整列举（pull 拉不到第 1001 个附件、push 按「云端缺文件」
  误判）；空游标则让服务端按「无游标」重发第一页，条目重复堆积直到 1000 页上限才报错。
- **WebDAV 列举不再丢掉「存在但属性取不到」的资源（P3/F74）**：`propfind` 支持 RFC 4918 的
  `(href, status)` 形态（`<status>` 直属 `<response>`，无 propstat 包装）。此前只在 `in_propstat`
  时记录 status，该形态下 `merged` 恒 false → **整条被丢**，存在的资源从列举结果里消失
  （`url_exists` 判「不存在」、`list_assets` 少对象）。资源级非 2xx 仍按「不存在」剔除，
  F31 口径不回退。
- 回归：`cargo test --workspace` 全绿（orbit-core 新增用例含 F48/F49/F50/F51/F52/F53/F57/F59/F60/F61
  与 F58/F65/F69/F71、F70/F72/F73/F74 的定向用例；F59 因附件差集会「看见」分片目录而无法在集成级构造，改用适配器内的最小内存
  WebDAV 假服务直测 `upload_asset_parts`；F58/F65/F71/F70/F72/F73/F74 八项均以「临时回退修复点 → 用例立即红 →
  恢复」验证过用例有效；期间修掉测试夹具 `spawn_header_server` 的请求体竞态——它读完请求头就回响应并关连接，
  换成带请求体的 PUT 用例后会撞 RST 报 `error sending request`，属与被测逻辑无关的时红时绿，F72 的先红证据
  因此另跑一次取得）；详细清单与逐项证据见
  `docs/同步功能第六轮全面盘查报告-2026-09-30.md` §八。

### 云同步第六轮盘查：剩余 9 项全部收口（2026-10-01）

至此第六轮报告 P1/P2/P3 全部编号清零。

- **条件写先补齐父目录（P2/F56）**：WebDAV `upload_conditional` 与普通 `upload` 同口径先
  `ensure_directory`。此前父目录链缺失时服务端回 409 AncestorsNotFound，被「带前置条件的
  409 → 前置条件不满足」折叠分支折成 CAS 失败，调用方反复重读重试直至报「并发冲突重试 N 次」，
  真实成因（目录缺失，可自愈）被掩盖，清单永不落盘。
- **rekey「以本机为准」真正可达，旧 Key 密文残留清除（P2/F64）**：处置时以临时探针实证
  「云端非空时 rekey 第一步读清单即报 KeyMismatch」——v2 改密 / v1→v2 迁移 / KeyMismatch
  恢复三场景的覆盖此前根本不可达。现 force 轮容忍清单解不开（按空清单起步、并发令牌保留供
  条件写覆盖）；force 轮索引不再以远端清单为底（「远端有、本机无」的桶条目指向 rekey 不重加密
  的旧 Key 密文，保留即混合态）；`manifest.prev` 改存本版新 Key 密文（原样另存上一版 = 旧 Key
  残留 + 无效回滚点）；rekey 后清理老版本遗留的根目录 `crypto/config`。
- **密钥材料换手前 zeroize 原地覆写（P2/F66）**：引入 `zeroize`，`SyncCryptoService` 的
  Data Key 与缓存密码在锁定/替换前显式擦除——直接 drop 只把内存标记回收，密钥字节仍留在
  已释放内存里（堆复用 / core dump / swap 可旁观）。
- **asset 三方法收口为 trait 默认实现（P3/F75）**：S3 与 WebDAV 各自一份逐字相同的拷贝删除，
  `BasePathAdapter` 的覆盖保留（base_path 语义唯一落点）并补注。
- **退出同步的外层超时随空闲窗走（P3/F76，移动端）**：`waitForIdleMs=15000` 的空闲等待窗此前
  永远被恒 6s 超时截断，且超时路径直接跳过业务缓存失效——本轮已拉到的数据不刷新 UI。
- **两端契约与 mock 口径对齐 core（P3/F77）**：`SyncResultJson` 两端补 `conflicts`（S28 冲突
  裁决数，core 一直下发、两端壳都未解析）；mock 桥与 core 同口径填 `changedTables`；mock 同步
  历史 `scope='all'` 对齐 core（三种增量类型并集而非「不过滤」），sync_type 真值修正（此前移动端
  标签映射与 mock 种子用的都是臆测字符串，真数据永远落不到标签上）；桥层默认值双端对齐；移动端
  on-change 推送遇密钥失配不再静默，弹恢复引导（对齐桌面端行为）。
- **403 时钟偏差不再误导为密钥错（P3/F78）**：S3/OSS 的 `RequestTimeTooSkewed` /
  `RequestExpired` 与真签名错共用 403，现按协议错误码分流为独立 `ClockSkew` 变体——文案直接
  给出处置方向（校准系统时间），不再引导用户乱改 AccessKey / 重新解锁同步密钥。
- **卫生批次 14 分项（P3/F80）**：DB Key hex 不再穿过 webview（Rust 进程内暂存，解锁/初始化/
  迁移三命令改编排式调用）；`MasterAuthMeta` 去掉 `Debug` 派生（防包装密钥进日志与 core dump）；
  数据库加密迁移失败清理半成品明文 tmp；备份删除前校验命名规范（防误传路径删任意文件）；
  `download_crypto_bundle` 404 语义对齐同族 API；配置加密存储去掉无条件二次写；删除无调用方的
  legacy 确定性 nonce 附件路径；分片清单头加版本字段（防新客户端头被旧客户端静默误解析）；附件
  列举并集去重去掉 O(n²) 探测；确定性 nonce 有效熵文档口径修正（48-bit，非 96-bit）；
  `validate_config` 拒全空白 endpoint；**S3 STS 会话令牌贯通**（新增 0004 迁移
  `sync_configs.session_token`，SigV4 canonical/signed headers 与请求头三处同步携带，两端配置
  表单与契约字段齐备，留空沿用已存）。
- **移动端日志落地（P3/F81）**：`orbit-flutter` 经 `#[frb(init)]` 钩子在库加载时安装
  `android_logger`（logcat，级别对齐桌面端 Info）——此前 core 侧全部 `log::*`（含 F35/F37
  「失败改 `log::warn!`」的成果）在移动端静默丢弃，排障只能靠 stderr。F71 保留的一处
  `eprintln!` 顺势改回 `log::error!`，两端日志口径一致。
- 回归：`cargo test --workspace` 全绿；F56/F64/F77/F78/F80（空白拒绝）均以「临时回退修复点 →
  用例立即红 → 恢复」验证过用例有效（F64 处置中的前置阻断以临时探针用例实证后转为正式回归）；
  F66 的 zeroize 效果在 Rust 语义内不可观测，以行为钉子用例保锁定语义；FRB codegen + fmt 复跑
  diff 为空；flutter analyze 零问题；桌面 vitest 487 全绿。详细清单与逐项证据见
  `docs/同步功能第六轮全面盘查报告-2026-09-30.md` §八。

### 节假日记账展示收口 + 旧口径文档复原（2026-09-30）

- **记账文案单一出口**：桌面新增 `features/todo/shared/holiday-meta.ts`（配 9 例单测）——
  同一份 `holiday_meta` 要喂设置页概览与日历页两处 tooltip，此前各自拼字符串，于是「每日固定
  时刻 → 每月一次」口径一动就漏三处；现在口径短句 / 时间戳 / 失败态判定集中一处，文案改一次
  即全端生效。
- **失败态从「一个数字」变成可诊断**：`failure_count > 0` 时同时亮出「上次尝试：…」并把
  「连续失败 N 次（旧缓存保留可用）」提为警示色（双端同口径）。原来只有计数，用户分不清调度器
  还在重试还是早已放弃；正常态两行都不出现，不占版面。
- **时间戳口径统一**：桌面设置页由 `toLocaleString()`（「2026/9/29 15:04:00」）改为与日历页
  tooltip 同款「9月29日 15:04」，**跨年自动补 `YYYY年`**——`last_update_ms` 只在自动更新范围内的
  年份成功后才推进，跨年才开机的用户看到「12月31日」无法判断是哪一年。
- **日历页 tooltip 补失败后缀**：失败态追加「，连续失败 N 次」，正常态不出现。
- **旧口径文档复原**（`docs/07 #24`、`docs/10 §A-5`、`docs/11 §G3`）：三处仍在用「每天固定
  时刻（0–23 可配）」当现行口径或当先例引用，已划线并注明 2026-09-29 随 `docs/07 #66` 改「每月一次」。
- **补上节假日零浏览器级覆盖**：新增 `e2e/calendar-settings.spec.ts`（2 例）——正常态只出
  「上次成功更新」、失败态补出「上次尝试」并用警示色亮出计数（`var(--warning)` 探针取色）；
  造态经 `ipc-mock` 的 `__orbitMock.setHolidayFailure` 写 localStorage（mock 是页面模块，
  内存态跨 `goto` 会丢，而用例需要「先设态 → 再进设置页」两步导航）。
- 回归：桌面 vitest 487 全绿（新增 `holiday-meta` 9 例）、`pnpm typecheck` 干净、
  e2e `calendar-settings.spec.ts` 2 例全绿；移动端本地分析器 0 issue（沙箱内 `flutter test`
  不可用，`holiday_cache_page_test` 新增 1 例失败态 + 正常态两条反向断言未在沙箱内执行）。

### 桌面端持续提醒补齐 UI 入口（2026-09-30）

- **详情抽屉提醒区补写入路径**：Rust 侧 `todo_reminders.is_constant` 与迁移
  `0002_reminder_constant.sql` 早已落地，桌面端却一直没有入口——调度层按「响到完成为止」
  在跑、UI 上却无处开启或关闭，等于功能对用户不可达。新增两处：新建 / 编辑提醒时的
  「持续提醒（响到完成为止）」开关（随行落库 `is_constant`），以及已开启行上的「持续」
  徽标（点按即翻）。
- 徽标翻转走「删旧建新、时刻不变」：提醒面只有 create / delete 两个命令，为翻转单加
  一条 Rust update 分支不划算；`remind_at` 原样带回，用户「下一次响铃」的感知不变。

### 移动端日历页/年视图按竞品版式打磨（2026-09-30）

- **月历去卡片化**：月历不再包白卡（描边 / 圆角 / 内衬），直接铺页面底色，左右 space12
  与页头上方 space8 留白保留（周条收起态同口径）。
- **页头改「月份大字 + 相对天数小字」**：小字锚定**选中日**距今天（点日格即变），翻月
  未重新选中时回落当月 1 号——竞品小字表达的是月份口径（「10月 5天后」），锚今天会在
  翻月浏览时产出「10月 今天」的错位文案。
- **横滑翻月的页码回调原样接回**：周档收到的是 ±7 天的逐字日期，中途归一化到 1 号会把
  周条拽回月初周，表现为「网格已经翻页、标题还停在旧月份」。
- **年视图收紧版式**：日格高 30 → 24（原值 12 个月挤不出一屏）、页边距 8 → 16、年份块
  上收进页头行并改为点击返回（省掉整行返回栏）。
- 测试：`test/orbit_month_calendar_test.dart`（新增）、`test/calendar_screen_test.dart`
  （重写）、`test/year_overview_page_test.dart`（新增）；本地分析器 212 文件 0 issue
  （沙箱内 Dart VM 无法 spawn 带管道的子进程，`flutter test` 不可用，未在沙箱内跑单测）。

### 同步故障矩阵入 CI + 夹具 absolute-form 容错（2026-09-30）

- **`sync_fault_matrix` 单独点名进 CI**：rust-core job 原口径 `cargo test --workspace --lib`
  只跑库内单测，`tests/` 整份不执行——这套 10 例是 F22（清单乐观锁条件头真的上过线）与
  F23（≥8MiB 附件真的走分片协议）的**唯一网络级证据**，长期只在本地跑，回归会静默溜过。
  它自带零依赖假服务（`tests/common`，std `TcpListener` 内存假 WebDAV/S3），干净机器可全绿，
  故与「要真 WebDAV 的 `m4_sync_e2e`」区别对待：新增步骤 `cargo test -p orbit-core --test
  sync_fault_matrix`（本机约 4.5 分钟，耗时来自用例自身的重试退避）。
- **夹具容忍 absolute-form 请求行**（`tests/common/mod.rs` `normalize_target`）：本机常驻
  `HTTP_PROXY` 时 reqwest 按代理约定发 `PUT http://127.0.0.1:PORT/base/... HTTP/1.1`，
  夹具此前把请求行 target 原样当对象键，键带上 `scheme://host:port` 前缀，导致
  `webdav_large_asset_uses_chunked_parts_protocol` 与 `truncated_and_stalled_bodies_are_not_accepted`
  在**本机红、CI/无代理机器绿**（一度被误判为既有仓库缺陷——换 worktree 复现只证明既有，
  环境变量会跟着一起复现）。真服务端必须容忍两种形态（RFC 7230 §5.3.2），故修夹具而非断言；
  断言路径口径与生产实现均未改动。
- 同批修正该模块头部过期描述（原写「短连接（响应恒带 `Connection: close`）」，实现早已是
  keep-alive）。

### 清单层级补齐：拖拽跨层级改父 + 父清单聚合子清单任务（对标 TickTick List Folder）

- **父清单聚合子清单任务**（选中父清单时，任务列表含其全部后代的**直接**任务）：
  - 核心侧新增**集合谓词** `ListFilter.project_ids: Option<Vec<i64>>`（`build_task_predicate_clause`
    拼 ` AND project_id IN (?, ?, …)`）。三条口径显式写死，写错会静默出错：① 空集合 = 「该视图不覆盖
    任何项目」→ ` AND 1 = 0`，**不能退化成「不加子句」**（那会把全库任务当成聚合结果）；② 集合非空时
    **优先于** `project_id`（二者不叠加）；③ 归档排除（`archived_exclude_clause`）在 `project_id`
    **与** `project_ids` 皆空时才生效——集合是用户主动指定的视图范围，含归档子清单时须放行。
  - 前端单一口径源 `projectIdsWithDescendants(projects, id)`（= 自身 + `collectDescendantIds`），
    桌面 `features/todo/shared/project-tree.ts`、移动 `modules/todo/logic/project_tree.dart` 各一份。
    桌面由壳层算好后**同时**喂给查询谓词（`todo-shell.tsx::taskPredicate`）与面板本地过滤
    （`task-panel.tsx::filterTasks`）——两层必须同源，只改一层会表现成「聚合不生效」。移动端数据层是
    「全量拉取 + 客户端过滤」，故只落 `TaskFilterInput.projectIds` 一路；`sub_list_screen._listQuery`
    刻意与入口语义分开——页头标题 / 空态 / 新建落点仍按被点中的**单个**清单解释。
- **拖拽跨层级改父**（桌面 + 移动同手势语义）：横向位移即意图——右拖 ≥ 20px **内嵌**为落点行的最后
  一个子项、左拖 ≥ 20px **提升一级**（挂到当前父的父下、紧跟原父之后）、位移不足阈值 **同级重排**。
  - 判定与落库顺序全在纯函数 `planProjectDrop`（双端逐字同口径，各带 12 例单测）：改层级必须在**树上
    做手术**（从原兄弟数组摘除 → 插入目标兄弟数组），再把手术后的树按前序展平取 id 序列。反例说明为何
    不能在旧展平序列上做下标算术：把节点插到某子树之后时，兄弟组落位由**父节点自身 `sort_order`**
    决定，下标算术会让被拖项漂到同层末位。单测用 `displayAfter()`（模拟落库后重拉：按新 `sort_order`
    排序 → 按新 `parent_uuid` 构树 → DFS）断言真实消费路径，而非只断言返回值。
  - 成环拒绝：落点落在被拖项子树的 DFS 连续区间内即视为成环 → 回落同级重排；空 uuid 的项目不当父。
  - 落库顺序口径改为**未折叠全量 DFS 序**（折叠只是浏览态，不该影响编号），缓存只覆盖 `sort_order`
    与被拖项的 `parent_uuid`（列表含折叠隐藏项，整表替换会把它们从缓存抹掉导致展开后闪空）。
  - **桌面**：dnd-kit `DragEndEvent.delta.x` 作横向信号；行 transform 由 `translateY` 改 `translate3d`
    让横向位移有可见反馈；把手加 `title` 承担可发现性（Lucide 图标不接 `title`，故挂在外层 `span`）。
  - **移动**：`ReorderableListView` 只支持纵向，横向层级由行体 `GestureDetector.onHorizontalDrag*`
    表达（手势竞技场按轴分流，不夺 `InkWell` 点击/长按与纵向重排），右移落点取「上一个可见行」
    （DFS 序里必不在自身子树内，天然不成环）；另给长按菜单加「移入上一项 / 移出上一层」——拖动无提示、
    无障碍不可达，这两条是显式可达路径（图标取 `OrbitIcons.indentIncrease/Decrease`，仍单口取图标）。
- **FRB 镜像同步**（`crates/orbit-flutter/src/api/dto.rs::ListFilter` 加 `project_ids`）并用
  `flutter_rust_bridge_codegen`（2.12.0，与依赖锁定同版本）重生成 `frb_generated.rs` /
  `frb_generated{,.io}.dart`：镜像结构变更**必须与生成物同批**，否则 Dart 侧 `SseEncode` 与 Rust 侧
  `SseDecode` 字段错位——`todo_projects_list` / `todo_tasks_list` 等 8 个入口共用该结构，错位即全线崩。
  生成后按仓库惯例 `cargo fmt --all` 并做**二次生成幂等校验**（改动文件 md5 零差异）。
- **mock IPC 边界修正**（`apps/desktop/src/test/ipc-mock.ts`，本批 e2e 的前置）：`todo_projects_update_sort_order`
  长期只在 `ipc-contract.test.ts` 的 `MOCK_ALLOWLIST` 占位、**从未实现**——拖拽在 mock 下第一条落库调用
  即 reject，`handleDragEnd` 整个中断（改层级因此永远走不到）。现补实现并移出 allowlist；同时
  `todo_projects_list` 补 `ORDER BY sort_order ASC, id ASC`（此前返回插入序，与真实链路排序不一致，
  重排结果在 e2e 里根本看不见）；`todo_tasks_list` 补 `project_ids` 集合谓词（含归档放行口径）。
- 验证：Rust `cargo test --lib` **663 passed / 0 failed**；桌面 `vitest` **478 passed / 48 files**
  （基线 457 → +21）；新增 `e2e/project-drag-reparent.spec.ts`（内嵌 / 提升 / 位移不足阈值不改层级）
  与 `e2e/project-aggregation.spec.ts`（父清单聚合）**共 4 passed**，并回归
  `e2e/project-folder.spec.ts` **3 passed**；移动端新增 `task_logic_test.dart` 的 `projectIds`
  集合过滤 4 例（与桌面 `task-filters.test.ts` 同口径）+ `project_tree_test.dart` 的
  `planProjectDrop` 12 例；移动端进程内 analyzer `ANALYZED_FILES=212 ISSUES=0`
  （沙箱内 `flutter analyze` / `flutter test` 不可用，新增用例留 CI 执行）。
  **提交范围**：桌面 `task-filters.ts` / `task-panel.tsx` / `task-filters.test.ts` 与并发会话的
  「工具栏排序方向档 + 收拢双菜单」改动同处 hunk，按「冲突文件不提交」约定留在工作树——故面板
  **客户端**过滤层的聚合（`filterTasks` 的 `projectIds` 分支）与其 UI 层 e2e 一并随该批落库；
  服务端谓词（`ListFilter.project_ids`）、侧栏拖拽与移动端聚合已随本批生效。

### 清单文件夹分组（对标 TickTick List Folder）

- **`todo_projects` 新增 `parent_uuid`**（`0003_project_parent.sql`，`TEXT DEFAULT NULL`，行尾中文注释）：
  指向父项目的**同步主键 uuid**，NULL = 顶层。刻意不用 `parent_id INTEGER`——云同步对整数外键走
  `SYNC_FK_COLUMNS` → `_fk: {列: 父行 uuid}` 标记翻译，其正确性依赖两条前提：「父表先于子表定序」
  （`fk_parent_order_ok()`，**仅表间成立**）与「落库时从本端已落库行建 uuid→id 映射」。**自引用同表
  会同时破坏两者**：父行未到 → `resolve_foreign_keys` 整表 `Err` → 事务回滚 → 父行永不落库 →
  永久死锁。改存 uuid 后父行悬空只是「回落顶层」，双端树构建按顶层渲染；父从回收站恢复后层级自动
  复现，无需级联改写子行。也不声明自引用外键——父行软删不牵连子行。加列零 `sync_registry` 改动
  （`todo_projects` 已在 `SYNCABLE_TABLES`，白名单为行级同步、天然覆盖新列）。
- **写入侧三类守卫**（`business_api::validate_project_parent`，create / update 两路径统一前置）：
  拒自引用、拒指向不存在或已软删的父、拒成环（沿父链上溯，上限 64 跳防异常数据）；守卫通过后
  再委托 `generic_repo`，DTO 三态（缺键 = 不改 / `null` = 移到顶层）沿用既有 `nullable` 反序列化口径。
- **双端侧栏层级树**：项目按 `parent_uuid` 构成层级树后展平渲染（父在前、子紧随其后），逐层缩进
  14px，有子项者带折叠箭头（折叠收起整棵子树）。纯函数层双端各一份、口径完全一致——桌面
  `features/todo/shared/project-tree.ts`、移动 `modules/todo/logic/project_tree.dart`：
  **孤儿（父不存在 / 父已软删）回落顶层**，自引用与成环整体回落顶层（保证递归终止且行不丢），
  同层沿用 `sort_order` 顺序。
- **双端编辑入口提供「上级文件夹」选择**：候选**排除自身与全部后代**（否则成环，Rust 侧必拒），
  文案带祖先路径（"父 / 子"）避免不同层级同名歧义；移动端为当前层级行 + 候选面板，桌面端为 Select。
- **拖拽排序语义**（本批）：拖拽仍只改同级 `sort_order`、**不改层级**（跨层级改父留后续批次）；
  折叠隐藏的后代不在可见序列内、保留原编号——它们只与自身兄弟集比较，不受影响。
  **后续批次已扩展**：横向位移可改父，见上节「清单层级补齐」。
- **mock IPC 边界修正**（`src/test/ipc-mock.ts`）：浏览器 / e2e mock 的 invoke 参数此前直传对象，
  与真实 Tauri IPC 的 **JSON 序列化边界**不一致——值为 `undefined` 的键在真实链路会被丢弃，在 mock 里
  却会让 `Object.assign(entity, input)` 把字段覆盖成 `undefined`（实测：编辑项目只改颜色 → 项目标题
  被清空）。现于命令分发入口统一做一次 JSON round-trip，与真实链路字段语义对齐。
- **未做**（本批）：拖拽跨层级改父、父清单聚合子清单任务。**均已补齐**（2026-09-30），见上节
  「清单层级补齐」。

### 日历周视图（对标 TickTick Week View）

- **桌面日历新增第四档「周」**（月 / 周 / 年 / 议程）：月历组件
  `components/business/month-calendar.tsx` 新增 `mode="week"`，日期网格由 6×7 月网格
  换为**锚点周 7 格（周一→周日）**，其余全部沿用月档同一套实现——今天/休息日/选中态色块、
  休班徽标、农历副标签、任务圆点行、右键快捷新增、**圆点拖拽改期**（落点 id 仍是
  `day:<ms>`，`rescheduleDue` 原样复用），零交互分叉。
- **周档锚点 = 选中日**，翻周即选中日 ±7 天（头部前后按钮与周条滚轮走同一回调），
  不新增视图态——与月档「右栏跟随视图月、选中日高亮定位」同一心智模型，档位来回切换不丢选中日。
- **右栏口径换为「本周任务」**：复用月档的虚拟化分组列表，区间按 ymd 字典序过滤
  （周一 00:00 ~ 周日 24:00 闭区间）；空态与加载骨架同月/年档口径。
- **「回到今天」在周档保留档位**（语义为「回到本周」），月档/议程档维持原有「回今天并切回月档」。
- **周档视觉独立于 fillHeight 拉伸**：7 格拉伸到整屏高度会退化成细长条，故周条恒为
  单行自然高度 + 在左栏内垂直居中（`cellWeek` / `gridWeek` / `numberWeek` / `titleWeek`
  四组尺寸令牌，与 42 格网格分开调校）。
- **日期工具收敛**：新增 `lib/date-utils.ts` 作为本地时区日期计算的单一出口
  （`startOfDay` / `addDays` / `startOfWeek` / `formatYmd` / `dayKey` / `relativeLabel` /
  `dayLabel` / `weekRangeLabel`），替换原先散落在月历、日历视图、快捷日期、NLP 解析的
  4 份 `startOfDay` 与 2 份 `formatYmd`；网格构造抽为 `lib/calendar-grid.ts`
  （`buildMonthGrid` / `buildWeekGrid`）使纯日期计算可被单测直接覆盖。
- **移动端无需改动**：`table_calendar` 的周档（`CalendarFormat.week`，上滑月历收成单行周条）
  已随日历页老版本落地并带专项测试（收展对齐选中日所在周 / 跨月周补位不弱化 / 横滑翻周 ±7 天），
  本次仅核验确认，未改并发会话正在重构的日历页。
- 测试：新增 `lib/date-utils.test.ts`（17 例）+ `lib/calendar-grid.test.ts`（10 例，含
  周日锚点归属本周、跨年周不裁剪、逐格递增无空洞等边界）；新增 e2e `e2e/calendar-week.spec.ts`
  （7 列网格 / 周区间标题 / 翻周 ±7 天 / 回到今天留档 / 切回月档 42 格）。桌面单测 430 passed。

### 每日摘要提醒（对标 TickTick Daily Reminder）

- **新增每日摘要提醒**：每天固定时刻一条汇总通知「今日 N 项 · 逾期 M 项（· 已完成 K 项）」。
  core 新增 `digest_api`，**无新增表 / 无新增迁移**——计数是 `todo_tasks` 上的只读聚合
  （今日截止 / 逾期 / 今日完成三档，本地时区日界，与 `stats_api::local_day_index` 同口径）。
- **配置落 `cfg_kv` 三键**（本机偏好，不随云同步）：`digest_enabled`（默认 **0=关**，
  打扰型功能需显式开启）、`digest_time`（`"HH:mm"`，默认 `08:00`，小时 0–23 / 分钟 0–59
  校验与备份调度同源）、`digest_last_day`（上次**已处置**的本地日，防同一天重复判定）。
- **每日一次判定**（`take_due_digest`）：开关开 + 当天目标时刻已过 + 当天未处置才返回；
  同一天内迟到超过 12 小时补弹窗口（`CATCHUP_WINDOW_MS`）则静默跳过当天并照样记账，
  避免「目标 08:00、21:00 才开机」时深夜补弹当日摘要。
- **文案单一真相源**：`summary_body` 在 Rust 侧生成（今日与逾期皆 0 给鼓励语、今日有完成
  追加尾巴），桌面系统通知与移动系统闹钟取同一份实现，避免双端措辞漂移。
- **桌面**：`digest_scheduler` 60s tick 调 `take_due_digest` → `notify-rust` 系统通知
  （无 action、默认超时；正文点击唤起主窗）+ 写 `notification_log`（kind `digest`，
  通知历史页新增「每日摘要」标签与图标）；设置页「待办」分区新增开关 + 时刻选择器 +
  当前口径预览（`digest_prefs` / `digest_set_prefs` / `digest_summary` 三个命令）。
- **移动**：不走 Rust tick（手机进程会被杀）而走**系统闹钟每日重复**本地通知——
  `NotificationService.syncDailyDigest` 用 `zonedSchedule` + `matchDateTimeComponents:
  DateTimeComponents.time`（AlarmManager 持有，应用被杀/Doze 均准时；独立渠道
  `todo_digest`、独立 id `2000000000`，与提醒三域互不覆盖）；新增 `DigestScheduler`
  在启动与 `dbChanges`（任务表）后防抖重排，让正文跟上最新计数；设置页新增卡片
  （开关 + 时刻选择 + 当前口径预览）。
- FRB 新增 `crates/orbit-flutter/src/api/digest.rs` 桥（`digest_prefs` /
  `digest_set_prefs` / `digest_summary` / `digest_body`），DTO 镜像 + codegen 产物已重生；
  `stats_api::local_day_index` 提升为 `pub(crate)` 供 digest 复用（同口径不漂移）。

### 持续提醒（对标 TickTick Constant Reminder）

- **新增持续提醒**：`todo_reminders.is_constant`（迁移 `0002_reminder_constant.sql`）——
  到期触发后任务仍未完成时，**同一行原地顺延 5 分钟**（`CONSTANT_REARM_INTERVAL_MS`）
  再次提醒，直至完成或提醒被删：「响到完成为止」。不软删、不克隆，天然无雪球；
  锚点取 `now + 间隔` 而非「原时刻 + 间隔」，应用离线数小时补扫时不会连发。
- **完成即停**：完成命令软删存活提醒行 + `list_due_reminders` 的 `done` 过滤双重收口；
  重复任务的持续标记随实例平移（`complete_todo_task` 克隆提醒行时继承），
  下一实例继续「响到完成为止」。
- **双端轮询去重键改 `(id, remind_at)`**（桌面 `notification_scheduler` / 移动 `events.rs`）：
  按 id 去重会把顺延后的后续几轮全部挡掉。
- **桌面系统通知新增「完成」action**（仅持续提醒挂载，排在三档推迟之前）→ 直调
  `complete_todo_task` + emit `todo_reminder:completed`，前端关闭常驻 in-app toast 并
  失效任务列表/计数/详情缓存；正文标注「持续提醒 · 完成后停止」。
- **移动端**：闹钟通知标题/正文标注持续语义；推迟落地（`landSnoozeInDb`）额外替换
  已顺延的持续链并继承标记——否则「顺延链 + 推迟行」会双份提醒。
- **双端编辑入口**：桌面表单/详情抽屉给开关（勾选即持续），行内显示可点击「持续」徽标；
  移动表单给开关行（仅在已设提醒时出现）、详情页给「持续」徽标。
- 提醒 CRUD 的 `is_constant` 带 `#[serde(default)]`（老壳传旧 JSON 按一次性落地），
  加列零 `sync_registry` 改动；FRB DTO 镜像与 codegen 产物已同步重生。

### 节假日更新能力对齐 PiggyCount（每月口径 + 自动开关 + 按年补写）

- **自动更新口径改月度**：原「每日固定时刻（`fixed_hour` 0–23 可配）」下线，改为
  `should_update_now` 月度判定——从未成功即更、上次成功所在自然月 ≠ 当前月即更；
  跨月后下次启动首轮 tick 即补更。随之移除 `holiday_set_fixed_hour` 桥位
  （core / Tauri command / FRB / `tauri.ts` / 移动 `OrbitBridge` 四实现）、
  `HolidayMeta.fixed_hour` 字段与双端「每日更新时刻」UI 及其测试。
- **新增自动更新总开关** `holiday_auto_enabled`（缺省开启，`cfg_kv` 无键按 1 处理）：
  关闭后 Rust 调度器不再联网，仅保留手动更新与按年补写；双端设置页给出开关行。
  **无 DDL 迁移**——全部新状态落 `cfg_kv`（`0001_init.sql` 保持冻结、未新增迁移文件），
  `sync_registry.rs` 白名单与同步表计数断言不动。
- **新增按年 / 按年范围联网补写**：`holiday_fetch_year(year)` 单年整年替换（可选
  2013 ~ 明年，`HOLIDAY_FETCH_YEAR_MIN = 2013`）；`holiday_fetch_range(start, end)`
  两阶段补写——阶段 1 分片并发（`RANGE_CONCURRENCY = 4`，保序 yield）纯网络拉取，
  阶段 2 串行落库（`sqlx` 事务不可并发），连续失败 3 次熔断（`RANGE_ABORT_AFTER`），
  整次操作 `failure_count` 只 +1；取消走 `AtomicBool` 单会话守卫（`RANGE_ACTIVE` CAS）
  + RAII `RangeGuard` 在 Drop 复位，支持并发拒绝与 panic 安全。
- **逐年进度跨端管线**：core 新建独立 `tokio::sync::broadcast` 通道（**刻意不复用
  `EVENT_BUS`**——节假日是只读缓存表，铁律要求不 emit `DbEvent`）；桌面侧
  `holiday_scheduler.rs` 新增一次性进度泵 `app.emit("holiday-progress", ..)`，前端
  `useHolidayProgress()`（`listen` + `useEffect` 清理）驱动设置页进度条与取消；移动侧
  FRB `subscribe_holiday_progress(StreamSink)` → Dart 单个 `StreamProvider` 收口
  （避免重复订阅产生多份监听），承载为可取消的进度弹层。
- **读取按年合并兜底**：`list_holidays` 以 DB 已覆盖年份为准、预置表只追加未覆盖
  年份；`is_holiday_on` 在该年已被 DB 覆盖时严格以 DB 为准（无行即 `None`，不回落预置）。
  修掉「补写任一历史年份 → 2026 预置徽标整体消失」的旧整表回落缺陷。
- **记账正确性 AC-E6 / AC-E7**：历史年份补写只写 `last_attempt_ms`、不动
  `last_update_ms`（否则会静默抑制当月自动更新，属隐性新鲜度 bug）；空响应按成功
  处理并清空该年，UI 明确提示「该年无数据」而非静默当作已更新。
- **双端设置页/缓存页**：桌面「日历与节假日」重构为概览 + 每月自动更新开关 +
  立即更新 + 按年份范围获取（两个 Select，`start <= end` 校验）+ 进度区（内联 bar，
  桌面无 `ui/progress.tsx`）+ 年份分组「更新该年」；移动设置页同款开关，缓存页新增
  范围入口（两次 `showSelectBottomSheet`）、单年「更新该年」与进度弹层（含取消）。
- 回归：`cargo test --workspace --lib` 636 全绿（节假日 29 例：月度三分支 / 按年合并 /
  覆盖年不回落 / `fetch_year` 三分支 / AC-E6 记账差异 / 熔断 / 取消恢复记账 /
  进度广播序列 / 并发范围被拒）；桌面 `pnpm typecheck` + vitest 398 全绿（新增
  `use-holiday-progress` 6 例）；移动端本地分析器 208 文件 0 issue。文档同步：
  `docs/02 §五` 查询键与进度流、`docs/07 §五` backlog、`docs/10` 桥表与 M11、
  `PRIVACY.md`、`docs/adr/0005`。

### 桌面端工具栏收拢为「↑↓」+「···」双菜单

- **12 控件收拢为 5**（TickTick Web 同款，prd/desktop-toolbar-dropdown）：工具栏右侧保留
  搜索框 / 新增 / 模板下拉，原状态 Select、优先级 Select、视图切换五联钮、看板分组
  Select、标签管理钮、存为视图、Ctrl+P 等低频入口全部并入两枚图标菜单——
  **「↑↓」排序与筛选菜单**：分组（仅看板显示）/ 排序五档 / 顺序（升降）+ 状态/优先级
  筛选 Sub 就地展开，段尾回显当前档；**「···」更多菜单**：顶部视图图标排（点按即切不关
  菜单、当前档高亮）+ 隐藏已完成开关 + 存为视图 / 搜索或跳转（Ctrl+P）/ 标签管理。
- **新增排序方向档**：`todo_sort_dir` localStorage 键（`asc`/`desc`，未存过 = 各档
  现状默认方向，存量顺序零变化）；方向只翻转主键比较，回落键不翻、due 档无截止恒
  沉底、manual 档忽略方向。`sortTasks(tasks, sortKey, dir?)` 第三参为可选——所有既有
  调用点语义不变。
- 回归：vitest 新增 6 用例（各档方向翻转 / manual 忽略 / 默认方向快照，64 用例全绿）；
  e2e 新增 2 用例（排序菜单升降序切换 + 视图图标排点按即切菜单不关）并把日历/看板/
  存为视图/标签管理 4 处入口断言平移到菜单路径；全量 smoke 28 用例绿。
  `docs/04 §二骨架图 / §四排序语义 / §七 localStorage 键全集` 规格同步。

### 标签管理弹窗整体高度钉死

- **LabelManager Dialog 固定 `h-[380px]`**（≈3 张标签卡 + 底部新建行，对齐参考图）：
  标签多于 3 条时列表区内部滚动（`flex-1 min-h-0 overflow-y-auto`），弹窗不再随内容
  无限长高；0 条时高度不变，新建行 `shrink-0` 钉底。
  `overflow-hidden` 覆盖 Dialog 原语非交互路径的 `overflow-y-auto`（弹窗自身不滚，
  滚动手势全交列表区）。
- 回归：e2e 新增「标签管理弹窗整体高度钉死」——真实创建链路灌 5 个标签，断言
  弹窗高度=380±2px、列表区 `scrollHeight > clientHeight`、新建输入框仍钉底可见；
  旧代码（无钉高）跑同用例判红。`docs/04 §3.8` 规格同步。

### 桌面端完成态勾选框灰化（对齐移动端）

- **完成 checkbox 去蓝**：列表行 / 看板卡 / 表格行 / 矩阵行 / 详情标题行 / 子任务共 6 处，
  完成态由 `border-primary bg-primary`（待办蓝）改为 `muted-foreground` 弱化灰实底
  （白勾保留），与已完成行的灰色划线标题同调；移动端 `OrbitCheckbox` 早已走
  `deactivatedText` 弱化灰，本次为跨端同源收口。
- 回归：e2e 新增「完成态勾选框灰化」——以 `var()` 探针读同名 token 解析值作基准，
  断言完成态底色等于 `--muted-foreground` 且不等于 `--primary`（oklch 计算值序列化
  不稳定，故不做字符串硬比）；`docs/04 §3.2` 完成 checkbox 规格行同步。

### 桌面端评论输入改为「点击占位框就地展开」

- **详情抽屉评论区**：常显的单行输入框换成「添加评论」占位框，点击才就地展开
  固定高度输入区（160px）；内容超出时走内部滚动条，不再随输入无限增高。
  `Ctrl+Enter` 发送、`Esc` 或取消钮收起（Esc 拦在 Radix DismissableLayer 之前，
  只收输入区、不连带关闭抽屉）。
- **右键「添加评论」弹窗**：Textarea 由 `field-sizing` 自适应增高改为固定高度 +
  超出内部滚动，与抽屉同口径。
- 回归：e2e 新增「详情评论：点击占位框就地展开固定高度输入区」（折叠态无输入控件 /
  展开即聚焦 / 灌 20 行后 `scrollHeight > clientHeight` 且控件高度不变 / 发送后收起并落库）；
  `docs/04 §3.4-8` 评论区块描述同步。

### 移动端清单侧栏与日历卡片化对齐今天列表

- **清单侧栏整卡化**（今天任务列表同款 `OrbitCardSegment` 口径）：
  快捷视图 7 行一卡、搜索/筛选器/回收站三行一卡、项目行 + 「新建项目」
  行一卡、已归档组一卡、「未分组」独立单段卡；卡外缘左右各让 12，
  卡间 `cardGap`。项目行按压水波盖在卡面上（行内自带圆角摘掉，
  外缘圆角归卡片）；重排把手与长按菜单行为不变。
- **日历月历整卡**：整张月历是一张单段卡（外缘 12、卡内垫 8），
  月 ⇄ 周收展只改变卡内高度；选中日描边/今天实心块口径不变。
- **议程档分组卡**：每组日期头作卡内首段（选中日高亮底保留，
  只取上圆角与卡片同弧）+ 任务行作续段；任务行去掉自带灰底圆角
  （卡面由段统一铺 `surface`），行高收敛到 `touchTarget` 不随内容跳动。
- **选中日列表去缝**：卡片/时间线两档段间 2px 间隙取消（整卡不断开，
  与今天列表同口径），外缘 16 收至 12；「当天没有任务」与议程档空态
  改为单段卡。
- 回归：新增 `sidebar_calendar_card_test`（侧栏裸行兜底 + 月历单段 +
  选中日空态卡 + 议程组卡首段）；既有日历/侧栏/冒烟用例全绿。

### 移动端任务行勾选框收至 20px

- **任务行 checkbox 由 24 下调到 20**（列表/看板/表格/矩阵/日历卡行统一，
  与桌面端任务行 `h-5 w-5` 跨端同源；相对 15px 标题更协调，热区仍外扩到
  44 不变）。看板/表格改用 `taskCheckboxSize` 口径（原误用子任务档）。
- 详情标题 28 / 子任务 22 不动；`orbit_checkbox_test` 锁定默认 20。

### 移动端快加面板工具栏不抢键盘

- **锚点小卡片改 Overlay 直挂**（优先级/项目/标签/「更多」）：原来走
  `showGeneralDialog` 路由，弹出即抢走输入框焦点致输入法下沉；直挂后焦点
  全程留在输入框，可边选边打字。定位/动效与路由版同源（`orbitFloatCardLayout`
  + `OrbitOverlayCard`），卡外点按关闭；卡片开着时返回键先关卡片（PopScope
  保住输入草稿）。
- **共享层**：定位计算抽取 `orbitFloatCardLayout`（路由/Overlay 同值防错位）；
  下拉面板内容公开为 `OrbitDropdownPanelView`（`onClose` 覆写关闭动作，默认
  路由 pop，既有调用方行为不变）；底部大抽屉（截止日期/图片管理）仍走路由，
  关闭后显式恢复焦点。
- 回归：`quick_add_sheet_test` 新增「工具栏不抢键盘」3 例（优先级/更多菜单
  打开时输入法不消失、截止抽屉点选后焦点回来，修前两例变红）；
  `orbit_dropdown_panel_test` 跟进公开类名定位。

> **0.1.0 条目口径**：0.1.0 是项目整体首个版本，本条目由 2026-08-23 初始提交至
> 2026-09-24 的**全部 git 记录**（543 次提交：222 feat / 130 fix / 32 perf / 84 docs，
> 余为 chore / refactor / style / test 及其他；计数口径为提交主题前缀，`git rev-list
> --count` 与 `findstr` 实测，PowerShell 原生管道会吞掉含中文主题的行故不用它计数）
> 按模块归并总结——合并同源提交、剔除过程性改动，不逐条罗列中间过程；逐条明细以
> git 历史与 `docs/07` backlog 为准。历史 `v0.1.0`
> （2026-09-15）tag 及其后的全部未发布工作（云同步存储结构重构、第五轮探查收口、
> 内存门禁入库、移动端快速添加面板与抽屉口径收口等）已一并并入本条目。

## [0.1.1] - 2026-09-26

### 移动端底部抽屉统一走根路由（2026-09-26）

- **全项目 `showModalBottomSheet` 补 `useRootNavigator: true`**：页签分支各持
  Navigator 后，落在分支路由的抽屉会被壳的悬浮钮/底栏盖住（FAB 与底栏是
  Scaffold 兄弟层，抽屉困在 body 内）——走根路由抽屉才盖住底栏全屏可点。
  共 15 处（确认/单选/更多动作三共享弹层 + 快加/表单/模板/日期/颜色/密码/
  标签/筛选器/详情区/侧栏/同步状态/子列表面板）。
- **单选弹层行首语义图标位**（`SelectItem` 新增 `icon` + `iconColor`，与色点
  二选一）：快捷视图切换等行语义来自图标而非颜色的场景（与清单页快捷行
  图标同源），`orbit_sheets_test` 锁图标色值与尺寸。
- 回归：`quick_add_sheet_test` 新增「抽屉盖住导航」用例——分支 Navigator 内
  开快加面板，壳 FAB 点位点不透、面板经遮罩可正常关闭。

### 移动端 UI 对标优化批次二：竞品版式收编（2026-09-25）

- **逾期区一键「顺延」**：今天/列表视图逾期区块头行（manual 档为列表上方横幅卡）新增
  「顺延」——整组逾期任务一键改期到今天 18:00 收工时刻（18:00 已过则到明天 18:00，保证
  任务真的离开逾期桶）；走批量写库单次收敛刷新，可撤销。
- **日历月档下方列表改选中日口径**：点日格即看当天任务——头行为日期语义头（今天 /
  M月D日 周X + N天后/前 + 农历节日副标签 + 休/班徽标），任务列同一张卡（勾选框优先级
  描边环 + 标题 + 右列时刻与重复/提醒/描述图标，可直接勾选完成）；当天无任务居中提示。
  议程档保持整月按日分组不变（整月浏览走议程档或翻月点选）。
- **四象限更名对齐竞品（双端）**：象限名由行动短语（立即做/计划做/抽空做/可延后）改为
  「重要且紧急 / 重要不紧急 / 不重要但紧急 / 不重要不紧急」，格头 = 罗马徽标Ⅰ-Ⅳ彩底
  圆标 + 象限色名称；桌面端补齐罗马徽标与色名（原「名称 + 轴副标」去重）、第四象限
  识别色由中性灰改绿（与移动端/竞品同源：红/琥珀/蓝/绿）。
- **完成按钮方角化对齐 TickTick（双端）**：任务勾选框由圆形改 4px 圆角方框
  （移动端 `CircleCheckbox` 更名 `OrbitCheckbox`，全应用 7 处列表/看板/表格/
  四象限/详情/日历统一；桌面端列表/看板/四象限/详情抽屉四处完成钮同改）；
  **桌面端紧急度改为以完成按钮颜色为准**——未完成描边 = 优先级色（P0「无」
  回落中性灰），与移动端既有口径同源，列表/四象限的优先级左缘竖条随之移除
  （日历右栏行无勾选框、竖条保留）；完成态保持主题色实底白勾不变。
- **日历选中日任务卡行内元信息图标补全**：描述图标此前的数据位因列表通道
  列裁剪恒为空（`description` 在 list 投影置 NULL，万级列表省 47% IPC 体积）
  而永不渲染——新增「有描述」行元信息投影（`task_description_flags`，只出
  description 非空的存活行 id，不回传原文不破裁剪）贯通 core → FRB 桥 →
  移动镜像，B7 表级失效链挂 `todo_tasks`（描述编辑即时点亮/熄灭）；重复与
  提醒图标沿用既有口径（提醒走 A4 投影），无元信息的行不出图标列。
- **日历月档上滑收成单行周条**：月历网格上滑收成一周条（选中日所在周，列表随之上顶）、
  下滑展开回整月——周条内横滑翻周（跨月周日期不弱化、标题跟随焦点月）、点格切换选中日
  任务卡，农历副标签/休班徽标/事件圆点在周条同渲染；「回到今天」在周档跳回本周。
  `OrbitMonthCalendar` 新增受控档位参数（calendarFormat/availableCalendarFormats/
  onFormatChange/focusedDay/dimOutsideMonth），单档调用方（日期选择面板等）手势与
  原行为不变；周档 focusedDay 须回传 onPageChanged 原样日期（归一化到月初会拽回
  月初那一周）。
- **底部导航可配置（功能模块）**：对齐竞品「功能模块」——「更多」面板标题行新增「编辑」入口，
  进全屏配置页管理八个模块（今天/清单/日历/四象限/统计/搜索/回收站/设置）：红圈减号停用、
  绿圈加号启用、段内拖拽手柄重排（触感与抬起动效同任务列表口径），最后一个启用模块不可停用；
  底栏 = 启用序前 4 个模块 + 固定「更多」位，其余启用模块收进「更多」面板，配置即写即落盘
  （`LocalPrefs`，键 `bottom_nav_modules`）并实时跟随重建。路由从 4 分支扩为 8 分支（统计/搜索/
  回收站/设置改为页签分支：面板/侧栏/设置页入口改 `go` 切分支，底栏常驻、切页不丢栈；冷启动
  落点随配置落到启用序第一个模块），默认配置与改造前导航完全一致。
- **底部导航重构**：四页签 + 中央添加钮改五页签均分 + 右下悬浮新建钮（今天 / 清单 / 日历 /
  四象限 / 更多）；「更多」动作位不切页——就地弹出锚在页签上方的次级目的地面板（统计 /
  搜索 / 回收站 / 设置），点面板外关闭、下层照旧可读。
- **四象限升级主导航页签**：新增 `/todo/matrix` 页签分支（全量任务落桶，桶内截止升序）；
  统计页退出页签改「更多」面板推入（补返回键），页面内新建入口统一右下悬浮钮（落点仍随
  `QuickAddContext` 预填，长按直达模板新建）。
- **四象限改版**：弃「概览 2×2 计数 → 点格下钻」两态，改为整幅 2×2 恒在——四象限卡同屏
  等分、任务行直接列在格内（标题 + 截止日期纵排两行）、超出格高格内自滚，空象限居中
  「没有任务」；象限识别色改罗马数字徽标口径（Ⅰ 红 / Ⅱ 琥珀 / Ⅲ 蓝 / Ⅳ 绿）。
- **批量选择入口收敛到列表档**：选区行只在列表档渲染，看板/表格/矩阵档的「批量选择」
  面板入口隐藏（此前进入后无视觉落点）。

### 移动端 UI 全面优化批次：语义收敛与几何收正（2026-09-25）

- **语义色单一来源**：逾期红统一 `OrbitAccents.overdueRed`（任务行 / 看板 / 表格 / 多选行 /
  逾期段头，此前与 `colors.destructive` 两套红并存）；计数角标统一红；星标统一星标黄。
- **几何收正**：看板 / 矩阵视图补左右 12 页边（列卡此前贴死屏幕边缘）；批量工具条收到页尾
  8px、选择态列表底部动态让位（末行不再被遮）；页签分支内各屏页尾 80px 手势兜底让位收敛为
  16px（底栏页签接管手势区后的遗留口径）。
- **触控与完成态**：`CircleCheckbox` 布局盒外扩到 `max(size, 44)`、图形居中（视觉直径不变）；
  完成态标题全视图统一「划线 + 置灰一档」。
- **视觉收敛**：看板卡 / 表格行优先级改由勾选框描边环承载（五种优先级形态收敛为两族）；
  侧栏功能行图标改次要文字色、计数徽标底色回归 token；共享段头原语 `OrbitSectionHeader`
  上收（侧栏 / 搜索单一来源）；项目拖拽把手热区补足 48。
- **搜索结果行重排**：与主列表任务行同一信息层级（状态图标描边承载优先级 / 项目名按色着字 /
  口语化日期右列 / 完成态划线置灰），日期由裸 `YYYY-MM-DD` 改口语化；搜索初始态补引导空态。
- **空态与加载**：回收站初次加载补骨架（不再闪「回收站是空的」）；日历空月文案改口（新建
  入口已上移底部导航中央添加钮）；日历月份标题回归字阶（w800→w600）、工具条按钮热区回 48、
  任务卡补水波反馈。
- **件杂**：关于页补右滑入转场；筛选器优先级档补全 P5；快速添加胶囊 / NLP chip 内边距回
  4pt 网格；统计总览卡栅格间距统一 `cardGap`。
- **文档**：docs/10 重命名为《移动端对标差距分析》并全文竞品名中性化（对齐批次文档口径）；
  docs/05 §4.5 完成态口径、§七常量（热区下限 44）、§十热区条目同步。

### 视图命名收尾：e2e 定位与规格文档同步（2026-09-25）

- e2e 冒烟 #39 用例的侧栏入口定位改「今天」（exact 匹配防任务行子串误中）；
  docs/04 / docs/05 规格中「今天截止 / 本周截止」视图名同步为「今天 / 近7天」。


### 重排档渲染流逾期置顶（2026-09-25）

- 拖拽重排（manual 档）此前按数据原序平铺，今天/近7天视图纳入逾期后逾期行
  会混在流中：渲染流改为逾期置顶平铺（`_manualReorderStream`，与标准分支的
  逾期置顶段同序），重排落库 `_reorderTasks` 消费同一流保证槽位索引一致；
  头行/分隔行不进流（会打破 ReorderableListView 槽位数学），无逾期时与旧
  口径逐字节一致。


### 日期展示口语化——列表/看板/表格/详情/表单全链（2026-09-25）

- **新增共享格式化**（`task_logic`）：`formatDueShort`（相对日期，带非零时刻时补
  `HH:mm`；本地零点纯日期不带时刻——时刻判定取本地字段，UTC+8 下
  `ms % 86400000` 恒非零的坑）与 `formatStampLabel`（历史/提醒戳：今天 / 昨天 /
  M月D日 / 跨年带年份，恒带时刻）。
- **消费面**：任务行右列（「今天 18:00」替代裸「今天」丢时刻）、看板卡与表格
  截止列（原 ISO `2026-09-24` → 「昨天」，表格列宽 64→76 容纳时刻）、详情属性行
  截止/开始日期、详情提醒行与历史时间戳（原 `2026-09-25 07:18` → 「今天 07:18」，
  历史行同步去掉 monospace）、新建表单日期/提醒值行与 NLP 解析 chip。
- `formatDueShort` / `formatStampLabel` 纯函数单测注入固定时钟覆盖边界。


### 项目视图行内去重项目名（2026-09-25）

- 列表 / 矩阵 / 多选行与看板「按状态」分组的卡片在**项目视图内**不再重复显示
  项目名（页头已是该项目，行内重述是噪音）；快捷视图、未分组、搜索等跨项目
  语境保留项目名着色段。表格视图保留「项目」列（结构化网格列位恒定）。


### 今天/近7天视图纳入逾期任务（2026-09-25）

- **视图窗口口径**：今天 / 近7天两个聚合视图改为「截止 < 窗口上界即命中」——逾期
  未完成任务进入「今天」页签与「近7天」视图，由既有逾期置顶段自然承接渲染
  （此前逾期任务只出现在项目列表，主聚合视图反而看不到）；与图标角标
  「今天截止或已逾期」计数口径统一，双端（移动 filterTasks / 桌面 task-filters）
  同步同口径。
- **命名随语义**：「今天截止」→「今天」、「本周截止」→「近7天」（视图已含逾期，
  原名不再准确）；逾期区下的分隔行按视图语境显示「今天 / 近7天」，项目等
  其余入口维持「其余任务」。
- 移动 603 项 flutter test、桌面 381 项 vitest 全绿（today/week 边界用例随新
  口径更新：昨日截止命中、明日零点起不命中）。

### 移动端列表显示详细与显示设置（2026-09-26）

- **页头 ⋮ 面板补两项**（「这个列表」组由六项扩为八项）：「显示详细」开关（关 =
  行内只剩标题 + 右列时刻的紧凑形态）与「显示设置」入口（底部抽屉：显示详细 +
  所属清单 + 标签三开关，写即落盘；主关关闭时另两位开关置灰禁用）。
- **三位显示偏好**（`logic/display_prefs.dart`，本机 `LocalPrefs` 键
  `todo_show_detail` / `todo_show_project` / `todo_show_tags`，缺省全开、零 DDL、
  不进同步）：分别门控任务行副标题整行 / 其中的所属清单名 / 标签段；搜索等未接
  偏好入口的复用面保持原渲染。
- 测试：新增 `test/display_prefs_test.dart`（控制器默认与落盘 2 例 + 行渲染门控
  4 例 + 卡片段位 1 例）；`flutter analyze` 零告警。

### 移动端日历页头收敛与选中日双样式（2026-09-26）

- **页头收敛**：移除「日历」文字标题——月份导航（`< 年月 >`，点标题进年视图）与
  回到今天 / 议程切换 / 节假日更新三个动作直接落在页头（标题槽 + 动作槽）；
  窄屏下标题等比缩字不断行（既有 FittedBox 口径），图标保持 48 热区不压缩。
- **选中日列表双样式**（月档，竞品同款切换钮在日期语义头右侧）：卡片（默认，
  勾选 + 标题 + 右列时刻/元信息）⇄ 时间线（`HH:mm` 左置列 + 右侧卡片行，
  无时刻留空对齐）；档位落本机偏好 `todo_calendar_day_compact`（缺省卡片，
  零 DDL、不进同步），议程档分组列表不受影响。
- 测试：`calendar_screen_test` 页头断言跟进（`日历` 文字 → 年月标题，翻页改
  tooltip 定位）+ 新增样式切换用例（卡片 ⇄ 时间线往返 + 时刻左置）。

### 移动端底栏去文字与功能模块页顶预览（2026-09-26）

- **底栏纯图标**：移除五枚页签文字（竞品同款），选中态只剩主题强调色图标；
  读屏文案走语义标签（button + selected），角标与「更多」锚点面板不变。
- **功能模块页顶加底栏预览**（编辑操作页顶部预览同口径）：启用序前 4 个模块 +
  固定「更多」位，与真实底栏同形（56 高 + 表面 + 描边 + 均分 + 22 图标），
  只读、启停/重排实时跟随；底部说明补「上方为底栏预览」。


### 移动端功能模块配置页横滑换段与跨段拖拽（2026-09-26）

- **行左右滑动在两段间移动**（与行首圆形加/减钮同语义的快捷路径）：滑动方向
  不区分左右、归属只看所在卡片；`Dismissible.onUpdate` 手势进度驱动预览图标
  跟手位移（滑出段淡出让位、滑入段幽灵图标淡入占位），过阈值一次触感确认，
  取消回弹沿原路跟回。
- **手柄拖拽跨段直移**（`NavModulesController.move`，槽位越界钳制、同段退化为
  区内重排、最后一个启用模块不可停用）：手指可在两张卡片之间直拖，悬停段/
  槽位按列表高度比例折算实时映射（行内带简介高度不一，不用整除口径），预览
  按落位结果预演、跨段翻越触感确认、松手提交即落盘，落位行播一次入场动画。
- 行内启停走 tooltip 按钮（横滑底衬加减图标不再承担定位）；`home_shell_test`
  跟进 tooltip 定位 + 懒构建段滚动断言；`nav_modules_test` 新增跨段移动 6 例
  （槽位插入/越界钳制/末模块保护/同段退化/落盘）。

### 移动端今天页签快捷视图切换（2026-09-26）

- **今天页签根标题即切换器**（点标题开单选抽屉）：在我的一天 / 今天 / 明天 /
  全部任务 / 已完成 / 收藏 / 无日期之间切换，切到哪标题就叫哪（行首语义图标
  与清单页快捷行同源、当前档打勾）；列表/空态/分隔行/Logbook 分组/新建落点
  同步跟随，切回今天即清覆写；会话态不持久化（下次进页签回到今天本位）。
- 页签栈内入栈的今天视图与项目/未分组列表不挂切换器（标题即入口语义）；
  覆写到别的视图时日期副标同步消失。
- 单选弹层图标位用例进 `orbit_sheets_test`（图标色值与尺寸断言）。

### 移动端已完成行整行置灰（2026-09-26）

- **完成态统一走弱化灰**（`deactivatedText`）：标题划线色、日期短标签、标签
  色点与文字、项目名、重复/提醒/进度/关联/星标图标全部置灰，不再保留主题蓝、
  逾期红、星标黄、优先级色环与标签原色（已完成实例不再警示）；未完成态渲染
  口径不变。勾选框填充同步置灰（`OrbitCheckbox.activeColor` 改弱化灰，
  完成态描边不再传优先级色环）。
- 回归：新增 `done_gray_test.dart`（标题/日期/星标/勾选框/四元信息图标统一
  置灰）；`orbit_checkbox_test` 跟进填充色断言。

### 双端节假日数据缓存查看（2026-09-26）

- **移动端新增缓存页**（`/settings/holidays`，设置页日历区「节假日数据缓存」
  入口）：缓存概览卡（总数放假/补班拆分 + 覆盖年份 + 更新记账 + 立即更新，
  走既有 `holidayUpdate` 桥位）+ 按年分组行（日期 + 休/班徽标 + 假日名，
  徽标配色与日历页同源）；只读聚合、不进同步白名单。
- **桌面端日历分区加数据缓存卡**：同源汇总与按年分组（`details` 折叠，最新年
  默认展开）+ 立即更新按钮；纯函数 `calendar-cache-format.ts`（汇总/分组/
  日期标签）与单测共置。
- 测试：移动 `holiday_cache_page_test` + 桌面 `calendar-cache-format.test.ts`。

### 移动端设置页视觉收敛（2026-09-26）

- **关于/外观/通知历史三页改 SectionCard 分组**（与缓存页同口径）：裸
  ListTile/SwitchListTile 改分组卡 + 值行/开关行；列表顶距统一按状态栏 +
  页头行高 + 16 计算、水平内边距统一 `pageInline`、底垫手势区 + 32。
- 统计页与其骨架屏同补 `pageInline` 水平内边距（原 16 硬编码）。

### 移动端拖拽浮层底面随抬起实色化（2026-09-26）

- **侧栏项目行 proxyDecorator 补实色渐变**：扁平行本身透明，常驻透明会透出
  页面底色变成灰块——底面随抬起 `elevated` 从透明渐变为实色 surface（与任务
  列表 manual 档 / 编辑操作页同口径，`Clip.antiAlias` + medium 圆角 + 6 高度
  阴影不变）。
- 口径入库：AGENTS.md 新增拖拽浮层统一口径条（scale + 实色底 + 起止触感，
  `elevated` 取 `AppMotion.standard.transform`）。

### 移动端底部页签主导航（2026-09-25）

- **底部导航栏落地**（`OrbitBottomNav` 原语 + `HomeShell` 壳式主导航）：今天 / 清单 /
  日历 / 统计四个一级页签经 `StatefulShellRoute.indexedStack` 各自持栈，切页签互不丢栈、
  页签内入栈（任务列表 / 搜索 / 回收站等）底栏常驻；任务详情、设置等根级路由覆盖
  全屏、底栏随之隐藏。页签选中态主题色高亮 + 切换触感反馈。
- **中央凸起添加钮承担全局新建**：48px 主题色圆钮（`OrbitFab` 新增 dimension 小档），
  新建落点跟随当前列表（`QuickAddContext` 登记页面筛选入参，预填项目 / 视图标记），
  长按直达模板新建；各一级页右下 FAB 统一上收，页面不再另设悬浮钮。
- **「今天」页签**：`/today` 成为启动默认落点，页头「今天 + M月D日 周X」日期副标
  （无返回键），完整复用今日截止视图的逾期置顶 / 完成进度线 / 已完成折叠卡能力；
  页签图标挂今日未完成计数角标（>99 折叠 99+）。
- **清单页信息架构收敛**：日历 / 统计升级页签后移除清单页对应入口行；快捷方式
  「今天」直达 `/today` 页签根。
- 全量 601 项 flutter test 通过（新增底部导航壳 4 用例：页签切换 / 中央添加 /
  角标计数）；模拟器目检页签切换、新建落库、详情全屏隐藏底栏、暗色模式。

### 桌面端四象限视图与完成进度线（两端对齐）（2026-09-25）

- **桌面视图档增至五档**（`ViewMode` 新增 `matrix`，工具栏第五钮 + localStorage 白名单 +
  内容区分支）：2×2 恒定四象限（宽屏无下钻态），每格色带/计数 + 格内独立 `useVirtualizer`
  虚拟化列表；行复用 TaskRow 信息层级（优先级竖条/勾选/标签/项目/提醒/截止/子任务进度），
  交互收敛为勾选完成 + 开详情 + 收藏（拖拽/多选在象限分桶下语义不成立）。`groupEisenhower`
  纯函数与单测同移动端逐字对齐；视图循环快捷键顺带修掉漏 table 档的既有缺陷。
- **任务面板完成进度线**（对齐移动页头）：工具栏底缘 2px 主题色通栏线，宽度 = 完成占比
  （width 过渡补间），Tooltip「已完成 x / y」；仅在既有未完成又有已完成时出现。
- **内存口径两端确认**：桌面 React Query 默认 gcTime 10min + 大列表 key 10s 收敛 +
  `perf-metrics` 双门禁（audit-unbounded 0 违例、growth-curve 阈值在 CI），与移动端
  autoDispose 改造对等，无需改码。
- 桌面 380 项 vitest + 37 项 Playwright e2e 全绿；浏览器目检（mock 四象限数据）验证
  矩阵渲染、进度线出现与勾选联动（20%→30%）。

### 移动端内存收口（2026-09-25）

- **五个 family provider 改 autoDispose**（`taskDetailProvider` / `taskActivityProvider` /
  `searchProvider` / `statsProvider` / `todoTasksSearchProvider`）：riverpod 3 的 family
  默认不自动回收，浏览过的每个任务详情/活动轨迹、搜过的每个关键词（含结果快照）、
  翻过的每个统计年份（含 365 天聚合）都常驻到进程结束；改后仅当前在看的实例驻留，
  离开即释放。
- **图片解码缓存封顶**：`imageCache` 从默认 1000 张/100MB 收到 300 张/60MB
  （`main.dart`，解码侧本有 cacheWidth 降采样，此处补缓存总量上限）。
- 全量 597 项 flutter test 通过——无用例依赖跨页缓存常驻语义。

### 移动端列表页头完成进度线与未完成计数（2026-09-25）

- **页头新增完成进度线**（`OrbitPageHeader.progress` 可选槽）：
  页头底缘 2px 主题色线通栏覆盖在 1px 描边之上，完成占比变化走隐式补间；只在
  「既有未完成又有已完成」时出现（看板/表格档隐藏完成行、Logbook 恒为完成集，不出线）。
- **标题旁未完成计数**：列表页标题右侧灰字小计数（Logbook 态不渲染），长标题与
  计数同行 `Flexible` 防溢出。
- 页头结构微调：水平内边距从 Container 移到标题行，进度线通栏；状态栏避让几何
  不变（既有几何测试全绿）。

### 移动端四象限视图（Eisenhower Matrix）（2026-09-25）

- **视图档新增第四档「矩阵」**（`TaskViewMode.matrix`；纯视图层实现，
  不动 Rust、不进同步）：页头 ⋮ 面板「视图」就地展开选档，编辑项目页视图示意图同步补齐。
- **轴口径**：重要 = 优先级 ≥ 高(3)，紧急 = 截止 ≤ 今天末（含逾期，本地日界）；
  已完成不入桶（`groupEisenhower` 纯函数 + 单测）。
- **概览 + 下钻两态**：概览 2×2 象限格（象限色带 + 行动短语 + 轴文案 + 计数 +
  前三条标题预览），点格下钻该象限全量任务列表，行复用列表档 `TodoTaskTile`
  （勾选/侧滑/提醒徽标全功能），返回行回概览。
- 象限识别色全部取既有 token（逾期红/待办蓝/琥珀/次要文本灰），零新增色值。

## [0.1.0] - 2026-09-24

### 移动端快速添加面板档位改锚点卡片（2026-09-24）

- **共享浮层卡片原语** `OrbitFloatCard` / `showOrbitFloatCard`（`orbit_dropdown_panel.dart`）：
  锚点上方 / 页头下方双形态，页头下拉面板改走同一壳（不再各包一层边框）；右沿钳制修掉
  左置按钮右对齐时 240 宽卡片滑出左屏的"窄条"假象；宽度统一走 `orbitFloatCardWidth`
  （屏宽 - 32 钳制）。
- **档位交互改锚点卡片**：优先级 / 项目为锚在触发钮上方的单选卡片（点选即回填关闭），
  标签为锚点多选卡片（点行即选中/取消，无确认尾栏）；日期改快捷抽屉
  （今天 / 明天 / 下周 / 选择日期…/ 清除日期，与桌面 `QuickDateMenu` 同口径）。
- **选中态只落底部图标**：已选档位展开为「图标 + 具体值」文字胶囊（日期/项目/标签/张数
  直接可见，优先级只旗子变该档色），输入框上方的 chips 行删除；术语「清单」改「项目」。
- **触感只给勾选确认**：勾选框与左滑完成只在未选→已选时震（docs/05 §9.1），滑回来恢复/
  取消完成不震。
- 测试：`quick_add_sheet_test` 档位交互改新口径（含卡片落屏内断言）+ `calendar_screen_test`
  长按预填跟进为图标态；全量 590 例绿 + `flutter analyze` 零告警。

### 移动端密码输入抽屉与 AlertDialog 清零（2026-09-24）

- **新增密码输入共享口径** `orbit_password_sheet.dart`（`OrbitSheetScaffold` 骨架，1–3 个
  obscure 字段 + 可选说明，长度下限与两次一致校验原样保留）。
- **设置页 3 处**（改主密码 / 开启加密 / 指纹密码确认）与**同步页 3 处**（改同步密码 /
  升 v2 / 密钥包密码）改走该抽屉。
- **`AlertDialog` 全量清零**（仅剩附件图片预览用透明 `Dialog`，非选择/确认/输入不算违规）；
  `AGENTS.md` 与 `orbit_sheets` 分工注释同步终态：选择走底部抽屉（页头列表操作例外走
  下拉面板）、确认走确认抽屉、输入走输入型抽屉。

### 移动端编辑操作页直拖换段与实时预览（2026-09-24）

- **跨段直拖**：手柄行可跨卡片直接拖过「更多」标题换段（标题行不可拖起但会被实时挤开），
  落点槽位即插入位并提交；拖拽中顶部预览实时预演（插入撑开 / 闭合），跨段翻越给触感确认。
- **横滑跟手**：行左右滑动由 `Dismissible.onUpdate` 进度归一驱动预览让位与幽灵占位；
  跟手期间时长切 `AppMotion.instant`（图标与手指 1:1 零拖尾），松手后切回常规时长收尾；
  顺带修掉落位入场动画从未播过的问题（只播换段落位行）。
- 双卡片加滑动换段动画：行滑动与加/减圆钮同语义换段，段内手柄拖只调顺序不换段；
  纯逻辑 `reorderQuickActions` 单测覆盖。

### 移动端新建统一入口与输入型底部抽屉（2026-09-24）

- **新建统一走列表页快速添加面板**：侧栏 FAB、桌面快捷方式、日历 FAB、日格长按改调
  `showQuickAddSheet`（同一入口）；面板新增 `initialDueDate` 预填（日历长按口径）；
  完整表单仅留编辑态 / 全屏展开 / 模板套用三条路。
- **新建项目 / 新建编辑标签改输入型底部抽屉**（名称输入 + 色板 + 固定尾栏，与模板/
  筛选器表单同口径；空名屉内拦截 toast，控制器交抽屉子树释放）。
- 测试口径跟进（侧栏 FAB 断言改面板、`todo_screens_smoke_test` 同步）。

### 重复任务完成推进提示（2026-09-23）

- **完成桥返回下一实例**：移动 `todoTaskComplete` 改返回手写镜像 `CompleteTaskResult`
  （task + nextInstance，Rust / Mock 同口径）；详情页 / 列表页勾选与通知「完成」动作弹
  「已完成，已生成下一期：M月d日（周X）」（后台静默）；批量完成单槽汇总，
  「已为 N 条重复任务生成下一期」并入撤销浮层副文案。
- **桌面同口径**：单条 toast + 批量汇总（`formatCnDate` 由 `repeat.ts` 导出复用）。
  背景：单实例链模型下完成即克隆下一实例，无提示用户会对列表多出的一条感到茫然。
- 测试：`todo_complete_test` 补 nextInstance 契约断言。

### 移动端底部快速添加面板 + 「编辑操作」设置页（2026-09-23）

- **底部快速添加面板**（新文件 `apps/mobile/lib/modules/todo/quick_add_sheet.dart`）：任务子列表右下加号
  点击即弹（空态「新建任务」同一入口）——输入框「准备做什么？」+ 已选条件 chips（日期/优先级/清单/标签/图片数，
  点 x 单项清除）+ 快捷操作图标行 +「...」更多 + 发送圆钮。Modal 抽屉承载（`OrbitSheetScaffold` 骨架，
  键盘避让 + 0.7 屏高上限），**不做常驻输入栏**（窄屏会吃掉列表可视区，docs/05 §八）。
- **七档快捷操作**（`logic/quick_actions.dart`）：日期 / 优先级 / 标签 / 清单 / 图片 / 模板 / 全屏。
  默认工具栏四档，图片·模板·全屏收在「...」菜单（尾部固定「设置」入口）。**语音输入与「转换为笔记」不做**：
  本仓无语音插件、无笔记实体，不摆无后端支撑的假功能。图片走「先建任务再挂附件」（单张失败不阻断任务本身）；
  模板复用既有「模板选择 → 表单预填」链（与长按加号同源，`showTemplateCreateFlow` 抽出共用）；
  全屏=携当前草稿打开完整新建表单；标签为多选抽屉（本地勾选态 + 底部确定，任务未创建不能勾选即落库）。
- **提交口径与桌面 `QuickAddBar` 一致**：NLP 解析（`parseQuickInput`）显式值 > 面板手动选择 >
  当前快捷视图默认值（#39 视图标记；今日/本周截止归一 18:00）；标签取 NLP ∪ 手动选择的并集。
- **「编辑操作」设置页** `/settings/quick-actions`（设置 → 组织 → 编辑操作）：面板形态预览（只读）+
  **一张连续可拖列表**——段标题「更多」之上 = 工具栏直显档、之下 = 收进「...」菜单的档，
  **拖拽越过标题行即换段**（标题行不可拖起，但会被拖拽项实时挤开，分界线随落点移动；
  重排切段抽成纯逻辑 `reorderQuickActions` 可单测），同段内拖拽只调顺序；行内圆形加/减按钮
  是跨段移动的快捷路径。落本机偏好键 `todo_quick_actions`（未知名忽略、缺档补「更多」，
  跨版本新增档不丢）。零 DDL、不进同步。
- **本页动效**：预览行图标用 `AnimatedPositioned` 按槽位定位——换序/换段时**平滑滑到新槽位**；
  拖拽抬起走项目既有口径（1.02 放大 + elevation 6 + surface 底 + 起止轻触反馈），
  行内加/减圆钮底色与图标随归属渐变，抬起中的档位在预览里着强调色。
- 文档：docs/05 新增 §十二 规格 + §4.2 FAB 描述与 §八 不对称条目；docs/01 §3.2「快速输入栏」由
  「桌面专属」改为两端。
- 测试：新增 `test/quick_add_sheet_test.dart`（档位读写 3 例 + 跨段重排 4 例 + 面板交互 5 例 +
  设置页 2 例）；全量 575 例绿 + `flutter analyze` 零告警。

### 移动端页头下拉面板 + 「编辑项目」整页（2026-09-23）

- **页头 ⋮ 改为顶部下拉面板**（新原语 `shared/widgets/shadcn/orbit_dropdown_panel.dart`）：锚在页头下沿、
  不铺遮罩、条目成组带 1px 分隔线；带子项的条目**就地展开**（子项缩进到文案列、当前档打勾），
  展开期间其余顶层条目置灰且不可点（点它们只收起子菜单）；点面板外关闭。六项两组——「这个列表」：
  编辑项目（仅项目视图，push 编辑页）/ 视图（就地展开列表·看板·表格）/ 看板分组（仅看板档）/
  隐藏已完成（开关项，与已完成卡头行同源同态）；「怎么操作」：筛选（行尾回显已启用档数）/
  排序方式（就地展开五档）/ 批量选择（进多选并预选首条未完成任务）。
- **「编辑项目」由对话框升级为整页**（`apps/mobile/lib/modules/todo/project_edit_page.dart`，路由
  `/todo/projects/:id/edit`）：页头 `X` + 标题 + `✓`（无改动置灰、保存中转圈）+ `⋮` 更多；
  主体 = 名称行（文件夹图标按当前色染色 + 无边框输入）/「清单颜色」（无颜色 + 10 色预设 + 自定义取色）/
  「视图类型」（列表·看板·表格三张灰底线框预览卡，选中 accent 描边 + 右上打勾）。删除 / 归档与侧栏
  长按菜单**共用** `logic/project_actions.dart`（写路径不再两处各写一份，色板同理上收
  `logic/project_palette.dart`）。
- **自定义取色**（新原语 `orbit_color_picker.dart` 的 `showOrbitColorPickerSheet`）：shadcn `ColorPicker`
  承载（默认 HEX 档、alpha 关掉），新增 `hex_color.colorToHex` 落库；「无颜色」写空串——下游本就回落
  中性表现（侧栏项目图标取强调色、列表行项目名回落次要文本色）。
- **每项目视图档**：进某个项目按「该项目上次用的档位」渲染（本地键 `todo_view_mode_project_<id>`，
  未设过回落全局档 `todo_view_mode`），在项目上下文切档只写项目档；桌面视图档仍为全局单键（docs/05 §八）。
- **约定同步**：`AGENTS.md`「选择类交互统一底部抽屉」补例外条款——页头「当前列表操作」入口走下拉面板，
  面板内单选集就地展开、不再二次弹层；只有表单类入口（筛选）仍开底部抽屉。
- 测试：新增 `orbit_dropdown_panel_test`（6 例）与 `project_edit_page_test`（7 例），a11y 的色板热区例
  改挂整页；全量 560 例绿 + `flutter analyze` 零告警。

### 移动端任务列表版式重排（2026-09-23）

- **任务行改左右两列**：右列 = 截止日期（相对化：今天 / 明天 / 昨天 / `M月D日` / 跨年带年份；未来与今天主题蓝、
  逾期红）+ 元信息图标行（重复 / 提醒 `HH:mm` / 子任务进度 / 关联 / 星标），左列只留标题 + 标签 + 项目名——
  纯标题行不再被空白副标题撑高，行高统一 `minHeight: 48`。
- **优先级移到勾选框描边**（P1–P5 六档语义色，P0「无」回落中性灰），副标题里的 8px 色点退役：同一信息不再两处呈现。
- **任务区卡片化**：新增原语 `shared/widgets/shadcn/orbit_list_card.dart`（`OrbitCardSegment` 按段画描边与段间分隔线
  ——列表是懒加载 `ListView.builder` / `ReorderableListView`，整卡包裹会把万行任务一次性实例化，且非均匀 `Border`
  与 `borderRadius` 不能共存），整列未完成任务拼一张圆角白卡；逾期区块头与「其余任务」分隔行同为卡内段，
  标准列表条目由「按下标反算 od/rest」改为显式条目表（顺带消掉 od 为空时 `rest[-1]` 的越界隐患）。
- **列表尾部「已完成 N ⌄」折叠卡**取代页头 eye 开关：完成时刻倒序、直显上限 20 条 + 「查看全部」进 Logbook，
  manual 重排档挂 `footer` 不与可拖行混排；展开态落本机偏好新键 `todo_done_section_open`
  （旧键 `todo_hide_done` 只作一次性回落：老用户上次把已完成显出来过，首次进入即展开）。
- **页头收敛成 返回 + 标题 + ⋮**：视图模式 / 筛选 / 排序三档进底部抽屉，菜单项回显当前档位，筛选生效时 ⋮ 挂角标；
  多选态标题栏（已选 N 项 + 全选 / 退出）不变。
- **有意边界**：卡片与已完成卡只覆盖列表两档（标准列表 / manual 重排档）——看板与表格没有承接位，维持
  「隐藏已完成」口径；Logbook（done 快捷视图）本身即完成集，不再叠一层折叠卡。
  测试：新增 `orbit_list_card_test` / `done_section_test` 与日期相对化、优先级描边、勾选框描边覆写用例；
  全量 547 例绿 + `flutter analyze` 零告警（自绘描边另用一次性 golden 目检后删除）。

### 移动端长按拖拽修复（2026-09-23）

- **长按拖动后不再误弹操作菜单**：manual 档（拖拽顺序，默认档）整行长按拾起后，只要手指移动过
  （`Listener` 原始指针位移 > `kTouchSlop`）就只落位排序、松手不弹菜单。此前位移标记挂在
  `onReorderItem` 上，而它只在真换过槽位时才触发（拖开一圈又落回原槽位全程无回调），拖动后松手
  会凭空弹出操作菜单；原地纹丝未动仍是长按，菜单入口不变。

### 小而实用批次（2026-09-23，A 类四项）

- **移动端附件图片缩略图（docs/09 A9 落地）**：详情附件区图片行显示 32px 行内缩略图（新增原语
  `shared/widgets/shadcn/orbit_image_thumb.dart`），只对「已在本机落地且 ≤ 2MB」的图片读字节，
  解码按 `size × dpr` 降采样；字节缓存 12 条 / 16MB 双上限 + 插入序 FIFO 淘汰 + 区块 dispose
  整体清空。全屏预览加双指缩放（内置 `InteractiveViewer`）。此前只能靠文件名分辨截图。
- **Android 长按图标静态快捷方式**：新建任务 / 今天 / 搜索三档（`res/xml/shortcuts.xml` +
  三个自绘矢量图标 + Manifest `android.app.shortcuts`），原生只暂存动作 id、Dart 侧
  `ShortcutReceiver` 统一落点（侧栏处理器承接，冷启动动作先暂存后补发），语义不跨端重写。
- **列表行「关联」徽标（A4 投影的 C7 消费）**：双端列表行在任务有关联时渲染链环徽标（桌面
  `use-task-dependencies` + `task-list-view` 元信息行、移动 `taskDependencyFlagsProvider` +
  `TodoTaskTile`），关联行写事件经 db-invalidation 精确失效该投影。「被阻塞」档不做——双端详情
  抽屉的「添加关联」固定写 `relates_to`，没有入口写 `blocks` / `blocked_by`。
- **同步状态可视化（双端接 `cloud_sync_get_state`）**：设置页新增「同步账本」卡——各表各桶的
  指纹前 8 位、push / pull 水位线、远端清单 epoch、本机设备标识；桌面展开才拉取并随同步完成
  刷新，移动端进入页面 + 刷新按钮回读。移动抽象桥补 `cloudSyncGetState` + `SyncStateView`
  镜像 DTO（JSON 串解析），`ipc-mock` 的 `cloud_sync_get_state` 修正为 SyncState 结构。

### 桌面端补齐批次（2026-09-23，docs/07 #60–#63）

- **桌面两处对称（#60）**：①设置页新增「日历」分类，值行读 `holiday_meta.fixed_hour` → 0-23
  整点下拉写 `holiday_set_fixed_hour`，日历页两处更新按钮 tooltip 带上当前固定时刻（与移动端
  #59 同口径）；②`tauri.ts` 补 `fullBackupDeviceInfo` 包装，备份卡导出区显示「本机设备标识」
  （与备份清单 `device_id` 同源，恢复预览的「来源设备」即此值），`ipc-mock` 补同名命令。
- **桌面提醒相对档（#61）**：移动端 #53 的对称项。`lib/quick-dates.ts` 新增
  `buildReminderDueOptions`（截止当天 09:00 / 前推 1 小时·30·15 分钟；同刻去重、过期不过滤），
  `QuickDateMenu` 加可选 `dueDateMs` 前置「相对截止」组、`DateTimePicker` 透传；三处提醒入口全覆盖
  ——快速输入栏、详情抽屉提醒区、任务表单（经 `FieldDef.relativeDateField` 从同表单截止值实时取锚点）。
  产物仍是绝对毫秒 `remind_at`，零 schema 变更。
- **应用内更新兜底出口（#62，`docs/07 #50` 残余收口）**：新增 `lib/update-fallback.ts`
  纯函数 `resolveReleaseFallbackUrl`；检查/下载安装两条失败路径的 toast 加「复制下载链接」action。
  **安装方式识别（MSI/NSIS/便携/dmg）有意不做**：`bundle.targets="all"` 但 `latest.json` 只发布
  nsis/mac-app/appimage/deb 键、不发布便携产物，可靠区分 MSI/NSIS 需注册表查询或真机安装器验证，
  启发式误判会挡住本可升级的用户——故只交付可验证的兜底出口。
- **内存治理三连（#63，docs/09 A6/A8/A2 首步）**：①回收站列表加 `LIMIT 1000`，并把
  `purge_all_trashed_tasks` 改走独立 id/uuid 投影查询（原本复用列表函数推事件，加限后会静默漏发
  db-change；新用例锁边界）；②连接池上限提为常量 `MAX_CONNECTIONS = 3`（同步已串行化，池上限即
  内存下界）；③瘦行首步：列表通道裁剪列清单加 `'' AS uuid`（约 450KB/万行，必须空串不能 NULL——
  DTO 非空 String；消费方核实后双端零依赖），双端 mock 同口径，契约测试与桥一致性用例同步加断言。

> 本轮环境限制：JS 侧门禁（`pnpm typecheck`/`test`/`build`、Playwright）在本机不可用
> （node_modules 的 pnpm 重解析点无法穿透，离线无法重建），桌面 TS 改动以 IDE 类型诊断 + 人工复核
> 验证，最终以 CI 为准；**`docs/09` 的 cold-start 基线取数（P3）因此未执行**（需先 `pnpm build`）。
> Rust 侧 `cargo test --workspace --lib` 617 全绿、移动端 `flutter analyze` 零问题 + 516 全绿。

### 移动端日历节假日更新时刻可配（2026-09-23，docs/07 #59）

- 桥位 `holiday_set_fixed_hour` **双端早就绪**（移动 FRB 生成物 `holidaySetFixedHour` + Rust
  `api/holiday.rs`；桌面 `holiday_cmd.rs` 已注册命令），但两端 UI 均零消费、`HolidayMeta.fixedHour`
  也无处展示——每日自动更新时刻只能吃 core 缺省 08:00。本轮移动端接线：抽象桥暴露该方法（Rust 侧
  转发 FRB 既有函数，**零 codegen**）+ Rust/Mock 两实现（mock 落 `MockStore.holidayFixedHour`，
  clamp 0-23）；设置页新增「日历与节假日」卡（值行读记账 → 0-23 整点单选抽屉 → 落库 + toast），
  日历页更新按钮 tooltip 带上当前固定时刻（与设置页同一份 `holidayMetaProvider` 记账）；新增
  `_valueRow` 值行原语（形制同回收站「保留时间」行）。测试 2 例。桌面侧接线留后续。

### 移动端体验对齐批次 P1（2026-09-23，docs/07 #55–#57）

- **同步密钥治理三入口（#55）**：桥位 `sync_crypto_meta_version` / `sync_crypto_upgrade_v2` /
  `cloud_sync_rekey` 早已存在且桌面 `sync-recovery-page` 有入口，移动端此前**零调用**——v1 老用户
  无法在移动端升级密钥方案、「以本机为准重置云端」不可达、也看不到自己是 v1 还是 v2。本轮在同步
  密码卡补「本机密钥方案」版本行 + v1 设备才出现的「升级密钥方案到 v2」（密码对话框）+「以本机为准
  重置云端」（destructive 二次确认，解析 `result_to_json` 后给出推送模块/附件数）。Mock 桥三方法由
  「Mock 未实现」补齐同口径实现（store 新增 `syncKeyVersion`）。测试 4 例。
- **日历议程档（#56）**：桌面 `CalendarSubMode` 有 `month|year|agenda` 三档，移动端只有「月历网格 +
  当月按日列表」一屏。本轮补工具栏月/列表切换：议程档隐藏网格、整页让给按日分组列表、切入时一次性
  定位今天、日期头带休/班徽标（月档不带，对齐桌面 `showHolidayMark`），提示与空态文案随档位改口；
  「班」徽标底色抽为 `ChineseCalendarColors.workdayBadge` 单一来源。测试 2 例。
- **备份导出区本机设备标识（#57）**：`full_backup_device_info` 桥位双端均零消费；恢复预览已有「来源
  设备」，导出侧却无从知道本机标识。本轮在导出卡补一行「本机设备标识：<id>」（读取失败静默不渲染、
  不阻断备份链路），与恢复预览「来源设备」同值可直接对号。桌面侧同步接线留后续。

### 移动端「修改后立即同步」生效（2026-09-23，docs/07 #58 / docs/10 §A-2）

- **写路径触发 `push_only`**：新增 `services/sync_on_change_scheduler.dart`（进程级单例），由
  BootGate 唯一的 dbChanges 订阅转发——业务写路径落库 → **5s 滑动防抖**（对齐桌面
  `sync_scheduler.rs` 的 `ON_CHANGE_DEBOUNCE_SECS`）→ 门控（已配置云同步 && `sync_on_change`
  && `is_auto_sync` && 有同步密码且已解锁 && 引擎空闲）→ `cloudSyncPushOnly(origin: background)`。
  不做表过滤（引擎增量指纹未变时秒级跳过，无放大效应），配置每轮现读，开关改动下一轮即生效。
- **两处有意差异（移动端无后台调度器所致）**：①桌面 60s tick 兜底在移动端不存在，故推送
  进行中收到的写入在出窗后**补排一轮**，避免漏推只能等下一次编辑或切前台；②移动端无
  sync-progress 事件流，后台推送不占用标题栏「同步中」指示，仅成功后失效
  `syncConfigProvider` 刷新「上次同步」。
- **耗电/流量口径**：触发只来自用户真实编辑，每窗口至多一次推送，引擎忙 / 指纹未变时零上传，
  不做后台轮询（进入 / 退出前台的 `cloudSyncForce` 兜底保持原状）。设置页开关文案改口（标注
  移动端已生效 + 依赖「定时同步」总开关）。测试 10 例（调度器 9 例 + BootGate 接线 1 例），
  flutter 514 全绿。

### 移动端体验对齐批次 P0（2026-09-23，docs/07 #52–#54）

- **ICS 日历导入打通（#52）**：`ics` 预设此前只有 orbit-core（`CsvImportPreset::Ics` + `map_ics_rows`）
  与桌面导入卡接通，移动端预设停在 orbit/todoist/ticktick、文件选择器只放行 `csv/txt`——本轮补
  「ICS 日历」档、按档位放行 `.ics`、导入卡标题改口为「导入文件（迁移）」并补 ICS 文案；文件读取由
  `String.fromCharCodes`（Latin-1 逐字节转码，中文标题必乱码）改为 `utf8.decode(allowMalformed)`。
  Mock 桥按 core 口径补 VTODO 解析（unfold / TEXT 反转义 / PRIORITY 逆表 / DUE 三种形态 /
  VEVENT 忽略 / 块级跳过），`csv_import_test` 新增 5 例。
- **提醒相对档快捷（#53）**：提醒字段由「点行直进日期时间面板」改两段式——先给相对档（有截止：
  截止当天 9:00 / 前推 1 小时·30·15 分钟；无截止：今天·明天 9:00），末项「自定义时间…」进原面板。
  产物仍是绝对毫秒时刻（`remind_at`），**零 schema 变更**；同刻档位去重、过期档位不过滤（与日期
  面板允许选过去同口径）。纯函数 `reminderPresets` + 单测 4 例，表单交互回归 2 例。
- **任务行元信息补齐（#54，对齐桌面）**：列表行副标题原本只有「优先级色点 + 项目名 + 截止」，本轮补
  标签段（6px 色点 + 名，超 3 折叠 `+N`）、提醒段（铃铛 + `HH:mm`；未来取最近一条 / 全过期取最早一条、
  已完成实例不警示、到期未完转逾期红）、子任务进度段（`listChecks` + `N%`，0/100 不显示）。新增
  `displayReminder` 纯函数镜像桌面 `reminder-meta.ts`；桥位 `taskRemindersProjection` 由「零调用」
  转为接线，并在 `db_invalidation.dart` 为 `todo_reminders` 补提醒投影失效目标（增删提醒后徽标立即跟随）。
  `docs/05 §4.5` 任务行规格随之同步。

### 移动端 UI 批次（2026-09-22）

- **字号档（全局 TextScaler）**：外观字号档从逐处覆写 `fontSize` 改为全局 `TextScaler`，
  硬宽度列（表格 / 看板列 / 热力图）加保护，放大后不再挤断。
- **空态引导**：`EmptyState` 支持主行动按钮，接通任务列表与筛选器的空态出口。
- **下拉刷新**：主列表 / 侧栏 / 统计 / 回收站接 `RefreshIndicator`（本地重读 + 已配置时跑一轮
  云同步）；看板（横滑）与表格（定表头横滚）**有意不接**——与横向拖拽抢同一手势。
- **骨架屏**：自绘 `OrbitSkeleton` 原语（`surfaceSecondary` + `skeletonPulse` 呼吸），只铺首屏
  四处初次加载（详情 / 统计 / 主列表 / 侧栏），**有旧值可守时不出现**；二级页与按钮内 loading
  保留 spinner。
- **视图切换过渡**：列表 / 看板 / 表格三态切换加淡入 + 上滑 3%（200ms），key 只跟视图走——
  任务增删、骨架落定、下拉刷新不重播整列表。
- **卡片去阴影**：卡片统一收口 `OrbitCard`，去掉 v2 阴影，回到「1px 描边 + 表面分层」口径。
- **行退场动画**：标准列表的删除 / 离场型完成播 300ms 高度收起 + 淡出；写库仍立即落库
  （ADR 0005），只延迟主列表那次失效，其余缓存即时刷新；边界与取舍见 docs/05 §9.2。
- **无障碍**：操作按钮补读屏标签（`IconButton.tooltip`），色点热区统一补到 48（`touchTarget`）
  且视觉直径不变——口径见 docs/05 §十，回归 `test/a11y_test.dart`（顺带修掉标签色板抽屉的
  色点仍是 40 裸点、未补热区）。
- **动效 token 收口**：路由转场与滚动定位的硬编码时长 / 曲线收进 `AppMotion` 别名
  （`pageInCubic` / `pageOutCubic` / `scrollSettle*`，数值零变化，`app_motion_test` 锁值）；
  删除零引用的 `pageIn` / `pageOut`。
- **依赖瘦身**：删除热力图副本与三个零引用依赖。
- **底部抽屉口径收口（`OrbitSheetScaffold` / `OrbitSheetActions`）**：新增抽屉骨架原语——手柄 +
  标题 + **可滚内容区** + **固定底部按钮行**，确认/取消类按钮一律钉在抽屉底部且标签居中
  （shadcn 按钮内标签盒子与按钮同宽，默认 `TextAlign.start` 会贴左，观感"字不在按钮中间"；
  圆角/高度未动，仍为 `AppShapes.medium`／shadcn `radiusMd` = 14）。已迁移：确认弹层、
  日期时间选择器、描述编辑、筛选器新建、模板新建/编辑、云同步面板、重复规则「确定」、
  列表过滤「清除全部筛选」（后两者原先在滚动区内，会随内容滚走）；口径与回归见 docs/05 §十一。
- **任务行样式收敛 + 拖动排序改整行长按**：任务行去卡底 / 去阴影 / 去描边，仅保留下沿 1px
  分隔线（与多选态行同形制，整列不再是一摞白卡），行尾拖拽把手图标移除；manual 档（拖拽顺序，
  默认档）拖动排序由「行尾把手」改为**长按 500ms 拾起整行**（不再与上滑滚动 / 左右滑抢手势），
  **拾起后原地松手仍弹操作菜单**——菜单入口与功能零损失（其余排序档 / 看板 / 表格长按照旧）。
  口径见 docs/05 §4.5 / §9.2。
- **破坏性按钮实心化**：`sh.Button.destructive` 常态填充原是 shadcn 默认的 50% 透明
  `destructive`（白字淡粉，被用户读成「按钮不可点」）→ 全局覆盖为 token 实色
  （`shadcn_theme.buildDestructiveButtonTheme`：悬停/按下混白 10% 变浅、禁用回落中性表面），
  与桌面 `bg-destructive text-white hover:bg-destructive/90` 同口径。

### 移动端撤销浮层常驻修复（2026-09-20）

- **症状**：批量改优先级等操作后，「已调整 N 个任务的优先级 / 撤销」浮层一直不消失。
- **根因**：`WaitToast` 对带动作按钮的条目特意不启动自动收起定时器（原意是等用户
  处置），而撤销浮层本就只在 5s 窗口内有效——窗口过后仍长驻挡住内容。
- **修复**：`WaitToast` 新增 `autoDismissAfter` 参数与 `defaultDwell`（2.6s）/
  `undoDwell`（5s）常量；撤销类调用点（任务列表 `_offerUndo`、回收站彻底删除）
  显式传窗口时长到期自动收。顺带修掉撤销浮层描述写死「已移入回收站的任务可在
  回收站恢复」——非删除类操作的撤销不再显示该指引。
- **回归**：新增 `test/wait_toast_test.dart` 4 例（撤销条自动收 / 纯提示自动收 /
  提醒条与错误引导条按设计保持常驻）。

### 移动端提醒「推迟」丢失修复（2026-09-20）

- **症状**：通知上点「推迟 10 分钟」后，任务里的提醒直接消失、且到点不再提醒。
- **根因**：引擎到期处置（`todo_api::advance_fired_reminder`）会把非重复任务的
  提醒行软删，而移动端推迟通道只重排系统闹钟**不写 DB**（后台 isolate 无法重入
  FRB 的历史约束）——于是提醒行被引擎清掉，紧随其后的 db-change 重排
  （`cancelAllPendingNotifications` + 按 DB 排）又把刚排上的推迟闹钟一并取消。
- **修复**：推迟落成 DB 事实（软删旧时刻行 + 新建推迟时刻行，与桌面
  `reminder-snooze.ts` 删旧建新同语义），新增 `lib/services/reminder_snooze.dart`：
  ① 前台（主 isolate）经 `NotificationService.onSnoozeAction`（BootGate 注入）
  点即落库；② App 不在前台时 action 由独立后台 isolate 回调（主 isolate 注入的
  静态回调与 FRB 在隔离区都不可见），意图写入 `dart:io` 暂存文件
  （`SnoozeSpool`），回前台（resumed）/冷启动时 drain 写回；③ **孤儿闹钟落地**
  为主通道（真机复验后调整）：Android 上后台 isolate 的 `Directory.systemTemp`
  实际不可写、且 DB 旧行多已被引擎清理，故改为重排前与回前台时读系统 pending，
  对「任务存活未完成 + 无提醒行 + 时刻在 (now, now+24h]」的闹钟补建提醒行；
  配套 `NotificationService.cancelAlarmFor`——用户手动删提醒时同步撤闹钟，
  避免残留闹钟被误判为推迟产物而复活。
  另修正推迟起算点为 `max(现在, 原时刻)`（补扫场景不再把新时刻排到过去），
  过期意图丢弃不补建（避免闹钟响过之后再弹一次）。
- **回归**：`test/reminder_snooze_test.dart` 20 例（计划纯函数各分支含孤儿四态、
  前台落库删旧建新/幂等/不误删其他时刻行/过期丢弃、暂存文件往返与脏行容错、
  补齐执行）；ADR 0002 §决策语义变化同步修订「后台不写 DB」旧口径。

### 移动端多选崩屏修复（2026-09-20）

- **多选进入即红屏**：`sub_list_screen` 非重排列表分支（选择态强制回落、切出
  「拖拽顺序」档后即走该分支）的逾期置顶 item 索引，在**无逾期任务**时算成
  `rest[-1]` → `RangeError (length)` 整屏红；改为逾期区为空时直接映射
  `rest[index]`，并修正逾期区偏移（旧实现把 `od[0]` 渲染两次、丢掉最后一条逾期行）。
- **回归守卫**：`todo_screens_smoke_test` 新增两例——无逾期任务进多选不崩、
  非重排档下逾期区每行只渲染一次（旧实现在 ≥2 条逾期时重复首行）。

### 移动端确认类交互统一底部抽屉（2026-09-20）

- **新增确认抽屉原语** `shared/widgets/confirm_bottom_sheet.dart`：`showConfirmBottomSheet` =
  拖拽手柄 + 标题/说明（长预览体走 `content`）+「取消 / 确认」按钮行，破坏性操作 `destructive`
  红底；返回 `bool`——确认 `true`，取消 / 点遮罩 / 下滑一律 `false`，纯告知场景 `cancelLabel: null`
  只留一个按钮。
- **确认类 `AlertDialog` 全量迁移到抽屉**：回收站彻底删除与清空、任务单条与批量删除、
  项目删除与删除保护提示、保存筛选器/模板/标签删除、子任务/评论/附件删除、
  同步冲突恢复与清空、备份恢复/版本不一致/删除、通知历史清空、关闭加密（二次确认）
  与清除主密码、明文导出与 CSV 导入确认、断开云同步与清除同步密码缓存。
- **`AlertDialog` 仅保留带 `TextField` 的输入表单**（新建/编辑项目与标签、改主密码/
  改同步密码/输密钥包密码）；口径写入 `AGENTS.md` 移动端约定与 `docs/05 §4.1`，
  `sync_settings_page_test` 的确认定位随形态由 `AlertDialog` 改为 `BottomSheet`。

### 移动端动效对齐微软 To-Do（2026-09-20，仅动效层）

- **动效 token 单一来源**：新增 `core/theme/app_motion.dart`（时长/曲线/缩放档）；
  `AppDimens` 移除旧时长常量，`wait_toast` / `sync_status_button` 迁移至新 token。
- **勾选反馈**：`CircleCheckbox` 加底色渐入 + 对号缩放淡入（构造签名不变，7 处调用点零改动）
  + 点按触感反馈。
- **完成态标题**：新增 `AnimatedStrikethrough`——保留真实 `Text` 节点，其上按行度量自左向右
  绘制删除线并过渡文字色，控制器初值即终态故滚动入场不重播；接入列表行/选区行/详情标题/
  子任务/看板/表格/日历/搜索/筛选预览共 9 处。
- **行入场与拖拽**：标准列表分支新行高度展开 + 淡入（只播"新出现"的任务，不整表重播）；
  任务行与侧栏项目拖拽加抬起放大 + elevation 与起止触感。
- **底部抽屉**：选择类/更多操作/表单三类统一 `sheetAnimationStyle` 轻快入场（入 250ms / 退 150ms）；
  日期选择器视图切换时长收口 `AppMotion.viewSwitch`。
- **零视觉漂移**：布局/间距/字阶/色值/圆角/直径/信息架构/路由全部未动，桌面端与 Rust 侧零改动。
  动效清单与五条有意边界记 `docs/05 §九`，竞品口径同步 `docs/07 §2.1/§2.3`。

### 移动端补齐（对照桌面命令 + 新页面）

- **FRB 桥补齐 10 函数缺口**：`todo_labels_get` / `todo_task_labels_get` /
  `todo_tasks_recalc_percent` / `business_count` / `todo_projects_get_by_uuid` /
  `todo_tasks_get_by_uuid` / `cloud_sync_force`（进入/退出应用专用）/
  `ping` / `crypto_sha256` / `crypto_random_hex`；Dart 侧 OrbitBridge 抽象、
  Rust/Mock 两实现、mock_store 同口径，BootGate 生命周期改走 `cloudSyncForce`。
- **保存筛选器七键可视化构建抽屉**：状态/最低优先级/天内截止/项目/标签/
  仅逾期/仅收藏七键，替代手写条件文本框；行内编辑钮支持更新已有筛选器。
- **详情页**：关联任务搜索增删（全局搜索选人 + 跳详情 + 解除）、子任务完成
  进度条、附件拍照（相机）与文件双来源（分享文本建任务仍由 ShareReceiver 覆盖）。
- **外观设置页**：主题三态（跟随系统/浅色/深色）+ 字号/字重三档，全走
  LocalPrefs 字符串读写，写后即时重建主题；app_theme 注释口径同步。
- **通知历史页**：类型过滤/分页（50 步进，上限 200）/清空 + 提醒总开关
 （`reminder_enabled`，关后仅记历史不弹窗）；开机经 `db_maintenance`
  清理过期通知日志（30 天 TTL）。
- **关于页**：package_info_plus 真实构建版本 + 更新日志分区 + 开源许可入口；
  设置页关于卡版本号同源；组织卡新增外观/通知历史入口；安全卡新增清除主密码
  入口（二次确认后路由到关闭加密库迁移流程）。

### 产品与平台

- **本地优先、零遥测、端到端加密**的跨平台任务管理应用：桌面 Tauri 2（Windows /
  macOS / Linux）+ 移动 Flutter（Android / iOS，ADR 0003），无账号、无订阅；应用显示名
  「循迹」（进程名 `orbit`）。
- **业务逻辑全量下沉 Rust 核心**（`crates/orbit-core`）：CRUD、重复规则引擎、提醒到期
  处置、回收站 TTL、统计聚合、CSV/ICS 导入导出、附件内容寻址、节假日；双端壳只保留
  薄 UI 与桥接（桌面 Tauri command + `src/lib/tauri.ts`；移动 `OrbitBridge` 抽象 →
  FRB `RustOrbitBridge` / `MockOrbitBridge`），桥接签名双端同名同参、mock 同口径。
- **事件总线**：db-change 单播双端壳（桌面 Tauri event / 移动 FRB event stream），
  前端缓存失效链统一依赖；桌面事件泵只传 `table` + `op` 精简载荷，广播溢出（`Lagged`）
  时补发全量失效哨兵而非终止转发。
- **monorepo 重组**（omnipass 模式）：根 Cargo workspace 只管 `crates/*`，
  `apps/desktop/src-tauri` 为嵌套独立 workspace，移动端经 cargokit 复用 core；包名统一
  `orbit-core` / `orbit-flutter`，pnpm lockfile 上收仓库根；Rust 工具链与 FRB codegen
  版本双双锁定（1.96 / 2.12.0）。
- **品牌资产管线**：`scripts/generate_icons.py` 一次产出桌面 PNG/ICO/ICNS（手写 ICNS
  容器，无 iconutil 依赖）+ Android 五密度图标 + 通知剪影；图标定标改**短轴撑满**
  （主体放大约 21%，任务栏小图标不再显小），v5 透明底「圆环轨道」全族重生成——ICO
  十槽结构与首帧 256px（任务栏取用位）不变。

### 任务核心

- 任务 / 子任务 / 项目 / 标签 / 评论 / 任务关联（6 类关系）/ 六档优先级（含「无」档
  全程着色）/ 多提醒 / 开始日期 / 完成进度 / 收藏。
- **重复任务**：规则编辑器（每周几掩码、结束条件、when done、完成后推进锚点）+
  「下次 M月d日（周X）」具体日预览（Things 口径）+ 推进引擎下沉 core 单事务（完成后
  自动生成下一实例，三端同一入口）；滚周期双轨迹——原实例记「已滚动下一周期」、新实例
  记 `create(from=repeat, parent_id)` 使自身历史可溯源，幂等再完成不重复记。
- **子任务转独立任务**（承接父任务项目 / 优先级 / 日期，完成事实保留）+ **一键复制任务**
  （克隆字段与子任务，副本紧邻原位）+ **项目归档**与项目颜色（侧栏圆点 + 全展示位按色渲染）。
- **任务模板**（同步表第 11 张：周报 / 报销单 / 差旅清单免从零搭）；**保存的筛选器** +
  可视化构建器（裸 JSON 手填退役，工具栏「存为视图」一键固化）。
- **回收站**：软删墓碑 → 列表 / 恢复 / 彻底删除 / TTL 守护，双端同语义；彻底删除与清空
  支持延迟提交 + 5s 撤销窗口（ADR 0005）。
- **通用撤销**（Ctrl+Z 全局栈，完成切换 / 批量操作 / 删除全接入）；删除类操作统一确认与反馈。
- **活动轨迹三段可读**：任务活动日志（对标 Todoist Activity log）——update 轨迹追加前后值
  变更集 `changes`（日期→本地日串、项目 id→项目名、长文本 60 字截断；重复规则六字段合并
  为单条 `repeat_rule` 快照），子任务 / 评论 / 关联 / 提醒 / 附件从属对象新增独立轨迹
  （附件按 hash 幂等挂接、子任务提升双埋点），老行无 changes 自动回退字段名清单；双端历史
  区块固定取最近 30 条，满档显「仅显示最近 30 条」+「显示更多」一次展到 core clamp 上限
  100；移动端详情页新增「十、历史」区块（FRB 只读桥 `task_activity_list`，格式化纯函数
  镜像桌面 `activity-format.ts`）。
- **列表逾期置顶分组**（未完成逾期任务永远先被看见，双端）+ 行内子任务进度百分比 +
  行内提醒徽标四视图贯通。

### 视图与交互

- 五套桌面视图：**列表**（全量虚拟化 / 拖拽排序 / 固定 57px 行高 / NLP 快速输入）、
  **看板**（列内虚拟化 + 卡片多选批量 + 键盘可达）、**日历**（月 / 议程 / 年三档，农历
  副标签、节假日徽标、圆点拖拽改期、右键新增预填日期）、**表格**（第四态，六列概览 +
  多选 + 键盘导航）、**Logbook**（完成历史按完成日分组回看，默认隐藏已完成）。
- **「我的一天」**置顶快捷视图（数据层 `my_day_date` + 四入口 + 视图内新增自动带视图标记；
  今日 / 本周视图内创建的截止时刻统一归一 18:00）。
- **全局搜索**（Ctrl+K，跨任务 / 项目 / 评论；后升级 FTS5 短语级全文检索）+ 命令面板
  （新建任务 / 切主题 / 切视图）+ 全局快速捕捉热键 `Alt+Shift+O` + 快捷键帮助面板
  （`?` 呼出 + 设置页常驻入口）。
- **多选批量**：shift 区间选 + 底部工具条（批量改期 / 优先级 / 项目 / 删除，图标按钮
  紧凑形态即点即执行）+ 键盘批量（x 选中 / Esc 退选）。
- **日期选择器与日历视图统一（双端）**：日期弹层与日历视图共用同一套日格（农历 / 节日 /
  节气副标签、休班徽标、周末蓝字、今天实心强调块、选中描边）与同一份节假日缓存，失效后
  两处同步刷新；桌面新增 `PickerCalendar`（复用 `MonthCalendar` md 档，`DatePicker` /
  `DateTimePicker` / 详情抽屉三处内联日历与快捷新增条两处全部替换，删除 react-day-picker
  封装与依赖）；移动端 `WaitDatePicker` 日视图由 mini 圆格改 `AppMonthCalendar` medium
  档并整面板可滚。
- **日历滚轮步进**：日期弹层整体滚轮切月、日历视图月历滚轮翻月、工具栏年 / 月分段各滚各、
  年视图滚轮切年；阈值 24px + 前后沿节流（单击零延迟、连滑零丢步），下拉展开时滚轮只滚
  列表，Ctrl+滚轮仍是浏览器缩放；同批修掉月份下拉 10~12 月「月」字截断与日格数字垂直偏移。
- 交互口径统一：tooltip 主题色底白字、滚动条全项目标准、空状态垂直居中、弹层飞入与
  行高 / 溢出的全库排查。

### 提醒与通知

- 提醒到期处置**下沉引擎**（已完成实例不再提醒、僵尸行清理）+ 详情页 / 快加栏 / 表单 /
  移动端全入口接线；新增任务不再默认填「一小时后」提醒。
- 桌面：三平台系统通知（右下角弹窗）+ **推迟 10/30/60 分钟**按钮 + 点击通知直达任务
  详情 + **Windows 计划通知**（托盘退出后提醒仍可达）+ AUMID 身份注册（DisplayName=Orbit）。
- 移动：**后台闹钟托管**（精确闹钟授权引导、AOT 可达性修复）+ 通知**推迟 / 完成**双
  action + 灵动岛类别 + 双通道去重。
- **通知历史中心**：提醒呈现轨迹可回看。
- Android 存在感链条补全：**桌面小组件** + **快捷设置磁贴** + **图标角标**（今日 +
  逾期未完成数，双口刷新）。

### 加密与安全

- **SQLCipher 本地库** + 主密码体系（设置 / 解锁 / 修改 / 清除）；Android 明文降级
  平台边界记入 ADR 0001 与 `PRIVACY.md`；`PRAGMA` 逐连接注入 + 每连接 `cache_size` 封顶
  （修复 SQLCipher 多连接读出密文的数据损坏级隐患）。
- 移动端**生物识别解锁**：指纹代替主密码解锁加密库。
- **云同步端到端加密**：AES-256-GCM + zstd 压缩、PBKDF2 600k 单调不降级；客户端密文
  上行、密钥不出本机；`crypto/config`（明文 JSON，存储端可改写）、本地 meta、
  `.orfullsync` 文件头三入口统一走 `ensure_kdf_strength` 下限 guard（下限取历史最小值
  200k，避免挡存量），关闭「存储端把迭代降到 1 次」的降级路径。
- **同步密钥方案 v2**：Data Key 由密码确定性派生，结构性消灭 KeyMismatch 分叉态；
  配套双向 rekey / 迁移命令与恢复页（含「以本机为准重置云端」5s 冷静期确认）。
- **错误串脱敏** `brief()`：截 200 字符并丢弃含 `Authorization` / `Credential` /
  `<StringToSign>` 的行，S3 原始响应体回显与用户输入 endpoint 的 userinfo 不再落
  `sync_history.error_message`、`app_log.log` 与 UI tooltip。

### 云同步

- **三协议适配器**：WebDAV / S3（含阿里云 OSS 兼容）+ 传输层条件写（ETag `If-Match` /
  `If-None-Match` 与 HEAD 存在性探测，S3 / WebDAV 各自实现，不支持条件写的服务端由写后
  回读校验兜底）；不再为判断「远端有没有数据」而下载整个模块文件。
- **存储结构：表级分桶差量 + 单一清单 CAS**。云端布局为 `manifest.orsync`（唯一真相源：
  epoch + 表分桶索引 + 墓碑水位线）+ `tables/{表}/{桶}.orsync` + `tombstones/{表}/{YYYY-MM}.orsync`；
  数据按 uuid 稳定哈希分 64 桶，**单行编辑只重传 1 个分桶**；清单写入带前置条件 + 写后
  回读校验，多设备并发写从「静默覆盖」变为「可检测冲突并自动收敛」；Push 采用「远端清单
  拷贝 + 本地变化桶覆盖」，不再删除他端桶条目，消除「后写者抹掉前写者新增行」的窗口。
- **墓碑水位线回收**：墓碑按本地时区月份分桶，按所有设备同步检查点最小值安全回收（只删
  已确定被全部设备看到的墓碑，设备数 < 2 时不回收），清单不再无限膨胀。
- **增量同步 + 账本持久化**：模块指纹 + 单模块失败隔离，启动 / 定时 / 修改后立即 / 手动
  四路触发；重启不再每启必全量；**增量同步历史**（成败 / 耗时 / 冲突数）可回看。
- **大附件传输**：内容寻址 + S3 原生 multipart 分片 + WebDAV 自造分片协议（>8MiB 起分片、
  断点续传）；确定性 nonce 派生（同明文同密文，续传前提）；HTTP 超时语义由「总超时」改
  「读超时」——慢而在动的大传输不再被 30s 线掐断。
- **进入 / 退出应用强制同步**（桌面 + 移动）：只要「已配置云同步 + 已解锁」即执行，
  忽略自动同步开关 / 同步间隔 / 修改后立即同步设置；桌面进入延迟 1.5s 触发，托盘退出与
  系统真退出路径在退出前阻塞同步（上限 15s，超时放行并留日志），前端显示退出遮罩；
  移动端 `resumed` 进入同步、`paused` 尽力同步（6s 超时，被系统冻结则放弃）。
- **逻辑时钟（HLC）裁决**：业务写路径时间戳改为单调逻辑时钟（推进 `max(wall, last+1)`、
  合并时按远端时间戳推进、`cfg_kv` 持久化跨重启不回退），LWW 比较键由裸墙上时钟换成逻辑
  时钟——同毫秒写入不再平局、时钟回拨不倒退，设备间时钟漂移造成的**系统性**偏置在首次
  同步后即被消除；实现**折叠进既有 `updated_at` / `deleted_at` 列**，零 schema 变更、
  向后兼容旧行（决策见 `docs/03` §八）。
- **冲突败方副本 + 查看 / 恢复 UI**：LWW 裁决丢掉的败方整行快照不再静默消失，落本地表
  `sync_conflicts`（与合并同一事务、容量上限 500 条）；只留档**真并发**冲突（双方记录都晚于
  上次同步基线）；双端设置页新增「冲突记录」：字段级差异对照、一键恢复为败方版本（发起新的
  本地写入，下一轮同步胜出）、忽略与清空。该表为纯本地表，不随同步、不进备份。
- **左上角云同步状态图标**（桌面 TitleBar 左端 + 移动首页标题栏左端）：同步中主题色旋转环、
  成功后对勾回弹（约 1.8s 回落待命）、失败红点常驻并可查看原因；桌面悬浮提示显示「当前状态 /
  上次同步 / 下次自动同步（估算）」，点击立即同步；未配置云同步或密码未解锁时点击直达设置页
  引导。原右下角「后台同步中」悬浮指示条移除，同步状态与进度统一由云图标承载。
- **完成提示与失效链诚实化**：无任何推拉且无错误时显示「已是最新，无需同步」（此前显示
  「推送 0 模块」，易被误读为失败），并修复清单 CAS 并发重试耗尽时模块计数丢失；pull 回报
  `changed_tables`，双端按真正写入的表精确失效缓存（未知表回退全量），修掉「只拉附件」那轮
  `pulled_modules == 0` 导致界面不刷新。
- **失败可见性**：后台自动同步与「修改后立即同步」失败改走 `log::warn!`（此前 `eprintln!`
  在打包 GUI 丢失，`app_log.log` 无痕）；多表失败合并入同步历史单条；进度事件的模块名取
  真实模块定义。
- **推送性能（docs/09 A10）**：新增 push 专用水位线 `SyncState.last_pushed_clock_ms`（与
  pull 的冲突判据基线刻意分离——后者在 pull 结束推进到本轮结束时刻，复用会把「本轮开始前的
  本地编辑」判成非脏而漏传），配合「存活行数与远端清单条目比对」检出 merge 应用墓碑造成的
  软删这类时间戳早于水位线的集合变化；非脏桶零指纹重算、零序列化、零载荷构造——10k 行库
  「改一行后同步」的本地序列化从万级行降到 1 个桶（~156 行）；同一轮同步内 raw / 包装适配器
  共享同一底层实例（一 run 一 Client，phase 间复用热连接）。
- **五轮系统性探查收口**：① 前三轮（09-07 / 09-13 / 09-14）——附件首传空列表三分叉（解
  死锁）、pull 漏拉窗口封堵、附件 GC↔pull 打架循环终结、rekey 中断一致性、push 模块级错误
  隔离、WebDAV PUT 409 自愈、附件存在性探测错误分类（403/5xx 不再被当「不存在」）、冲突裁决
  计数全链透传；② 第四轮（09-18）——push 组装清单时整体替换远端索引致他端同轮桶条目被孤立
  （改桶级合并）、换密 rekey 后桶指纹密钥无关致增量全跳与云端停留旧 Key 密文（新增强制全量
  重传）、pull 存在失败表时不再推进清单 epoch、merge 表级失败回滚事务并向上抛错、push_only
  与 rekey 补业务级网络重试、S3 错误体中文截断 panic；③ 第五轮（09-19）——清单乐观锁
  （ETag CAS）**在生产链路从未发出过条件请求**（`BasePathAdapter` 漏转发
  `download_with_token` / `upload_conditional` / `exists` 三个 trait 方法，落到 mock 友好
  退化默认而单测 mock 恰实现了真方法，长期假绿；已补转发并以契约测试钉住「包装器与两适配器
  覆写同一组方法」）、WebDAV 大附件分片协议（>8MiB）自落地起从未执行（包装器先拼 `base_path`
  而分片判定要求 `path.starts_with("assets/")`；改按「上一段目录名 == assets」判定并把分片根
  随路径推导，分片落在 `{base_path}/assets_parts/`）、回收站物理清理守卫线被非干净轮次推进
  （记账收口到引擎唯一回写点 `advances_ledger()` = 非跳过且无错误，删除四处壳层回写）；
  ④ 减熵——删除死代码 `AdapterType`、`SyncAdapter::list_files` 及全部实现、
  `gc::collect_garbage` / `missing_tombstone_buckets`、恒 0 的 `RemoteFile.lamport_version`、
  空目录 `src/manifest/` 与 `src/sync_bundle/`。
- **协议合规小修**：S3 列举补 `Size` / `LastModified`（云端备份列表「最新在前」此前在 S3 上
  退化为最旧在前）、multipart 失败补 `AbortMultipartUpload`（孤儿分片不再长期占桶）、Complete
  请求体转义服务端 ETag；WebDAV href 百分号解码（中文 / 空格备份名不再乱码）、PROPFIND 207
  按 propstat 状态码取舍、补申请 `<getetag/>`（列举侧并发令牌与条件写同源）；适配器错误判定改
  typed variant（不再按错误串嗅探 409 / AncestorsNotFound）；跨设备整数外键改由父行 uuid
  承载、桶指纹排除本端 id。
- **ADR 0010 第一拍**（AAD 绑定两拍发布的前置拍）：布局版本门禁 `!=` → 大小判定（可区分
  「未来版本」与「上古版本」）；新错误码 `PayloadVersionMismatch`（tag `payload_version`，
  双端归类为「升级应用」提示，不跳密钥恢复页）；`DeviceCheckpoint.app_version` 能力协商位
  （清单为加密 JSON + serde default，零迁移）；AAD 绑定代码入库（`PAYLOAD_VERSION=0x02`，
  只绑表桶对象路径、附件永不做），写侧由「清单内全部已登记设备 ≥ 0.2.0」门控、本版默认关闭
  ——第二拍发布后自动打开，门禁代码无需再改。
- **两个上线阻塞修复**：首同步补传 `crypto/config`（第二台设备入环 KeyMismatch）与 Android
  release 构建补 `INTERNET` 权限（真机云同步 / 云端备份全线静默失败）。
- **合并事务原子化**：单表「数据合并 + 墓碑应用」收敛为同一事务，消除半合并窗口。
- **故障注入假服务 + 稳定性矩阵**：零依赖 `TcpListener` 假服务（7 种故障注入：5xx / 限流 /
  半截体 / 停滞 / 列举截断 / 412 冲突 / 忽略条件头）与 `tests/sync_fault_matrix.rs`（四类
  操作 × 故障矩阵，含 9MiB 分片双用例）替代本机真 WebDAV 依赖；`cargo test --workspace` 在
  干净机器全绿，原活体用例降级为 `#[ignore]` 的真服务端方言专用。

### 备份与恢复

- 本地全量备份（定时 / 手动）+ 云端全量备份（上传 / 列表 / 取回）**融合为单入口**（云端为
  默认，本地显式导出）；备份包 AES-256-GCM（`.orsync`，与同步载荷格式区分；历史 `.waitsync`
  全链路迁移）。
- **恢复安全确认**：五秒时停、恢复预览（自预览解密落定起算）、危险操作分级与两段式确认；
  备份列表云端 / 本地视觉区分与缺失元数据兜底。
- 备份文件名消毒（URL 危险字符）、失败不再「假成功」（本地写失败不推进账本并如实上报）、
  附件图片预览 blob 泄漏修复。
- **密钥派生强度对齐**：`.orfullsync` 的 PBKDF2 迭代由硬编码 200k 改为引用同步链路常量
  （600k，单一来源，旧包按容器头 iterations 解密仍兼容）；**同步前自动备份默认开启**（本地
  安全副本，可在设置关闭），push 前另存上一版清单作为回滚点辅助。

### 附件

- **内容寻址 + E2E 同步**：附件二进制走 `assets/{hash}.orsync` 加密通道；关联表入同步
  白名单，账本表保持本地（pull 侧按缓存标志差集重拉）。
- 守卫与治理：单任务 20 × 50MB 上限、本地 GC（无引用清理文件与账本）、**磁盘缓存 2GB
  上限 + LRU 逐出**（`is_uploaded=0` 的 pending 源绝不逐出）。
- 交互：桌面拖放文件直添、`Ctrl+V` 粘贴截图、行内 32px 缩略图、应用内 lightbox 预览；
  移动降采样解码预览与描述区 Markdown 渲染。

### 数据迁移与导出

- **CSV 导入**（orbit / Todoist / TickTick 三档预设）；**CSV/JSON 导出**（UTF-8 BOM，
  Excel 双击打开中文不乱码）。
- **ICS 日历导出**（VTODO，供日历软件导入 / 订阅）与 **ICS 文件导入**（VTODO 迁移入轨）。
- **明文数据导出**（JSON 结构化全量 + CSV 任务主视图，本地优先的「数据主权」路径）。

### 统计与分析

- 统计仪表盘：**完成热力图**（按年视图 + 年份切换 + 比例分档色阶，对齐 wait-home）、
  连续完成天数、分布条（项目自选色 / 优先级语义色，未完成段同色弱化）。
- **节假日数据层** `cfg_holidays` + 自动更新守护（60s tick）+ 日历徽标与手动更新。

### 桌面端（Tauri 2）

- 窗口：自绘标题栏 + 窗口控制三键（移植 Win11 规范，macOS 原生红绿灯 / Linux 材质回退）
  + **Mica 云母材质** + 启动白屏消除（`visible:false` → 前端就绪后 `show()`）+ 启动
  动画节奏调优。
- **托盘 + 关窗驻留**（守护不中断，托盘真退出放行；托盘图标独立按 shell 尺寸下采样并紧致
  裁剪撑满方格）+ **窄窗侧栏自适应折叠**（断点自动折叠 + 手动覆盖持久化）。
- **开机自启动（07 backlog #51）**：设置页「通用」分类读写系统启动项（Windows
  `HKCU\...\Run` / macOS LaunchAgent / Linux XDG `.desktop`，由 `tauri-plugin-autostart`
  承担），**不做本地状态副本**——开关状态以系统为准；自启进程带 `--hidden` 照常启动
  （托盘 + 四个后台守护齐全）但**不弹主窗**，壳层接上隐藏回收链（WebView2 降档 + 超时销毁），
  常驻内存回落宿主档（~330MB → ~40MB）。已知口径：安装路径含空格时 Windows 注册项会被系统
  解析坏（插件底层拼注册值不加引号），卸载前建议先关闭本开关。
- 设置面：安全 / 主题 / 待办 / 同步与备份 / 快捷键 / 任务模板 / 通知历史 / 冲突记录 /
  通用 / **关于与更新**（手动检查更新 → 下载 → 安装重启三步，不自动轮询）。
- 主题：六套 OKLCH 配色（含自定义强调色）+ 字号字重档位 + 双强调色 token 体系
  （`TODO_ACCENT` / `themeAccent`）。
- 关于页四分区：应用信息 / 更新日志 / 开源许可 / 开源组件。
- 壳层健壮性：双层错误边界保壳层监听与标题栏存活、虚拟列表焦点项无障碍播报、详情抽屉历史
  区块实时刷新（轨迹落库后自发 `todo_activity_log` Insert 事件并按表精确失效）。

### 移动端（Flutter）

- Flutter + flutter_rust_bridge 2.12（**显式 DTO 镜像**，core 类型不外泄）+ cargokit
  真机构建链路（NDK / SQLCipher 攻坚结论入 ADR）。
- 复刻 wait-home/mobile 观感：LiquidGlassTitleBar、玻璃 FAB、物理动画 Spinner、
  snap-spring 底部表单、toast/alert 皮肤、整页滚动布局。
- 功能对齐桌面：任务列表 / 子列表 / 详情 / 表单 / 日历 / 回收站 / 统计 / 全局搜索 /
  排序选项 / 长按拖拽重排 / 侧滑完成删除 / NLP 快速输入（实时解析 + 预览 chips）/
  描述 Markdown / Android 分享接收 / 云同步设置与密钥包导入恢复 / 冲突记录页 /
  详情页历史区块。

### 性能与内存

- 渲染：双端**全量虚拟化** + 路由级懒加载 + vite vendor 分包 + Material Symbols 子集化
  （首屏 chunk 985KB → 63KB；图标字体 5.1MB → 7KB）；**逾期置顶段并入任务列表同一条
  `useVirtualizer` 流**——万级驻留 76MB → **37MB**、DOM 节点 9980 → **863**（三档恒定）、
  切视图峰值 267MB → **61MB**、勾选峰值 327MB → **83MB**、进程树 RSS 433MB → **354MB**，
  置顶段外观不变但键盘 j/k 与 Enter 首次可达（旧实现既不能拖拽也不能键盘导航），顺带修掉
  按 `tasks` 取索引而行来自 `rest` 的焦点错位。
- 数据：谓词下推 SQL + 列表通道列裁剪（万级 IPC 体积 **-47%**）+ FTS5 全文索引 + 三条
  软删前缀组合索引 + db-change 表级失效（双端）+ **缓存驻留收敛**（主列表与两条全表投影
  `gcTime` 10min → 10s 并摘掉 `placeholderData`，换来「按谓词分叉的万行缓存不再长期挂着」，
  换视图 / 换项目首帧改短暂骨架）+ 纯字段写路径缓存 patch 提前 paint（真值仍由 db-change
  失效链收敛，且不从 TS 复刻引擎规则）。
- 投影与取数：列表标签 / 提醒改 **core 侧一次往返瘦投影**（`task_labels_projection` /
  `task_reminders_projection` / `task_dependency_flags`）；移动端任务列表收成**单份万行缓存
  + 派生过滤**，关键词单开服务端通道保住「按描述搜索」（`todo_tasks` 工具栏关键词下沉服务端，
  修复列裁剪后搜描述静默无结果）；万行列表命中单次加载上限时显式提示「列表不完整」。
- 资源：桌面**驻留内存优化**（隐藏降档 Low + 超时回收主窗，ADR 0006）+ release profile
  （LTO / strip / codegen-units，嵌套 workspace 补齐）+ devtools 摘除 + 连接池收紧。
- 治理：日志表 30 天 TTL + 附件缓存上限 + **数据库维护一键化**（WAL checkpoint /
  附件 GC / PRAGMA optimize / VACUUM，双端设置页可触发）。
- 度量口径入库并接 CI（`perf-metrics/`）：`growth-curve.mjs`（1k/5k/10k 三档 × 3 次中位、
  强制 GC 采真实驻留、切视图与勾选两类峰值、20 次写后泄漏、进程树 RSS 按 pid 子树收敛）、
  `audit-unbounded.mjs`（无界累加容器审计 `bounded*` 标记 + 棘轮登记）、冷启动改应用自报首屏
  marker；**更正历史基线**——旧报告 10k 档「169MB used / 257MB total」采自未强制 GC 的
  采样点（量到的是分配量），同档位强制 GC 后真实驻留为 76MB / 128MB。

### 发布工程与质量门禁

- **CI 四 job**：web（typecheck + vitest + build + Playwright 冒烟）/ rust-core
  （`cargo check --workspace --all-targets` + `cargo test --workspace --lib`）/
  flutter-mobile（FRB codegen 一致性门禁 + analyze + test，Flutter 锁 3.44.2）/
  perf-gate（无界容器审计 + 内存增长曲线）。
- **Release 流水线**（tag 触发）：桌面三平台（tauri-action）+ Android APK + `SHA256SUMS`；
  应用内更新清单 `latest.json` 单点合成（`includeUpdaterJson` 恒 false 避开矩阵并发竞态）；
  `workflow_dispatch` dry_run 预演；发版前置门禁（版本一致性 / tag 对齐 / updater 签名私钥 /
  依赖审计）。
- **签名与分发决策** ADR 0004：未签名平台明示 + 用户侧校验指引；updater 产物签名
  （minisign）+ 应用内更新（07 backlog #20）。
- **版本单一来源** + `pnpm bump` / `pnpm bump:check` + 发版一致性护栏（vitest 断言五处
  清单 / 两个 lock / 应用内日志，e2e 断言关于页版本徽标）。
- 测试规模（2026-09-24）：Rust 617 / vitest 377 / Flutter 590（`flutter analyze`
  零告警）/ Playwright 19（基线数，以 CI 为准）。

### 文档与规范

- `AGENTS.md` 全项目规则单一真相源（含版本发布与更新流程、内存口径与有界容器、FRB 生成物
  判据、迁移增量策略等规范节）；`docs/01-09` 编号文档（产品需求 / 技术架构 / 数据模型与同步 /
  UI 复刻规格桌面 + 移动 / 里程碑 / 竞品 backlog / 发布与更新流程 / 内存与性能治理专项）。
- ADR 0001-0007、0010（SQLCipher 策略 / 移动通知 / 双端拆分 / 发布工程 / 回收站边界 /
  桌面驻留内存 / 内存度量门禁 / 同步载荷 AAD 绑定）。
- 7 份专项审查与优化报告入库（同步域五轮 + 性能与 UX + 桌面开机自启动探索）；`docs/07`
  竞品 backlog：50 项基线收口后新增的 #51–#63（开机自启动、移动端对标 P0/P1、
  修改后立即同步、日历更新时刻、桌面补齐批次等）亦全部落地，见上文 dated 条目。

### 破坏性口径与明确不做

- 移除 `todo_tasks.end_date`（迁移 / 模型 / 仓储 / CSV / FRB / 双端 UI 全链路收窄）。
- 迁移文件合并为单文件 `0001_init.sql`（多轮并回；**存量库升级口径 = 删库重初始化**）。
- 仓库重组：`orbit_core` → `orbit-core`、`flutter-plugin-orbit` → `orbit-flutter`、
  pnpm lockfile 上收仓库根、React 移动端移除（移动端改由 Flutter 承载）；云同步去 V2 化
  （存储结构重构即初始版本）。
- 明确不做：协作 / 指派、番茄钟 / 习惯追踪、i18n / Web 版、自动更新轮询（更新时机归用户）。
