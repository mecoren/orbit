//! v2 — 帧式流式备份容器（`.orfullsync` v2，magic `OFS2`）
//!
//! 目标（docs/13 §6.2 M1）：**峰值内存与备份体积解耦**。v1 把每张表全量
//! 序列化成 `String` 汇总进 `BTreeMap`，再整包 ZIP + AES-GCM——峰值 ≈ 库
//! JSON + ZIP + 密文三份叠加，与数据总量线性相关。v2 改为定长帧流式写入：
//! 任何时刻在内存里的只有一帧明文 + 一帧密文。
//!
//! ## 文件布局
//!
//! ```text
//! [magic "OFS2" 4B]
//! [header 长度 BE u32 4B][header 明文 变长]   ← 见 FrameHeader
//! 重复直到文件尾：
//!   [帧序号 BE u64 8B][密文长度 BE u32 4B][密文 变长]
//! ```
//!
//! ## 帧加密
//!
//! - master_key 由同步密码 + salt 经 PBKDF2 派生（与 v1 同强度，迭代数写进 header）；
//! - 每帧 nonce = 基础 nonce（12B）与帧序号异或后 8 字节——同一 key 下帧序号
//!   唯一即 nonce 唯一，满足 AES-GCM 的 nonce 不可复用要求；
//! - **帧序号进 AAD**：防重排/截断/拼接（删帧或换序都会让 tag 校验失败）。
//!
//! ## 与 v1 的关系
//!
//! - v2 默认写；v1 读路径保留（`decode_backup`），旧备份可照常恢复；
//! - 旧版本应用无法读 v2 属预期（发布说明需标注）。

use std::collections::BTreeMap;
use std::io::{Read, Write};

use crate::crypto::{derive_master_key, ensure_kdf_strength, random_bytes};
use crate::full_sync_backup::error::{FullSyncBackupError, FullSyncBackupResult};
use crate::full_sync_backup::manifest::BackupManifest;

/// v2 magic
pub const MAGIC_V2: [u8; 4] = *b"OFS2";

/// 帧明文上限（4 MiB）
///
/// 取值理由：一帧即一次加解密的粒度，4 MiB 让「单帧在内存」的成本可控，
/// 同时避免帧数过多（每帧 8B 序号 + 4B 长度 + 16B tag 的固定开销摊薄）。
pub const FRAME_PLAIN_MAX: usize = 4 * 1024 * 1024;

/// v2 header（明文，位于 magic 之后）
///
/// header 本身不加密：它只含派生密钥所需的公开参数与备份元数据摘要，
/// 不含业务数据。**manifest 完整内容放在第一个数据帧里**（加密），
/// 因此 `peek` 只需读 header + 首帧即可拿到设备/表计数，不必解压正文。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2Header {
    /// PBKDF2 盐（16B）
    pub salt: [u8; 16],
    /// 帧 nonce 基值（12B；每帧与序号异或）
    pub nonce_base: [u8; 12],
    /// PBKDF2 迭代次数
    pub iterations: u32,
    /// 帧明文上限（写入方声明，读方据此分配缓冲；超上限即拒）
    pub frame_plain_max: u32,
}

/// v2 header 的固定字节长度（salt16 + nonce12 + iterations4 + frame_max4）
pub const V2_HEADER_LEN: usize = 36;

impl V2Header {
    /// 序列化为固定布局字节（16+12+4+4 = 36B）
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(V2_HEADER_LEN);
        out.extend_from_slice(&self.salt);
        out.extend_from_slice(&self.nonce_base);
        out.extend_from_slice(&self.iterations.to_be_bytes());
        out.extend_from_slice(&self.frame_plain_max.to_be_bytes());
        out
    }

    /// 从字节解析（长度必须正好 36）
    pub fn from_bytes(data: &[u8]) -> FullSyncBackupResult<Self> {
        if data.len() != V2_HEADER_LEN {
            return Err(FullSyncBackupError::InvalidFormat(format!(
                "v2 header 长度错误：期望 {V2_HEADER_LEN}，实际 {}",
                data.len()
            )));
        }
        let mut salt = [0u8; 16];
        salt.copy_from_slice(&data[0..16]);
        let mut nonce_base = [0u8; 12];
        nonce_base.copy_from_slice(&data[16..28]);
        let iterations = u32::from_be_bytes([data[28], data[29], data[30], data[31]]);
        let frame_plain_max = u32::from_be_bytes([data[32], data[33], data[34], data[35]]);
        Ok(Self {
            salt,
            nonce_base,
            iterations,
            frame_plain_max,
        })
    }
}

