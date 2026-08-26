use subtle::ConstantTimeEq;

/// 常量时间字节比较，防止时序攻击
///
/// 与 Dart `CryptoServiceImpl._constantTimeEquals` 行为一致，
/// 但使用 subtle crate 的审计过实现。
pub fn constant_time_equals(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.ct_eq(b).into()
}
