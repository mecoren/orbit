use rand::RngCore;

/// 生成密码学安全随机字节
///
/// 与 Dart `KeyDerivation.randomBytes` 行为一致。
pub fn random_bytes(len: usize) -> Vec<u8> {
    let mut out = vec![0u8; len];
    rand::thread_rng().fill_bytes(&mut out);
    out
}