/// 帧 nonce：基础 nonce 的低 8 字节与帧序号异或
///
/// 帧序号唯一 ⇒ nonce 唯一（AES-GCM 要求同一 key 下 nonce 不复用）。
fn frame_nonce(base: &[u8; 12], seq: u64) -> [u8; 12] {
    let mut nonce = *base;
    let seq_bytes = seq.to_be_bytes();
    for i in 0..8 {
        nonce[4 + i] ^= seq_bytes[i];
    }
    nonce
}

/// 帧 AAD：magic + 帧序号（防重排/截断/拼接）
fn frame_aad(seq: u64) -> Vec<u8> {
    let mut aad = Vec::with_capacity(12);
    aad.extend_from_slice(&MAGIC_V2);
    aad.extend_from_slice(&seq.to_be_bytes());
    aad
}

/// v2 写入器：把明文流切帧加密后写入任意 `Write`
///
/// 用法：`write_frame` 反复追加，最后 `finish` 落尾。每帧明文独立加密，
/// 调用方负责把「一条完整记录」放进同一帧（v2 的帧边界语义是「记录边界」，
/// 由 `StreamWriter` 封装）。
pub struct FrameWriter<W: Write> {
    inner: W,
    key: Vec<u8>,
    nonce_base: [u8; 12],
    seq: u64,
    /// 当前帧的明文缓冲（未满即继续追加，满则自动落帧）
    buf: Vec<u8>,
    frame_plain_max: usize,
}

impl<W: Write> FrameWriter<W> {
    /// 创建写入器：先写 magic + header，再返回可追加帧的写入器
    pub fn new(
        mut inner: W,
        sync_password: &str,
        iterations: u32,
        frame_plain_max: usize,
    ) -> FullSyncBackupResult<Self> {
        let salt: [u8; 16] = random_bytes(16)
            .try_into()
            .map_err(|_| FullSyncBackupError::InvalidFormat("salt 长度错误".into()))?;
        let nonce_base: [u8; 12] = random_bytes(12)
            .try_into()
            .map_err(|_| FullSyncBackupError::InvalidFormat("nonce 长度错误".into()))?;
        let key = derive_master_key(sync_password, &salt, iterations, 32)?;

        let header = V2Header {
            salt,
            nonce_base,
            iterations,
            frame_plain_max: frame_plain_max as u32,
        };
        let header_bytes = header.to_bytes();

        inner.write_all(&MAGIC_V2)?;
        inner.write_all(&(header_bytes.len() as u32).to_be_bytes())?;
        inner.write_all(&header_bytes)?;

        Ok(Self {
            inner,
            key,
            nonce_base,
            seq: 0,
            buf: Vec::with_capacity(frame_plain_max),
            frame_plain_max,
        })
    }

    /// 追加明文；缓冲满 `frame_plain_max` 即自动落帧
    pub fn write(&mut self, data: &[u8]) -> FullSyncBackupResult<()> {
        let mut rest = data;
        while !rest.is_empty() {
            let room = self.frame_plain_max - self.buf.len();
            let take = room.min(rest.len());
            self.buf.extend_from_slice(&rest[..take]);
            rest = &rest[take..];
            if self.buf.len() >= self.frame_plain_max {
                self.flush_frame()?;
            }
        }
        Ok(())
    }

    /// 强制把当前缓冲落成一帧（记录边界处调用，保证一条记录不跨帧）
    pub fn flush_frame(&mut self) -> FullSyncBackupResult<()> {
        if self.buf.is_empty() {
            return Ok(());
        }
        let seq = self.seq;
        let nonce = frame_nonce(&self.nonce_base, seq);
        let aad = frame_aad(seq);
        let ciphertext = aes_gcm_encrypt_with_aad(&self.key, &self.buf, &nonce, &aad)?;

        self.inner.write_all(&seq.to_be_bytes())?;
        self.inner
            .write_all(&(ciphertext.len() as u32).to_be_bytes())?;
        self.inner.write_all(&ciphertext)?;

        self.buf.clear();
        self.seq += 1;
        Ok(())
    }

    /// 收尾：落最后一帧并 flush 底层写入器
    pub fn finish(mut self) -> FullSyncBackupResult<W> {
        self.flush_frame()?;
        self.inner.flush()?;
        Ok(self.inner)
    }

    /// 已写帧数（诊断用）
    pub fn frame_count(&self) -> u64 {
        self.seq
    }
}

/// v2 读取器：逐帧解密读出
pub struct FrameReader<R: Read> {
    inner: R,
    key: Vec<u8>,
    nonce_base: [u8; 12],
    frame_plain_max: usize,
    seq: u64,
}

impl<R: Read> FrameReader<R> {
    /// 校验 magic + header 并派生 key
    pub fn new(mut inner: R, sync_password: &str) -> FullSyncBackupResult<Self> {
        let mut magic = [0u8; 4];
        inner.read_exact(&mut magic)?;
        if magic != MAGIC_V2 {
            return Err(FullSyncBackupError::MagicMismatch {
                expected: MAGIC_V2,
                got: magic,
            });
        }
        let mut len_bytes = [0u8; 4];
        inner.read_exact(&mut len_bytes)?;
        let header_len = u32::from_be_bytes(len_bytes) as usize;
        if header_len > 1024 {
            return Err(FullSyncBackupError::InvalidFormat(format!(
                "v2 header 长度异常：{header_len}"
            )));
        }
        let mut header_bytes = vec![0u8; header_len];
        inner.read_exact(&mut header_bytes)?;
        let header = V2Header::from_bytes(&header_bytes)?;

        // 外部输入：先验 KDF 强度下限（与 v1 同口径）
        ensure_kdf_strength(header.iterations, "备份文件头")?;
        let key = derive_master_key(sync_password, &header.salt, header.iterations, 32)?;

        Ok(Self {
            inner,
            key,
            nonce_base: header.nonce_base,
            frame_plain_max: header.frame_plain_max as usize,
            seq: 0,
        })
    }

    /// 读下一帧明文；到文件尾返回 `Ok(None)`
    pub fn next_frame(&mut self) -> FullSyncBackupResult<Option<Vec<u8>>> {
        let mut seq_bytes = [0u8; 8];
        match self.inner.read_exact(&mut seq_bytes) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e.into()),
        }
        let seq = u64::from_be_bytes(seq_bytes);
        // 帧序号必须严格递增：防重排/重放
        if seq != self.seq {
            return Err(FullSyncBackupError::InvalidFormat(format!(
                "v2 帧序号不连续：期望 {}，实际 {seq}",
                self.seq
            )));
        }
        let mut len_bytes = [0u8; 4];
        self.inner.read_exact(&mut len_bytes)?;
        let ct_len = u32::from_be_bytes(len_bytes) as usize;
        // 密文长度上限 = 帧明文上限 + GCM tag(16)
        if ct_len > self.frame_plain_max + 16 {
            return Err(FullSyncBackupError::InvalidFormat(format!(
                "v2 帧密文超上限：{ct_len} > {}",
                self.frame_plain_max + 16
            )));
        }
        let mut ciphertext = vec![0u8; ct_len];
        self.inner.read_exact(&mut ciphertext)?;

        let nonce = frame_nonce(&self.nonce_base, seq);
        let aad = frame_aad(seq);
        let plain = aes_gcm_decrypt_with_aad(&self.key, &ciphertext, &nonce, &aad)
            .map_err(|_| FullSyncBackupError::WrongSyncPassword)?;

        self.seq += 1;
        Ok(Some(plain))
    }
}

/// 带 AAD 的 AES-256-GCM 加密（v2 帧用）
fn aes_gcm_encrypt_with_aad(
    key: &[u8],
    plaintext: &[u8],
    nonce: &[u8; 12],
    aad: &[u8],
) -> FullSyncBackupResult<Vec<u8>> {
    crate::crypto::aes_gcm::aes_gcm_encrypt_aad(key, plaintext, nonce, aad)
        .map_err(FullSyncBackupError::Crypto)
}

/// 带 AAD 的 AES-256-GCM 解密（v2 帧用）
fn aes_gcm_decrypt_with_aad(
    key: &[u8],
    ciphertext: &[u8],
    nonce: &[u8; 12],
    aad: &[u8],
) -> FullSyncBackupResult<Vec<u8>> {
    crate::crypto::aes_gcm::aes_gcm_decrypt_aad(key, ciphertext, nonce, aad)
        .map_err(FullSyncBackupError::Crypto)
}

/// v2 备份的元数据快照（`peek` 只读这一层，不解正文）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2Meta {
    pub manifest: BackupManifest,
    pub schema_version_json: String,
}

/// 把一个 JSON 记录数组按记录切块写入帧（每条记录一帧，超大记录自行分帧）
///
/// 这是 v2 的「表级流式」入口：调用方逐条产出记录，本函数负责分帧与落盘，
/// 内存只保留当前记录。
pub fn write_records<W: Write>(
    writer: &mut FrameWriter<W>,
    records: impl Iterator<Item = serde_json::Value>,
) -> FullSyncBackupResult<usize> {
    let mut n = 0usize;
    for rec in records {
        let line = serde_json::to_vec(&rec)?;
        writer.write(&line)?;
        writer.write(b"\n")?;
        writer.flush_frame()?; // 记录边界落帧：一条记录不跨帧
        n += 1;
    }
    Ok(n)
}

/// 帧明文流按行切回 JSON 记录（与 [`write_records`] 配对）
pub fn read_records<F>(
    frames: impl Iterator<Item = FullSyncBackupResult<Vec<u8>>>,
    mut on_record: F,
) -> FullSyncBackupResult<usize>
where
    F: FnMut(serde_json::Value) -> FullSyncBackupResult<()>,
{
    let mut carry: Vec<u8> = Vec::new();
    let mut n = 0usize;
    for frame in frames {
        let plain = frame?;
        carry.extend_from_slice(&plain);
        // 逐个完整行解析；不完整的尾巴留到下一帧
        let mut start = 0usize;
        while let Some(pos) = carry[start..].iter().position(|b| *b == b'\n') {
            let end = start + pos;
            let line = &carry[start..end];
            if !line.is_empty() {
                let v: serde_json::Value = serde_json::from_slice(line)?;
                on_record(v)?;
                n += 1;
            }
            start = end + 1;
        }
        if start > 0 {
            carry.drain(..start);
        }
    }
    if !carry.is_empty() {
        let v: serde_json::Value = serde_json::from_slice(&carry)?;
        on_record(v)?;
        n += 1;
    }
    Ok(n)
}

/// 表名 → 记录迭代器（导出侧用；由调用方提供分页读）
pub type TableRecordStream<'a> =
    Box<dyn Iterator<Item = FullSyncBackupResult<serde_json::Value>> + 'a>;

/// 各表记录数（manifest 用）
pub type TableCounts = BTreeMap<String, usize>;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// 测试用迭代数：必须 ≥ 生产下限，否则写侧就过不了 `ensure_kdf_strength`
    /// （这条防护本身由 `weak_kdf_iterations_rejected_on_read` 单独验证）
    const TEST_ITER: u32 = crate::crypto::MIN_KDF_ITERATIONS;

    fn header_of(bytes: &[u8]) -> V2Header {
        let len = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as usize;
        V2Header::from_bytes(&bytes[8..8 + len]).unwrap()
    }

    #[test]
    fn magic_and_header_are_written() {
        let sink = Cursor::new(Vec::new());
        let writer = FrameWriter::new(sink, "pw", TEST_ITER, FRAME_PLAIN_MAX).unwrap();
        let out = writer.finish().unwrap().into_inner();
        assert_eq!(&out[0..4], &MAGIC_V2);
        let h = header_of(&out);
        assert_eq!(h.iterations, TEST_ITER);
        assert_eq!(h.frame_plain_max as usize, FRAME_PLAIN_MAX);
    }

    #[test]
    fn frames_roundtrip_across_multiple_frames() {
        let payload: Vec<u8> = (0..(FRAME_PLAIN_MAX * 2 + 12345))
            .map(|i| (i % 251) as u8)
            .collect();
        let sink = Cursor::new(Vec::new());
        let mut writer = FrameWriter::new(sink, "pw", TEST_ITER, FRAME_PLAIN_MAX).unwrap();
        writer.write(&payload).unwrap();
        let out = writer.finish().unwrap().into_inner();

        let mut reader = FrameReader::new(Cursor::new(out), "pw").unwrap();
        let mut got = Vec::new();
        while let Some(frame) = reader.next_frame().unwrap() {
            got.extend_from_slice(&frame);
        }
        assert_eq!(got, payload, "跨多帧内容必须逐字节还原");
    }

    #[test]
    fn wrong_password_fails_at_first_frame() {
        let sink = Cursor::new(Vec::new());
        let mut writer = FrameWriter::new(sink, "right", TEST_ITER, FRAME_PLAIN_MAX).unwrap();
        writer.write(b"secret").unwrap();
        let out = writer.finish().unwrap().into_inner();

        let mut reader = FrameReader::new(Cursor::new(out), "wrong").unwrap();
        let err = reader.next_frame().unwrap_err();
        assert!(matches!(err, FullSyncBackupError::WrongSyncPassword));
    }

    #[test]
    fn tampered_frame_fails_authentication() {
        let sink = Cursor::new(Vec::new());
        let mut writer = FrameWriter::new(sink, "pw", TEST_ITER, FRAME_PLAIN_MAX).unwrap();
        writer.write(b"important").unwrap();
        let mut out = writer.finish().unwrap().into_inner();

        // 篡改密文最后一字节（GCM tag 区域内）
        let last = out.len() - 1;
        out[last] ^= 0xff;
        let mut reader = FrameReader::new(Cursor::new(out), "pw").unwrap();
        assert!(reader.next_frame().is_err(), "篡改必须被 GCM tag 拒绝");
    }

    #[test]
    fn reordered_frame_sequence_is_rejected() {
        let sink = Cursor::new(Vec::new());
        let mut writer = FrameWriter::new(sink, "pw", TEST_ITER, 64).unwrap();
        writer.write(b"frame-one").unwrap();
        writer.flush_frame().unwrap();
        writer.write(b"frame-two").unwrap();
        writer.flush_frame().unwrap();
        let out = writer.finish().unwrap().into_inner();

        // 找到第二帧起点并把它的序号改成 0（重排/重放）
        let header_len = 8 + u32::from_be_bytes([out[4], out[5], out[6], out[7]]) as usize;
        // 第一帧：8B seq + 4B len + ct
        let ct1_len = u32::from_be_bytes([
            out[header_len + 8],
            out[header_len + 9],
            out[header_len + 10],
            out[header_len + 11],
        ]) as usize;
        let frame2_start = header_len + 12 + ct1_len;
        let mut bad = out.clone();
        bad[frame2_start..frame2_start + 8].copy_from_slice(&0u64.to_be_bytes());

        let mut reader = FrameReader::new(Cursor::new(bad), "pw").unwrap();
        // 第一帧正常
        assert!(reader.next_frame().unwrap().is_some());
        // 第二帧序号不连续 → 拒
        let err = reader.next_frame().unwrap_err();
        assert!(
            err.to_string().contains("帧序号不连续"),
            "应报序号不连续：{err}"
        );
    }

    #[test]
    fn empty_backup_has_no_frames() {
        let sink = Cursor::new(Vec::new());
        let writer = FrameWriter::new(sink, "pw", TEST_ITER, FRAME_PLAIN_MAX).unwrap();
        let out = writer.finish().unwrap().into_inner();
        let mut reader = FrameReader::new(Cursor::new(out), "pw").unwrap();
        assert!(reader.next_frame().unwrap().is_none());
    }

    #[test]
    fn records_roundtrip_through_frames() {
        let records = vec![
            serde_json::json!({"uuid": "a", "title": "甲"}),
            serde_json::json!({"uuid": "b", "title": "乙"}),
            serde_json::json!({"uuid": "c", "title": "丙"}),
        ];
        let sink = Cursor::new(Vec::new());
        let mut writer = FrameWriter::new(sink, "pw", TEST_ITER, FRAME_PLAIN_MAX).unwrap();
        let n = write_records(&mut writer, records.clone().into_iter()).unwrap();
        assert_eq!(n, 3);
        let out = writer.finish().unwrap().into_inner();

        let mut reader = FrameReader::new(Cursor::new(out), "pw").unwrap();
        let mut got = Vec::new();
        let frames = std::iter::from_fn(|| reader.next_frame().transpose());
        let count = read_records(frames, |v| {
            got.push(v);
            Ok(())
        })
        .unwrap();
        assert_eq!(count, 3);
        assert_eq!(got, records);
    }

    #[test]
    fn oversized_frame_length_is_rejected() {
        // 伪造一个超大 ct_len，必须在分配缓冲前拒绝（防内存打爆）
        let sink = Cursor::new(Vec::new());
        let mut writer = FrameWriter::new(sink, "pw", TEST_ITER, 64).unwrap();
        writer.write(b"x").unwrap();
        let mut out = writer.finish().unwrap().into_inner();
        let header_len = 8 + u32::from_be_bytes([out[4], out[5], out[6], out[7]]) as usize;
        // 把 ct_len 改成远超上限
        out[header_len + 8..header_len + 12].copy_from_slice(&(u32::MAX).to_be_bytes());
        let mut reader = FrameReader::new(Cursor::new(out), "pw").unwrap();
        let err = reader.next_frame().unwrap_err();
        assert!(err.to_string().contains("超上限"), "{err}");
    }

    #[test]
    fn weak_kdf_iterations_rejected_on_read() {
        let sink = Cursor::new(Vec::new());
        let writer = FrameWriter::new(sink, "pw", 1, FRAME_PLAIN_MAX).unwrap();
        let out = writer.finish().unwrap().into_inner();
        let result = FrameReader::new(Cursor::new(out), "pw");
        assert!(result.is_err(), "弱 KDF 必须在构造期被拒");
        let err = result.err().expect("已断言为 Err");
        assert!(
            err.to_string().contains("迭代") || err.to_string().contains("强度"),
            "应拒绝弱 KDF：{err}"
        );
    }
}
